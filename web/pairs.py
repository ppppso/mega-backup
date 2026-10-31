"""Folder pairs: /config/pairs.json (format in scripts/lib.sh).

Each pair syncs one MEGA folder with <MEGA folder>/<name>. The web UI adds and
removes pairs here; the engine (scripts/pairs.sh) creates and removes the syncs.
Every change holds pairs.lock, which the engine's one-time migration also takes.
"""
import contextlib
import datetime
import fcntl
import json
import os
import re
import tempfile

# Same rule as PAIR_NAME_RE in scripts/lib.sh.
NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9 _.()-]{0,59}")


def config_dir():
    return os.environ.get("MB_CONFIG", "/config")


def path():
    return os.path.join(config_dir(), "pairs.json")


def valid_name(name):
    return bool(NAME_RE.fullmatch(name or "")) and not name.endswith(" ")


def valid_remote(remote):
    return (isinstance(remote, str) and remote.startswith("/")
            and not any(ord(c) < 32 for c in remote) and ".." not in remote.split("/"))


def norm_remote(remote):
    return remote.rstrip("/") or "/"


def suggest_name(remote):
    """A folder name for a MEGA path, like pair_name_for in pairs.sh."""
    base = norm_remote(remote).rsplit("/", 1)[-1]
    base = re.sub(r"[^A-Za-z0-9 _.()-]", "_", base)
    base = re.sub(r"^[^A-Za-z0-9_]+", "", base).rstrip(" ")[:60]
    return base or "MEGA"


def nested(a, b):
    """True if MEGA paths a and b are the same or one is inside the other."""
    a, b = norm_remote(a), norm_remote(b)
    return a == b or a == "/" or b == "/" or a.startswith(b + "/") or b.startswith(a + "/")


def read():
    """The file's content: {"pairs": [...], "removed": [...]}, or None if it doesn't
    exist. Raises ValueError if it can't be read."""
    try:
        with open(path()) as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise ValueError(f"The folder list cannot be read: {e}") from None
    if not isinstance(data, dict) or not isinstance(data.get("pairs", []), list):
        raise ValueError("The folder list has the wrong format.")
    data.setdefault("pairs", [])
    data.setdefault("removed", [])
    return data


def active():
    """Valid active pairs, in order. [] if none or unreadable."""
    try:
        data = read() or {}
    except ValueError:
        return []
    return [p for p in data.get("pairs", [])
            if isinstance(p, dict) and valid_name(p.get("name")) and valid_remote(p.get("remote"))]


def removed():
    try:
        data = read() or {}
    except ValueError:
        return []
    return [p for p in data.get("removed", []) if isinstance(p, dict) and valid_name(p.get("name"))]


@contextlib.contextmanager
def _locked():
    fd = os.open(os.path.join(config_dir(), "pairs.lock"), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _write(data):
    fd, tmp = tempfile.mkstemp(dir=config_dir(), prefix=".pairs.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp, path())
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def add(name, remote, merge=False):
    """Add a pair. Raises ValueError with a message for the user."""
    if not valid_name(name):
        raise ValueError("Use a folder name of up to 60 letters, digits, spaces and . _ - ( ), "
                         "not starting with a dot or space.")
    if not valid_remote(remote):
        raise ValueError("Pick a MEGA folder.")
    remote = norm_remote(remote)
    with _locked():
        data = read() or {"pairs": [], "removed": []}
        for p in data["pairs"]:
            if str(p.get("name", "")).lower() == name.lower():
                raise ValueError(f"There is already a folder named '{p['name']}'.")
            if valid_remote(p.get("remote")) and nested(p["remote"], remote):
                raise ValueError(f"'{remote}' is inside, or contains, the MEGA folder of "
                                 f"'{p['name']}' ({p['remote']}). MEGA cannot sync nested folders.")
        data["removed"] = [p for p in data["removed"] if p.get("name") != name]
        data["pairs"].append({"name": name, "remote": remote, "merge": bool(merge), "added": _now()})
        _write(data)


def remove(name):
    """Stop syncing a pair. The engine removes the sync; files stay on both sides."""
    with _locked():
        data = read() or {"pairs": [], "removed": []}
        keep = [p for p in data["pairs"] if p.get("name") != name]
        if len(keep) == len(data["pairs"]):
            raise ValueError("No such folder.")
        gone = next(p for p in data["pairs"] if p.get("name") == name)
        data["pairs"] = keep
        data["removed"] = [p for p in data["removed"] if p.get("name") != name]
        data["removed"].append({"name": name, "remote": gone.get("remote"), "removed": _now()})
        _write(data)


def allow_merge(name):
    with _locked():
        data = read() or {"pairs": []}
        for p in data["pairs"]:
            if p.get("name") == name:
                p["merge"] = True
                _write(data)
                return
        raise ValueError("No such folder.")
