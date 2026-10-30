"""Web UI for Backup for MEGA (Flask). Served by waitress from server.py."""
import collections
import datetime
import hmac
import os
import re
import secrets
import threading
import time
from functools import wraps
from urllib.parse import quote

from flask import (Flask, Response, abort, flash, jsonify, redirect, render_template, request,
                   session, url_for)

import engine
import jobs
import megalogin
import restic
import settings


def human_bytes(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000


def human_time(t):
    """datetime -> "2026-10-30 19:32" in the container's time zone (TZ)."""
    return t.astimezone().strftime("%Y-%m-%d %H:%M") if t else ""


def parse_prune_hold(text):
    """[(reason, before_id, after_id), ...] from the prune-hold file."""
    out = []
    for block in text.split("\n\n"):
        reason = re.search(r"^Reason: (.*)$", block, re.M)
        ids = re.search(r"Before: snapshot ([0-9a-f]+)\s+After: snapshot ([0-9a-f]+)", block)
        when = re.search(r"^Prune hold set (.*)$", block, re.M)
        if reason or ids:
            out.append({"when": when.group(1) if when else "",
                        "reason": reason.group(1) if reason else "",
                        "before": ids.group(1) if ids else None,
                        "after": ids.group(2) if ids else None})
    return out


def _secret_file(name, nbytes):
    """Read a secret from /config, creating it (mode 600) on first use."""
    path = engine.cfg(name)
    try:
        with open(path) as f:
            value = f.read().strip()
        if value:
            return value
    except FileNotFoundError:
        pass
    value = secrets.token_urlsafe(nbytes)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value + "\n")
    return value


def app_password():
    """APP_PASSWORD (set by Umbrel), else a generated one kept in /config/app-password."""
    return os.environ.get("APP_PASSWORD") or _secret_file("app-password", 18)


class RateLimit:
    """At most `limit` failures per `window` seconds, for everyone together.

    Global rather than per client: behind Umbrel's proxy every request has the
    same address.
    """

    def __init__(self, limit, window):
        self.limit, self.window = limit, window
        self.failures = collections.deque()
        self.lock = threading.Lock()

    def wait_seconds(self):
        now = time.monotonic()
        with self.lock:
            while self.failures and now - self.failures[0] > self.window:
                self.failures.popleft()
            if len(self.failures) < self.limit:
                return 0
            return int(self.window - (now - self.failures[0])) + 1

    def fail(self):
        with self.lock:
            self.failures.append(time.monotonic())


def create_app():
    app = Flask(__name__)
    app.secret_key = _secret_file("web-secret", 32)
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        PERMANENT_SESSION_LIFETIME=datetime.timedelta(days=30),
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    app.jinja_env.filters["bytes"] = human_bytes
    app.jinja_env.filters["when"] = human_time
    app_login_limit = RateLimit(5, 15 * 60)
    mega_login_limit = RateLimit(5, 15 * 60)
    mega_login_lock = threading.Lock()

    # --- request plumbing --------------------------------------------------

    def csrf_token():
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(32)
        return session["csrf"]

    app.jinja_env.globals["csrf_token"] = csrf_token

    @app.before_request
    def check_csrf():
        if request.method == "POST":
            sent = request.form.get("csrf", "")
            if not sent or not hmac.compare_digest(sent, session.get("csrf", "")):
                abort(400, "The form expired. Go back, reload the page and try again.")

    @app.after_request
    def headers(resp):
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; img-src 'self' data:; frame-ancestors 'self'; "
            "form-action 'self'; base-uri 'none'")
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Referrer-Policy"] = "same-origin"
        resp.headers["Cache-Control"] = "no-store"
        return resp

    def login_required(view):
        @wraps(view)
        def wrapper(*a, **kw):
            if not session.get("auth"):
                if request.path.startswith("/api/"):
                    return jsonify(error="login required"), 401
                return redirect(url_for("login", next=request.path))
            return view(*a, **kw)
        return wrapper

    # --- state ---------------------------------------------------------------

    def setup_state():
        """Each setup step with done/blocked and a message."""
        s = settings.effective()
        who = engine.whoami()
        cur_ok = engine.mount_ok(engine.CURRENT)
        repo_ok = engine.mount_ok(engine.REPO)
        overlap = cur_ok and repo_ok and engine.mounts_overlap(engine.CURRENT, engine.REPO)
        steps = {
            "folders": {
                "done": cur_ok and repo_ok and not overlap,
                "current": cur_ok, "repo": repo_ok, "overlap": overlap,
                "restore": engine.mount_ok(restic.restore_dir()),
            },
            "login": {"done": bool(who), "who": who, "server": who is not None},
            "password": {"done": s["restic_password_saved"],
                         "available": engine.restic_password() is not None},
            "folder": {"done": bool(s["mega_remote_path"]), "path": s["mega_remote_path"],
                       "local_empty": engine.dir_is_empty(engine.CURRENT)},
        }
        steps["complete"] = all(v["done"] for v in steps.values())
        return steps

    def status_data():
        who = engine.whoami()
        row = engine.sync_row() if who else None
        level, words = engine.sync_words(row, who)
        st = engine.read_json("engine-status.json") or {}
        return {
            "engine": st,
            "who": who,
            "sync": {"level": level, "text": words, "row": row},
            "last_run": engine.read_json("last-run.json"),
            "backup_running": engine.backup_running() or (jobs.running() and jobs.current()["kind"] == "backup"),
            "job": jobs.current(),
            "prune_hold": engine.prune_hold() is not None,
            "disk": {"current": engine.disk(engine.CURRENT), "repo": engine.disk(engine.REPO)},
            "now": int(time.time()),
        }

    # --- pages ---------------------------------------------------------------

    @app.get("/healthz")
    def healthz():
        return "ok\n", 200, {"Content-Type": "text/plain"}

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            wait = app_login_limit.wait_seconds()
            if wait:
                error = f"Too many failed attempts. Try again in {wait // 60 + 1} min."
            elif hmac.compare_digest(request.form.get("password", "").encode(),
                                     app_password().encode()):
                csrf = session.get("csrf")
                session.clear()
                session.permanent = True
                session["auth"] = True
                session["csrf"] = csrf or secrets.token_urlsafe(32)
                nxt = request.args.get("next", "")
                return redirect(nxt if nxt.startswith("/") and not nxt.startswith("//") else url_for("index"))
            else:
                app_login_limit.fail()
                error = "Wrong password."
        return render_template("login.html", error=error,
                               umbrel=bool(os.environ.get("APP_PASSWORD")))

    @app.post("/logout")
    @login_required
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    @login_required
    def index():
        if not setup_state()["complete"]:
            return redirect(url_for("setup"))
        return render_template("status.html", page="status", data=status_data())

    @app.get("/setup")
    @login_required
    def setup():
        steps = setup_state()
        folders, folder_error = [], None
        browse = request.args.get("path", "/")
        if not browse.startswith("/") or ".." in browse.split("/"):
            browse = "/"
        if steps["login"]["done"] and not steps["folder"]["done"]:
            try:
                folders = engine.list_folders(browse)
            except RuntimeError as e:
                folder_error = str(e)
        password = None
        if steps["password"]["available"] and not steps["password"]["done"]:
            password = engine.restic_password()
        parent = browse.rsplit("/", 1)[0] or "/"
        return render_template("setup.html", page="setup", steps=steps, browse=browse,
                               parent=parent, folders=folders, folder_error=folder_error,
                               restic_password=password, needs_code=session.pop("needs_code", False),
                               email=session.pop("login_email", ""))

    @app.post("/setup/mega-login")
    @login_required
    def mega_login():
        wait = mega_login_limit.wait_seconds()
        if wait:
            flash(f"Too many failed logins. Try again in {wait // 60 + 1} min.", "error")
            return redirect(url_for("setup"))
        if not mega_login_lock.acquire(blocking=False):
            flash("A login is already in progress.", "error")
            return redirect(url_for("setup"))
        email = request.form.get("email", "").strip()
        try:
            who = megalogin.login(email, request.form.get("password", ""),
                                  request.form.get("code", ""))
            print("[web] MEGA login: OK.", flush=True)
            flash(f"Logged in to MEGA as {who}.", "ok")
        except megalogin.NeedsCode as e:
            print("[web] MEGA login: 2FA code needed.", flush=True)
            session["needs_code"] = True
            session["login_email"] = email
            flash(str(e), "info")
        except megalogin.LoginError as e:
            print(f"[web] MEGA login failed: {e}", flush=True)
            mega_login_limit.fail()
            session["login_email"] = email
            flash(str(e), "error")
        finally:
            mega_login_lock.release()
        return redirect(url_for("setup"))

    @app.post("/setup/password-saved")
    @login_required
    def password_saved():
        if request.form.get("saved") != "1":
            flash("Tick the box once you have saved the password.", "error")
        else:
            settings.update({"restic_password_saved": True})
        return redirect(url_for("setup"))

    @app.post("/setup/start")
    @login_required
    def start():
        steps = setup_state()
        if not (steps["folders"]["done"] and steps["login"]["done"] and steps["password"]["done"]):
            flash("Finish the steps above first.", "error")
            return redirect(url_for("setup"))
        path = request.form.get("path", "")
        if not path.startswith("/") or ".." in path.split("/"):
            flash("Pick a MEGA folder.", "error")
            return redirect(url_for("setup"))
        changes = {"mega_remote_path": path}
        if not steps["folder"]["local_empty"]:
            if request.form.get("merge") != "1":
                flash("The local MEGA folder is not empty. Confirm the merge to continue.", "error")
                return redirect(url_for("setup", path=path))
            changes["allow_nonempty_init"] = True
        try:
            settings.update(changes)
        except ValueError as e:
            flash(f"Could not save: {e}", "error")
            return redirect(url_for("setup", path=path))
        flash(f"Starting the sync with {path}. The first download can take a while.", "ok")
        return redirect(url_for("index"))

    @app.get("/log")
    @login_required
    def log_page():
        return render_template("log.html", page="log", lines=engine.log_tail())

    # --- backups and snapshots ------------------------------------------------

    @app.post("/backup-now")
    @login_required
    def backup_now():
        if not setup_state()["complete"]:
            flash("Finish the setup first.", "error")
        elif engine.backup_running() or jobs.running():
            flash("A backup or restore is already running.", "error")
        elif jobs.start_backup():
            flash("Backup started. This page updates when it's done.", "ok")
        return redirect(request.form.get("back") if request.form.get("back") in ("/", "/snapshots")
                        else url_for("index"))

    @app.get("/snapshots")
    @login_required
    def snapshots():
        try:
            snaps, error = restic.snapshots(), None
        except restic.ResticError as e:
            snaps, error = [], str(e)
        return render_template("snapshots.html", page="snapshots", snaps=snaps, error=error,
                               running=engine.backup_running() or jobs.running(),
                               keep=settings.effective())

    def _snap_or_404(snap_id):
        try:
            return restic.find(snap_id)
        except restic.ResticError as e:
            abort(404, str(e))

    @app.get("/snapshots/<snap_id>")
    @login_required
    def snapshot(snap_id):
        snap, prev = _snap_or_404(snap_id)
        try:
            rel = restic.check_rel(request.args.get("path", ""))
            entries, truncated = restic.ls(snap, rel)
            error = None
        except restic.ResticError as e:
            rel, entries, truncated, error = "", [], False, str(e)
        crumbs, acc = [], ""
        for part in rel.split("/") if rel else []:
            acc = f"{acc}/{part}" if acc else part
            crumbs.append((part, acc))
        return render_template("snapshot.html", page="snapshots", snap=snap, prev=prev, rel=rel,
                               crumbs=crumbs, entries=entries, truncated=truncated, error=error,
                               can_restore=engine.mount_ok(restic.restore_dir()),
                               busy=jobs.running())

    @app.get("/snapshots/<snap_id>/diff")
    @login_required
    def snapshot_diff(snap_id):
        snaps = restic.snapshots()
        new, prev = restic.find(snap_id, snaps) if snap_id else (None, None)
        against = request.args.get("against")
        old = restic.find(against, snaps)[0] if against else prev
        if old is None:
            flash("This is the oldest snapshot; there is nothing to compare it with.", "info")
            return redirect(url_for("snapshot", snap_id=new["short_id"]))
        try:
            changes, stats, truncated = restic.diff(old, new)
            error = None
        except restic.ResticError as e:
            changes, stats, truncated, error = [], None, False, str(e)
        return render_template("diff.html", page="snapshots", old=old, new=new, changes=changes,
                               stats=stats, truncated=truncated, error=error)

    @app.get("/snapshots/<snap_id>/download")
    @login_required
    def snapshot_download(snap_id):
        snap, _ = _snap_or_404(snap_id)
        try:
            rel = restic.check_rel(request.args.get("path", ""))
            if not rel or restic.node_type(snap, rel) != "file":
                abort(404, "Only files can be downloaded.")
        except restic.ResticError as e:
            abort(404, str(e))
        name = rel.rsplit("/", 1)[-1]
        ascii_name = re.sub(r'[^A-Za-z0-9._ -]', "_", name) or "file"
        return Response(restic.dump(snap, rel), mimetype="application/octet-stream", headers={
            "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}",
        })

    @app.post("/snapshots/<snap_id>/restore")
    @login_required
    def snapshot_restore(snap_id):
        snap, _ = _snap_or_404(snap_id)
        try:
            rel = restic.check_rel(request.form.get("path", ""))
        except restic.ResticError as e:
            abort(400, str(e))
        back = url_for("snapshot", snap_id=snap["short_id"], path=rel.rsplit("/", 1)[0] if "/" in rel else "")
        if not engine.mount_ok(restic.restore_dir()):
            flash("No Restore folder chosen. Pick one in the app's Umbrel settings (or set RESTORE_DIR).", "error")
            return redirect(back)
        label = f"Restore of {rel or 'everything'} from {human_time(snap['time'])}"
        if jobs.start_restore(label, lambda: "Restored into the Restore folder, sub-folder "
                              + restic.restore(snap, rel) + "."):
            flash(f"{label} started. The Status page shows when it's done.", "ok")
        else:
            flash("A backup or restore is already running. Try again when it's done.", "error")
        return redirect(back)

    # --- prune hold -------------------------------------------------------------

    @app.get("/prune-hold")
    @login_required
    def prune_hold():
        text = engine.prune_hold()
        return render_template("prune_hold.html", page="status", text=text,
                               events=parse_prune_hold(text or ""))

    @app.post("/prune-hold/clear")
    @login_required
    def prune_hold_clear():
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm the changes were intended.", "error")
            return redirect(url_for("prune_hold"))
        path = engine.cfg("prune-hold")
        if os.path.exists(path):
            # Keep the old file for reference.
            os.replace(path, path + ".cleared-" + time.strftime("%Y%m%d-%H%M%S"))
            print("[web] Prune hold cleared by the user.", flush=True)
            flash("Pruning resumed. Old snapshots will be thinned out again after the next backup.", "ok")
        return redirect(url_for("index"))

    @app.get("/api/status")
    @login_required
    def api_status():
        return jsonify(status_data())

    @app.errorhandler(400)
    def bad_request(e):
        return render_template("error.html", message=e.description), 400

    @app.errorhandler(404)
    def not_found(e):
        return render_template("error.html", message=e.description), 404

    @app.errorhandler(restic.ResticError)
    def restic_error(e):
        return render_template("error.html", message=str(e)), 502

    return app
