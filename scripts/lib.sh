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

# Prints "RUN_STATE|STATUS|ERROR|REMOTEPATH" for the sync whose local path is
# $MB_CURRENT, or nothing if there is none. Column names verified against
# MEGAcmd 2.6 (`mega-sync --help` and src/sync_command.cpp).
# Healthy: RUN_STATE=Running, ERROR=NO. STATUS: Synced | Syncing | Pending | Processing | NONE.
sync_row() {
  local out
  # Never call a mega-* client without a server: it would start a second one.
  server_running || return 1
  out="$(mega-sync --col-separator='|' --output-cols=LOCALPATH,RUN_STATE,STATUS,ERROR,REMOTEPATH 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -F'|' -v p="$MB_CURRENT" '
    { for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
    $1 == p || $1 == p "/" { print $2 "|" $3 "|" $4 "|" $5; exit }'
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
