#!/bin/bash
# Docker HEALTHCHECK: healthy = MEGAcmd server running and logged in.
# `mega-whoami` exits 0 when logged in and 57 when not (verified on MEGAcmd 2.6).
set -eu
# Check the server first: a mega-* client started without a server spawns a new one.
pgrep -x mega-cmd-server >/dev/null || exit 1
cd /tmp
exec mega-whoami >/dev/null 2>&1
