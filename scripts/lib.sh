# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this
# Shared helpers, sourced by entrypoint.sh, main.sh and backup.sh.

# Paths inside the container. Overridable only so tests can use temp dirs.
# (Not CONFIG_DIR/SYNC_DIR: those names hold *host* paths in .env.)
MB_CONFIG="${MB_CONFIG:-/config}"
MB_CURRENT="${MB_CURRENT:-/data/current}"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/data/repo}"

# Fixed restic host name: the container hostname changes on recreation, and restic
# uses host + path to pick the parent snapshot and to group snapshots in `forget`.
RESTIC_HOST=mega-backup

SYNC_MARKER="$MB_CONFIG/sync-established"
REPO_ID_FILE="$MB_CONFIG/restic-repo-id"
PRUNE_HOLD="$MB_CONFIG/prune-hold"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_TAG:-mega-backup}" "$*"
}

# Prints a block that stands out in `docker logs`.
log_banner() {
  log "=================================================================="
  local line
  for line in "$@"; do log "$line"; done
  log "=================================================================="
}

# True if the dir is missing or has nothing in it except MEGA's .debris folder.
dir_is_empty() {
  [ ! -d "$1" ] || [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name .debris -print -quit)" ]
}

# Sleep that returns early when a trapped signal arrives.
isleep() {
  sleep "$1" &
  wait $! || true
}

server_running() {
  pgrep -x mega-cmd-server >/dev/null 2>&1
}

# Prints every sync as "LOCALPATH|RUN_STATE|STATUS|ERROR|REMOTEPATH" (no header).
# Column names verified against MEGAcmd 2.6+ (`mega-sync --help`).
# Healthy: RUN_STATE=Running, ERROR=NO. STATUS: Synced | Syncing | Pending | Processing | NONE.
sync_rows() {
  local out
  # Never call a mega-* client without a server: it would start a second one.
  server_running || return 1
  out="$(mega-sync --col-separator='|' --output-cols=LOCALPATH,RUN_STATE,STATUS,ERROR,REMOTEPATH 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -F'|' '
    NF >= 5 && $1 !~ /^[ \t]*LOCALPATH[ \t]*$/ {
      for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      if ($1 != "/") sub(/\/+$/, "", $1)
      print $1 "|" $2 "|" $3 "|" $4 "|" $5 }'
}

# sync_row [localpath]: "RUN_STATE|STATUS|ERROR|REMOTEPATH" of the sync for that
# local path (default $MB_CURRENT), or nothing if there is none.
sync_row() {
  local rows
  rows="$(sync_rows)" || return 1
  printf '%s\n' "$rows" | awk -F'|' -v p="$(strip_slash "${1:-$MB_CURRENT}")" '
    $1 == p { print $2 "|" $3 "|" $4 "|" $5; exit }'
}

# "/a/b/" -> "/a/b"
strip_slash() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

# ping_hc [suffix] [body-file]: healthchecks.io-style ping. Never fails.
ping_hc() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  local url="${HEALTHCHECK_URL%/}${1:+/$1}"
  if [ -n "${2:-}" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "@$2" "$url" || log "healthcheck ping failed: $url"
  else
    curl -fsS -m 10 --retry 3 -o /dev/null "$url" || log "healthcheck ping failed: $url"
  fi
  return 0
}

# Prints the repo ID, or fails if the repo can't be opened.
restic_repo_id() {
  restic cat config --json 2>/dev/null | jq -er .id
}

# ---------------------------------------------------------------------------
# Settings. Each setting comes from /config/settings.json (written by the web UI),
# else from the environment variable with the upper-case name (plain compose .env),
# else from the schema default. Values are validated against the schema; invalid
# ones fall back to the default with a warning. Result: shell variables CFG_<NAME>
# (not exported). Booleans become 1/0.
SETTINGS_FILE="$MB_CONFIG/settings.json"
SETTINGS_SCHEMA="${MB_SCHEMA:-/usr/local/share/mega-backup/settings-schema.json}"
_SETTINGS_WARNED=""

load_settings() {
  local settings='{}' k v warn=""
  if [ -s "$SETTINGS_FILE" ]; then
    settings="$(jq -ce 'if type == "object" then . else error("not an object") end' "$SETTINGS_FILE" 2>/dev/null)" \
      || { warn="$SETTINGS_FILE is not a valid JSON object; ignoring it."; settings='{}'; }
  fi
  while IFS=$'\t' read -r k v; do
    if [ "$k" = WARN ]; then
      warn="${warn:+$warn }$v"
    else
      printf -v "CFG_$k" '%s' "$v"
    fi
  done < <(jq -nr --argjson s "$settings" --slurpfile sc "$SETTINGS_SCHEMA" '
    def norm($spec; $v):
      if $spec.type == "int" then
        (if ($v | type) == "number" and ($v | floor) == $v then $v
         elif ($v | type) == "string" and ($v | test("^[0-9]+$")) then ($v | tonumber)
         else null end) as $n
        | if $n != null and $n >= $spec.min and $n <= $spec.max then ($n | tostring) else null end
      elif $spec.type == "bool" then
        if $v == true or $v == "1" or $v == "true" then "1"
        elif $v == false or $v == "0" or $v == "false" or $v == "" then "0"
        else null end
      else
        if ($v | type) == "string" and ($v | explode | all(. >= 32))
           and ($v | test($spec.pattern)) then $v else null end
      end;
    $sc[0] | to_entries[] | .key as $k | .value as $spec | ($k | ascii_upcase) as $K
    | (if $s | has($k) then {src: "settings.json", v: $s[$k]}
       elif ($ENV | has($K)) and $ENV[$K] != "" then {src: "environment", v: $ENV[$K]}
       else {src: "default", v: $spec.default} end) as $c
    | norm($spec; $c.v) as $n
    | if $n != null then "\($K)\t\($n)"
      else "WARN\tInvalid \($k) in \($c.src), using the default (\($spec.default | tojson)).",
           "\($K)\t\(norm($spec; $spec.default))"
      end')
  # Log each distinct warning set once, not on every reload.
  if [ -n "$warn" ] && [ "$warn" != "$_SETTINGS_WARNED" ]; then
    log "WARNING: $warn"
  fi
  _SETTINGS_WARNED="$warn"
}

# ---------------------------------------------------------------------------
# Mounts. On Umbrel, a folder the user has not picked yet is not mounted at all: the
# path then is a plain directory inside the container, and anything written there
# is lost on restart. MB_REQUIRE_MOUNTS=0 turns the check off (tests only).

# True if $1 is a mount point (or the check is off).
mount_ok() {
  [ "${MB_REQUIRE_MOUNTS:-1}" = 1 ] || return 0
  awk -v p="$1" '$5 == p { f = 1 } END { exit !f }' /proc/self/mountinfo
}

# True if the folders mounted at $1 and $2 are the same, or one is inside the other
# (same device, and one mount root is a prefix of the other).
mounts_overlap() {
  local a b
  a="$(awk -v p="$1" '$5 == p { r = $3 " " $4 } END { print r }' /proc/self/mountinfo)"
  b="$(awk -v p="$2" '$5 == p { r = $3 " " $4 } END { print r }' /proc/self/mountinfo)"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "${a%% *}" = "${b%% *}" ] || return 1
  a="${a#* }"; b="${b#* }"
  [ "$a" = / ] || [ "$b" = / ] || [ "$a" = "$b" ] || [ "${a#"$b"/}" != "$a" ] || [ "${b#"$a"/}" != "$b" ]
}

# ---------------------------------------------------------------------------
# Engine status for the web UI: /config/engine-status.json, written atomically and
# only when something changes. NEXT_BACKUP (epoch seconds) is included when set.
STATE_FILE="$MB_CONFIG/engine-status.json"
_STATE_LAST=""

set_state() {
  local key="$1|${2:-}|${NEXT_BACKUP:-}" tmp
  [ "$key" != "$_STATE_LAST" ] || return 0
  tmp="$STATE_FILE.tmp.$$"
  jq -n --arg s "$1" --arg m "${2:-}" --arg next "${NEXT_BACKUP:-}" --arg since "$(date -Iseconds)" \
    '{state: $s, message: $m, since: $since,
      next_backup: (if $next == "" then null else ($next | tonumber) end)}' > "$tmp" \
    && mv -f "$tmp" "$STATE_FILE"
  _STATE_LAST="$key"
}

# A sync was created at some point (either marker). Used to refuse starting MEGAcmd
# when the local folder is missing.
SYNC_CREATED="$MB_CONFIG/sync-created"
sync_was_created() {
  [ -e "$SYNC_CREATED" ] || [ -e "$SYNC_MARKER" ]
}

# ---------------------------------------------------------------------------
# Folder pairs. Each pair syncs one MEGA folder with a sub-folder of the MEGA folder
# ($MB_CURRENT/<name>), and gets its own snapshots (restic path = that sub-folder).
# The list is /config/pairs.json, written by the web UI (and once by the migration
# from the single-folder setup):
#   {"pairs":   [{"name": "Photos", "remote": "/Photos", "merge": false, "added": "<iso>"}],
#    "removed": [{"name": "Old",    "remote": "/Old",    "removed": "<iso>"}]}
# The engine removes the sync of a pair listed under "removed". A sync that is in
# neither list is left alone, so a broken or missing file never removes a sync.
PAIRS_FILE="$MB_CONFIG/pairs.json"
PAIRS_LOCK="$MB_CONFIG/pairs.lock"
PAIR_STATE="$MB_CONFIG/pair-state"
# Same rule as NAME_RE in web/pairs.py.
PAIR_NAME_RE='^[A-Za-z0-9_][A-Za-z0-9 _.()-]{0,59}$'

pair_dir() { printf '%s/%s' "$MB_CURRENT" "$1"; }

# pairs_active: one "name<TAB>remote<TAB>merge(1/0)<TAB>added" line per valid pair.
# Fails (prints nothing) if pairs.json exists but cannot be read.
pairs_active() {
  [ -e "$PAIRS_FILE" ] || return 0
  jq -er --arg re "$PAIR_NAME_RE" '
    if type == "object" and ((.pairs // []) | type) == "array" then . else error("bad") end
    | (.pairs // [])[]
    | select((.name | type) == "string" and (.name | test($re)) and (.name | test(" $") | not)
             and (.remote | type) == "string" and (.remote | test("^/")) and (.remote | explode | all(. >= 32)))
    | [.name, .remote, (if .merge == true then "1" else "0" end), (.added // "")] | @tsv' \
    "$PAIRS_FILE" 2>/dev/null || [ "$(jq -r '(.pairs // []) | length' "$PAIRS_FILE" 2>/dev/null)" = 0 ]
}

# pairs_removed: names of removed pairs, one per line.
pairs_removed() {
  [ -e "$PAIRS_FILE" ] || return 0
  jq -r '(.removed // [])[]? | .name | strings' "$PAIRS_FILE" 2>/dev/null
}

# Run a command while holding the pairs.json lock (shared with the web UI).
with_pairs_lock() {
  ( flock -x 9 && "$@" ) 9>"$PAIRS_LOCK"
}
