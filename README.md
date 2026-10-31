# mega-backup

Keeps an independent backup of one or more MEGA folders on your Umbrel's disk, in
case something happens to MEGA (account closed, files deleted, files corrupted).

```
MEGA /Photos  <── MEGAcmd sync (official, 2-way) ──>  current/Photos   (Umbrel disk)
MEGA /Work    <── MEGAcmd sync (official, 2-way) ──>  current/Work
                                                          │
                                         nightly `restic backup`, one snapshot per folder
                                                          ▼
                                             repo/   (restic repository:
                                             deduplicated, encrypted snapshots)
```

- **Folders.** Each MEGA folder you pick (on the Setup page, then the Folders page) is
  synced with a sub-folder of the same name in `current/`, by MEGA's official MEGAcmd
  client. Folders can be added and removed at any time. Two synced MEGA folders can't
  be inside one another (MEGA doesn't allow nested syncs).
- **`repo/`** holds the history. Every night each folder gets its own restic snapshot.
  Snapshots are deduplicated, so 90 daily + 24 monthly snapshots cost little more
  than one copy, as long as most files don't change.
- **Space is freed.** After every backup, snapshots past the retention period are
  removed and `restic prune` deletes the data no remaining snapshot needs.

> **Rule: don't write into the synced folders unless you mean it.** The sync is
> two-way. Anything you add, change or delete there is copied up to MEGA. (Deletions
> end up in MEGA's rubbish bin, so they are recoverable, but don't rely on that.)
> Other items directly in `current/` are not synced and not backed up.

## What it protects against

| Problem | What saves you |
|---|---|
| MEGA account closed or lost | `current/` and `repo/` on the Umbrel |
| Files deleted on MEGA | Older snapshots in `repo/` |
| Files overwritten / encrypted on MEGA | Older snapshots in `repo/`, plus the mass-change alert (below) |
| Umbrel disk dies | MEGA still has everything (but no history; see "Future options") |

## Deploy on Umbrel

1. SSH into the Umbrel and copy this folder there:
   ```sh
   ssh umbrel@umbrel.local
   git clone <this repo> /home/umbrel/mega-backup   # or copy it with scp
   cd /home/umbrel/mega-backup
   cp .env.example .env
   nano .env
   ```
2. In `.env`, set `TZ` and check the paths (see [Paths on Umbrel](#paths-on-umbrel)).
   `MEGA_REMOTE_PATH` is optional: you pick MEGA folders in the web page instead.
   Set `APP_PASSWORD` to choose the web page's password (otherwise one is generated).
3. Build and start:
   ```sh
   docker compose up -d --build
   docker logs -f mega-backup
   ```
4. Open **http://umbrel.local:2947** (or your machine's address; the port is
   `WEB_PORT`) and log in with the app password. If you didn't set one:
   ```sh
   docker exec mega-backup cat /config/app-password
   ```
5. Follow the **Setup** page:
   - **MEGA login:** email, password, and the 2FA code if your account has it. The
     password goes straight to MEGAcmd and isn't stored; MEGAcmd keeps a session in
     `config/`, so this survives restarts and rebuilds.
   - **Backup password:** copy the restic password into your password manager
     **now**. Without it the backups can't be read, not even by you.
   - **What to sync:** browse your MEGA folders and pick one (skipped if
     `MEGA_REMOTE_PATH` is set). Add more later on the **Folders** page.
6. The Status page then shows the sync downloading into `current/<folder>`. The first backup
   runs at `BACKUP_TIME`. To run one right away (after the download finishes):
   `docker exec mega-backup backup.sh`.

**Without the web page** (e.g. over SSH only), the same steps work in a terminal:
```sh
docker exec mega-backup cat /config/restic-password     # save it
docker exec -it mega-backup mega-cmd
MEGA CMD> login you@example.com
Password:                     # typed, not shown
MEGA CMD> exit --only-shell
```
Use `exit --only-shell`: a plain `exit` (or `quit`) stops the MEGAcmd server too
(the container then restarts). Don't use `mega-login email password`: it puts the
password on the command line. MEGAcmd can't take passwords containing `"` or `\`,
in the web page or the terminal.

A folder's sync is only created if its local folder is empty (or new). That avoids
merging stray local files up into MEGA by mistake; the web page asks before merging.

**Upgrading from 1.0 (one MEGA folder):** on the first start, the app removes the old
sync (nothing changes on MEGA), moves the content of `current/` into
`current/<name of the MEGA folder>/`, and syncs that folder again. MEGA finds the
files already there and transfers nothing. Snapshots taken before stay available on
the Snapshots page ("Whole MEGA folder") until they expire.

**Portainer:** the Umbrel App Store's Portainer may not build images from a
Dockerfile on the device (not tested). The SSH route above is the supported one.

**Memory:** MEGAcmd and restic can both use a few hundred MB of RAM with large
folders. On a small device (e.g. a 4 GB Raspberry Pi) watch `docker stats` during the
first sync and backup. You can add a `mem_limit:` in `docker-compose.yml` if needed,
but too low a limit will make them crash.

### Paths on Umbrel

The defaults put everything under `/home/umbrel/umbrel/home/mega-backup/`, which
umbrelOS 1.x shows in the Files app. Check this folder exists on your device
(`ls /home/umbrel/umbrel/home`). `REPO_DIR` can be on a different disk from
`SYNC_DIR`. That's actually better.

`CONFIG_DIR` (default `./config`, next to `docker-compose.yml`) contains the MEGA
session and the restic password. Keep it private.

## Everyday commands

All of these run as the right user automatically.

```sh
docker logs -f mega-backup                         # what's happening
docker exec mega-backup mega-sync                  # sync state (want: Running / Synced / NO)
docker exec mega-backup mega-sync-issues           # details if ERROR says "Sync Issues (n)"
docker exec mega-backup restic snapshots           # list backups
docker exec mega-backup backup.sh                  # run a backup now
docker exec mega-backup restic stats --mode raw-data   # space used by the repo
docker exec mega-backup forget.sh --snapshot <id>  # delete a snapshot and free its space
```

## Restore

Snapshots live in the restic repo, not as plain folders. To get files back:

```sh
# 1. Find the snapshot
docker exec mega-backup restic snapshots

# 2. Look inside it / compare two snapshots
docker exec mega-backup restic ls 1a2b3c4d /data/current/Photos/Some/Folder
docker exec mega-backup restic diff 1a2b3c4d 5e6f7a8b

# 3. Restore (everything, or only some paths) into RESTORE_DIR
docker exec mega-backup restic restore 1a2b3c4d --target /data/restore
docker exec mega-backup restic restore 1a2b3c4d --target /data/restore --include /data/current/Photos/Some/Folder
```

Files appear in `RESTORE_DIR` on the host under `data/current/...`. Copy them where
you need them. To put them back on MEGA, upload them in the MEGA app, or copy them
into the synced folder (they will sync up). The web page's Snapshots page does all
of this with buttons, and never overwrites anything.

`restic mount` (browse snapshots as folders) is not available in this container.

**Restoring without this container:** all you need is the `restic` program, a copy of
the `repo/` folder and the password:
`restic -r /path/to/repo restore latest --target ./restored`.

## Alerts and the prune hold

Set `HEALTHCHECK_URL` to a [healthchecks.io](https://healthchecks.io) check (free) to
get an email when a nightly run fails or doesn't happen. A run reports **fail** when:

- a folder's MEGA sync isn't healthy (paused, error, sync issues, not logged in);
- a folder is empty (no backup is taken of it; the other folders are still backed up);
- the repo can't be opened, or a restic command fails;
- **more than `MAX_DROP_PERCENT` of files were removed, or more than
  `MAX_CHANGE_PERCENT` changed content, since the previous backup.**

The last case means something may have deleted or overwritten many files on MEGA.
The backup is still taken, but **removing old snapshots stops** and stays stopped
until you clear it (the Status page links to the details, with a button). Normal
clean-up would otherwise slowly remove the good snapshots. While it is on hold the
Backup folder grows, and each night keeps failing with "prune on hold" as a reminder.
Without the web page:

```sh
docker exec mega-backup cat /config/prune-hold         # what happened, which snapshots
docker exec mega-backup restic diff <before> <after>   # see exactly what changed
# If it was intended (you really deleted/changed those files):
docker exec mega-backup rm /config/prune-hold
# If not: restore from the <before> snapshot (see Restore), fix things on MEGA.
```

Changing only file timestamps doesn't count as a change. Content changes do.

## How old snapshots are removed

After every backup (also one with problems, such as an unreadable file):

1. **Folders that are synced:** each keeps every snapshot from the last 2 days, then
   one per day for `KEEP_DAILY` days and one per month for `KEEP_MONTHLY` months.
2. **Folders that are no longer synced** (removed on the Folders page, or the single
   folder from before 1.1): their snapshots stay until the newest one is older than
   the retention period (`KEEP_MONTHLY` months, or `KEEP_DAILY` days if longer), then
   they are all removed. They can also be deleted right away on the Snapshots page.
3. `restic prune` deletes the data that no remaining snapshot uses. The Status page
   shows the Backup folder's size and what the last clean-up freed.

The Snapshots page's **Kept until** column shows, for each snapshot, which rule keeps
it and an estimated date (assuming a backup every night from now on; days without a
backup push the dates later). Only a prune hold (above) stops steps 1 and 2. Single snapshots can be deleted on
their page; files that other snapshots also contain stay, so this may free little.

## Safety guards

- **Empty folder at startup.** Once a folder's sync is set up and has files, if that
  folder is ever empty or missing when the container starts (disk not mounted, wrong
  `SYNC_DIR`), MEGAcmd is **not started**. The Status page and the logs say why. This
  stops an empty folder from being synced up to MEGA as "delete everything". If the
  folder really is empty on purpose, confirm it on the Status page.
- **Folder list.** A sync is only removed when you remove its folder on the Folders
  page. If `config/pairs.json` can't be read, nothing is changed.
- **Missing repo.** If `repo/` disappears after it was created, a new empty repo is
  **not** created silently. Backups fail until the disk/mount is fixed.
- **Missed runs.** If the container was down at `BACKUP_TIME` and the last backup is
  more than 26 h old, a backup runs at startup.
- **Weekly check.** On `CHECK_WEEKDAY`, `restic check` verifies the repo and re-reads
  `CHECK_READ_PERCENT`% of the data.

## Settings (`.env`)

Choices made in the web page are saved in `config/settings.json` and take precedence
over `.env`.

| Variable | Default | Meaning |
|---|---|---|
| `MEGA_REMOTE_PATH` | empty | first MEGA folder to sync, if none is set up yet (or pick it on the Setup page) |
| `WEB_PORT` | 2947 | port of the web page on this machine |
| `APP_PASSWORD` | generated | password for the web page (`/config/app-password` if generated) |
| `CONFIG_DIR` / `SYNC_DIR` / `REPO_DIR` / `RESTORE_DIR` | see `.env.example` | host folders |
| `PUID` / `PGID` | 1000 | owner of all files (1000 = `umbrel` user) |
| `TZ` | UTC | timezone for `BACKUP_TIME` and logs |
| `BACKUP_TIME` | 03:30 | daily backup time |
| `KEEP_DAILY` / `KEEP_MONTHLY` | 90 / 24 | snapshots kept |
| `MAX_DROP_PERCENT` / `MAX_CHANGE_PERCENT` | 20 / 20 | mass-change alert thresholds |
| `CHECK_WEEKDAY` / `CHECK_READ_PERCENT` | 7 / 5 | weekly repo check |
| `HEALTHCHECK_URL` | empty | healthchecks.io-style ping URL |
| `BACKUP_ON_START` | 0 | 1 = back up on every container start |
| `ALLOW_NONEMPTY_INIT` | 0 | 1 = with `MEGA_REMOTE_PATH`: allow syncing into a non-empty folder |

Retention keeps every snapshot from the last 2 days, then one per day (the day's
last) for `KEEP_DAILY` days and one per month for `KEEP_MONTHLY` months.

For `backup.sh` run by hand: `DRY_RUN=1` (show what pruning would delete) and
`FORCE_CHECK=1` (run the repo check now), e.g.
`docker exec -e DRY_RUN=1 mega-backup backup.sh`.

## Security

- `config/` contains a MEGA session with **full access to your MEGA account**, and
  the restic password. Don't share it or put it in a public place.
- The repo is encrypted, so a copy of `repo/` alone is useless without the password.
- Your MEGA password is never stored. Only the session is.
- The web page can control your MEGA account, so it has its own password, even on
  your home network. Logins are rate-limited.

## MEGA-side settings worth checking

- **`.megaignore`**: MEGA puts this file in the synced folder. By default it skips
  hidden files (names starting with `.`), `~*`, `*.tmp`, `Thumbs.db` and similar, so
  those are neither synced nor backed up. Edit it (in MEGA or `current/`) if you need them.

- **Rubbish bin retention**: how long MEGA keeps deleted files (depends on your plan).
- **File versioning**: on by default; keeps old versions of changed files on MEGA.

## Things to check after the first real run

Verified while building this (MEGAcmd 2.6.0, restic 0.19.1):
- `mega-sync` columns and values (`RUN_STATE` Running, `ERROR` NO when healthy).
- `mega-whoami` exits 0 when logged in and 57 when not. The web page uses it.
- One-shot `mega-login <email>` does NOT ask for the password ("Extra args required
  in non-interactive mode"); `login <email>` inside the `mega-cmd` shell does, and the
  shell uses the already-running server.
- restic's JSON output fields used by the mass-change alert.

Still to verify on the first real run (needs a MEGA account):
- [x] The session survives `docker compose down && up` (tested 2026-10-29, MEGAcmd 2.7.0).
- [x] A file deleted on MEGA ends up in `current/.debris/<date>/` locally (tested).
- [x] `mega-sync` shows `Running  Synced  NO`; local adds go up to MEGA; mass deletion
      sets the prune hold; restore works; empty-folder guard blocks MEGAcmd (tested on a PC).
- [ ] Memory use is fine on your device during the first sync and backup.
- [ ] After the next umbrelOS update, the container is still there and running
      (`docker ps`). If not, run `docker compose up -d` again from the repo folder.
- [ ] Your MEGA plan's rubbish-bin retention.

## Future options

- Off-site copy of the history: `restic copy` to a second repo (USB disk, Backblaze
  B2, another machine).

## Development

```sh
docker compose build
# backup.sh logic (no MEGA account needed), inside the image:
docker run --rm -u 1000:1000 -v "$PWD/tests:/tests:ro" --entrypoint bash \
  mega-backup:local /tests/backup_test.sh
# folder pairs (MEGAcmd faked): guard, migration, adding/removing syncs:
docker run --rm -u 1000:1000 -v "$PWD/tests:/tests:ro" --entrypoint bash \
  mega-backup:local /tests/pairs_test.sh
# web UI (MEGAcmd faked): app login, CSRF, MEGA login incl. 2FA, setup, status:
docker run --rm -u 1000:1000 -v "$PWD/tests:/tests:ro" --entrypoint python3 \
  mega-backup:local -I /tests/web_test.py
# whole-container behaviour (logged out): startup, guards, stop, permissions:
tests/container_test.sh
# lint
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 -x -P scripts scripts/*.sh tests/*.sh
```

`backup_test.sh` covers: empty source; first backup; dedup (unchanged run and folder
rename add almost no data); deleted/changed files restorable; timestamp-only changes
don't trip the alert; mass deletion and mass overwrite set the sticky prune hold;
retention with old snapshots (dry run and real); stale lock left by a killed restic;
no concurrent runs; repo ID mismatch / missing repo; `last-run.json`; settings
precedence and invalid values; refusing to back up when the Backup folder isn't
mounted; healthcheck start/fail/success pings with the log as body; clean-up runs
after a partial backup; prune frees the space of forgotten snapshots; one snapshot per
folder, compared only with its own folder; an empty folder doesn't stop the others;
snapshots of folders no longer synced expire (but not with a broken folder list, and
never those of a synced folder); deleting snapshots by hand (`forget.sh`).

`pairs_test.sh` covers: the start-up guard (empty or missing folder, MEGA folder not
mounted); the move from the single-folder setup (old sync removed, everything moved
incl. hidden files and a same-name folder, markers moved, resumes after a crash);
syncs created and removed per folder (files kept); non-empty folders need the merge
confirmation; missing and nested MEGA folders refused; unknown syncs and a broken or
empty folder list never remove a sync.

`web_test.py` covers: every page needs the app login; CSRF on every form; login
rate limit; no open redirect; MEGA login (wrong password, OK, 2FA, input checks; the
password never reaches a command line, environment or file, and the shell is left
with `exit --only-shell`); restic password step; MEGA folder browser and first folder
(non-empty folder needs the merge confirmation; bad paths and names refused); Folders
page (add, nested/duplicate refused, remove, re-add only after the sync is gone, merge
button, unsynced items listed, broken list never overwritten); empty-folder guard
confirmation; status API; snapshots per folder (browse, diff within the folder,
folders no longer synced, delete a folder's snapshots or one snapshot); prune hold and
running-backup detection; log page; settings precedence/validation.

`container_test.sh` covers: first start (password, repo init, login hint, one server
as PUID, web UI up as PUID and behind its login, health check passes when logged
out, engine status, private app log); `docker exec` commands run as PUID and don't
start a second server; manual backup leaves nothing root-owned; the container exits
if the web UI dies; stop in < 10 s; machine-id and repo persist across recreation;
missing repo not re-created; empty-folder guard blocks MEGAcmd until the folder has
content; overlapping folders detected; no repo created without a mounted Backup
folder; MEGAcmd not started when the MEGA folder isn't mounted after a sync existed.

`SKIP_SYNC_CHECK=1` skips the MEGA sync check in `backup.sh`. It's for tests only.

Files: `scripts/entrypoint.sh` (root: machine-id, permissions, drop to PUID),
`supervise.sh` (runs the engine and the web UI; stops both if one exits),
`logsink.py` (copies output to `config/logs/app.log`), `main.sh` (the engine: guards,
repo setup, MEGAcmd, login and setup wait, syncs, scheduler), `pairs.sh` (folder
pairs: guard, migration, creating/removing syncs), `backup.sh` (one nightly run),
`forget.sh` (delete snapshots and prune), `healthcheck.sh` (MEGAcmd server and web UI up), `as-user.sh` (makes `docker exec` commands run as
PUID; the Dockerfile puts a wrapper for every `mega-*` command and `restic` in front of
the real ones), `lib.sh` (shared helpers, settings loader, mount checks).
`share/settings-schema.json` lists every setting with its default and validation;
the engine and the web UI both read it. `web/` is the web UI (Flask, served by
waitress): `app.py` (pages, login, CSRF), `engine.py` (reads state), `megalogin.py`
(MEGA login through the `mega-cmd` shell), `settings.py`, `pairs.py` (the folder list),
`restic.py` (snapshots, browse, restore), `jobs.py` (background jobs).

### Releasing

Push a tag such as `v1.0.0`. The GitHub Actions workflow
(`.github/workflows/release.yml`) runs the tests, then builds the image for amd64 and
arm64 and publishes `ghcr.io/ppppso/mega-backup:1.0.0`. Its summary shows the
`image: …@sha256:…` line to put in the Umbrel package
([ppppso/umbrel-app-store](https://github.com/ppppso/umbrel-app-store)).

MEGAcmd is pinned in the Dockerfile by version and checksum. MEGA's repository keeps
only the latest version, so after a MEGA release the build stops at the checksum
step: take the new version and both checksums from
`https://mega.nz/linux/repo/Debian_12/Packages`.
