#!/bin/bash
# Runs as PUID: starts MEGAcmd, waits for login, makes sure the sync and the restic
# repo exist, then runs backup.sh once a day.
set -euo pipefail
LOG_TAG=main
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

MEGA_REMOTE_PATH="$(strip_slash "${MEGA_REMOTE_PATH:-}")"
BACKUP_TIME="${BACKUP_TIME:-03:30}"
BACKUP_ON_START="${BACKUP_ON_START:-0}"
ALLOW_NONEMPTY_INIT="${ALLOW_NONEMPTY_INIT:-0}"
SOCKET="$HOME/.megaCmd/megacmd.socket"

SERVER_PID=""
BACKUP_PID=""

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
  log "Stopped."
  exit 0
}
trap shutdown TERM INT

# Exit non-zero if our server died, so Docker restarts the container.
check_server() {
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "mega-cmd-server has exited. See $HOME/.megaCmd/megacmdserver.log. Exiting so Docker restarts the container."
    exit 1
  fi
}

# Sleep N seconds, waking every 60 s to check the server.
wait_checking() {
  local left="$1" step
  while [ "$left" -gt 0 ]; do
    step=$(( left < 60 ? left : 60 ))
    isleep "$step"
    check_server
    left=$(( left - step ))
  done
}

# ---------------------------------------------------------------------------
# 0. Config sanity
if [ -z "$MEGA_REMOTE_PATH" ] || [ "${MEGA_REMOTE_PATH#/}" = "$MEGA_REMOTE_PATH" ]; then
  log "MEGA_REMOTE_PATH must be set to an absolute MEGA path, e.g. /Backup/Photos (got '${MEGA_REMOTE_PATH}')."
  exit 1
fi
if ! [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  log "BACKUP_TIME must be HH:MM (24h), got '$BACKUP_TIME'."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Mount guard. If a sync was set up before and the local folder is now empty, the
# disk/bind mount is probably missing. Starting MEGAcmd then could treat every file
# as deleted locally and delete it on MEGA too. Refuse to start until it's fixed.
while [ -e "$SYNC_MARKER" ] && dir_is_empty "$MB_CURRENT"; do
  log_banner \
    "REFUSING TO START MEGAcmd: $MB_CURRENT is empty, but a sync was set up before." \
    "The disk or the SYNC_DIR mount is probably missing; syncing now could delete" \
    "your files on MEGA. Check SYNC_DIR in .env and that the disk is mounted." \
    "If the MEGA folder really is empty and this is intended, run:" \
    "  docker exec mega-backup rm $SYNC_MARKER" \
    "Re-checking every 5 minutes."
  isleep 300
done

# ---------------------------------------------------------------------------
# 2. Restic repository: password + init on first start only (no MEGA needed).
ensure_repo() {
  local pw="${RESTIC_PASSWORD_FILE:-$MB_CONFIG/restic-password}" id
  if [ ! -s "$pw" ]; then
    if [ -e "$REPO_ID_FILE" ]; then
      log "ERROR: restic password file $pw is missing but a repo was created before. Restore the password file."
      return 1
    fi
    (umask 077; head -c 32 /dev/urandom | base64 > "$pw")
    log_banner \
      "Generated a new restic repository password: $pw" \
      "COPY IT SOMEWHERE OFF THIS DEVICE (e.g. a password manager)." \
      "Without it the backups cannot be read. Show it with:" \
      "  docker exec mega-backup cat $pw"
  fi

  if [ -e "$RESTIC_REPOSITORY/config" ]; then
    if ! id="$(restic_repo_id)"; then
      log "ERROR: cannot open the restic repo at $RESTIC_REPOSITORY (wrong password?)."
      return 1
    fi
    if [ ! -e "$REPO_ID_FILE" ]; then
      echo "$id" > "$REPO_ID_FILE"
      log "Adopted existing restic repo $id."
    elif [ "$(cat "$REPO_ID_FILE")" != "$id" ]; then
      log "ERROR: repo at $RESTIC_REPOSITORY has ID $id, expected $(cat "$REPO_ID_FILE"). Wrong REPO_DIR?"
      return 1
    fi
    log "restic repo OK ($id)."
    return 0
  fi

  if [ -e "$REPO_ID_FILE" ]; then
    log_banner \
      "ERROR: no restic repo at $RESTIC_REPOSITORY, but one was created before ($(cat "$REPO_ID_FILE"))." \
      "The repo disk/mount is probably missing. Not creating a new empty repo." \
      "If you really want to start over: docker exec mega-backup rm $REPO_ID_FILE"
    return 1
  fi
  if ! dir_is_empty "$RESTIC_REPOSITORY"; then
    log "ERROR: $RESTIC_REPOSITORY is not empty and is not a restic repo. Not touching it."
    return 1
  fi
  log "Initialising restic repo at $RESTIC_REPOSITORY"
  # Explicit error checks: `set -e` is off inside a function called with `||`.
  restic init || { log "ERROR: restic init failed."; return 1; }
  id="$(restic_repo_id)" || { log "ERROR: cannot read the new repo's ID."; return 1; }
  echo "$id" > "$REPO_ID_FILE"
  log "restic repo created ($id)."
}
# Problems here are not fatal: the sync keeps running, and each nightly backup
# re-checks the repo and reports a failure to the healthcheck.
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
# 4. Wait for login (done by the user, once; the session persists in /config).
if ! mega-whoami >/dev/null 2>&1; then
  while ! mega-whoami >/dev/null 2>&1; do
    log_banner \
      "Not logged in to MEGA. Run this once on the host:" \
      "  docker exec -it mega-backup mega-login you@example.com" \
      "(it asks for the password; with 2FA add --auth-code=123456)"
    wait_checking 60
  done
fi
log "Logged in as: $(mega-whoami 2>/dev/null | head -n1)"

# ---------------------------------------------------------------------------
# 5. Make sure the sync between $MB_CURRENT and $MEGA_REMOTE_PATH exists.
ensure_sync() {
  local row remote
  row="$(sync_row || true)"
  if [ -n "$row" ]; then
    remote="$(strip_slash "${row##*|}")"
    log "Sync exists: $MB_CURRENT <-> $remote (RUN_STATE|STATUS|ERROR: ${row%|*})"
    if [ "$remote" != "$MEGA_REMOTE_PATH" ]; then
      log_banner \
        "WARNING: the existing sync points to '$remote', but MEGA_REMOTE_PATH is '$MEGA_REMOTE_PATH'." \
        "Leaving it unchanged. To switch, remove the old sync and empty $MB_CURRENT first:" \
        "  docker exec mega-backup mega-sync -d $MB_CURRENT"
    fi
    return 0
  fi

  if ! mega-ls "$MEGA_REMOTE_PATH" >/dev/null 2>&1; then
    log "ERROR: MEGA folder '$MEGA_REMOTE_PATH' does not exist (or is not accessible). Fix MEGA_REMOTE_PATH."
    return 1
  fi
  if ! dir_is_empty "$MB_CURRENT" && [ "$ALLOW_NONEMPTY_INIT" != 1 ]; then
    log_banner \
      "Not creating the sync: $MB_CURRENT is not empty." \
      "A two-way sync would merge these local files up into MEGA." \
      "Empty the folder, or set ALLOW_NONEMPTY_INIT=1 if a merge is really what you want."
    return 1
  fi
  log "Creating sync: $MB_CURRENT <-> $MEGA_REMOTE_PATH"
  if ! mega-sync "$MB_CURRENT" "$MEGA_REMOTE_PATH"; then
    log "ERROR: mega-sync failed to create the sync."
    return 1
  fi
}
until ensure_sync; do
  log "Retrying in 5 minutes."
  wait_checking 300
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
# 6. Scheduler.
run_backup() {
  mark_sync_established
  /usr/local/bin/backup.sh &
  BACKUP_PID=$!
  local rc=0
  # `wait` returns early on a signal; the trap then exits.
  wait "$BACKUP_PID" || rc=$?
  BACKUP_PID=""
  [ "$rc" = 0 ] || log "Backup run finished with exit code $rc."
  return 0
}

latest_snapshot_age() {
  local t
  t="$(restic snapshots --json --latest 1 --host "$RESTIC_HOST" --path "$MB_CURRENT" 2>/dev/null \
       | jq -r '.[0].time // empty')" || return 1
  [ -n "$t" ] || return 1
  echo $(( $(date +%s) - $(date -d "$t" +%s) ))
}

if [ "$BACKUP_ON_START" = 1 ]; then
  log "BACKUP_ON_START=1: running a backup now."
  run_backup
elif age="$(latest_snapshot_age)" && [ "$age" -gt $(( 26 * 3600 )) ]; then
  log "Last backup is $(( age / 3600 )) h old (missed run?): running a backup now."
  run_backup
fi

while true; do
  now=$(date +%s)
  next=$(date -d "today $BACKUP_TIME" +%s)
  [ "$next" -gt "$now" ] || next=$(date -d "tomorrow $BACKUP_TIME" +%s)
  log "Next backup: $(date -d "@$next" '+%Y-%m-%d %H:%M %Z')"
  # Re-compute in chunks so clock changes (DST, NTP) don't push the run off.
  while [ "$(date +%s)" -lt "$next" ]; do
    left=$(( next - $(date +%s) ))
    wait_checking $(( left < 300 ? left : 300 ))
  done
  run_backup
done
