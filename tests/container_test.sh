#!/bin/bash
# Container-level tests without a MEGA account. Runs on the Docker host:
#   docker compose build && tests/container_test.sh
# Uses a throwaway container "mega-backup-test" and temp dirs; never logs in to MEGA.
set -uo pipefail

IMAGE="${IMAGE:-mega-backup:local}"
NAME=mega-backup-test
T="$(mktemp -d)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; docker run --rm -v "$T:/t" --entrypoint rm "$IMAGE" -rf /t/config /t/current /t/repo /t/restore; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T"/{config,current,repo,restore}

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# start: MOUNTS, if set, replaces the default mounts.
MOUNTS_ALL=(-v "$T/config:/config" -v "$T/current:/data/current" -v "$T/repo:/data/repo" -v "$T/restore:/data/restore")
start() {
  docker rm -f "$NAME" >/dev/null 2>&1
  local mounts
  if [ -n "${MOUNTS+x}" ]; then mounts=("${MOUNTS[@]}"); else mounts=("${MOUNTS_ALL[@]}"); fi
  docker run -d --name "$NAME" --hostname mega-backup --init \
    -e MEGA_REMOTE_PATH=/Test -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ=UTC -e APP_PASSWORD=test-app-pw \
    "${mounts[@]}" "$IMAGE" >/dev/null
}
# web PATH: HTTP status code of a request from inside the container.
web() { docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080$1"; }
state() { docker exec "$NAME" jq -r .state /config/engine-status.json 2>/dev/null; }
# wait_log PATTERN [seconds]
wait_log() {

  for _ in $(seq 1 "${2:-30}"); do
    docker logs "$NAME" 2>&1 | grep -q "$1" && return 0
    sleep 1
  done
  return 1
}
servers() { docker exec "$NAME" pgrep -x mega-cmd-server | wc -l; }

echo "== first start (logged out)"
start
check "password banner shown"          wait_log 'Generated a new restic repository password'
check "restic repo created"            wait_log 'restic repo created'
check "login hint shown"               wait_log 'docker exec -it mega-backup mega-cmd' 60
check "container still running"        [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ]
check "exactly one MEGAcmd server"     [ "$(servers)" = 1 ]
check "server runs as PUID"            [ "$(docker exec "$NAME" ps -o uid= -C mega-cmd-server | tr -d ' ')" = "$(id -u)" ]
for _ in $(seq 1 20); do [ "$(web /healthz)" = 200 ] && break; sleep 1; done
check "web UI answers /healthz"        [ "$(web /healthz)" = 200 ]
check "  ...pages need the app login"  [ "$(web /)" = 302 ]
check "  ...login page loads"          [ "$(web /login)" = 200 ]
check "web UI runs as PUID"            [ "$(docker exec "$NAME" ps -o uid= -C python3 | tr -d ' ' | sort -u)" = "$(id -u)" ]
docker exec "$NAME" /usr/local/bin/healthcheck.sh; rc=$?
check "healthcheck passes when logged out (rc=$rc)" [ "$rc" = 0 ]
check "engine status: waiting-login"   [ "$(state)" = waiting-login ]
check "app log written"                docker exec "$NAME" grep -q 'Not logged in to MEGA' /config/logs/app.log
check "app log is private"             [ "$(docker exec "$NAME" stat -c %a /config/logs/app.log)" = 600 ]
docker exec "$NAME" mega-whoami >/dev/null 2>&1; rc=$?
check "mega-whoami via docker exec: not logged in (rc=$rc)" [ "$rc" = 57 ]
check "  ...did not start a second server" [ "$(servers)" = 1 ]
check "nothing root-owned in /config"  [ -z "$(docker exec "$NAME" find /config ! -uid "$(id -u)")" ]
check "password file is private"       [ "$(docker exec "$NAME" stat -c %a /config/restic-password)" = 600 ]
mid1="$(docker exec "$NAME" cat /etc/machine-id)"

echo "== manual backup via docker exec (as root) keeps ownership"
echo hello > "$T/current/a.txt"
docker exec -e SKIP_SYNC_CHECK=1 "$NAME" backup.sh >/dev/null 2>&1; rc=$?
check "manual backup succeeds (rc=$rc)" [ "$rc" = 0 ]
check "nothing root-owned in repo"     [ -z "$(docker exec "$NAME" find /data/repo ! -uid "$(id -u)")" ]
check "restic snapshots works via exec" docker exec "$NAME" restic snapshots -q >/dev/null

echo "== the container exits if the web UI dies"
docker exec "$NAME" pkill -f /app/web/server.py
for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] && break; sleep 1; done
check "container stopped"              [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ]
check "  ...with a non-zero code"      [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" != 0 ]
check "  ...and says why"              bash -c "docker logs $NAME 2>&1 | grep -q 'The web UI exited'"
start
check "restarts fine"                  wait_log 'Not logged in to MEGA' 60

echo "== stop"
s=$(date +%s); docker stop "$NAME" >/dev/null; took=$(( $(date +%s) - s ))
check "stops in < 10 s (took ${took}s)" [ "$took" -lt 10 ]
check "graceful stop logged"           bash -c "docker logs $NAME 2>&1 | grep -q 'Stopped.'"

echo "== recreate: machine-id and repo persist"
start
check "repo recognised"                wait_log 'restic repo OK'
check "machine-id unchanged"           [ "$(docker exec "$NAME" cat /etc/machine-id)" = "$mid1" ]

echo "== missing repo is not silently re-created"
docker rm -f "$NAME" >/dev/null
docker run --rm -v "$T:/t" --entrypoint sh "$IMAGE" -c 'rm -rf /t/repo/* /t/repo/.[!.]*'
start
check "error about missing repo"       wait_log 'Not creating a new empty repo'
check "repo dir still empty"           [ -z "$(ls -A "$T/repo")" ]
check "MEGAcmd still starts"           wait_log 'Started mega-cmd-server'

echo "== empty-folder guard"
docker rm -f "$NAME" >/dev/null
rm -f "$T/current/a.txt"
date > "$T/config/sync-established"
start
check "refuses to start MEGAcmd"       wait_log 'REFUSING TO START MEGAcmd'
sleep 2
check "no MEGAcmd server running"      [ "$(servers)" = 0 ]
echo back > "$T/current/a.txt"
docker restart "$NAME" >/dev/null
check "starts once folder has content" wait_log 'Started mega-cmd-server'

echo "== folder mount checks"
check "overlap: separate folders"      docker exec "$NAME" bash -c '. /usr/local/bin/lib.sh; ! mounts_overlap /data/current /data/repo'
docker rm -f "$NAME" >/dev/null
mkdir -p "$T/current/inner"
MOUNTS=(-v "$T/config:/config" -v "$T/current:/data/current" -v "$T/current/inner:/data/repo")
start
wait_log 'Started mega-cmd-server' 60 >/dev/null
check "overlap: nested folders found"  docker exec "$NAME" bash -c '. /usr/local/bin/lib.sh; mounts_overlap /data/current /data/repo'
docker rm -f "$NAME" >/dev/null
rmdir "$T/current/inner" 2>/dev/null || docker run --rm -v "$T:/t" --entrypoint rm "$IMAGE" -rf /t/current/inner

MOUNTS=(-v "$T/config:/config" -v "$T/current:/data/current")
start
check "no Backup folder: not created"  wait_log 'not mounted; not creating a repository' 60
docker rm -f "$NAME" >/dev/null

MOUNTS=(-v "$T/config:/config" -v "$T/repo:/data/repo")
start
check "no MEGA folder after a sync: refuses MEGAcmd" wait_log 'REFUSING TO START MEGAcmd: /data/current is not mounted'
check "  ...engine status says so"     [ "$(state)" = folder-missing ]
check "  ...web UI still up"           [ "$(web /healthz)" = 200 ]
check "  ...no MEGAcmd server"         [ "$(servers)" = 0 ]
unset MOUNTS

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
