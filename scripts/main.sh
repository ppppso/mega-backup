#!/bin/bash
# The backup engine. Runs as PUID: starts MEGAcmd, waits for login and setup (done
# in the web UI, or via .env for the plain compose setup), keeps one sync per folder
# pair (pairs.sh) and the restic repo, and runs backup.sh once a day.
# Progress is written to /config/engine-status.json for the web UI (set_state).
set -euo pipefail
LOG_TAG=main
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh
# shellcheck source=pairs.sh
. /usr/local/bin/pairs.sh

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
# See pairs_guard. Re-checked every 10 s, so a fix (or "continue" in the web UI)
# applies quickly; the banner is repeated every 5 minutes.
n=0
until pairs_guard; do
  set_state "$GUARD_STATE" "$GUARD_MSG"
  if [ $(( n % 30 )) = 0 ]; then
    log_banner "REFUSING TO START MEGAcmd: $GUARD_MSG" \
      "Syncing now could delete your files on MEGA. Fix the folder (Umbrel app settings," \
      "or SYNC_DIR in .env). If a folder really is meant to be empty, confirm it on the" \
      "app's Status page."
  fi
  n=$(( n + 1 ))
  isleep 10
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
# 5. Move a single-folder setup to folder pairs (once), then wait until at least
# one folder pair is set up (Folders page in the web UI).
load_settings
until pairs_migrate; do
  set_state sync-error "Moving to folder pairs failed; retrying. See the log."
  wait_checking 60
  load_settings
done
if [ -z "$(pairs_active 2>/dev/null)" ]; then
  set_state waiting-setup "Choose a MEGA folder to sync on the Setup page."
  log "Waiting for a folder pair to be set up in the web UI."
  while [ -z "$(pairs_active 2>/dev/null)" ]; do
    wait_checking 5 5
  done
fi

# ---------------------------------------------------------------------------
# 6. Keep the syncs in line with the folder pairs: now, and every minute after.
sync_pairs() {
  pairs_reconcile || true
}
sync_pairs

# ---------------------------------------------------------------------------
# 7. Scheduler. Settings are re-read every minute, so a new backup time applies
# without a restart.
run_backup() {
  sync_pairs
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
  t="$(restic snapshots --json --host "$RESTIC_HOST" 2>/dev/null \
       | jq -r 'map(.time) | max // empty')" || return 1
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

engine_message() {
  if [ -n "$REPO_PROBLEM" ]; then
    printf '%s' "$REPO_PROBLEM"
  elif [ "$PAIRS_PROBLEMS" -gt 0 ]; then
    printf '%s' "Running. $PAIRS_PROBLEMS folder(s) need attention: see the Folders page."
  else
    printf 'Running.'
  fi
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
  set_state running "$(engine_message)"
  # Wake every minute: re-read settings, and re-compute so clock changes (DST, NTP)
  # don't push the run off.
  while [ "$(date +%s)" -lt "$NEXT_BACKUP" ]; do
    left=$(( NEXT_BACKUP - $(date +%s) ))
    wait_checking $(( left < 60 ? left : 60 ))
    load_settings
    sync_pairs
    set_state running "$(engine_message)"
    new="$(next_run)"
    if [ "$new" != "$NEXT_BACKUP" ] && [ "$new" -gt "$(date +%s)" ] \
       && [ "$(date -d "@$new" +%H:%M)" != "$(date -d "@$NEXT_BACKUP" +%H:%M)" ]; then
      NEXT_BACKUP="$new"
      log "Backup time changed. Next backup: $(date -d "@$NEXT_BACKUP" '+%Y-%m-%d %H:%M %Z')"
      set_state running "$(engine_message)"
    fi
  done
  run_backup
done
