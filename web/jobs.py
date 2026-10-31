"""One background job at a time (a manual backup or a restore), run from the web UI.

The result of the last job is kept in memory for the Status page; a backup's full
result is in last-run.json as well.
"""
import subprocess
import threading
import time

_lock = threading.Lock()
_job = None        # dict: kind, label, started, finished, ok, message


def current():
    with _lock:
        return dict(_job) if _job else None


def running():
    j = current()
    return bool(j and j["finished"] is None)


def _start(kind, label, fn):
    """Run fn() in a thread. fn returns a message, or raises with one."""
    global _job
    with _lock:
        if _job and _job["finished"] is None:
            return False
        _job = {"kind": kind, "label": label, "started": time.time(), "finished": None,
                "ok": None, "message": ""}
        job = _job

    def work():
        try:
            msg, ok = fn(), True
        except Exception as e:   # shown to the user; details are in the log
            msg, ok = str(e) or type(e).__name__, False
        print(f"[web] {label}: {'done' if ok else 'failed'}. {msg}", flush=True)
        with _lock:
            job.update(finished=time.time(), ok=ok, message=msg)

    threading.Thread(target=work, daemon=True).start()
    return True


def start_backup():
    def run():
        # Output goes to our stdout, i.e. the app log.
        rc = subprocess.call(["/usr/local/bin/backup.sh"], cwd="/tmp")
        if rc == 0:
            return "Backup finished OK."
        if rc == 75:
            raise RuntimeError("Another backup was already running.")
        raise RuntimeError("Backup finished with problems. See the Status page and the log.")
    return _start("backup", "Manual backup", run)


def start_restore(label, fn):
    return _start("restore", label, fn)


def start_forget(label, args):
    """Delete snapshots (forget.sh) and free the space."""
    def run():
        p = subprocess.run(["/usr/local/bin/forget.sh", *args], cwd="/tmp",
                           capture_output=True, text=True, errors="replace")
        print(p.stdout + p.stderr, end="", flush=True)   # into the app log
        if p.returncode == 75:
            raise RuntimeError("A backup is running. Try again when it's done.")
        if p.returncode != 0:
            raise RuntimeError("Deleting failed. See the log.")
        freed = next((int(line.split()[1]) for line in p.stdout.splitlines()[::-1]
                      if line.startswith("freed ")), None)
        return "Deleted." + (f" {freed / 1e6:.1f} MB freed." if freed is not None else "")
    return _start("forget", label, run)
