#!/bin/bash
# Delete snapshots by hand (Snapshots page), then prune to free the space.
#   forget.sh --snapshot ID...   delete these snapshots
#   forget.sh --path PATH        delete every snapshot of this backed-up folder
# Takes the backup lock, so it never runs at the same time as a backup.
# Prints "freed <bytes>" as its last line.
set -euo pipefail
LOG_TAG=forget
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

if [ "$(id -u)" = 0 ]; then
  exec /usr/local/bin/as-user.sh "$0" "$@"
fi
cd /tmp

exec 9>"$MB_CONFIG/backup.lock"
if ! flock -n 9; then
  log "A backup is running; try again when it is done."
  exit 75
fi

ids=()
case "${1:-}" in
  --snapshot)
    shift
    for id in "$@"; do
      [[ "$id" =~ ^[0-9a-f]{8,64}$ ]] || { log "Invalid snapshot ID: $id"; exit 2; }
      ids+=("$id")
    done
    ;;
  --path)
    [ -n "${2:-}" ] || { log "No path given."; exit 2; }
    mapfile -t ids < <(restic snapshots --json --host "$RESTIC_HOST" --path "$2" | jq -r '.[].id')
    ;;
  *) log "Usage: forget.sh --snapshot ID... | --path PATH"; exit 2 ;;
esac
[ "${#ids[@]}" -gt 0 ] || { log "No snapshots to delete."; exit 2; }

before="$(du -sb "$RESTIC_REPOSITORY" | cut -f1)"
log "Deleting ${#ids[@]} snapshot(s): ${ids[*]}"
restic forget "${ids[@]}"
log "restic prune"
restic prune --cleanup-cache
after="$(du -sb "$RESTIC_REPOSITORY" | cut -f1)"
freed=$(( before > after ? before - after : 0 ))
log "Done: $freed bytes freed."
echo "freed $freed"
