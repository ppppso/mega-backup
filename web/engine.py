"""Read-only view of the engine for the web UI: mounts, MEGAcmd, state files.

Every MEGAcmd client call first checks that mega-cmd-server is running: a client
started without a server would start a second server.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import threading
import time

CURRENT = os.environ.get("MB_CURRENT", "/data/current")
REPO = os.environ.get("RESTIC_REPOSITORY", "/data/repo")
RESTORE = "/data/restore"


def config_dir():
    return os.environ.get("MB_CONFIG", "/config")


def cfg(name):
    return os.path.join(config_dir(), name)


# --- mounts ----------------------------------------------------------------

def _mountinfo():
    """{mount point: (device, root)} from /proc/self/mountinfo."""
    out = {}
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 5:
                    point = parts[4].replace("\\040", " ")
                    out[point] = (parts[2], parts[3].replace("\\040", " "))
    except OSError:
        pass
    return out


def mount_ok(path):
    if os.environ.get("MB_REQUIRE_MOUNTS", "1") != "1":
        return True
    return path in _mountinfo()


def mounts_overlap(a, b):
    """Same logic as mounts_overlap in lib.sh."""
    info = _mountinfo()
    if a not in info or b not in info:
        return False
    (dev_a, root_a), (dev_b, root_b) = info[a], info[b]
    if dev_a != dev_b:
        return False
    return (root_a == "/" or root_b == "/" or root_a == root_b
            or root_a.startswith(root_b + "/") or root_b.startswith(root_a + "/"))


def dir_is_empty(path):
    """Like dir_is_empty in lib.sh: missing, or nothing but .debris."""
    try:
        return all(e == ".debris" for e in os.listdir(path))
    except FileNotFoundError:
        return True


def disk(path):
    try:
        u = shutil.disk_usage(path)
        return {"total": u.total, "free": u.free}
    except OSError:
        return None


# --- MEGAcmd ---------------------------------------------------------------

def server_running():
    return subprocess.run(["pgrep", "-x", "mega-cmd-server"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def mega(*args, timeout=30):
    """Run a mega-* client. Returns (exit code, output). None if no server."""
    if not server_running():
        return None
    try:
        p = subprocess.run(list(args), cwd="/tmp", capture_output=True, text=True,
                           timeout=timeout, errors="replace")
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "MEGAcmd did not answer in time."
    except OSError as e:
        return 127, str(e)


_cache = {}
_cache_lock = threading.Lock()


def cached(key, seconds, fn):
    """Small time-based cache, so several open tabs don't flood MEGAcmd."""
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < seconds:
            return hit[1]
    value = fn()
    with _cache_lock:
        _cache[key] = (now, value)
    return value


def clear_cache():
    with _cache_lock:
        _cache.clear()


def whoami():
    """The logged-in email, "" if logged out, None if MEGAcmd isn't running."""
    def get():
        r = mega("mega-whoami")
        if r is None:
            return None
        rc, out = r
        if rc != 0:
            return ""
        m = re.search(r"[^\s:]+@[^\s]+", out)
        return m.group(0) if m else out.splitlines()[0] if out else ""
    return cached("whoami", 5, get)


def sync_rows():
    """All syncs as {local path: row dict}, None if MEGAcmd isn't running."""
    def get():
        r = mega("mega-sync", "--col-separator=|",
                 "--output-cols=LOCALPATH,RUN_STATE,STATUS,ERROR,REMOTEPATH")
        if r is None:
            return None
        rc, out = r
        if rc != 0:
            return None
        rows = {}
        for line in out.splitlines():
            cols = [c.strip() for c in line.split("|")]
            if len(cols) >= 5 and cols[0] != "LOCALPATH":
                rows[cols[0].rstrip("/") or "/"] = {
                    "run_state": cols[1], "status": cols[2], "error": cols[3], "remote": cols[4]}
        return rows
    return cached("sync", 5, get)


def sync_row(path=None):
    """The sync for a local path (default CURRENT): dict, {} if none, None if unknown."""
    rows = sync_rows()
    if rows is None:
        return None
    return rows.get((path or CURRENT).rstrip("/"), {})


def pair_dir(name):
    return os.path.join(CURRENT, name)


def pairs_problems():
    """{pair name: problem} from the engine's last check of the syncs."""
    data = read_json("pairs-status.json") or {}
    return data.get("problems") or {}


def guard_empty():
    """Folders that the start-up guard holds back: [(name, marker file)]. Name "" is
    the whole MEGA folder (single-folder setup)."""
    out = []
    if os.path.exists(cfg("sync-established")) and dir_is_empty(CURRENT):
        out.append(("", cfg("sync-established")))
    state = cfg("pair-state")
    try:
        names = sorted(f[:-len(".established")] for f in os.listdir(state) if f.endswith(".established"))
    except OSError:
        names = []
    for name in names:
        if dir_is_empty(pair_dir(name)):
            out.append((name, os.path.join(state, name + ".established")))
    return out


def other_items(names):
    """Entries in the MEGA folder that belong to no folder pair (not synced)."""
    try:
        entries = os.listdir(CURRENT)
    except OSError:
        return []
    skip = set(names) | {".debris", ".mb-migrating"}
    return sorted(e for e in entries if e not in skip)


# ls -l line: FLAGS VERS SIZE DATE NAME (format from MEGAcmd's dumpNodeSummary).
_LS_LINE = re.compile(r"^(\S{4})\s+(\S+)\s+(\S+)\s+(\S+) (.+)$")


def list_folders(path):
    """Sub-folder names of a MEGA path. Raises RuntimeError with MEGA's message."""
    r = mega("mega-ls", "-l", "--time-format=ISO6081_WITH_TIME", path, timeout=60)
    if r is None:
        raise RuntimeError("MEGAcmd is not running yet.")
    rc, out = r
    if rc != 0:
        raise RuntimeError(out or f"mega-ls failed (code {rc}).")
    names = []
    for line in out.splitlines():
        m = _LS_LINE.match(line)
        if m and m.group(1)[0] == "d":
            names.append(m.group(5))
    return sorted(names, key=str.lower)


def sync_words(row, who):
    """Plain-words sync state: (level, text). level is ok / busy / bad / off."""
    if who is None:
        return "off", "MEGAcmd is not running."
    if who == "":
        return "bad", "Not logged in to MEGA."
    if row is None:
        return "bad", "Cannot read the sync state from MEGAcmd."
    if not row:
        return "off", "No sync set up yet."
    if row["run_state"] != "Running" or row["error"] not in ("NO", ""):
        return "bad", f"Sync problem: {row['run_state']}, error: {row['error']}."
    status = row["status"]
    if status == "Synced":
        return "ok", "In sync."
    if status in ("Syncing", "Pending", "Processing"):
        return "busy", f"Syncing ({status.lower()})…"
    return "busy", f"Sync state: {status}."


# --- state files -----------------------------------------------------------

def read_json(name):
    try:
        with open(cfg(name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def prune_hold():
    try:
        with open(cfg("prune-hold")) as f:
            return f.read()
    except OSError:
        return None


def backup_running():
    """True if backup.sh holds its lock."""
    try:
        fd = os.open(cfg("backup.lock"), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def restic_password():
    path = os.environ.get("RESTIC_PASSWORD_FILE", cfg("restic-password"))
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def log_tail(lines=500):
    """Last lines of the app log, oldest first."""
    path = cfg("logs/app.log")
    chunks = []
    for p in (path + ".1", path):
        try:
            with open(p, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 200_000))
                chunks.append(f.read().decode("utf-8", "replace"))
        except OSError:
            pass
    return "".join(chunks).splitlines()[-lines:]
