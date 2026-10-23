# mega-backup — implementation brief

You (the implementing agent) are building a small, self-contained project in this repo.
Read the whole brief before starting. Ask the user before doing anything that needs
real MEGA credentials, touches the Umbrel device, commits, or pushes.

## 1. Goal

Keep an **independent backup** of one folder from a MEGA (mega.nz) account on an
**umbrelOS** device's disk, "just in case something happens to MEGA" (account ban/closure,
data loss, accidental deletion, corruption/ransomware propagating through MEGA).

- Changes almost always happen on MEGA. Umbrel must reflect them.
- Nothing on the Umbrel side should normally write to the synced folder.
- The backup must survive: MEGA account loss, files deleted on MEGA, files overwritten
  with garbage on MEGA.

## 2. Decisions already made (with the user) — do not revisit without asking

1. **Use the official MEGAcmd client** (`mega-sync`) for the MEGA ↔ Umbrel sync.
   - Rejected: rclone's native mega backend (unofficial reimplementation, reports of
     login failures and temporary account blocks, 2FA awkward for unattended runs).
   - Rejected: MEGAcmd WebDAV + rclone (works, but reports of MEGAcmd WebDAV crashing
     /hanging on long transfers; more moving parts).
2. MEGAcmd sync is **two-way** (there is no download-only mode). Accepted because:
   - deletions that propagate *up* to MEGA land in MEGA's rubbish bin / version history
     (recoverable), and
   - the Umbrel side is kept "write-free" by convention.
3. Because a sync is not a backup, take **nightly restic backups** of the synced folder
   into a local restic repository on the Umbrel disk (independent of MEGA). This is what
   protects against deletions/corruption syncing *down*.
   - Chosen over rsync `--link-dest` hardlink snapshots because restic deduplicates by
     content (renames/moves and partial changes cost almost nothing), so long retention
     is cheap; snapshots are read-only; integrity can be verified (`restic check`); and
     its JSON output gives per-run change counts for the mass-change guard.
   - Accepted trade-offs: restores need the `restic` command (not plain folders), and
     the repository password must be kept safe (lose it = lose the backups).
4. Deliver as a **single Docker container** (docker compose), deployable on umbrelOS.
   No official MEGAcmd image exists, so build our own from MEGA's official apt repo.

## 3. Architecture

```
MEGA cloud folder  <── MEGAcmd sync (official, 2-way) ──>  /data/current   (Umbrel disk)
                                                                │
                                                     nightly `restic backup`
                                                                ▼
                                                   /data/repo   (restic repository:
                                                   deduplicated, encrypted, read-only snapshots)
```

One container, `mega-backup`, runs:
- `mega-cmd-server` (the MEGAcmd daemon; holds the login session and the sync), and
- a small shell scheduler that runs a backup once a day (backup + guard + forget/prune +
  periodic check) and pings an optional healthcheck URL.

## 4. Repo layout to create

```
mega-backup/
├── IMPLEMENTATION.md      (this file — keep it)
├── README.md              (user-facing: setup, first login, restore, troubleshooting)
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore             (.env, config/, data/)
├── scripts/
│   ├── entrypoint.sh      (root: machine-id, perms, drop privileges → main.sh)
│   ├── main.sh            (start server, wait for login, ensure sync, ensure repo, scheduler loop)
│   ├── backup.sh          (one backup run + guard + forget/prune + check + healthcheck ping;
│   │                       runnable manually)
│   ├── healthcheck.sh     (Docker HEALTHCHECK; added during implementation, §10)
│   ├── as-user.sh         (run a command as PUID; added during implementation, §10)
│   └── lib.sh             (shared helpers: log(), ping_hc(), restic env) — optional
└── tests/
    ├── backup_test.sh     (offline tests, §6)
    └── container_test.sh  (whole-container tests on the Docker host; added, §10)
```

Shell: POSIX `sh` or `bash` (bash is fine, it's in the image). Use `set -eu` (and
`pipefail` in bash). Keep scripts small and readable; comment the non-obvious parts only.

## 5. Component specs

### 5.1 Dockerfile

- Base: `debian:12-slim` (MEGA publishes Debian 12 packages for **amd64 and arm64** —
  Umbrel may be either, e.g. Umbrel Home = amd64, Raspberry Pi = arm64).
- Packages: `ca-certificates curl gnupg bzip2 jq tzdata procps util-linux` (+ `megacmd`).
- MEGA apt repo (flat repo, signed):
  - key: `https://mega.nz/linux/repo/Debian_12/Release.key`
  - source line: `deb [signed-by=<key>] https://mega.nz/linux/repo/Debian_12/ ./`
  - **Gotcha (already hit once):** the `megacmd` package installs its *own* apt source
    that uses `signed-by=/etc/apt/keyrings/meganz-archive-keyring.gpg`. If your source
    line uses a different key path, the next `apt-get` fails with
    `Conflicting values set for option Signed-By`. Fix: dearmor the key to
    `/etc/apt/keyrings/meganz-archive-keyring.gpg` (mkdir it first) and delete your own
    `.list` file right after installing megacmd (the package's list remains).
- **restic:** Debian 12's package is too old (0.14). Install a pinned release binary
  instead: `ARG RESTIC_VERSION` (a current release, **≥ 0.17**, which stores a summary
  in each snapshot), download
  `https://github.com/restic/restic/releases/download/v${V}/restic_${V}_linux_${TARGETARCH}.bz2`
  plus `SHA256SUMS`, **verify the checksum**, `bunzip2`, install to
  `/usr/local/bin/restic`. Use buildx's `TARGETARCH` (amd64/arm64) so both arches build.
- Clean apt lists; purge `gnupg` afterwards if you like.
- `ENV HOME=/config` so MEGAcmd stores its session in `/config/.megaCmd`.
- restic env (so `docker exec … restic snapshots` works without flags):
  `RESTIC_REPOSITORY=/data/repo`, `RESTIC_PASSWORD_FILE=/config/restic-password`,
  `RESTIC_CACHE_DIR=/config/restic-cache`.
- Copy `scripts/` to `/usr/local/bin/`, `chmod +x`.
- `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`
- `HEALTHCHECK`: something cheap that proves the server is up and logged in, e.g.
  `mega-whoami` exit code (verify it returns non-zero when logged out).
- Check the megacmd postinst doesn't fail in a container without systemd.

### 5.2 entrypoint.sh (runs as root)

1. **Persistent machine-id.** A community image reports `mega-sync` breaks without a
   unique, stable `/etc/machine-id`. If `/config/machine-id` doesn't exist, generate one
   (e.g. `cat /proc/sys/kernel/random/uuid | tr -d -`). Copy it to `/etc/machine-id`
   on every start.
2. Create `/data/current` and `/data/repo` if missing; `chown` `/config`,
   `/data/current`, `/data/repo` to `PUID:PGID` (defaults 1000:1000 — the `umbrel`
   user). Only chown the top-level dirs + /config recursively; never recursively chown
   the data tree on every boot (could be huge) — do it only if ownership is wrong
   at the top level.
3. Drop privileges with `setpriv --reuid=$PUID --regid=$PGID --init-groups` (or
   `--clear-groups`) and `exec main.sh`.

### 5.3 main.sh (runs as PUID)

1. `trap` SIGTERM/SIGINT → `mega-quit` (graceful server shutdown), then exit.
2. Start `mega-cmd-server` in the background; wait until a client command responds
   (poll with timeout).
3. **Login:** never take the MEGA password from env vars or files. If not logged in,
   log clearly, repeatedly (every ~60 s) something like:
   `Not logged in. Run: docker exec -it mega-backup mega-login <email>` (mention
   `--auth-code=<2FA code>` for 2FA accounts), and wait. The session persists in
   `/config/.megaCmd`, so this is a one-time step.
4. **Ensure the sync exists** between `/data/current` and `$MEGA_REMOTE_PATH`:
   - If a sync for that pair already exists → do nothing (log its state).
   - If not: create it **only if `/data/current` is empty** (ignore `.debris`). If it is
     not empty, refuse, log why, and keep waiting — unless `ALLOW_NONEMPTY_INIT=1`.
     Reason: avoid an unexpected merge pushing local files up to MEGA on first setup.
   - Verify `$MEGA_REMOTE_PATH` exists on MEGA first (`mega-ls`); fail loudly if not.
5. **Ensure the restic repository exists:**
   - Password: if `/config/restic-password` doesn't exist, generate a long random one
     (e.g. `head -c 32 /dev/urandom | base64`), `chmod 600`, and log a prominent
     one-time warning: *copy this password somewhere off the device; without it the
     backups cannot be read.*
   - Repo: if `restic cat config` succeeds → fine. Otherwise run `restic init` **only if
     `/data/repo` is empty and `/config/restic-repo-id` does not exist**. After init,
     store the repo ID (`restic cat config | jq -r .id`) in `/config/restic-repo-id`.
     On later starts, if the repo is missing/empty but that file exists, **refuse to
     init** and fail loudly (the repo volume is probably not mounted; silently starting
     a new empty repo would hide that).
   - If the repo ID doesn't match `/config/restic-repo-id` → fail loudly (wrong path).
6. **Scheduler loop:** once per day at `BACKUP_TIME` (HH:MM, container TZ), run
   `backup.sh`. Implement as: compute seconds until next run, `sleep` in chunks
   (e.g. ≤ 300 s, so SIGTERM is handled promptly — run `sleep` in background + `wait`).
   Optionally `BACKUP_ON_START=1` to run one immediately (handy for testing).
7. If `mega-cmd-server` dies, exit non-zero so Docker's restart policy restarts the
   container.

### 5.4 backup.sh (runs as PUID; also runnable via `docker exec mega-backup backup.sh`)

Hold an exclusive `flock` (e.g. on `/config/backup.lock`) for the whole run, so a manual
run and the scheduled run never overlap. Tee all output to a temp log for the fail ping.

1. Ping `$HEALTHCHECK_URL/start` (if set). Use `curl -fsS -m 10 --retry 3`; never let a
   ping failure fail the backup.
2. **Sync health check:** inspect `mega-sync` output for the configured pair. Treat
   anything other than a healthy running/synced state (disabled, suspended, failed,
   error column set) as a problem → remember it, keep going (a backup is still
   harmless and useful), but end with a FAIL ping. **Verify the real output format**
   with `mega-sync --help` / actual output on MEGAcmd 2.6 (column names such as
   `RUN_STATE`, `STATUS`, `ERROR`; there may be `--output-cols`). Do not guess.
   Optionally wait (bounded, e.g. up to 30 min) while the sync reports it is still
   transferring, so the backup is consistent.
3. **Empty-source guard:** if `/data/current` is missing or empty (ignoring `.debris`)
   → do NOT back up, FAIL.
4. **Back up:**
   - `restic unlock` first (removes only stale locks left by a crashed run).
   - `restic backup /data/current --host mega-backup --tag nightly --exclude /data/current/.debris --json`
   - `--host` must be fixed: the container hostname changes when the container is
     recreated, and restic uses host + paths to find the parent snapshot and to group
     snapshots for `forget`. (Also set `hostname: mega-backup` in compose.)
   - Exclude `.debris` (MEGA's local "removed by sync" folder): restic history already
     keeps old versions. Document this.
   - Parse the final `"message_type":"summary"` line with `jq`: `files_new`,
     `files_changed`, `files_unmodified`, `total_files_processed`.
5. **Mass-change guard.** Compare with the previous snapshot of this host/path
   (its file count from `restic snapshots --json` → `.summary.total_files_processed`;
   verify the field name on the pinned version; fall back to `restic diff <prev> <new>`
   stats if needed). Let `prev` = previous file count.
   - removed ≈ `prev − (total_files_processed − files_new)`;
     trip if `removed / prev × 100 > MAX_DROP_PERCENT` (default 20).
   - trip if `files_changed / prev × 100 > MAX_CHANGE_PERCENT` (default 20) — this
     catches files overwritten with garbage (ransomware-style), where the count stays
     the same.
   - No previous snapshot (first run) → don't trip.
   - On trip: the backup is kept, FAIL with a clear message ("possible mass deletion /
     overwrite on MEGA — pruning is on hold"), and write `/config/prune-hold`
     containing the date, the counts and the reason.
6. **Sticky prune hold.** If `/config/prune-hold` exists (from this run or any earlier
   one): **skip forget/prune**, and FAIL every run with "prune on hold since <date>,
   see /config/prune-hold". Pruning resumes only when the user deletes the file after
   checking (`docker exec mega-backup rm /config/prune-hold`). Reason: comparing only
   with the previous snapshot would let the guard pass the next night, and normal
   retention would then age out the good snapshots.
7. **Forget + prune** (only if the backup succeeded and no hold exists):
   `restic forget --host mega-backup --keep-daily $KEEP_DAILY --keep-monthly $KEEP_MONTHLY --prune`
   (defaults 90 / 24). restic always keeps the latest snapshot. Support `DRY_RUN=1`
   (→ `--dry-run`). Log what is removed.
8. **Integrity check:** once a week (on `CHECK_WEEKDAY`, default Sunday), run
   `restic check --read-data-subset=$CHECK_READ_PERCENT%` (default 5). A failure is a
   FAIL ping.
9. Ping success, or `$HEALTHCHECK_URL/fail` with the last ~50 log lines as POST body.
10. Log to stdout (visible in `docker logs`) with timestamps.

### 5.5 docker-compose.yml

- Service `mega-backup`, `build: .`, `container_name: mega-backup`,
  `hostname: mega-backup`, `restart: unless-stopped`, `env_file: .env`.
- Volumes (host paths from `.env`):
  - `${CONFIG_DIR}:/config`
  - `${SYNC_DIR}:/data/current`
  - `${REPO_DIR}:/data/repo`
  - `${RESTORE_DIR}:/data/restore` (target for `restic restore`)
- No published ports. Default bridge network is fine.
- Sensible log rotation (`logging: json-file`, `max-size: 10m`, `max-file: 3`).
- Consider a memory limit note in README (MEGAcmd and restic can both be RAM-hungry on
  small devices; restic's memory grows with repo size); don't hard-code a low limit.

### 5.6 .env.example

```
MEGA_REMOTE_PATH=/Backup/SomeFolder      # folder in the MEGA account
CONFIG_DIR=./config                      # MEGAcmd session, restic password, machine-id (keep private!)
SYNC_DIR=/home/umbrel/umbrel/home/mega-backup/current
REPO_DIR=/home/umbrel/umbrel/home/mega-backup/repo
RESTORE_DIR=/home/umbrel/umbrel/home/mega-backup/restore
PUID=1000
PGID=1000
TZ=UTC                                   # set to the user's timezone
BACKUP_TIME=03:30
KEEP_DAILY=90
KEEP_MONTHLY=24
MAX_DROP_PERCENT=20
MAX_CHANGE_PERCENT=20
CHECK_WEEKDAY=7                          # 1=Mon … 7=Sun
CHECK_READ_PERCENT=5
HEALTHCHECK_URL=                         # e.g. https://hc-ping.com/<uuid> (optional)
BACKUP_ON_START=0
ALLOW_NONEMPTY_INIT=0
```

The Umbrel paths are a best guess (umbrelOS 1.x keeps the Files app data under
`/home/umbrel/umbrel/home/`). The user must confirm on their device. `SYNC_DIR` and
`REPO_DIR` may be on different disks (a separate disk for the repo is more resilient).

### 5.7 README.md (for the user, not for agents)

Short and practical:
1. What it does + the diagram + the "sync is two-way, don't write into `current/`" rule.
2. Deploy on Umbrel: `ssh umbrel@umbrel.local`, clone/copy repo to e.g.
   `/home/umbrel/mega-backup`, `cp .env.example .env`, edit, `docker compose up -d --build`.
   (Portainer from the Umbrel App Store is an alternative; note it may not build images
   from a compose file — check and document what works.)
3. First login: `docker exec -it mega-backup mega-login you@example.com`
   (2FA: `--auth-code=123456`). Then `docker logs -f mega-backup`.
4. **Save the restic password** (`config/restic-password`) somewhere off the device
   (password manager). Without it the backups are unreadable.
5. Check status: `docker exec mega-backup mega-sync`,
   `docker exec mega-backup restic snapshots`, run a backup now (`backup.sh`).
6. Restore:
   - list: `restic snapshots`, browse: `restic ls <id> [path]`, compare: `restic diff <a> <b>`
   - restore: `restic restore <id> --target /data/restore [--include <path>]`, then copy
     from `RESTORE_DIR` on the host.
   - `restic mount` needs FUSE/privileged mode — not supported in this setup.
   - Restoring without this container: any machine with `restic`, a copy of the repo
     folder and the password.
7. Prune hold: what the FAIL message means, how to inspect (`restic diff`), how to clear
   (`rm /config/prune-hold`).
8. Security: `config/` contains a session with full access to the MEGA account and the
   repo password.
9. Things to check once (see §7).
10. MEGA side: rubbish bin retention and file versioning settings.
11. Future options: off-site copy of the repo (`restic copy` to B2/S3/another disk).

## 6. Testing (do this in a local dev container with Docker; no Umbrel device needed)

Docker is available here. You do **not** have MEGA credentials — do not try to obtain
or guess any.

Without an account, test what you can:
- Image builds (`docker compose build`); ideally also `docker buildx build --platform
  linux/arm64` if buildx/qemu is available (skip if not, and say so). Confirm
  `restic version` runs on each built arch.
- `mega-cmd-server` starts in the container; logged-out path logs the login hint and
  the container stays up; SIGTERM stops it within a few seconds.
- machine-id persistence across container recreation.
- Repo setup: password generated once; repo initialised on first start; **not**
  re-initialised when `/data/repo` is emptied but `/config/restic-repo-id` exists;
  repo-ID mismatch fails.
- `backup.sh` logic in isolation: make it testable by allowing the sync health check
  to be skipped (e.g. `SKIP_SYNC_CHECK=1`, test-only, documented as such). Use fake
  data in temp dirs to test: first backup; unchanged second run adds ~no data
  (`data_added` ≈ 0); renaming a folder adds ~no data; changed file shows up in
  `restic diff`; deleted file still restorable from the older snapshot; `.debris`
  excluded; empty-source guard; drop guard and change guard each create
  `prune-hold`; hold persists across runs and blocks forget until removed; forget
  retention with synthetic snapshots (`restic backup --time <date>`, DRY_RUN and real);
  stale lock is cleared; `flock` prevents overlapping runs.
- `shellcheck` all scripts if available (install it in a throwaway container if needed).
- Put these in `tests/backup_test.sh`, runnable inside the container.

With an account (only if the user provides a **throwaway/test** account or does the
login themselves): end-to-end — login, sync creation, file appears locally, delete on
MEGA → check local `.debris` behavior, backup, restore.

## 7. Unverified facts — confirm and record results in README

- Exact `mega-sync` listing format / states in MEGAcmd 2.6 (needed for §5.4.2).
- Whether MEGAcmd sync moves locally-removed files into `<sync root>/.debris`
  (MEGA desktop app does; same SDK, likely but unconfirmed).
- That `mega-whoami` (or similar) gives a usable exit code for HEALTHCHECK.
- That `--auth-code` is the right 2FA flag for `mega-login` in 2.6.
- That the session survives container restarts/recreation with `/config` persisted.
- Whether a stable `/etc/machine-id` is actually required (keep it anyway; it's cheap).
- restic: field names in the `backup --json` summary and in `snapshots --json`
  `.summary` on the pinned version (needed for §5.4.5).
- restic memory use on the target device with a realistic repo size.
- MEGA rubbish-bin retention for the user's account type (user-side check).

## 8. Out of scope

- Off-site third copy of the repo (mention `restic copy` in README as a future option).
- Notifications other than the healthchecks.io-style URL.
- Any change on the user's MEGA account or the Umbrel device. Deployment is done by
  the user following README.

## 9. Done when

- All files in §4 exist, scripts pass shellcheck, image builds.
- §6 offline tests pass (`tests/backup_test.sh`) and are described briefly in a README
  "Development" section.
- §7 items are either verified or clearly listed as "still to verify on first run".
- Report back to the user: what was built, what was tested, what remains unverified.
- Do not commit or push unless the user asks.

## 10. Implementation notes (decisions taken while implementing, 2026-10-23)

Taken autonomously while the user was away; listed here for review.

1. **`docker exec` runs as PUID.** The Dockerfile puts a wrapper for every `mega-*`
   client and for `restic` in `/usr/local/bin` (ahead of `/usr/bin` in PATH) that
   drops to PUID:PGID via `as-user.sh`; `backup.sh` re-executes itself the same way.
   Reason: verified that a MEGAcmd client started without a reachable server starts
   its own server as the calling user, so root `docker exec` calls would have created
   root-owned state or a second server.
2. **Empty-folder (mount) guard** in `main.sh`: once the sync exists and `current/` had
   content (`/config/sync-established`), MEGAcmd is not started while `current/` is
   empty. Protects MEGA from a missing disk/bind mount looking like "everything deleted".
3. **Repo setup runs before MEGA login**, so the password banner appears on first
   start and the repo logic is testable without an account.
4. **Health check** checks `pgrep mega-cmd-server` before `mega-whoami`, so it never
   starts a server itself.
5. **Mass-change guard uses `restic diff`** (removed files, content-changed files)
   rather than the backup summary, because the summary counts timestamp-only changes
   as "changed" (verified). Previous file count comes from the previous snapshot's
   `.summary.total_files_processed`.
6. **Prune hold file is `/config/prune-hold`**; forget/prune is also skipped when the
   backup exited non-zero (e.g. exit 3 = some files unreadable).
7. **Catch-up:** if the newest snapshot is older than 26 h at container start, a backup
   runs immediately (no catch-up before the first snapshot exists).
8. **Compose:** `init: true`, `stop_grace_period: 60s`, `hostname: mega-backup`,
   `image: mega-backup:local`, and `${VAR:?}` so missing paths fail fast.
9. **`.env.example` has comments on their own lines**: Docker Compose turned
   `HEALTHCHECK_URL=   # comment` into the value "# comment" (verified).
10. **restic 0.19.1** pinned (latest release older than two weeks), SHA256-verified.
11. **MEGAcmd server log** goes to `/config/.megaCmd/megacmdserver.log` (very verbose
    at DBG level, not useful in `docker logs`).
12. **Verified facts (§7):** `mega-sync` columns/values (from `--help` and MEGAcmd
    2.6.0 source: healthy = `RUN_STATE` Running, `ERROR` NO; conflicts show as
    `Sync Issues (n)`; file column is `FILES`), `mega-whoami` exit 0/57,
    `--auth-code` flag, `mega-login <email>` prompts for the password, socket at
    `$HOME/.megaCmd/megacmd.socket`, megacmd postinst works without systemd, restic
    JSON fields. Session persistence, `.debris` behaviour and memory use still need a
    real account/device (listed in README).
13. **arm64:** image builds; both test suites pass under qemu emulation. Not run on
    real arm64 hardware.
