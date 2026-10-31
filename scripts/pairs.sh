# shellcheck shell=bash disable=SC2034  # GUARD_* are read by main.sh
# Folder pairs for the engine (sourced by main.sh after lib.sh): the start-up guard,
# the one-time move from the single-folder setup, and keeping the MEGAcmd syncs in
# line with pairs.json.

# ---------------------------------------------------------------------------
# Guard, run before MEGAcmd starts (MEGAcmd resumes existing syncs right away, and a
# resumed sync whose local folder is suddenly empty deletes everything on MEGA too).
# Returns 1 and sets GUARD_STATE / GUARD_MSG if MEGAcmd must not start.
#  - The MEGA folder is not mounted, although a sync was set up before.
#  - A pair's folder (or, before the migration, the whole MEGA folder) is empty or
#    missing, although it had files before: the disk is probably missing.
# The web UI can clear a pair's marker when the folder really is meant to be empty.
GUARD_STATE=""; GUARD_MSG=""
pairs_guard() {
  local f name empty=()
  GUARD_STATE=""; GUARD_MSG=""
  if { sync_was_created || compgen -G "$PAIR_STATE/*.created" >/dev/null \
       || compgen -G "$PAIR_STATE/*.established" >/dev/null; } && ! mount_ok "$MB_CURRENT"; then
    GUARD_STATE=folder-missing
    GUARD_MSG="The MEGA folder is not available. Pick it again in the app's Umbrel settings (or check SYNC_DIR), then restart the app."
    return 1
  fi
  if [ -e "$SYNC_MARKER" ] && dir_is_empty "$MB_CURRENT"; then
    empty+=("MEGA folder")
  fi
  for f in "$PAIR_STATE"/*.established; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .established)"
    dir_is_empty "$(pair_dir "$name")" && empty+=("$name")
  done
  if [ "${#empty[@]}" -gt 0 ]; then
    GUARD_STATE=guard-refusing
    local list; list="$(printf '"%s", ' "${empty[@]}")"; list="${list%, }"
    GUARD_MSG="These folders are empty or missing, but had files before: $list. The disk is probably missing, so syncing is stopped to protect your files on MEGA."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# One-time move from the single-folder setup (one sync of the whole MEGA folder,
# MEGA_REMOTE_PATH) to folder pairs. Needs a running, logged-in MEGAcmd.
#   1. remove the old sync (files stay on both sides),
#   2. move everything in the MEGA folder into a sub-folder named after the MEGA folder,
#   3. write pairs.json with that one pair (merge allowed: the files came from MEGA).
# The pair's new sync is then created by pairs_reconcile; MEGA matches the existing
# files and transfers nothing. Safe to re-run after a crash at any step.
MIGRATING="$MB_CONFIG/migrating"
MIGRATE_TMP=".mb-migrating"

pair_name_for() {
  local base="${1##*/}"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9 _.()-' '_' | sed 's/^[^A-Za-z0-9_]*//; s/ *$//' | cut -c1-60)"
  printf '%s' "${base:-MEGA}"
}

migrate_needed() {
  [ ! -e "$PAIRS_FILE" ] || [ -e "$MIGRATING" ]
}

pairs_migrate() {
  local row remote="" name merge=0 e
  [ -e "$PAIRS_FILE" ] && [ ! -e "$MIGRATING" ] && return 0
  row="$(sync_row "$MB_CURRENT")" || { log "Migration: cannot query MEGAcmd."; return 1; }
  if [ -e "$MIGRATING" ]; then
    IFS=$'\t' read -r name remote merge < "$MIGRATING"
  elif [ -n "$row" ]; then
    remote="$(strip_slash "${row##*|}")"; merge=1
  elif [ -n "$CFG_MEGA_REMOTE_PATH" ]; then
    remote="$(strip_slash "$CFG_MEGA_REMOTE_PATH")"; merge="$CFG_ALLOW_NONEMPTY_INIT"
  else
    return 0   # nothing to migrate: new install, folders are added in the web UI
  fi
  [ -n "${name:-}" ] || name="$(pair_name_for "$remote")"
  if ! mount_ok "$MB_CURRENT"; then
    log "Migration to folder pairs waits: $MB_CURRENT is not mounted."
    return 1
  fi
  log_banner "Moving to folder pairs: the MEGA folder's content moves into the sub-folder" \
    "'$name', synced with MEGA's '$remote'. Nothing changes on MEGA."
  printf '%s\t%s\t%s\n' "$name" "$remote" "$merge" > "$MIGRATING"

  if [ -n "$row" ]; then
    log "Migration: removing the old sync of the whole MEGA folder (files stay)."
    mega-sync -d "$MB_CURRENT" >/dev/null 2>&1 || true
    row="$(sync_row "$MB_CURRENT")" || return 1
    if [ -n "$row" ]; then
      log "ERROR: migration: could not remove the old sync. Will retry."
      return 1
    fi
  fi

  # Move into a temp folder first (the content may itself have an entry named $name),
  # then rename it. "$MIGRATING.moved" marks that everything is in the temp folder.
  if [ ! -e "$MIGRATING.moved" ]; then
    mkdir -p "$MB_CURRENT/$MIGRATE_TMP" || return 1
    for e in "$MB_CURRENT"/* "$MB_CURRENT"/.[!.]* "$MB_CURRENT"/..?*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      [ "${e##*/}" = "$MIGRATE_TMP" ] && continue
      mv -- "$e" "$MB_CURRENT/$MIGRATE_TMP/" || { log "ERROR: migration: cannot move $e."; return 1; }
    done
    : > "$MIGRATING.moved"
  fi
  if [ -d "$MB_CURRENT/$MIGRATE_TMP" ]; then
    mv -T -- "$MB_CURRENT/$MIGRATE_TMP" "$(pair_dir "$name")" || { log "ERROR: migration: cannot rename the folder."; return 1; }
  fi

  mkdir -p "$PAIR_STATE"
  [ -e "$SYNC_CREATED" ] && mv -f "$SYNC_CREATED" "$PAIR_STATE/$name.created"
  [ -e "$SYNC_MARKER" ] && mv -f "$SYNC_MARKER" "$PAIR_STATE/$name.established"
  with_pairs_lock _write_migrated_pairs "$name" "$remote" "$merge" || return 1
  rm -f "$MIGRATING" "$MIGRATING.moved"
  log "Migration done: folder pair '$name' <-> '$remote'. Older snapshots stay available."
}

_write_migrated_pairs() {
  local tmp="$PAIRS_FILE.tmp.$$"
  [ -e "$PAIRS_FILE" ] && return 0
  jq -n --arg n "$1" --arg r "$2" --arg m "$3" --arg t "$(date -Iseconds)" \
    '{pairs: [{name: $n, remote: $r, merge: ($m == "1"), added: $t, migrated: true}], removed: []}' \
    > "$tmp" && mv -f "$tmp" "$PAIRS_FILE"
}

# ---------------------------------------------------------------------------
# Bring the MEGAcmd syncs in line with pairs.json. Never removes a sync that is not
# listed under "removed". Problems per pair go to /config/pairs-status.json for the
# web UI. Returns 1 if MEGAcmd or pairs.json could not be read.
PAIRS_STATUS="$MB_CONFIG/pairs-status.json"
PAIRS_PROBLEMS=0
_PAIRS_STATUS_LAST=""
_UNKNOWN_LOGGED=""

pairs_reconcile() {
  local rows active removed name remote merge dir row cur run err problems='{}' p other
  PAIRS_PROBLEMS=0
  rows="$(sync_rows)" || { log "Cannot read the syncs from MEGAcmd."; return 1; }
  if ! active="$(pairs_active)"; then
    log "ERROR: $PAIRS_FILE cannot be read; not changing any sync."
    _pairs_status '{"_file": "The folder list (pairs.json) cannot be read."}'
    PAIRS_PROBLEMS=1
    return 1
  fi
  removed="$(pairs_removed)"
  mkdir -p "$PAIR_STATE"

  # 1. Removed pairs: delete the sync (not the files) and the markers.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qxF -- "$name" <<< "$(cut -f1 <<< "$active")" && continue   # added again
    dir="$(pair_dir "$name")"
    if grep -q "^$(_re "$dir")|" <<< "$rows"; then
      log "Removing the sync of folder '$name' (files stay on MEGA and in $dir)."
      mega-sync -d "$dir" >/dev/null 2>&1 || log "ERROR: could not remove the sync of '$name'."
    fi
    rm -f "$PAIR_STATE/$name.created" "$PAIR_STATE/$name.established" \
      "$PAIR_STATE/$name.resume" "$PAIR_STATE/$name.resume-failed"
  done <<< "$removed"

  # Syncs nobody asked for are left alone; log each once.
  while IFS='|' read -r cur _ _ _ remote; do
    [ -n "$cur" ] || continue
    name="${cur#"$MB_CURRENT"/}"
    if [ "$cur" = "$MB_CURRENT" ] || [ "$name" = "$cur" ] || [[ "$name" == */* ]] \
       || { ! grep -qxF -- "$name" <<< "$(cut -f1 <<< "$active")" && ! grep -qxF -- "$name" <<< "$removed"; }; then
      if [[ "$_UNKNOWN_LOGGED" != *"|$cur|"* ]]; then
        log "Note: MEGAcmd has a sync this app does not manage: $cur <-> $remote. Leaving it alone."
        _UNKNOWN_LOGGED+="|$cur|"
      fi
    fi
  done <<< "$rows"

  # 2. Active pairs: make sure each sync exists.
  while IFS=$'\t' read -r name remote merge _; do
    [ -n "$name" ] || continue
    dir="$(pair_dir "$name")"
    remote="$(strip_slash "$remote")"
    p=""
    row="$(grep "^$(_re "$dir")|" <<< "$rows" | head -n1)"
    if [ -n "$row" ]; then
      IFS='|' read -r _ run _ err cur <<< "$row"
      cur="$(strip_slash "$cur")"
      # MEGA stopped the sync (folder deleted on MEGA, disk error, ...). "Resume" on
      # the Folders page asks to start it again; starting a stopped sync works like
      # a new one (it merges, it never deletes).
      if [ "$run" = Disabled ] || [ "$run" = Suspended ] || { [ -n "$err" ] && [ "$err" != NO ]; }; then
        local resume_err=""
        if [ -e "$PAIR_STATE/$name.resume" ]; then
          rm -f "$PAIR_STATE/$name.resume"
          log "Folder '$name': resuming the sync (asked in the web UI)."
          if ! resume_err="$(mega-sync -e "$dir" 2>&1)"; then
            resume_err="$(printf '%s' "$resume_err" | sed 's/^\[[^]]*\] *//' | tr '\n' ' ' | cut -c1-200)"
            log "Folder '$name': MEGAcmd could not resume the sync: $resume_err"
            printf '%s\n' "${resume_err:-MEGAcmd refused.}" > "$PAIR_STATE/$name.resume-failed"
          else
            rm -f "$PAIR_STATE/$name.resume-failed"
          fi
        fi
        case "$err" in
          *Rubbish*|*deleted*)
            p="MEGA stopped this sync: the folder was deleted on MEGA (it is in MEGA's Rubbish bin). Restore it there first, then press Resume. Or stop syncing it here and add it again: that uploads this copy to a new MEGA folder." ;;
          *)
            p="MEGA stopped this sync ($run: $err). Fix the cause, then press Resume." ;;
        esac
        if [ -s "$PAIR_STATE/$name.resume-failed" ]; then
          p="$p Last resume failed: $(head -c 200 "$PAIR_STATE/$name.resume-failed")"
        fi
      elif rm -f "$PAIR_STATE/$name.resume-failed" && [ "$cur" != "$remote" ]; then
        p="The sync of this folder points to '$cur' on MEGA, not '$remote'. Remove the folder and add it again."
      else
        [ -e "$PAIR_STATE/$name.created" ] || date '+%F %T' > "$PAIR_STATE/$name.created"
        if [ ! -e "$PAIR_STATE/$name.established" ] && ! dir_is_empty "$dir"; then
          date '+%F %T' > "$PAIR_STATE/$name.established"
          log "Folder '$name': sync established; empty-folder guard armed."
        fi
      fi
    elif ! mount_ok "$MB_CURRENT"; then
      p="No MEGA folder chosen in the app's Umbrel settings (or SYNC_DIR not set)."
    elif mounts_overlap "$MB_CURRENT" "$RESTIC_REPOSITORY"; then
      p="The MEGA folder and the Backup folder overlap. Pick separate folders in the app's Umbrel settings."
    elif ! mkdir -p "$dir" 2>/dev/null; then
      p="Cannot create the local folder."
    elif ! dir_is_empty "$dir" && [ "$merge" != 1 ]; then
      p="The local folder already has files. Confirm on the Folders page that they may be merged into MEGA."
    elif other="$(_remote_overlap "$name" "$remote" "$active")"; then
      p="'$remote' is inside, or contains, the MEGA folder of '$other'. MEGA cannot sync nested folders."
    elif ! mega-ls "$remote" >/dev/null 2>&1; then
      p="The MEGA folder '$remote' does not exist (or is not accessible)."
    else
      log "Creating sync: $dir <-> $remote"
      if mega-sync "$dir" "$remote" >/dev/null 2>&1; then
        date '+%F %T' > "$PAIR_STATE/$name.created"
      else
        p="MEGAcmd could not create the sync. See the log."
        log "ERROR: mega-sync failed for '$name'."
      fi
    fi
    if [ -n "$p" ]; then
      PAIRS_PROBLEMS=$(( PAIRS_PROBLEMS + 1 ))
      problems="$(jq -c --arg n "$name" --arg p "$p" '. + {($n): $p}' <<< "$problems")"
    fi
  done <<< "$active"
  _pairs_status "$problems"
  return 0
}

# Regex-escape a literal string for grep.
_re() { printf '%s' "$1" | sed 's/[]\/$*.^[]/\\&/g'; }

# Prints the name of an earlier pair in the list whose remote is the same as,
# inside, or around $2 (the earlier pair keeps its sync).
_remote_overlap() {
  local me="$1" r="$2" n o
  while IFS=$'\t' read -r n o _; do
    [ "$n" != "$me" ] || return 1
    [ -n "$n" ] || continue
    o="$(strip_slash "$o")"
    if [ "$o" = "$r" ] || [ "$o" = / ] || [ "$r" = / ] || [[ "$r" == "$o"/* ]] || [[ "$o" == "$r"/* ]]; then
      printf '%s' "$n"; return 0
    fi
  done <<< "$3"
  return 1
}

# Write pairs-status.json when the problems change. Logs each new problem once.
_pairs_status() {
  local tmp="$PAIRS_STATUS.tmp.$$" old="${_PAIRS_STATUS_LAST:-}"
  [ "$1" != "$old" ] || return 0
  [ -n "$old" ] || old='{}'
  jq -r --argjson old "$old" 'to_entries[] | select($old[.key] != .value) | "Folder \(.key): \(.value)"' <<< "$1" \
    | while IFS= read -r line; do log "PROBLEM: $line"; done
  jq -n --argjson p "$1" --arg t "$(date -Iseconds)" '{problems: $p, checked: $t}' > "$tmp" \
    && mv -f "$tmp" "$PAIRS_STATUS"
  _PAIRS_STATUS_LAST="$1"
}
