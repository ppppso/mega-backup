#!/bin/bash
# One backup run: sync health check -> restic backup -> mass-change guard ->
# forget/prune (unless on hold) -> weekly check -> healthcheck ping.
# Run manually with: docker exec mega-backup backup.sh
set -euo pipefail
LOG_TAG=backup
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

# `docker exec` runs as root: re-run as PUID so nothing in the repo becomes root-owned.
if [ "$(id -u)" = 0 ]; then
  exec /usr/local/bin/as-user.sh "$0" "$@"
fi
cd /tmp

load_settings
KEEP_DAILY="$CFG_KEEP_DAILY"
KEEP_MONTHLY="$CFG_KEEP_MONTHLY"
MAX_DROP_PERCENT="$CFG_MAX_DROP_PERCENT"
MAX_CHANGE_PERCENT="$CFG_MAX_CHANGE_PERCENT"
CHECK_WEEKDAY="$CFG_CHECK_WEEKDAY"
CHECK_READ_PERCENT="$CFG_CHECK_READ_PERCENT"
HEALTHCHECK_URL="$CFG_HEALTHCHECK_URL"
SYNC_WAIT_MAX="${SYNC_WAIT_MAX:-1800}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_CHECK="${FORCE_CHECK:-0}"
SKIP_SYNC_CHECK="${SKIP_SYNC_CHECK:-0}"   # test-only: skip the MEGAcmd sync check

# Only one run at a time (scheduled vs. manual).
exec 9>"$MB_CONFIG/backup.lock"
if ! flock -n 9; then
  log "Another backup is already running; not starting a second one."
  exit 75
fi

# Keep a copy of this run's output for the failure ping.
RUN_LOG="$(mktemp)"
trap 'rm -f "$RUN_LOG" "${RUN_LOG}".*' EXIT
exec > >(tee -a "$RUN_LOG") 2>&1

PROBLEMS=()
HOLD_SET_NOW=0
STARTED="$(date -Iseconds)"
# Filled in as the run goes; written to last-run.json by finish().
new_id=""; summary=""; stats=""
problem() {
  PROBLEMS+=("$*")
  log "PROBLEM: $*"
}

# Summary of this run for the web UI, written atomically.
write_last_run() {
  local tmp="$MB_CONFIG/last-run.json.tmp.$$"
  printf '%s\n' "${PROBLEMS[@]+"${PROBLEMS[@]}"}" \
    | jq -Rn --arg started "$STARTED" --arg finished "$(date -Iseconds)" \
        --arg snap "$new_id" --arg summary "${summary:-null}" --arg stats "${stats:-null}" '
      [inputs | select(. != "")] as $p
      | ($summary | fromjson? // null) as $s
      | ($stats | fromjson? // null) as $d
      | {started: $started, finished: $finished,
         result: (if ($p | length) == 0 then "ok" elif $snap == "" then "failed" else "problems" end),
         problems: $p,
         snapshot_id: (if $snap == "" then null else $snap end),
         files_total: $s.total_files_processed, files_new: $s.files_new,
         files_changed: $s.files_changed, bytes_added: $s.data_added,
         diff: (if $d == null then null
                else {added: $d.added.files, removed: $d.removed.files, changed: $d.changed_files} end)}' \
    > "$tmp" || { log "Could not write last-run.json."; return 0; }
  mv -f "$tmp" "$MB_CONFIG/last-run.json" || log "Could not write last-run.json."
}

finish() {
  write_last_run
  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    log "Backup run OK."
    ping_hc "" ""
    exit 0
  fi
  log "Backup run finished with ${#PROBLEMS[@]} problem(s):"
  local p
  for p in "${PROBLEMS[@]}"; do log "  - $p"; done
  tail -n 50 "$RUN_LOG" > "$RUN_LOG.tail"
  ping_hc fail "$RUN_LOG.tail"
  exit 1
}

log "Backup run started."
ping_hc start ""

# --- 1. Sync health -------------------------------------------------------
check_sync() {
  local row run status err remote waited=0
  while true; do
    if ! row="$(sync_row)"; then
      problem "cannot query MEGAcmd (server not running?)"
      return
    fi
    if [ -z "$row" ]; then
      problem "no MEGA sync configured for $MB_CURRENT"
      return
    fi
    IFS='|' read -r run status err remote <<< "$row"
    log "Sync state: RUN_STATE=$run STATUS=$status ERROR=$err REMOTE=$remote"
    if [ "$run" != Running ] || [ "$err" != NO ]; then
      problem "sync is not healthy (RUN_STATE=$run, STATUS=$status, ERROR=$err). Check: docker exec mega-backup mega-sync; mega-sync-issues"
      return
    fi
    case "$status" in
      Syncing|Pending|Processing) ;;
      *) return ;;
    esac
    if [ "$waited" -ge "$SYNC_WAIT_MAX" ]; then
      log "Sync still busy after ${waited}s; backing up anyway (snapshot may be mid-sync)."
      return
    fi
    log "Sync is busy ($status); waiting for it to settle..."
    sleep 60
    waited=$(( waited + 60 ))
  done
}
if [ "$SKIP_SYNC_CHECK" = 1 ]; then
  log "SKIP_SYNC_CHECK=1: not checking the MEGA sync (test mode)."
else
  check_sync
fi

# --- 2. Repository --------------------------------------------------------
if ! mount_ok "$RESTIC_REPOSITORY"; then
  problem "no Backup folder: $RESTIC_REPOSITORY is not mounted (pick one in the app's Umbrel settings, or set REPO_DIR)"
  finish
fi
if ! repo_id="$(restic_repo_id)"; then
  problem "cannot open restic repo at $RESTIC_REPOSITORY (not mounted? wrong password?)"
  finish
fi
if [ -e "$REPO_ID_FILE" ] && [ "$(cat "$REPO_ID_FILE")" != "$repo_id" ]; then
  problem "restic repo ID $repo_id does not match $REPO_ID_FILE ($(cat "$REPO_ID_FILE")); wrong REPO_DIR?"
  finish
fi

# --- 3. Empty-source guard ------------------------------------------------
if dir_is_empty "$MB_CURRENT"; then
  problem "$MB_CURRENT is empty or missing; not backing up"
  finish
fi

# --- 4. Back up -----------------------------------------------------------
restic unlock >/dev/null 2>&1 || true   # removes only stale locks

prev_id=""; prev_files=0
prev_json="$(restic snapshots --json --latest 1 --host "$RESTIC_HOST" --path "$MB_CURRENT")" || prev_json='[]'
if [ "$(jq length <<< "$prev_json")" -gt 0 ]; then
  prev_id="$(jq -r '.[0].id' <<< "$prev_json")"
  prev_files="$(jq -r '.[0].summary.total_files_processed // 0' <<< "$prev_json")"
fi

log "Running restic backup of $MB_CURRENT"
backup_rc=0
restic backup "$MB_CURRENT" --host "$RESTIC_HOST" --tag nightly \
  --exclude "$MB_CURRENT/.debris" --json > "$RUN_LOG.json" || backup_rc=$?
summary="$(jq -c 'select(.message_type == "summary")' "$RUN_LOG.json" | tail -n1)"
jq -r 'select(.message_type == "error" or .message_type == "exit_error") | "restic: \(.message // .error.message // .)"' \
  "$RUN_LOG.json" 2>/dev/null | head -n 20 || true

if [ -z "$summary" ]; then
  problem "restic backup failed (exit $backup_rc); no snapshot was created"
  finish
fi
new_id="$(jq -r .snapshot_id <<< "$summary")"
log "Snapshot ${new_id:0:8}: $(jq -r '"\(.total_files_processed) files, \(.files_new) new, \(.files_changed) changed (incl. metadata), \(.data_added) bytes added"' <<< "$summary")"
if [ "$backup_rc" = 3 ]; then
  problem "restic could not read some files (exit 3); the snapshot is incomplete"
elif [ "$backup_rc" != 0 ]; then
  problem "restic backup exited with $backup_rc"
fi

# --- 5. Mass-change guard -------------------------------------------------
# Uses `restic diff`, which counts content changes only (the backup summary also
# counts files whose timestamps changed).
if [ -n "$prev_id" ] && [ "$prev_files" -gt 0 ] && [ "$prev_id" != "$new_id" ]; then
  stats="$(restic diff --json "$prev_id" "$new_id" | jq -c 'select(.message_type == "statistics")' | tail -n1)" || stats=""
  if [ -z "$stats" ]; then
    problem "restic diff failed; cannot run the mass-change guard"
  else
    removed="$(jq -r '.removed.files' <<< "$stats")"
    changed="$(jq -r '.changed_files' <<< "$stats")"
    added="$(jq -r '.added.files' <<< "$stats")"
    removed_pct=$(( removed * 100 / prev_files ))
    changed_pct=$(( changed * 100 / prev_files ))
    log "Since previous snapshot (${prev_id:0:8}, $prev_files files): $added added, $removed removed (${removed_pct}%), $changed content-changed (${changed_pct}%)"
    reason=""
    if [ "$removed_pct" -gt "$MAX_DROP_PERCENT" ]; then
      reason="$removed of $prev_files files removed (${removed_pct}% > ${MAX_DROP_PERCENT}%)"
    fi
    if [ "$changed_pct" -gt "$MAX_CHANGE_PERCENT" ]; then
      reason="${reason:+$reason; }$changed of $prev_files files changed (${changed_pct}% > ${MAX_CHANGE_PERCENT}%)"
    fi
    if [ -n "$reason" ]; then
      {
        echo "Prune hold set $(date '+%F %T')"
        echo "Reason: $reason"
        echo "Before: snapshot ${prev_id:0:8}   After: snapshot ${new_id:0:8}"
        echo "Inspect: docker exec mega-backup restic diff ${prev_id:0:8} ${new_id:0:8}"
        echo "Delete this file to allow pruning again."
        echo
      } >> "$PRUNE_HOLD"
      problem "possible mass deletion/overwrite on MEGA: $reason. Pruning is on hold until $PRUNE_HOLD is removed"
      HOLD_SET_NOW=1
    fi
  fi
fi

# --- 6+7. Forget/prune unless on hold -------------------------------------
if [ -e "$PRUNE_HOLD" ]; then
  # Report every run until the user clears it (unless this run already did).
  if [ "$HOLD_SET_NOW" != 1 ]; then
    problem "prune on hold since $(head -n1 "$PRUNE_HOLD" | sed 's/^Prune hold set //'); see $PRUNE_HOLD, delete it after checking"
  fi
  log "Skipping forget/prune (on hold)."
elif [ "$backup_rc" != 0 ]; then
  log "Skipping forget/prune because the backup was not fully successful."
else
  # --keep-within 2d: keep every snapshot of the last two days, so manual
  # "Back up now" runs aren't thinned to one per day right away.
  forget_args=(forget --host "$RESTIC_HOST" --path "$MB_CURRENT" --keep-within 2d
               --keep-daily "$KEEP_DAILY" --keep-monthly "$KEEP_MONTHLY" --prune)
  [ "$DRY_RUN" = 1 ] && forget_args+=(--dry-run)
  log "restic ${forget_args[*]}"
  if ! restic "${forget_args[@]}"; then
    problem "restic forget/prune failed"
  fi
fi

# --- 8. Weekly integrity check --------------------------------------------
if [ "$FORCE_CHECK" = 1 ] || [ "$(date +%u)" = "$CHECK_WEEKDAY" ]; then
  log "Running restic check (reading ${CHECK_READ_PERCENT}% of data)"
  if ! restic check --read-data-subset="${CHECK_READ_PERCENT}%"; then
    problem "restic check reported errors"
  fi
fi

finish
