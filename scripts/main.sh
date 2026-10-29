#!/bin/bash
# The backup engine. Runs as PUID: starts MEGAcmd, waits for login and setup (done
# in the web UI, or via .env for the plain compose setup), makes sure the sync and
# the restic repo exist, then runs backup.sh once a day.
# Progress is written to /config/engine-status.json for the web UI (set_state).
set -euo pipefail
LOG_TAG=main
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

SOCKET="$HOME/.megaCmd/megacmd.socket"
SERVER_PID=""
BACKUP_PID=""
NEXT_BACKUP=""

cd /tmp   # MEGAcmd clients resolve relative paths against the cwd

shutdown() {
  log "Stopping..."
  if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    log "Interrupting running backup."
    kill -TERM "$BACKUP_PID" 2>/dev/null || true
  fi
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    mega-quit >/dev/null 2>&1 || kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  NEXT_BACKUP=""
  set_state stopped "Stopped."
  log "Stopped."
  exit 0
}
trap shutdown TERM INT

# Exit non-zero if our server died, so the container restarts.
check_server() {
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "mega-cmd-server has exited. See $HOME/.megaCmd/megacmdserver.log. Exiting so the container restarts."
    exit 1
  fi
}

# Sleep N seconds in steps of at most STEP (default 60) seconds, checking the server
# after each step.
wait_checking() {
  local left="$1" step
  while [ "$left" -gt 0 ]; do
    step=$(( left < ${2:-60} ? left : ${2:-60} ))
    isleep "$step"
    check_server
    left=$(( left - step ))
  done
}

load_settings
set_state starting "Starting."

# ---------------------------------------------------------------------------
# 1. Folder guards, before MEGAcmd starts (it resumes existing syncs right away).
#  - Not mounted: on Umbrel the "MEGA folder" was removed from the app settings,
#    or never picked. The path is then an empty folder inside the container.
#  - Mounted but empty, although a sync was set up before: the disk or bind mount is
#    probably missing.
# Either way, syncing could treat every file as deleted locally and delete it on
# MEGA too. Refuse to start MEGAcmd until it's fixed.
while true; do
  if sync_was_created && ! mount_ok "$MB_CURRENT"; then
    set_state folder-missing "The MEGA folder is not available. Pick it again in the app's Umbrel settings (or check SYNC_DIR), then restart the app."
    log_banner \
      "REFUSING TO START MEGAcmd: $MB_CURRENT is not mounted, but a sync was set up before." \
      "Syncing now could delete your files on MEGA. Pick the MEGA folder in the app's" \
      "settings on Umbrel (or check SYNC_DIR in .env), then restart. Re-checking every 5 minutes."
  elif [ -e "$SYNC_MARKER" ] && dir_is_empty "$MB_CURRENT"; then
    set_state guard-refusing "The MEGA folder is empty, but it had files before. The disk or folder is probably missing, so syncing is stopped to protect your files on MEGA."
    log_banner \
      "REFUSING TO START MEGAcmd: $MB_CURRENT is empty, but a sync was set up before." \
      "The disk or the folder mount is probably missing; syncing now could delete" \
      "your files on MEGA. Check the folder (Umbrel app settings, or SYNC_DIR in .env)." \
      "If the MEGA folder really is empty and this is intended, run:" \
      "  docker exec mega-backup rm $SYNC_MARKER" \
      "Re-checking every 5 minutes."
  else
    break
  fi
  isleep 300
done

# ---------------------------------------------------------------------------
# 2. Restic: password (shown in the web UI) and repository init. No MEGA needed.
REPO_PROBLEM=""
ensure_repo() {
  local pw="${RESTIC_PASSWORD_FILE:-$MB_CONFIG/restic-password}" id
  REPO_PROBLEM=""
  if [ ! -s "$pw" ]; then
    if [ -e "$REPO_ID_FILE" ]; then
      REPO_PROBLEM="The restic password file is missing, but a repository was created before. Restore the password file."
      log "ERROR: restic password file $pw is missing but a repo was created before. Restore the password file."
      return 1
    fi
    (umask 077; head -c 32 /dev/urandom | base64 > "$pw")
    log_banner \
      "Generated a new restic repository password: $pw" \
      "SAVE IT SOMEWHERE OFF THIS DEVICE (e.g. a password manager)." \
      "Without it the backups cannot be read. Open the app to see it, or run:" \
      "  docker exec mega-backup cat $pw"
  fi

  if ! mount_ok "$RESTIC_REPOSITORY"; then
    REPO_PROBLEM="No Backup folder chosen. Pick one in the app's Umbrel settings (or set REPO_DIR)."
    log "Backup folder $RESTIC_REPOSITORY is not mounted; not creating a repository inside the container."
    return 1
  fi

  if [ -e "$RESTIC_REPOSITORY/config" ]; then
    if ! id="$(restic_repo_id)"; then
      REPO_PROBLEM="Cannot open the restic repository (wrong password?)."
      log "ERROR: cannot open the restic repo at $RESTIC_REPOSITORY (wrong password?)."
      return 1
    fi
    if [ ! -e "$REPO_ID_FILE" ]; then
      echo "$id" > "$REPO_ID_FILE"
      log "Adopted existing restic repo $id."
    elif [ "$(cat "$REPO_ID_FILE")" != "$id" ]; then
      REPO_PROBLEM="The Backup folder holds a different repository than the one this app created."
      log "ERROR: repo at $RESTIC_REPOSITORY has ID $id, expected $(cat "$REPO_ID_FILE"). Wrong Backup folder?"
      return 1
    fi
    log "restic repo OK ($id)."
    return 0
  fi

  if [ -e "$REPO_ID_FILE" ]; then
    REPO_PROBLEM="The Backup folder has no repository, but one was created before. Is the right folder picked?"
    log_banner \
      "ERROR: no restic repo at $RESTIC_REPOSITORY, but one was created before ($(cat "$REPO_ID_FILE"))." \
      "The repo disk/mount is probably missing. Not creating a new empty repo." \
      "If you really want to start over: docker exec mega-backup rm $REPO_ID_FILE"
    return 1
  fi
  if ! dir_is_empty "$RESTIC_REPOSITORY"; then
    REPO_PROBLEM="The Backup folder is not empty and is not a restic repository. Pick an empty folder."
    log "ERROR: $RESTIC_REPOSITORY is not empty and is not a restic repo. Not touching it."
    return 1
  fi
  log "Initialising restic repo at $RESTIC_REPOSITORY"
  # Explicit error checks: `set -e` is off inside a function called with `||`.
  restic init || { REPO_PROBLEM="restic init failed."; log "ERROR: restic init failed."; return 1; }
  id="$(restic_repo_id)" || { REPO_PROBLEM="Cannot read the new repository's ID."; log "ERROR: cannot read the new repo's ID."; return 1; }
  echo "$id" > "$REPO_ID_FILE"
  log "restic repo created ($id)."
}
# Problems here are not fatal: the sync keeps running, and each nightly backup
# re-checks the repo and reports a failure.
ensure_repo || log "Backups will fail until the repo problem is fixed."

# ---------------------------------------------------------------------------
# 3. Start the MEGAcmd server. Its (very verbose) log goes to its own file.
rm -f "$SOCKET"
mega-cmd-server --do-not-log-to-stdout >/dev/null &
SERVER_PID=$!
log "Started mega-cmd-server (pid $SERVER_PID); its log: $HOME/.megaCmd/megacmdserver.log"

for _ in $(seq 1 120); do
  [ -S "$SOCKET" ] && break
  check_server
  isleep 0.5
done
[ -S "$SOCKET" ] || { log "mega-cmd-server did not open its socket within 60 s."; exit 1; }

# ---------------------------------------------------------------------------
# 4. Wait for login (done once in the web UI; the session persists in /config).
if ! mega-whoami >/dev/null 2>&1; then
  set_state waiting-login "Not logged in to MEGA. Log in on the Setup page."
  n=0
  while ! mega-whoami >/dev/null 2>&1; do
    # Remind every 10 minutes; check every 5 s so the UI moves on quickly.
    if [ $(( n % 120 )) = 0 ]; then
      log_banner \
        "Not logged in to MEGA. Open the app's web page and log in on the Setup page." \
        "Without the web page: docker exec -it mega-backup mega-cmd" \
        "then at the MEGA CMD> prompt: login you@example.com" \
        "(it asks for the password, and the 2FA code if enabled), then: exit --only-shell"
    fi
    n=$(( n + 1 ))
    wait_checking 5 5
  done
fi
log "Logged in as: $(mega-whoami 2>/dev/null | head -n1)"

# ---------------------------------------------------------------------------
# 5. Wait until a MEGA folder is chosen (Setup page, or MEGA_REMOTE_PATH in .env).
load_settings
if [ -z "$CFG_MEGA_REMOTE_PATH" ]; then
  set_state waiting-setup "Choose the MEGA folder to back up on the Setup page."
  log "Waiting for a MEGA folder to be chosen in the web UI."
  while [ -z "$CFG_MEGA_REMOTE_PATH" ]; do
    wait_checking 5 5
    load_settings
  done
fi

# ---------------------------------------------------------------------------
# 6. Make sure the sync between $MB_CURRENT and the MEGA folder exists.
SYNC_PROBLEM=""
ensure_sync() {
  local row remote want
  want="$(strip_slash "$CFG_MEGA_REMOTE_PATH")"
  SYNC_PROBLEM=""
  row="$(sync_row || true)"
  if [ -n "$row" ]; then
    remote="$(strip_slash "${row##*|}")"
    log "Sync exists: $MB_CURRENT <-> $remote (RUN_STATE|STATUS|ERROR: ${row%|*})"
    [ -e "$SYNC_CREATED" ] || date '+%F %T' > "$SYNC_CREATED"
    if [ "$remote" != "$want" ]; then
      log_banner \
        "WARNING: the existing sync points to '$remote', but the chosen MEGA folder is '$want'." \
        "Leaving it unchanged. To switch, remove the old sync and empty $MB_CURRENT first:" \
        "  docker exec mega-backup mega-sync -d $MB_CURRENT"
    fi
    return 0
  fi

  if ! mount_ok "$MB_CURRENT"; then
    SYNC_PROBLEM="No local MEGA folder chosen. Pick one in the app's Umbrel settings (or set SYNC_DIR)."
    log "Not creating the sync: $MB_CURRENT is not mounted (files would be lost on restart)."
    return 1
  fi
  if mounts_overlap "$MB_CURRENT" "$RESTIC_REPOSITORY"; then
    SYNC_PROBLEM="The MEGA folder and the Backup folder overlap. The Backup folder must not be inside the MEGA folder (or the other way round)."
    log "Not creating the sync: $MB_CURRENT and $RESTIC_REPOSITORY are the same folder or nested."
    return 1
  fi
  if ! mega-ls "$want" >/dev/null 2>&1; then
    SYNC_PROBLEM="The MEGA folder '$want' does not exist (or is not accessible)."
    log "ERROR: MEGA folder '$want' does not exist (or is not accessible)."
    return 1
  fi
  if ! dir_is_empty "$MB_CURRENT" && [ "$CFG_ALLOW_NONEMPTY_INIT" != 1 ]; then
    SYNC_PROBLEM="The local MEGA folder is not empty. A two-way sync would upload its files to MEGA. Empty it, or confirm the merge on the Setup page."
    log_banner \
      "Not creating the sync: $MB_CURRENT is not empty." \
      "A two-way sync would merge these local files up into MEGA." \
      "Empty the folder, or allow the merge (Setup page, or ALLOW_NONEMPTY_INIT=1)."
    return 1
  fi
  log "Creating sync: $MB_CURRENT <-> $want"
  if ! mega-sync "$MB_CURRENT" "$want"; then
    SYNC_PROBLEM="MEGAcmd could not create the sync. See the log."
    log "ERROR: mega-sync failed to create the sync."
    return 1
  fi
  date '+%F %T' > "$SYNC_CREATED"
}
until ensure_sync; do
  set_state sync-error "$SYNC_PROBLEM"
  log "Retrying in 1 minute."
  wait_checking 60
  load_settings
done

# Arm the mount guard once the sync exists and the local folder has content.
mark_sync_established() {
  if [ ! -e "$SYNC_MARKER" ] && [ -n "$(sync_row || true)" ] && ! dir_is_empty "$MB_CURRENT"; then
    date '+%F %T' > "$SYNC_MARKER"
    log "Sync established; empty-folder guard armed ($SYNC_MARKER)."
  fi
}
mark_sync_established

# ---------------------------------------------------------------------------
# 7. Scheduler. Settings are re-read every minute, so a new backup time applies
# without a restart.
run_backup() {
  mark_sync_established
  set_state backing-up "Backup running."
  /usr/local/bin/backup.sh &
  BACKUP_PID=$!
  local rc=0
  # `wait` returns early on a signal; the trap then exits.
  wait "$BACKUP_PID" || rc=$?
  BACKUP_PID=""
  [ "$rc" = 0 ] || log "Backup run finished with exit code $rc."
  # Retry the repo setup if it failed at start (e.g. the folder was fixed since).
  [ -z "$REPO_PROBLEM" ] || ensure_repo || true
  return 0
}

latest_snapshot_age() {
  local t
  t="$(restic snapshots --json --latest 1 --host "$RESTIC_HOST" --path "$MB_CURRENT" 2>/dev/null \
       | jq -r '.[0].time // empty')" || return 1
  [ -n "$t" ] || return 1
  echo $(( $(date +%s) - $(date -d "$t" +%s) ))
}

next_run() {
  local now next
  now=$(date +%s)
  next=$(date -d "today $CFG_BACKUP_TIME" +%s)
  [ "$next" -gt "$now" ] || next=$(date -d "tomorrow $CFG_BACKUP_TIME" +%s)
  echo "$next"
}

if [ "$CFG_BACKUP_ON_START" = 1 ]; then
  log "Backup on start is on: running a backup now."
  run_backup
elif age="$(latest_snapshot_age)" && [ "$age" -gt $(( 26 * 3600 )) ]; then
  log "Last backup is $(( age / 3600 )) h old (missed run?): running a backup now."
  run_backup
fi

while true; do
  load_settings
  NEXT_BACKUP="$(next_run)"
  log "Next backup: $(date -d "@$NEXT_BACKUP" '+%Y-%m-%d %H:%M %Z')"
  set_state running "${REPO_PROBLEM:-Running.}"
  # Wake every minute: re-read settings, and re-compute so clock changes (DST, NTP)
  # don't push the run off.
  while [ "$(date +%s)" -lt "$NEXT_BACKUP" ]; do
    left=$(( NEXT_BACKUP - $(date +%s) ))
    wait_checking $(( left < 60 ? left : 60 ))
    load_settings
    new="$(next_run)"
    if [ "$new" != "$NEXT_BACKUP" ] && [ "$new" -gt "$(date +%s)" ] \
       && [ "$(date -d "@$new" +%H:%M)" != "$(date -d "@$NEXT_BACKUP" +%H:%M)" ]; then
      NEXT_BACKUP="$new"
      log "Backup time changed. Next backup: $(date -d "@$NEXT_BACKUP" '+%Y-%m-%d %H:%M %Z')"
      set_state running "${REPO_PROBLEM:-Running.}"
    fi
  done
  run_backup
done
