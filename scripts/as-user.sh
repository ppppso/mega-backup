#!/bin/sh
# Run a command as PUID:PGID. Used by the mega-*/restic wrappers so that commands
# started with `docker exec` (which runs as root) behave like the main process.
set -eu
if [ "$(id -u)" = 0 ]; then
  exec setpriv --reuid="${PUID:-1000}" --regid="${PGID:-1000}" --clear-groups -- "$@"
fi
exec "$@"
