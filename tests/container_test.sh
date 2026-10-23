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

start() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" --hostname mega-backup --init \
    -e MEGA_REMOTE_PATH=/Test -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ=UTC \
    -v "$T/config:/config" -v "$T/current:/data/current" \
    -v "$T/repo:/data/repo" -v "$T/restore:/data/restore" "$IMAGE" >/dev/null
}
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
check "login hint shown"               wait_log 'docker exec -it mega-backup mega-login' 60
check "container still running"        [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ]
check "exactly one MEGAcmd server"     [ "$(servers)" = 1 ]
check "server runs as PUID"            [ "$(docker exec "$NAME" ps -o uid= -C mega-cmd-server | tr -d ' ')" = "$(id -u)" ]
docker exec "$NAME" /usr/local/bin/healthcheck.sh; rc=$?
check "healthcheck fails when logged out (rc=$rc)" [ "$rc" != 0 ]
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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
