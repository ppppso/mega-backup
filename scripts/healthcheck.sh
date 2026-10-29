#!/bin/bash
# Docker HEALTHCHECK: healthy = MEGAcmd server running and the web UI answering.
# Login and sync state are shown in the web UI instead.
set -eu
pgrep -x mega-cmd-server >/dev/null || exit 1
exec curl -fsS -m 10 -o /dev/null "http://127.0.0.1:${LISTEN_PORT:-8080}/healthz"
