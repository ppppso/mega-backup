# mega-backup

Keeps an independent backup of one MEGA folder on your Umbrel's disk, in case
something happens to MEGA (account closed, files deleted, files corrupted).

```
MEGA cloud folder  <── MEGAcmd sync (official, 2-way) ──>  current/   (Umbrel disk)
                                                              │
                                                   nightly `restic backup`
                                                              ▼
                                                 repo/   (restic repository:
                                                 deduplicated, encrypted snapshots)
```

- **`current/`** is a live mirror of the MEGA folder, kept up to date by MEGA's
  official MEGAcmd client.
- **`repo/`** holds the history. Every night a restic snapshot of `current/` is taken.
  Snapshots are deduplicated, so 90 daily + 24 monthly snapshots cost little more
  than one copy, as long as most files don't change.

> **Rule: don't write into `current/`.** The sync is two-way. Anything you add, change
> or delete there is copied up to MEGA. (Deletions end up in MEGA's rubbish bin, so
> they are recoverable, but don't rely on that.)

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
2. In `.env`, set at least `MEGA_REMOTE_PATH` (the MEGA folder, e.g. `/Photos`) and
   `TZ`. Check the paths (see [Paths on Umbrel](#paths-on-umbrel)).
3. Build and start:
   ```sh
   docker compose up -d --build
   docker logs -f mega-backup
   ```
4. **Save the restic password.** On first start the logs say a password was
   generated. Copy it into your password manager **now**:
   ```sh
   docker exec mega-backup cat /config/restic-password
   ```
   Without it the backups can't be read, not even by you.
5. **Log in to MEGA (once):**
   ```sh
   docker exec -it mega-backup mega-login you@example.com
   ```
   It asks for your password. With two-factor auth, add `--auth-code=123456`.
   The session is stored in `config/`, so this survives restarts and rebuilds.
6. Watch `docker logs -f mega-backup`. It creates the sync and MEGAcmd starts
   downloading into `current/`. The first backup runs at `BACKUP_TIME`.
   To run one right away (after the download finishes): `docker exec mega-backup backup.sh`.

The sync is only created if `current/` is empty. That avoids merging stray local
files up into MEGA by mistake. Override with `ALLOW_NONEMPTY_INIT=1` only if you
want that merge.

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
```

## Restore

Snapshots live in the restic repo, not as plain folders. To get files back:

```sh
# 1. Find the snapshot
docker exec mega-backup restic snapshots

# 2. Look inside it / compare two snapshots
docker exec mega-backup restic ls 1a2b3c4d /data/current/Some/Folder
docker exec mega-backup restic diff 1a2b3c4d 5e6f7a8b

# 3. Restore (everything, or only some paths) into RESTORE_DIR
docker exec mega-backup restic restore 1a2b3c4d --target /data/restore
docker exec mega-backup restic restore 1a2b3c4d --target /data/restore --include /data/current/Some/Folder
```

Files appear in `RESTORE_DIR` on the host under `data/current/...`. Copy them where
you need them. To put them back on MEGA, upload them in the MEGA app, or copy them
into `current/` (they will sync up).

`restic mount` (browse snapshots as folders) is not available in this container.

**Restoring without this container:** all you need is the `restic` program, a copy of
the `repo/` folder and the password:
`restic -r /path/to/repo restore latest --target ./restored`.

## Alerts and the prune hold

Set `HEALTHCHECK_URL` to a [healthchecks.io](https://healthchecks.io) check (free) to
get an email when a nightly run fails or doesn't happen. A run reports **fail** when:

- the MEGA sync isn't healthy (paused, error, sync issues, not logged in);
- `current/` is empty (no backup is taken);
- the repo can't be opened, or a restic command fails;
- **more than `MAX_DROP_PERCENT` of files were removed, or more than
  `MAX_CHANGE_PERCENT` changed content, since the previous backup.**

The last case means something may have deleted or overwritten many files on MEGA.
The backup is still taken, but **pruning old snapshots stops** and stays stopped
until you clear it. Normal pruning would otherwise slowly remove the good snapshots.
Each night keeps failing with "prune on hold" as a reminder. To handle it:

```sh
docker exec mega-backup cat /config/prune-hold         # what happened, which snapshots
docker exec mega-backup restic diff <before> <after>   # see exactly what changed
# If it was intended (you really deleted/changed those files):
docker exec mega-backup rm /config/prune-hold
# If not: restore from the <before> snapshot (see Restore), fix things on MEGA.
```

Changing only file timestamps doesn't count as a change. Content changes do.

## Safety guards

- **Empty folder at startup.** Once the sync is set up, if `current/` is ever empty when
  the container starts (disk not mounted, wrong `SYNC_DIR`), MEGAcmd is **not started**.
  The logs say why. This stops an empty folder from being synced up to MEGA as "delete
  everything". If the MEGA folder really is empty on purpose:
  `docker exec mega-backup rm /config/sync-established`.
- **Missing repo.** If `repo/` disappears after it was created, a new empty repo is
  **not** created silently. Backups fail until the disk/mount is fixed.
- **Missed runs.** If the container was down at `BACKUP_TIME` and the last backup is
  more than 26 h old, a backup runs at startup.
- **Weekly check.** On `CHECK_WEEKDAY`, `restic check` verifies the repo and re-reads
  `CHECK_READ_PERCENT`% of the data.

## Settings (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `MEGA_REMOTE_PATH` | (required) | MEGA folder to back up |
| `CONFIG_DIR` / `SYNC_DIR` / `REPO_DIR` / `RESTORE_DIR` | see `.env.example` | host folders |
| `PUID` / `PGID` | 1000 | owner of all files (1000 = `umbrel` user) |
| `TZ` | UTC | timezone for `BACKUP_TIME` and logs |
| `BACKUP_TIME` | 03:30 | daily backup time |
| `KEEP_DAILY` / `KEEP_MONTHLY` | 90 / 24 | snapshots kept |
| `MAX_DROP_PERCENT` / `MAX_CHANGE_PERCENT` | 20 / 20 | mass-change alert thresholds |
| `CHECK_WEEKDAY` / `CHECK_READ_PERCENT` | 7 / 5 | weekly repo check |
| `HEALTHCHECK_URL` | empty | healthchecks.io-style ping URL |
| `BACKUP_ON_START` | 0 | 1 = back up on every container start |
| `ALLOW_NONEMPTY_INIT` | 0 | 1 = allow creating the sync into a non-empty folder |

For `backup.sh` run by hand: `DRY_RUN=1` (show what pruning would delete) and
`FORCE_CHECK=1` (run the repo check now), e.g.
`docker exec -e DRY_RUN=1 mega-backup backup.sh`.

## Security

- `config/` contains a MEGA session with **full access to your MEGA account**, and
  the restic password. Don't share it or put it in a public place.
- The repo is encrypted, so a copy of `repo/` alone is useless without the password.
- Your MEGA password is never stored. Only the session is.

## MEGA-side settings worth checking

- **Rubbish bin retention**: how long MEGA keeps deleted files (depends on your plan).
- **File versioning**: on by default; keeps old versions of changed files on MEGA.

## Things to check after the first real run

Verified while building this (MEGAcmd 2.6.0, restic 0.19.1):
- `mega-sync` columns and values (`RUN_STATE` Running, `ERROR` NO when healthy).
- `mega-whoami` exits 0 when logged in and 57 when not. The Docker health check uses it.
- `--auth-code` is the 2FA option of `mega-login`, and `mega-login <email>` asks for
  the password.
- restic's JSON output fields used by the mass-change alert.

Still to verify on the first real run (needs a MEGA account):
- [ ] The session survives `docker compose down && up` (it should: it's in `config/`).
- [ ] A file deleted on MEGA ends up in `current/.debris/` locally (MEGA's desktop app
      does this; `.debris` is excluded from backups either way).
- [ ] `docker exec mega-backup mega-sync` shows `Running  Synced  NO` once the first
      download is done, and the nightly log has no sync problem.
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
# whole-container behaviour (logged out): startup, guards, stop, permissions:
tests/container_test.sh
# lint
docker run --rm -v "$PWD/scripts:/s:ro" -w /s koalaman/shellcheck:stable -x -P /s $(cd scripts && echo *.sh)
```

`backup_test.sh` covers: empty source; first backup; dedup (unchanged run and folder
rename add almost no data); deleted/changed files restorable; timestamp-only changes
don't trip the alert; mass deletion and mass overwrite set the sticky prune hold;
retention with old snapshots (dry run and real); stale lock left by a killed restic;
no concurrent runs; repo ID mismatch / missing repo; healthcheck start/fail/success
pings with the log as body.

`container_test.sh` covers: first start (password, repo init, login hint, one server
as PUID, health check fails when logged out); `docker exec` commands run as PUID and
don't start a second server; manual backup leaves nothing root-owned; stop in < 10 s;
machine-id and repo persist across recreation; missing repo not re-created;
empty-folder guard blocks MEGAcmd until the folder has content.

`SKIP_SYNC_CHECK=1` skips the MEGA sync check in `backup.sh`. It's for tests only.

Files: `scripts/entrypoint.sh` (root: machine-id, permissions, drop to PUID),
`main.sh` (guards, repo setup, MEGAcmd, login wait, sync, scheduler), `backup.sh`
(one nightly run), `healthcheck.sh`, `as-user.sh` (makes `docker exec` commands run as
PUID; the Dockerfile puts a wrapper for every `mega-*` command and `restic` in front of
the real ones), `lib.sh` (shared helpers).
