# Backup for MEGA — Umbrel app: implementation plan

Status: **approved (2026-10-29). Phase 1 done (2026-10-30): tested offline and with the real MEGA test account.**

This turns the working v1 (scripts + `docker compose` over SSH, tested end-to-end
with a real MEGA account on 2026-10-29) into a native umbrelOS 2.0 app. Everything is
done from the Umbrel web UI: install, MEGA login, settings, status, restore.

The backup engine stays as it is: MEGAcmd two-way sync into a local folder plus
nightly restic snapshots, with the existing guards. Its design and the decisions
behind it are in [`docs/engine-design.md`](docs/engine-design.md). This plan covers
what we add around it.

---

## 0. Decisions for you to review

These need a yes/no or a choice before building. **R** is my recommendation.
Decided items are marked ✅ with the date.

| # | Question | Options | R |
|---|---|---|---|
| D1 | Where does the backup history (`repo/`) live? | (a) a folder you pick in the app's Umbrel settings, in Home or on an external drive; backups stay off until one is picked · (b) default under Home › Downloads (the only default location Umbrel apps can use today) · (c) inside the app's data (**deleted on uninstall**) | ✅ **(a)** (2026-10-29) |
| D2 | Where does the MEGA mirror (`current/`) live? | (a) inside the app's data, excluded from Umbrel backups, not visible in Files · (b) a Home folder you pick, so you can browse it in Files (it gets indexed; files written there go up to MEGA) | ✅ **(b)** (2026-10-29): you browse your MEGA files in Files, and files you add there go up to MEGA. Restic snapshots are the safety net. Setup refuses a non-empty folder unless you confirm the merge |
| D3 | App login in addition to Umbrel's? | (a) yes: a per-install app password, shown on Umbrel's app page · (b) no, rely on Umbrel's login only | ✅ **(a)** (2026-10-29), see §6 |
| D4 | Allow turning snapshots (restic) off? | (a) yes, with a clear warning that a mirror alone isn't a backup · (b) no | ✅ **(a)**, default on (2026-10-29) |
| D5 | Public GitHub repositories? Umbrel can only install from a **public** app-store repo and a **public** image. `ppppso/mega-backup` is private today. | (a) make `mega-backup` public, publish the image on `ghcr.io/ppppso/mega-backup`, plus a new public `ppppso/umbrel-app-store` · (b) keep the code private, publish only the image and the store repo | ✅ **(a)**, but only after checking that no commit contains secrets (2026-10-29). Check done on the single commit `1fdd01e` and the working tree: gitleaks v8.28.0 found nothing, a manual search for personal data (emails, home paths, ping URLs, keys) found nothing, the author email is the GitHub no-reply address, and `.env`/`config/`/`data/` were never committed. **Repeat both checks on the full history right before making it public.** |
| D6 | App name | "Backup for MEGA" (unofficial; avoids implying it's MEGA's own app) · "MEGA Backup" | ✅ **Backup for MEGA** (2026-10-29) |
| D7 | Keep the plain `docker compose` setup working as well? | yes / no | ✅ **yes** (2026-10-29): Umbrel's guidelines require it, and it's how we test |

---

## 1. Goal

A user with an Umbrel 2.0 device:

1. adds the community app store and installs **Backup for MEGA**;
2. opens it and follows a setup page: log in to MEGA (email, password, 2FA), pick
   the MEGA folder, pick a backup folder, **save the restic password**;
3. from then on sees a status page (sync healthy? last backup OK? next backup?) and
   gets alerts when something is wrong;
4. can change settings, run a backup, see what changed, clear a prune hold and
   restore files, all from the browser, with no SSH.

---

## 2. Facts about umbrelOS 2.0 apps (researched 2026-10-29)

Sources: `getumbrel/umbrel-apps` (its developer guides in `.agents/skills/`, plus
existing packages), `getumbrel/umbrel-community-app-store` (template), and the
umbrelOS 2.0.0 release notes.

- **Package = `umbrel-app.yml` + `docker-compose.yml`** in a folder named after the
  app ID. A community store is a public git repo with `umbrel-app-store.yml`
  (`id`, `name`). App IDs must start with the store ID, e.g. `ppppso-mega-backup`.
- **Images must be prebuilt**, public, **multi-arch (amd64 + arm64)** and pinned as
  `tag@sha256:<index digest>`. Compose `build:` isn't allowed.
- **App data** lives in `${APP_DATA_DIR}/data/...` (bind mounts). With
  `storage: dataRoot: data`, a 2.0 user can move it to another drive. It's included in
  **Umbrel backups** unless listed in `backupIgnore:`. **Uninstalling deletes it.**
- **`folderAccess:`** (2.0): the app declares named folders, and the user points each
  one at a Home folder, an external drive or a network share in the app's settings.
  Without a default in compose, nothing is mounted until the user picks one. The only
  proven default is the Downloads folder (`${UMBREL_ROOT}/data/storage/downloads/...`,
  rewritten to `${UMBREL_ROOT}/home/Downloads/...`).
- **Web UI via `app_proxy`**: the manifest `port` is the browser port, and
  `APP_PORT` is our internal port. **Umbrel login protects it by default**, but in 2.0
  the owner can switch "Require Umbrel login" off per app. In 2.0 no proxy container
  runs, and the guide says to treat the shared Docker network as untrusted, so other
  containers can reach our internal port directly.
- **The app must be usable from the browser**: "Normal setup must not require editing
  `docker-compose.yml` or `.env` files, SSH, one-off commands, log scraping…".
  Settings should apply without a container restart.
- **Per-install secrets**: `APP_PASSWORD` is derived from the device seed and stays the
  same across restarts and updates. With `deterministicPassword: true` Umbrel shows it
  on the app's page.
- **Conventions**: `restart: on-failure`, `init: true` when needed, files owned by
  1000:1000, no Docker socket, no privileged mode or extra capabilities, a status
  endpoint, never log secrets.
- **Widgets** (optional): home-screen cards fed by an internal JSON endpoint that
  Umbrel fetches without the user's login, so they must expose nothing sensitive.
- **Testing**: Umbrel publishes a containerized umbrelOS
  (`ghcr.io/getumbrel/umbrelos:<version>`, run privileged) for local testing, plus
  `sudo umbreld client apps.*` commands on a device.

---

## 3. Architecture

One container (the "single-service app" shape). Two long-running processes, started
and watched by the entrypoint: if either exits, the container exits non-zero and
Umbrel restarts it.

```
container (user 1000, after a short root step)
├── engine   main.sh: guards, MEGAcmd server, sync, scheduler → backup.sh   (existing, adapted)
└── web      Python + Flask, served by waitress on :8080 (internal)          (new)
              ├── reads state:  mega-sync / mega-whoami output, restic snapshots,
              │                 last-run.json, prune-hold, settings.json
              └── acts:         login, settings, run backup, clear hold, restore
                                (calls the same scripts and CLI the engine uses)
```

- **Web stack:** Python 3.11 + Flask + waitress from Debian 12's own packages (no pip,
  no JavaScript build step). Server-rendered HTML with a little plain JS for polling
  status. Small, easy to review, and it fits the existing Debian image. Rejected: Go
  (more code for forms and templates), Node (big runtime, build step).
- **No database.** State stays in small files in `/config`, as today, plus
  `settings.json` and `last-run.json`.
- **The engine reads `settings.json`** instead of environment variables. `main.sh`
  re-reads it each scheduler cycle, and `backup.sh` at the start of each run, so
  changes apply without a restart. Environment variables remain as defaults for the
  plain `docker compose` setup.

### Volumes

| In container | Umbrel package | Plain compose | Notes |
|---|---|---|---|
| `/config` | `${APP_DATA_DIR}/data/config` | `./config` | MEGA session, restic password, settings, state. Included in Umbrel backups (on purpose, see §6) |
| `/data/current` | folderAccess **"MEGA folder"** (D2b), visible in Files | `SYNC_DIR` | Two-way with MEGA. Must not contain the Backup folder (checked at setup) |
| `/data/repo` | folderAccess **"Backup folder"** (D1a) | `REPO_DIR` | Survives uninstall. Must be a real mount (§5) |
| `/data/restore` | folderAccess **"Restore folder"** (default: Downloads) | `RESTORE_DIR` | Where restores go, visible in Files |

---

## 4. Web UI

All pages need the app login (D3). Every action is a POST with a CSRF token.

1. **Setup** (shown until everything is configured; each step shows ✅ or what's missing):
   1. *Folders*: if `/data/current` (MEGA folder) or `/data/repo` (Backup folder)
      isn't a mounted folder, explain how to pick it in the app's Umbrel settings.
      Refuse if one is inside the other.
   2. *MEGA login*: email, password, optional 2FA code. Shows MEGA's error message
      on failure. The password is never stored or logged (§6).
   3. *MEGA folder*: browse the account's folders (`mega-ls`) and pick one. A
      warning explains two-way sync in plain words.
   4. *Restic password*: generated, shown once with copy and download buttons, and
      a required "I saved it" checkbox. Viewable later under Settings.
   5. *Start*: creates the sync and shows download progress (files, size).
2. **Status** (home page): sync state in plain words ("In sync", "Downloading 1,204
   files", "Sync issues: 3", "Not logged in"), last backup (time, result, files
   added/changed/removed), next backup, disk use of mirror and repo, free space, and
   any warning (prune hold, failing runs, low disk). Buttons: **Back up now**,
   **View log**.
3. **Snapshots**: list (time, files, size added). Pick one to browse its folders
   (`restic ls --json`) and **restore** a file, folder or everything into the Restore
   folder (into a new sub-folder per restore, never overwriting), or **download** a
   single file (`restic dump`). **Compare** two snapshots (`restic diff`).
4. **Prune hold** (only when active): what happened, the change list, and buttons
   **"It was intended, resume pruning"** or **"Restore from before"** (links to
   Snapshots).
5. **Settings** (apply without restart):
   - Snapshots on/off (D4); backup time; timezone;
   - keep daily N, keep monthly N, or "keep everything";
   - mass-change thresholds (% removed, % changed);
   - weekly check day and % of data read;
   - alert URL (healthchecks.io-style) with a **Send test alert** button;
   - MEGA account: show who's logged in, **Log out**;
   - ~~Change MEGA folder~~ replaced by the **Folders** page (§5.9): add and remove
     folder pairs;
   - show the restic password (asks for the app password again).
6. **Log**: the last ~500 lines of our own log (not MEGAcmd's very verbose log),
   filtered so no secrets can appear.

Optional, later: a home-screen widget ("Last backup: OK, 6 h ago · Sync: In sync").

---

## 5. Engine changes

Changes to `scripts/` (all behaviour stays covered by tests):

1. **Settings file**: `lib.sh` gets `load_settings` (`jq` from `/config/settings.json`,
   falling back to environment variables, then to the defaults). Validated in one
   place, used by `main.sh` and `backup.sh`.
2. **`last-run.json`**, written atomically by `backup.sh`: start and end time, result,
   problems, snapshot ID, counts, bytes added. The web UI reads this instead of
   parsing logs.
3. **Repo must be a real mount**: before init or backup, check `/proc/self/mountinfo`
   for `/data/repo`. If it isn't mounted, the repo would land inside the container
   and vanish on restart, so refuse and show "choose a Backup folder". Plain
   compose always mounts it, so this check passes there.
4. **Wait for setup**: `main.sh` waits (as it now waits for login) until a MEGA
   folder is set, and creates the sync when the user presses *Start*.
5. **Snapshots off**: the scheduler skips `restic` and the alert covers only sync
   health. Existing snapshots are kept, never deleted automatically.
6. ~~Change MEGA folder~~: replaced by folder pairs (9). Changing a folder is now
   "remove the pair, add the new one".
7. **Logging**: everything we log also goes to `/config/logs/app.log` (rotated,
   1 MB × 3) for the Log page.
8. **Remove the "log in over SSH" banner**, replaced by "open the app to log in".
9. **Folder pairs** (done 2026-10-31, requested after 1.0.0). Option A of three
   (one parent folder; the others were "give the app all of Home" and "fixed
   folderAccess slots"):
   - Several MEGA folders, each synced with `<MEGA folder>/<name>` on Umbrel. The list
     is `/config/pairs.json` (web UI writes it under `pairs.lock`); `scripts/pairs.sh`
     creates the syncs every minute and removes only those listed under "removed".
     Nested MEGA folders are refused (MEGA can't sync them); a non-empty local folder
     needs a merge confirmation.
   - One restic snapshot per folder (path `<MEGA folder>/<name>`, tag `folder:<name>`),
     the mass-change guard per folder (only against snapshots taken since the pair was
     added), retention per folder (`--group-by host,paths`). An empty folder is
     skipped; the others are still backed up.
   - Empty-folder guard per folder (`pair-state/<name>.established`), with a
     "meant to be empty" confirmation on the Status page.
   - 1.0 installs move automatically: old sync removed, content moved into
     `<MEGA folder>/<name of the MEGA folder>`, sync created again (MEGA finds the
     files, nothing is transferred), crash-safe. Old snapshots stay as "Whole MEGA
     folder (old)".
   - **Space:** forget + prune run after every backup, also a partial one (before,
     one unreadable file stopped all clean-up). Snapshots of folders no longer synced
     expire once their newest is older than the retention period (`--keep-daily`
     counts days *with* snapshots, so they would otherwise stay forever). Snapshots
     can be deleted by hand (one, or all of an old folder; `forget.sh`). The Status
     page shows the Backup folder's size and what the last clean-up freed.

---

## 6. Security

- **The MEGA password goes to MEGAcmd without touching disk, logs or process
  arguments.** The web process drives MEGAcmd's interactive shell (`mega-cmd`)
  through a pseudo-terminal and types the password at its `Password:` prompt, which
  we verified on 2026-10-29. That's the same as the manual login, and it avoids
  `mega-login email password`, where the password would be visible in the process
  list. The request handler holds it in memory only for the login call. The 2FA
  prompt in this path is unverified (§10).
- **App login (D3a)**: one password, `APP_PASSWORD`, which Umbrel shows on the app's
  page (`deterministicPassword: true`), giving a signed session cookie (HttpOnly,
  SameSite=Lax, plus a CSRF token on every form; Strict would log you out when
  arriving from Umbrel's dashboard). Why both logins: in 2.0 other containers on the Umbrel network
  can reach our port directly, bypassing Umbrel's login, and the owner can switch
  that login off. Anyone reaching an unprotected page could control the MEGA account.
  If two logins feel like too much, D3b is a one-line change, but I don't recommend it.
- **CSRF token** on every POST; **rate limiting** on the app and MEGA login forms.
- **Restore paths**: only inside `/data/restore`, into new sub-folders; snapshot paths
  are validated (no `..`, no absolute paths outside `/data/current`).
- **Secrets on screen**: the restic password is shown only on request, after
  re-entering the app password. Never in logs, widget output or the status JSON.
- **Umbrel backups include `/config`**, so the MEGA session and the restic password
  end up in your Umbrel backups (USB or NAS). That's useful (the password can't be
  lost along with the device) but means those backups must be kept private.
  Alternative: `backupIgnore` the session and keep only the password. Your call;
  default is to include both.
- **Container privileges** stay as today: no extra capabilities, devices, Docker
  socket or host network. The web server binds to `0.0.0.0:8080` inside the container
  only, with no published host ports (Umbrel routes to it).
- **Dependencies** come from Debian packages and MEGA's signed repository; restic is
  pinned and checksum-verified, as today.

---

## 7. Packaging and publishing

```
ppppso/mega-backup            (code; D5)
├── Dockerfile, scripts/, web/, tests/, docker-compose.yml (plain setup), README.md
└── .github/workflows/release.yml   tag v* → build amd64+arm64 → push ghcr.io/ppppso/mega-backup:<ver>

ppppso/umbrel-app-store       (public; what you add in Umbrel)
├── umbrel-app-store.yml       id: ppppso, name: "ppppso"
└── ppppso-mega-backup/
    ├── umbrel-app.yml         manifestVersion 2.0 (uses folderAccess + 2.0 HTTPS), storage,
    │                          folderAccess (MEGA folder, Backup folder, Restore folder), port, deterministicPassword,
    │                          backupIgnore (data/config/restic-cache/*), icon
    └── docker-compose.yml     app_proxy (APP_HOST ppppso-mega-backup_server_1, APP_PORT 8080),
                               server: image ghcr.io/ppppso/mega-backup:<ver>@sha256:…,
                               restart on-failure, init, stop_grace_period 60s, volumes (§3)
```

- **Port**: one not used by the official store, checked against its 400 apps when
  publishing (e.g. 2947, currently free).
- **MEGAcmd version** pinned in the Dockerfile (today it takes whatever MEGA's repo
  has; 2.6.0 became 2.7.0 between two builds). Updates then happen on purpose,
  through a new app version.
- **Versioning**: app version = our version (`1.0.0`, …), shown in the manifest with
  release notes. The image tag matches it.
- Publishing steps that need you (D5): create or make public the repositories, allow
  the GitHub Actions workflow to push the image, and set the package to public.

---

## 8. Testing

| Level | Where | What |
|---|---|---|
| Unit | Docker, no account | existing `backup_test.sh` (44) + new: settings load and validation, `last-run.json`, repo-not-mounted refusal, snapshots off, folder-change guard skip |
| Web | Docker, no account | pytest against the Flask app with MEGAcmd and restic faked: auth required everywhere, CSRF, login never logs or stores the password, restore path checks, settings apply |
| Container | Docker, no account | existing `container_test.sh` (24) adapted: both processes up, either dying restarts the container, status page reachable, no root-owned files |
| Real MEGA | this PC, `/mega-backup-test` | the stage-2 checklist again, done through the web UI: login (also with 2FA if you enable it on the test account), folder pick, download, backup, delete on MEGA, mass-delete hold, restore, download a file |
| Umbrel (local) | containerized umbrelOS 2.0 on this PC | install from our store, folderAccess settings appear and work, open via Umbrel, app password shown, restart keeps state, **uninstall keeps the Backup folder** |
| Umbrel (device) | your Umbrel, test folder first | the same, plus arm64, memory use, an umbrelOS update later |

Each phase ends with its tests passing. Shellcheck + a Python linter stay clean.

---

## 9. Phases

1. **Foundation**: settings file, `last-run.json`, mount check, logging (§5). Web
   skeleton with app login, Status page, MEGA login, Setup flow. Plain compose with
   the web port. *Result: setup without SSH works locally.*
   ✅ Built 2026-10-29. Tests: `backup_test.sh` 62, `web_test.py` 24 (MEGAcmd faked),
   `container_test.sh` 42, shellcheck and pyflakes clean. Real-account test passed
   2026-10-30 (see §10).
2. **Packaging**: release workflow, store repo, manifest. Test in local umbrelOS,
   then on your device with the test folder. *Result: installable from Umbrel.*
   ✅ Local test 2026-10-30 in containerized umbrelOS 2.0.0 (amd64): the store is added
   by URL, the app installs, the folderAccess folders and TZ appear in the app's
   settings, the Restore folder defaults to `Downloads/mega-restores`, the app password
   is shown, and the app survives an umbrelOS restart. The image builds for amd64 and
   arm64 (arm64 checked under emulation). MEGAcmd is pinned by version and checksum.
   Still to do: first release, then a test on your device.
3. **Settings and actions**: Settings page, Back up now, prune-hold page, alert test,
   change MEGA folder, snapshots on/off.
4. **Snapshots and restore**: browse, compare, restore, download.
5. **Polish**: widget, README for Umbrel users, final device test, switch to the
   real MEGA folder.

I'd stop after each phase for you to try it.

---

## 10. Unverified (to check during the phases)

- ✅ Verified with the real test account (2026-10-30), through the web UI: wrong
  password shows MEGA's "Login failed: invalid email or password"; the **2FA prompt**
  appears and login with the code works; the logged-in prompt is detected; the
  folder picker lists real folders (`mega-ls -l` parsing); the sync is created and
  downloads; a backup writes `last-run.json`; the Status API shows it.
  Found on the way: in password mode the shell reads raw keys and only accepts `\r`
  as Enter (`\n` is silently ignored, so the first version hung until its timeout).
  The fake shell in `web_test.py` now behaves the same way.
- Passwords containing `"` or `\` are refused: MEGAcmd's shell wraps the password in
  double quotes internally (`login -v email "pw"`), so they would be mangled.
- `mega-ls -l` output parsing for the folder picker (format taken from the source:
  FLAGS VERS SIZE DATE NAME); check with real folders, including names with spaces.
- Whether Umbrel shows apps inside a frame (the CSP has `frame-ancestors 'self'`).
- What a **folderAccess folder** is on disk in 2.0 with multiple users (owner's
  Home?), and that **uninstalling leaves it alone** (phase 2, local umbrelOS).
- Whether Umbrel's **Files indexing** of the Backup folder (thousands of encrypted
  pack files) costs noticeable CPU on a Pi, and whether a folder can be excluded.
- Whether `folderAccess` can have a **non-Downloads default** (would make D1 smoother).
- `deterministicPassword` shows the password on the app's page in 2.0 as documented.
- Whether Umbrel backups are encrypted (affects the `/config` question in §6).
- ✅ Checked in umbrelOS 2.0.0's source and tests: folderAccess paths are in the
  owner's namespace (`/Home/...`). The owner's Home is private: members get their own
  Home under `/Users/<name>` and can't list `/Home`. Members see a folder or an app
  only if the owner shares it. Not yet tried with a real second user.
- With **several Umbrel users**, whether a folderAccess folder is visible only to the
  user who picked it (phase 2, local umbrelOS).
- Files written through the **Files app** (owner, permissions) are picked up by the
  sync and uploaded; files downloaded from MEGA (mode 600) are readable in Files.
- Whether **Files indexing** of a large MEGA mirror is acceptable, and whether Umbrel
  backups can skip that folder (it can be downloaded again from MEGA).

## 11. Out of scope

- Several MEGA accounts in one install (one login; several folders are supported, §5.9).
- Off-site copies of the repo (`restic copy`). Possible later as a setting.
- Submitting to the official Umbrel App Store. Possible later; the official store
  has the same rules, so this plan keeps the door open.
- Automatic conflict resolution: sync issues are shown, with MEGA's description, and
  you resolve them in MEGA.
