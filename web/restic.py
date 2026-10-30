"""Read snapshots and restore files with restic, for the web UI.

All paths shown to the user are relative to the MEGA folder (engine.CURRENT).
User input (snapshot IDs, paths) is validated here and only ever passed to restic
as separate arguments, never through a shell.
"""
import datetime
import os
import posixpath
import re
import subprocess

import engine

HOST = "mega-backup"          # same as RESTIC_HOST in lib.sh
LOCK_WAIT = "30s"             # wait this long for a lock held by a backup/prune
LIST_LIMIT = 2000             # entries shown per folder

_ID = re.compile(r"[0-9a-f]{8,64}")


class ResticError(Exception):
    pass


def restore_dir():
    return os.environ.get("MB_RESTORE", "/data/restore")


def _run(args, timeout=120):
    try:
        p = subprocess.run(["restic", "--retry-lock", LOCK_WAIT, *args], cwd="/tmp",
                           capture_output=True, text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ResticError("restic took too long. Try again later.") from None
    if p.returncode != 0:
        msg = (p.stderr or p.stdout).strip().splitlines()
        raise ResticError(msg[-1] if msg else f"restic failed (code {p.returncode}).")
    return p.stdout


def _jsonl(text):
    import json
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def _time(iso):
    """restic time (RFC 3339, nanoseconds) -> aware datetime in local time."""
    iso = re.sub(r"(\.\d{6})\d+", r"\1", iso).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(iso).astimezone()


def check_rel(rel):
    """Normalize a user-supplied path inside the MEGA folder ("" = the folder itself)."""
    rel = (rel or "").strip("/")
    if not rel:
        return ""
    if "\x00" in rel or any(part in ("", ".", "..") for part in rel.split("/")):
        raise ResticError("Invalid path.")
    return posixpath.normpath(rel)


def abs_path(rel):
    return engine.CURRENT.rstrip("/") + ("/" + rel if rel else "")


def snapshots():
    """Snapshots of the MEGA folder, newest first."""
    import json
    data = json.loads(_run(["snapshots", "--json", "--host", HOST, "--path", engine.CURRENT]) or "[]")
    out = []
    for s in data:
        summ = s.get("summary") or {}
        out.append({
            "id": s["id"], "short_id": s["short_id"], "time": _time(s["time"]),
            "tags": s.get("tags") or [],
            "files": summ.get("total_files_processed"),
            "size": summ.get("total_bytes_processed"),
            "added": summ.get("data_added"),
        })
    out.sort(key=lambda s: s["time"], reverse=True)
    return out


def find(snap_id, snaps=None):
    """The snapshot with this (short or full) ID, and the one before it."""
    if not _ID.fullmatch(snap_id or ""):
        raise ResticError("Invalid snapshot ID.")
    snaps = snaps if snaps is not None else snapshots()
    for i, s in enumerate(snaps):
        if s["id"].startswith(snap_id):
            return s, (snaps[i + 1] if i + 1 < len(snaps) else None)
    raise ResticError("No such snapshot.")


def ls(snap, rel):
    """Direct contents of a folder in a snapshot: (entries, truncated)."""
    target = abs_path(rel)
    entries = []
    for n in _jsonl(_run(["ls", "--json", snap["id"], target])):
        if n.get("struct_type") != "node" or n.get("path") == target:
            continue
        path = n["path"]
        if posixpath.dirname(path) != target:
            continue
        entries.append({
            "name": n["name"], "type": n["type"],
            "rel": path[len(engine.CURRENT.rstrip("/")) + 1:],
            "size": n.get("size"),
            "mtime": _time(n["mtime"]) if n.get("mtime") else None,
        })
    entries.sort(key=lambda e: (e["type"] != "dir", e["name"].lower()))
    return entries[:LIST_LIMIT], len(entries) > LIST_LIMIT


def node(snap, rel):
    """The ls() entry for a path in a snapshot (None for the MEGA folder itself)."""
    if not rel:
        return None
    parent, name = posixpath.split(rel)
    for e in ls(snap, parent)[0]:
        if e["name"] == name:
            return e
    raise ResticError("Not found in this snapshot.")


def node_type(snap, rel):
    """"dir", "file", ... for a path in a snapshot; raises if missing."""
    e = node(snap, rel)
    return e["type"] if e else "dir"


def diff(old, new, limit=1000):
    """Changes from snapshot old to new: (changes, stats, truncated)."""
    changes, stats = [], None
    base = engine.CURRENT.rstrip("/") + "/"
    for m in _jsonl(_run(["diff", "--json", old["id"], new["id"]], timeout=600)):
        if m.get("message_type") == "change":
            changes.append({"mod": m["modifier"],
                            "rel": m["path"][len(base):] if m["path"].startswith(base) else m["path"]})
        elif m.get("message_type") == "statistics":
            stats = {"added": m["added"]["files"], "removed": m["removed"]["files"],
                     "changed": m["changed_files"]}
    changes.sort(key=lambda c: c["rel"])
    return changes[:limit], stats, len(changes) > limit


def dump(snap, rel):
    """Yield a file's content from a snapshot in chunks (for downloads)."""
    p = subprocess.Popen(["restic", "--retry-lock", LOCK_WAIT, "dump", snap["id"], abs_path(rel)],
                         cwd="/tmp", stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        while True:
            chunk = p.stdout.read(256 * 1024)
            if not chunk:
                break
            yield chunk
        if p.wait() != 0:
            raise ResticError("restic could not read the file from the snapshot.")
    finally:
        if p.poll() is None:
            p.kill()
        p.wait()


def restore(snap, rel):
    """Restore a file or folder into a new sub-folder of the Restore folder.

    Never overwrites: the sub-folder is new for every restore. Returns its name.
    """
    entry = node(snap, rel)
    kind = entry["type"] if entry else "dir"
    name = posixpath.basename(rel) or "everything"
    safe = re.sub(r"[^\w.-]+", "_", name).strip("._")[:60] or "item"
    stamp = snap["time"].strftime("%Y-%m-%d_%H%M")
    folder = f"restore_{stamp}_{snap['short_id']}_{safe}"
    target = os.path.join(restore_dir(), folder)
    n = 1
    while os.path.exists(target):
        n += 1
        target = os.path.join(restore_dir(), f"{folder}_{n}")
    os.makedirs(target)
    if kind == "dir":
        _run(["restore", f"{snap['id']}:{abs_path(rel)}", "--target", target], timeout=None)
    elif kind == "file":
        # `restic dump` is exact for a single file (no --include pattern matching).
        path = os.path.join(target, name)
        with open(path, "wb") as f:
            for chunk in dump(snap, rel):
                f.write(chunk)
        if entry.get("mtime"):
            # Keep the file's original date, as `restic restore` does for folders.
            t = entry["mtime"].timestamp()
            os.utime(path, (t, t))
    else:
        raise ResticError("Only files and folders can be restored.")
    return os.path.basename(target)
