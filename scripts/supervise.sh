#!/bin/bash
# Runs as PUID: starts the engine (main.sh) and the web UI, and stops both when
# either one exits, so the container exits non-zero and gets restarted.
# All output also goes to /config/logs/app.log (for the web UI's Log page).
set -uo pipefail
LOG_TAG=supervise
# shellcheck source=lib.sh
. /usr/local/bin/lib.sh

mkdir -p "$MB_CONFIG/logs"
exec > >(exec /usr/local/bin/logsink.py "$MB_CONFIG/logs/app.log") 2>&1

ENGINE=""; WEB=""
stop_all() {
  local p
  for p in $ENGINE $WEB; do kill -TERM "$p" 2>/dev/null; done
  # main.sh needs a few seconds to stop MEGAcmd cleanly.
  for _ in $(seq 1 300); do
    kill -0 $ENGINE 2>/dev/null || kill -0 $WEB 2>/dev/null || return 0
    sleep 0.2
  done
  for p in $ENGINE $WEB; do kill -KILL "$p" 2>/dev/null; done
}
# shellcheck disable=SC2317  # called from the trap
on_signal() {
  stop_all
  exit 0
}
trap on_signal TERM INT

/usr/local/bin/main.sh &
ENGINE=$!
python3 -I /app/web/server.py &
WEB=$!
log "Started engine (pid $ENGINE) and web UI (pid $WEB)."

rc=0
wait -n "$ENGINE" "$WEB" || rc=$?
if kill -0 "$ENGINE" 2>/dev/null; then who="web UI"; else who="engine"; fi
log "The $who exited (code $rc). Stopping, so the container restarts."
stop_all
exit 1
