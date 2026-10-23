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
