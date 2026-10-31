"""Web UI for Backup for MEGA (Flask). Served by waitress from server.py."""
import collections
import contextlib
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
import pairs
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
    app.jinja_env.filters["day"] = lambda d: d.strftime("%-d %b %Y") if d else ""
    app.jinja_env.filters["month"] = lambda d: d.strftime("%b %Y") if d else ""
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
            "folder": {"done": bool(pairs.active()) or bool(s["mega_remote_path"] and pairs_missing()),
                       "pairs": pairs.active(), "legacy": s["mega_remote_path"]},
        }
        steps["complete"] = all(v["done"] for v in steps.values())
        return steps

    def pairs_missing():
        try:
            return pairs.read() is None
        except ValueError:
            return False

    def folders_state(who=None):
        """Each folder pair with its sync state in plain words."""
        rows = engine.sync_rows() if who else None
        problems = engine.pairs_problems()
        out = []
        for p in pairs.active():
            local = engine.pair_dir(p["name"])
            row = None if rows is None else rows.get(local, {})
            level, words = engine.sync_words(row, who)
            if problems.get(p["name"]):
                level, words = "bad", problems[p["name"]]
            out.append({"name": p["name"], "remote": p["remote"], "path": local,
                        "level": level, "text": words,
                        "needs_merge": (not row and not p.get("merge")
                                        and not engine.dir_is_empty(local)),
                        "stopped": bool(row) and (row["run_state"] in ("Disabled", "Suspended")
                                                  or row["error"] not in ("NO", "")),
                        "resuming": os.path.exists(engine.cfg(f"pair-state/{p['name']}.resume")),
                        "in_rubbish": bool(row) and row["remote"].startswith("//bin/"),
                        "added": p.get("added")})
        return out

    def status_data():
        who = engine.whoami()
        folders = folders_state(who)
        order = {"bad": 3, "busy": 2, "off": 1, "ok": 0}
        if folders:
            worst = max(folders, key=lambda f: order.get(f["level"], 0))
            level = worst["level"]
            if len(folders) == 1:
                words = worst["text"]
            else:
                words = {"ok": "All folders in sync.", "busy": "Syncing…",
                         "bad": "A folder needs attention."}.get(level, "Not syncing.")
        else:
            level, words = engine.sync_words({} if who else None, who)
        st = engine.read_json("engine-status.json") or {}
        return {
            "engine": st,
            "who": who,
            "sync": {"level": level, "text": words},
            "folders": folders,
            "guard": [n for n, _ in engine.guard_empty()] if st.get("state") == "guard-refusing" else [],
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
        held = (engine.read_json("engine-status.json") or {}).get("state") in ("guard-refusing", "folder-missing")
        if not held and not setup_state()["complete"]:
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
            folders, folder_error = browse_mega(browse)
        password = None
        if steps["password"]["available"] and not steps["password"]["done"]:
            password = engine.restic_password()
        parent = browse.rsplit("/", 1)[0] or "/"
        return render_template("setup.html", page="setup", steps=steps, browse=browse,
                               parent=parent, folders=folders, folder_error=folder_error,
                               suggest=pairs.suggest_name(browse), browse_view="setup",
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

    def browse_mega(path):
        try:
            return engine.list_folders(path), None
        except RuntimeError as e:
            return [], str(e)

    def safe_browse(value):
        value = value or "/"
        if not value.startswith("/") or ".." in value.split("/"):
            return "/"
        return value

    # --- folder pairs --------------------------------------------------------

    @app.get("/folders")
    @login_required
    def folders_page():
        steps = setup_state()
        if not (steps["folders"]["done"] and steps["login"]["done"] and steps["password"]["done"]):
            return redirect(url_for("setup"))
        who = engine.whoami()
        browse = safe_browse(request.args.get("path"))
        folders, folder_error = browse_mega(browse) if who else ([], None)
        active = folders_state(who)
        rows = (engine.sync_rows() or {}) if who else {}
        removing = [p for p in pairs.removed() if engine.pair_dir(p["name"]) in rows]
        return render_template(
            "folders.html", page="folders", pairs=active, removing=removing,
            other=engine.other_items([p["name"] for p in active] + [p["name"] for p in removing]),
            browse=browse, parent=browse.rsplit("/", 1)[0] or "/", folders=folders,
            folder_error=folder_error, suggest=pairs.suggest_name(browse), browse_view="folders_page",
            can_add=engine.mount_ok(engine.CURRENT) and bool(who))

    @app.post("/folders/add")
    @login_required
    def folder_add():
        steps = setup_state()
        from_setup = request.form.get("from") == "setup"
        remote = request.form.get("path", "")
        name = request.form.get("name", "").strip() or pairs.suggest_name(remote)
        back = url_for("setup" if from_setup else "folders_page", path=remote)
        if not (steps["folders"]["done"] and steps["login"]["done"] and steps["password"]["done"]):
            flash("Finish the steps above first.", "error")
            return redirect(url_for("setup"))
        if not pairs.valid_remote(remote):
            flash("Pick a MEGA folder.", "error")
            return redirect(back)
        if not pairs.valid_name(name):
            flash("Use a folder name of up to 60 letters, digits, spaces and . _ - ( ), "
                  "not starting with a dot or space.", "error")
            return redirect(back)
        local = engine.pair_dir(name)
        if os.path.lexists(local) and not os.path.isdir(local):
            flash(f"There is a file named '{name}' in the MEGA folder. Choose another name.", "error")
            return redirect(back)
        if local in (engine.sync_rows() or {}):
            flash(f"The folder '{name}' is still being removed. Try again in a minute.", "error")
            return redirect(back)
        nonempty = not engine.dir_is_empty(local)
        if nonempty and request.form.get("merge") != "1":
            flash(f"The folder '{name}' in the MEGA folder already has files. Tick the box to merge "
                  "them into MEGA, or choose another name.", "error")
            return redirect(back)
        try:
            pairs.add(name, remote, merge=nonempty)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(back)
        print(f"[web] Folder pair added: {name} <-> {remote}", flush=True)
        flash(f"Added: {remote} on MEGA syncs with the folder '{name}' in the MEGA folder. "
              "The sync starts within a minute; the first download can take a while.", "ok")
        return redirect(url_for("index" if from_setup else "folders_page"))

    @app.post("/folders/remove")
    @login_required
    def folder_remove():
        name = request.form.get("name", "")
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm.", "error")
            return redirect(url_for("folders_page"))
        try:
            pairs.remove(name)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("folders_page"))
        print(f"[web] Folder pair removed: {name}", flush=True)
        flash(f"'{name}' is no longer synced (within a minute). Its files stay on MEGA and in the "
              "MEGA folder here; its snapshots stay until they expire, or until you delete them on "
              "the Snapshots page.", "ok")
        return redirect(url_for("folders_page"))

    @app.post("/folders/merge")
    @login_required
    def folder_merge():
        name = request.form.get("name", "")
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm.", "error")
            return redirect(url_for("folders_page"))
        try:
            pairs.allow_merge(name)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("folders_page"))
        print(f"[web] Folder pair {name}: merge into MEGA allowed.", flush=True)
        flash(f"The files in '{name}' will be merged into MEGA when the sync starts (within a minute).", "ok")
        return redirect(url_for("folders_page"))

    @app.post("/folders/resume")
    @login_required
    def folder_resume():
        name = request.form.get("name", "")
        if not any(p["name"] == name for p in pairs.active()):
            abort(404, "No such folder.")
        os.makedirs(engine.cfg("pair-state"), exist_ok=True)
        with open(engine.cfg(f"pair-state/{name}.resume"), "w") as f:
            f.write(time.strftime("%F %T") + "\n")
        print(f"[web] Folder pair {name}: resume asked.", flush=True)
        flash(f"Resuming the sync of '{name}' within a minute.", "ok")
        return redirect(url_for("folders_page"))

    @app.post("/guard/continue")
    @login_required
    def guard_continue():
        name = request.form.get("name", "")
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm.", "error")
            return redirect(url_for("index"))
        for n, marker in engine.guard_empty():
            if n == name:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(marker)
                print(f"[web] Empty-folder guard cleared for {name or 'the MEGA folder'}.", flush=True)
                flash("Confirmed. Syncing resumes within a few seconds.", "ok")
                break
        else:
            flash("That folder is not held back (any more).", "info")
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

    def snapshot_groups(snaps):
        """Snapshots by folder: the folder pairs first (in order), then folders that are
        no longer synced (removed pairs, the single-folder setup), newest first."""
        cfg = settings.effective()
        window = max(cfg["keep_daily"], cfg["keep_monthly"] * 31, 2)
        groups, seen = [], set()
        for p in pairs.active():
            path = engine.pair_dir(p["name"])
            seen.add(path)
            groups.append({"path": path, "label": p["name"], "remote": p["remote"], "active": True,
                           "snaps": [s for s in snaps if s["path"] == path]})
        removed = {engine.pair_dir(p["name"]): p for p in pairs.removed()}
        legacy = cfg["mega_remote_path"]
        for s in snaps:
            if s["path"] in seen:
                continue
            seen.add(s["path"])
            folder = s["folder"]
            label = folder if folder else "Whole MEGA folder (old)" if folder == "" else s["path"]
            remote = (removed[s["path"]].get("remote") if s["path"] in removed
                      else legacy if folder == "" else None)
            group = [o for o in snaps if o["path"] == s["path"]]
            groups.append({"path": s["path"], "label": label, "remote": remote, "active": False,
                           "snaps": group,
                           "expires": group[0]["time"] + datetime.timedelta(days=window)})
        return groups

    @app.get("/snapshots")
    @login_required
    def snapshots():
        try:
            snaps, error = restic.snapshots(), None
        except restic.ResticError as e:
            snaps, error = [], str(e)
        groups = snapshot_groups(snaps)
        cfg = settings.effective()
        try:
            kept = restic.retention(snaps, cfg["keep_daily"], cfg["keep_monthly"]) if snaps else {}
        except restic.ResticError:
            kept = {}
        for g in groups:
            for s in g["snaps"]:
                k = kept.get(s["id"]) or {}
                if not g["active"]:
                    k = dict(k, until=g["expires"].date(), kept_as=["folder not synced"], remove=False)
                s["kept"] = k
        want = request.args.get("folder")
        current = next((g for g in groups if g["path"] == want), groups[0] if groups else None)
        last = engine.read_json("last-run.json") or {}
        return render_template("snapshots.html", page="snapshots", groups=groups, group=current,
                               error=error, running=engine.backup_running() or jobs.running(),
                               keep=settings.effective(), repo_bytes=last.get("repo_bytes"),
                               legacy_path=engine.CURRENT.rstrip("/"),
                               hold=engine.prune_hold() is not None,
                               freed=last.get("bytes_freed"))

    @app.post("/snapshots/delete-folder")
    @login_required
    def snapshots_delete_folder():
        path = request.form.get("path", "")
        back = url_for("snapshots", folder=path)
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm.", "error")
            return redirect(back)
        groups = snapshot_groups(restic.snapshots())
        group = next((g for g in groups if g["path"] == path and not g["active"]), None)
        if not group:
            abort(404, "No such folder, or it is still synced.")
        if jobs.start_forget(f"Deleting the snapshots of {group['label']}", ["--path", path]):
            flash(f"Deleting {len(group['snaps'])} snapshot(s) of {group['label']}. "
                  "The Status page shows when it's done.", "ok")
        else:
            flash("A backup, restore or delete is already running. Try again when it's done.", "error")
        return redirect(url_for("snapshots"))

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

    @app.post("/snapshots/<snap_id>/delete")
    @login_required
    def snapshot_delete(snap_id):
        snap, _ = _snap_or_404(snap_id)
        if request.form.get("confirm") != "1":
            flash("Tick the box to confirm.", "error")
            return redirect(url_for("snapshot", snap_id=snap["short_id"]))
        label = f"Deleting the snapshot of {human_time(snap['time'])}"
        if engine.backup_running() or not jobs.start_forget(label, ["--snapshot", snap["id"]]):
            flash("A backup, restore or delete is already running. Try again when it's done.", "error")
            return redirect(url_for("snapshot", snap_id=snap["short_id"]))
        flash(f"{label} started. The Status page shows when it's done.", "ok")
        return redirect(url_for("snapshots", folder=snap["path"]))

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
