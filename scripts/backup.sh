#!/bin/bash
# One backup run. For each folder pair: sync health check -> restic backup ->
# mass-change guard. Then forget (unless on hold) and prune -> weekly check ->
# healthcheck ping.
# Run manually with: docker exec <container> backup.sh
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
FOLDERS_JSON=""; ANY_SNAPSHOT=0; FREED=""
problem() {
  PROBLEMS+=("$*")
  log "PROBLEM: $*"
}

repo_bytes() { du -sb "$RESTIC_REPOSITORY" 2>/dev/null | cut -f1; }

# jq: restic/ISO time with offset ("2026-10-31T03:30:00.12+01:00") -> epoch seconds.
# shellcheck disable=SC2016  # jq code, not shell
JQ_EPOCH='def epoch: (.[0:19] + "Z" | fromdateiso8601) as $t
  | (capture("(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") // null) as $o
  | if $o == null then $t
    else $t - (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60) * (if $o.s == "+" then 1 else -1 end) end;'

# Summary of this run for the web UI, written atomically.
write_last_run() {
  local tmp="$MB_CONFIG/last-run.json.tmp.$$"
  printf '%s\n' "${PROBLEMS[@]+"${PROBLEMS[@]}"}" \
    | jq -Rn --arg started "$STARTED" --arg finished "$(date -Iseconds)" --arg any "$ANY_SNAPSHOT" \
        --arg freed "${FREED:-}" --arg size "$(repo_bytes)" \
        --slurpfile folders "${FOLDERS_JSON:-/dev/null}" '
      [inputs | select(. != "")] as $p
      | def total(f): ($folders | map(f // 0) | add);
      {started: $started, finished: $finished,
       result: (if ($p | length) == 0 then "ok" elif $any == "1" then "problems" else "failed" end),
       problems: $p,
       folders: $folders,
       snapshot_id: ($folders | map(.snapshot_id | strings) | first),
       files_total: (if $any == "1" then total(.files_total) else null end),
       bytes_added: (if $any == "1" then total(.bytes_added) else null end),
       diff: (if ($folders | map(.diff) | any(. != null))
              then {added: total(.diff.added), removed: total(.diff.removed), changed: total(.diff.changed)}
              else null end),
       bytes_freed: (if $freed == "" then null else ($freed | tonumber) end),
       repo_bytes: (if $size == "" then null else ($size | tonumber) end)}' \
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

# --- 1. Folder pairs ------------------------------------------------------
PAIRS=()
if ! pairs_txt="$(pairs_active)"; then
  problem "the folder list ($PAIRS_FILE) cannot be read; not backing up"
  PAIRS_OK=0
else
  PAIRS_OK=1
  while IFS= read -r line; do [ -n "$line" ] && PAIRS+=("$line"); done <<< "$pairs_txt"
  [ "${#PAIRS[@]}" -gt 0 ] || problem "no folders are set up yet; nothing to back up"
fi

# Sync health of one folder; waits (up to SYNC_WAIT_MAX for the whole run) while
# MEGA is still busy, so the snapshot isn't taken mid-sync.
SYNC_DEADLINE=$(( $(date +%s) + SYNC_WAIT_MAX ))
check_sync() {
  local name="$1" dir="$2" row run status err remote
  while true; do
    if ! row="$(sync_row "$dir")"; then
      problem "$name: cannot query MEGAcmd (server not running?)"
      return
    fi
    if [ -z "$row" ]; then
      problem "$name: no MEGA sync set up for this folder (see the Folders page)"
      return
    fi
    IFS='|' read -r run status err remote <<< "$row"
    log "$name: sync state RUN_STATE=$run STATUS=$status ERROR=$err REMOTE=$remote"
    if [ "$run" != Running ] || [ "$err" != NO ]; then
      problem "$name: sync is not healthy (RUN_STATE=$run, STATUS=$status, ERROR=$err)"
      return
    fi
    case "$status" in
      Syncing|Pending|Processing) ;;
      *) return ;;
    esac
    if [ "$(date +%s)" -ge "$SYNC_DEADLINE" ]; then
      log "$name: sync still busy; backing up anyway (snapshot may be mid-sync)."
      return
    fi
    log "$name: sync is busy ($status); waiting for it to settle..."
    sleep 60
  done
}

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

# --- 3-5. Back up each folder ---------------------------------------------
restic unlock >/dev/null 2>&1 || true   # removes only stale locks

FOLDERS_JSON="$RUN_LOG.folders"; : > "$FOLDERS_JSON"
ANY_SNAPSHOT=0

# back_up_folder NAME REMOTE ADDED: one snapshot of $MB_CURRENT/NAME, then the
# mass-change guard against that folder's previous snapshot. Appends a JSON line
# with the result to $FOLDERS_JSON.
back_up_folder() {
  local name="$1" remote="$2" added="$3" dir n_before="${#PROBLEMS[@]}"
  local prev_json prev_id="" prev_files=0 rc=0 sum="" id="" st="" removed changed plus pct_r pct_c reason
  dir="$(pair_dir "$name")"
  [ "$SKIP_SYNC_CHECK" = 1 ] || check_sync "$name" "$dir"

  if dir_is_empty "$dir"; then
    problem "$name: the folder is empty or missing; not backing up"
  else
    # Previous snapshot of this folder, taken since the pair was (last) added.
    prev_json="$(restic snapshots --json --host "$RESTIC_HOST" --path "$dir")" || prev_json='[]'
    prev_json="$(jq -c --arg a "$added" "$JQ_EPOCH"'
      [.[] | select($a == "" or ((.time | epoch) >= ($a | epoch)))]
      | sort_by(.time | epoch) | last // empty' <<< "$prev_json" 2>/dev/null)" || prev_json=""
    if [ -n "$prev_json" ]; then
      prev_id="$(jq -r .id <<< "$prev_json")"
      prev_files="$(jq -r '.summary.total_files_processed // 0' <<< "$prev_json")"
    fi

    log "$name: running restic backup of $dir"
    restic backup "$dir" --host "$RESTIC_HOST" --tag nightly --tag "folder:$name" \
      --exclude "$dir/.debris" --json > "$RUN_LOG.json" || rc=$?
    sum="$(jq -c 'select(.message_type == "summary")' "$RUN_LOG.json" | tail -n1)"
    jq -r 'select(.message_type == "error" or .message_type == "exit_error") | "restic: \(.message // .error.message // .)"' \
      "$RUN_LOG.json" 2>/dev/null | head -n 20 || true

    if [ -z "$sum" ]; then
      problem "$name: restic backup failed (exit $rc); no snapshot was created"
    else
      id="$(jq -r .snapshot_id <<< "$sum")"
      ANY_SNAPSHOT=1
      log "$name: snapshot ${id:0:8}: $(jq -r '"\(.total_files_processed) files, \(.files_new) new, \(.files_changed) changed (incl. metadata), \(.data_added) bytes added"' <<< "$sum")"
      if [ "$rc" = 3 ]; then
        problem "$name: restic could not read some files (exit 3); the snapshot is incomplete"
      elif [ "$rc" != 0 ]; then
        problem "$name: restic backup exited with $rc"
      fi
      # Mass-change guard. `restic diff` counts content changes only (the backup
      # summary also counts files whose timestamps changed).
      if [ -n "$prev_id" ] && [ "$prev_files" -gt 0 ] && [ "$prev_id" != "$id" ]; then
        st="$(restic diff --json "$prev_id" "$id" | jq -c 'select(.message_type == "statistics")' | tail -n1)" || st=""
        if [ -z "$st" ]; then
          problem "$name: restic diff failed; cannot run the mass-change guard"
        else
          removed="$(jq -r '.removed.files' <<< "$st")"
          changed="$(jq -r '.changed_files' <<< "$st")"
          plus="$(jq -r '.added.files' <<< "$st")"
          pct_r=$(( removed * 100 / prev_files ))
          pct_c=$(( changed * 100 / prev_files ))
          log "$name: since previous snapshot (${prev_id:0:8}, $prev_files files): $plus added, $removed removed (${pct_r}%), $changed content-changed (${pct_c}%)"
          reason=""
          if [ "$pct_r" -gt "$MAX_DROP_PERCENT" ]; then
            reason="$removed of $prev_files files removed (${pct_r}% > ${MAX_DROP_PERCENT}%)"
          fi
          if [ "$pct_c" -gt "$MAX_CHANGE_PERCENT" ]; then
            reason="${reason:+$reason; }$changed of $prev_files files changed (${pct_c}% > ${MAX_CHANGE_PERCENT}%)"
          fi
          if [ -n "$reason" ]; then
            {
              echo "Prune hold set $(date '+%F %T')"
              echo "Folder: $name"
              echo "Reason: $reason"
              echo "Before: snapshot ${prev_id:0:8}   After: snapshot ${id:0:8}"
              echo "Delete this file to allow pruning again."
              echo
            } >> "$PRUNE_HOLD"
            problem "$name: possible mass deletion/overwrite on MEGA: $reason. Old snapshots are kept until you check (prune hold)"
            HOLD_SET_NOW=1
          fi
        fi
      fi
    fi
  fi

  printf '%s\n' "${PROBLEMS[@]:$n_before}" | jq -Rn --arg n "$name" --arg r "$remote" --arg id "$id" \
      --arg sum "${sum:-null}" --arg st "${st:-null}" '
    [inputs | select(. != "")] as $p | ($sum | fromjson? // null) as $s | ($st | fromjson? // null) as $d
    | {name: $n, remote: $r,
       result: (if ($p | length) == 0 then "ok" elif $id == "" then "failed" else "problems" end),
       problems: $p, snapshot_id: (if $id == "" then null else $id end),
       files_total: $s.total_files_processed, files_new: $s.files_new, files_changed: $s.files_changed,
       bytes_added: $s.data_added,
       diff: (if $d == null then null
              else {added: $d.added.files, removed: $d.removed.files, changed: $d.changed_files} end)}' \
    >> "$FOLDERS_JSON"
}

for line in "${PAIRS[@]+"${PAIRS[@]}"}"; do
  IFS=$'\t' read -r p_name p_remote _ p_added <<< "$line"
  back_up_folder "$p_name" "$p_remote" "$p_added"
done

# --- 6+7. Forget and prune ------------------------------------------------
# Runs after every backup, even one with problems (an unreadable file must not stop
# the clean-up for good). Only a prune hold (possible mass deletion) stops `forget`.
# Old snapshots are thinned per folder; snapshots of folders that are no longer
# synced expire once their newest one is older than the retention period. `prune`
# then deletes the data no snapshot needs any more.
size_before="$(repo_bytes)"; FREED=""
if [ -e "$PRUNE_HOLD" ]; then
  if [ "$HOLD_SET_NOW" != 1 ]; then
    problem "prune on hold since $(head -n1 "$PRUNE_HOLD" | sed 's/^Prune hold set //'); old snapshots are kept until you check (Status page)"
  fi
  log "Skipping forget (prune hold)."
else
  # shellcheck disable=SC2054  # host,paths is one argument
  forget_args=(forget --host "$RESTIC_HOST" --group-by host,paths --keep-within 2d
               --keep-daily "$KEEP_DAILY" --keep-monthly "$KEEP_MONTHLY")
  [ "$DRY_RUN" = 1 ] && forget_args+=(--dry-run)
  log "restic ${forget_args[*]}"
  restic "${forget_args[@]}" || problem "restic forget failed"

  # Folders that are no longer synced (removed pairs, the single-folder setup):
  # their snapshots never get newer, so `--keep-daily` alone would keep them forever.
  if [ "$PAIRS_OK" = 1 ]; then
    window_days=$(( KEEP_DAILY > KEEP_MONTHLY * 31 ? KEEP_DAILY : KEEP_MONTHLY * 31 ))
    [ "$window_days" -ge 2 ] || window_days=2
    active_dirs="$(for line in "${PAIRS[@]+"${PAIRS[@]}"}"; do pair_dir "${line%%$'\t'*}"; echo; done)"
    expired="$(restic snapshots --json --host "$RESTIC_HOST" | jq -r --arg active "$active_dirs" \
        --argjson cutoff "$(( $(date +%s) - window_days * 86400 ))" "$JQ_EPOCH"'
      ($active | split("\n")) as $a
      | group_by(.paths) | .[]
      | select((.[0].paths | length) != 1 or (.[0].paths[0] | IN($a[]) | not))
      | select(all(.[]; (.time | epoch) < $cutoff))
      | "\(.[0].paths | join(","))\t\(map(.id) | join(" "))"')" || expired=""
    while IFS=$'\t' read -r e_path e_ids; do
      [ -n "$e_ids" ] || continue
      log "Snapshots of $e_path (no longer synced) are all older than $window_days days: removing them."
      # shellcheck disable=SC2086  # IDs are hex, split on purpose
      if [ "$DRY_RUN" = 1 ]; then
        log "DRY_RUN: would forget $e_ids"
      else
        restic forget $e_ids || problem "restic forget of old folder snapshots failed"
      fi
    done <<< "$expired"
  fi
fi
# Prune also after a hold, to free what was deleted by hand on the Snapshots page.
if [ "$DRY_RUN" != 1 ]; then
  log "restic prune"
  if restic prune --cleanup-cache; then
    size_after="$(repo_bytes)"
    if [ -n "$size_before" ] && [ -n "$size_after" ]; then
      FREED=$(( size_before > size_after ? size_before - size_after : 0 ))
      log "Backup folder: $size_after bytes after prune ($FREED bytes freed)."
    fi
  else
    problem "restic prune failed"
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
