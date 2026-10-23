#!/bin/bash
# Runs as root: prepares machine-id and permissions, then drops to PUID:PGID.
set -euo pipefail
LOG_TAG=entrypoint
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ "$(id -u)" != 0 ]; then
  log "Not started as root; skipping machine-id and permission setup."
  exec /usr/local/bin/main.sh
fi

case "$PUID$PGID" in
  *[!0-9]*) log "PUID/PGID must be numeric (got '$PUID:$PGID')"; exit 1 ;;
esac

mkdir -p "$MB_CONFIG" "$MB_CURRENT" "$RESTIC_REPOSITORY" /data/restore

# MEGAcmd needs a unique, stable machine-id. Keep it in /config so it survives
# container recreation.
if [ ! -s "$MB_CONFIG/machine-id" ]; then
  tr -d '-' < /proc/sys/kernel/random/uuid > "$MB_CONFIG/machine-id"
  log "Generated new machine-id."
fi
cp "$MB_CONFIG/machine-id" /etc/machine-id

# Ownership: /config and the restic repo are small enough to fix recursively (only
# entries with wrong ownership are touched). The synced folder can be huge, so only
# its top level is fixed.
for d in "$MB_CONFIG" "$RESTIC_REPOSITORY"; do
  find "$d" \( ! -uid "$PUID" -o ! -gid "$PGID" \) -exec chown -h "$PUID:$PGID" {} +
done
for d in "$MB_CURRENT" /data/restore; do
  [ "$(stat -c %u:%g "$d")" = "$PUID:$PGID" ] || chown "$PUID:$PGID" "$d"
done
chmod 700 "$MB_CONFIG"

# --clear-groups (not --init-groups): PUID usually has no /etc/passwd entry here.
exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups -- /usr/local/bin/main.sh
