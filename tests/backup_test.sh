#!/bin/bash
# Offline tests for backup.sh (no MEGA account needed). Runs inside the image:
#   docker compose build
#   docker run --rm -u 1000:1000 -v "$PWD/tests:/tests:ro" --entrypoint bash \
#     mega-backup:local /tests/backup_test.sh
set -uo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export MB_CONFIG="$T/config" MB_CURRENT="$T/current"
export RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/config/restic-password"
export RESTIC_CACHE_DIR="$T/cache"
export SKIP_SYNC_CHECK=1 HEALTHCHECK_URL="" CHECK_WEEKDAY=0
# Temp dirs are not mount points; the mount check has its own test below.
export MB_REQUIRE_MOUNTS=0
export KEEP_DAILY=3 KEEP_MONTHLY=2 MAX_DROP_PERCENT=20 MAX_CHANGE_PERCENT=20
mkdir -p "$MB_CONFIG" "$MB_CURRENT"
echo test-password > "$RESTIC_PASSWORD_FILE"
restic init -q

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

OUT="$T/out"
run() { backup.sh > "$OUT" 2>&1; echo $?; }
snap_count() { restic snapshots --json | jq length; }
latest() { restic snapshots --json --latest 1 | jq -r '.[0].short_id'; }
make_files() { local i; for i in $(seq 1 "$1"); do echo "file $i $RANDOM" > "$MB_CURRENT/f$i.txt"; done; }

echo "== empty source"
check "empty source fails"            [ "$(run)" = 1 ]
check "  ...with a clear message"     grep -q 'is empty or missing' "$OUT"
check "  ...and creates no snapshot"  [ "$(snap_count)" = 0 ]

echo "== first backup"
make_files 50
mkdir -p "$MB_CURRENT/.debris" "$MB_CURRENT/photos/2024"
echo junk > "$MB_CURRENT/.debris/old.txt"
head -c 3000000 /dev/urandom > "$MB_CURRENT/photos/2024/big.bin"
check "first backup succeeds"         [ "$(run)" = 0 ]
check "  ...one snapshot"             [ "$(snap_count)" = 1 ]
check "  ...forget ran"               grep -q 'restic forget' "$OUT"
check ".debris is excluded"           bash -c "! restic ls latest | grep -q '\.debris'"
first="$(latest)"

echo "== unchanged second run adds ~no data"
run >/dev/null
added="$(grep -o '[0-9]* bytes added' "$OUT" | cut -d' ' -f1)"
check "second run added < 10 kB (got $added)" [ "${added:-999999}" -lt 10000 ]

echo "== renaming a big folder adds ~no data"
mv "$MB_CURRENT/photos" "$MB_CURRENT/pictures"
run >/dev/null
added="$(grep -o '[0-9]* bytes added' "$OUT" | cut -d' ' -f1)"
check "rename added < 100 kB (got $added)" [ "${added:-999999}" -lt 100000 ]

echo "== changed and deleted files"
echo "new content" > "$MB_CURRENT/f1.txt"
rm "$MB_CURRENT/f2.txt"
check "small change passes the guard" [ "$(run)" = 0 ]
check "  ...diff logged"              grep -q '1 removed' "$OUT"
check "deleted file restorable from first snapshot" \
  bash -c "restic dump $first '$MB_CURRENT/f2.txt' | grep -q '^file 2 '"
check "old version of changed file restorable" \
  bash -c "restic dump $first '$MB_CURRENT/f1.txt' | grep -q '^file 1 '"

echo "== touching files (metadata only) does not trip the guard"
touch "$MB_CURRENT"/f*.txt
check "touch-all run passes"          [ "$(run)" = 0 ]

echo "== mass deletion trips the guard and sets a sticky prune hold"
rm "$MB_CURRENT"/f1*.txt "$MB_CURRENT"/f2*.txt "$MB_CURRENT"/f3*.txt   # ~30 of 50
n_before="$(snap_count)"
check "mass deletion run fails"       [ "$(run)" = 1 ]
check "  ...snapshot still taken"     [ "$(snap_count)" = $((n_before + 1)) ]
check "  ...prune-hold file written"  [ -s "$MB_CONFIG/prune-hold" ]
check "  ...forget skipped"           grep -q 'Skipping forget/prune (on hold)' "$OUT"
check "next run still fails (sticky)" [ "$(run)" = 1 ]
check "  ...says prune on hold"       grep -q 'prune on hold since' "$OUT"
check "  ...forget still skipped"     bash -c "! grep -q 'restic forget' '$OUT'"
rm "$MB_CONFIG/prune-hold"
check "after clearing hold: passes"   [ "$(run)" = 0 ]

echo "== overwrite with garbage (same file count) trips the guard"
for f in "$MB_CURRENT"/f*.txt; do head -c 100 /dev/urandom > "$f"; done
check "mass overwrite run fails"      [ "$(run)" = 1 ]
check "  ...reason is 'changed'"      grep -q 'files changed' "$MB_CONFIG/prune-hold"
rm "$MB_CONFIG/prune-hold"

echo "== retention (KEEP_DAILY=3, KEEP_MONTHLY=2) with synthetic old snapshots"
for d in 2026-01-10 2026-01-20 2026-02-05 2026-02-25 2026-03-01 2026-03-02 2026-03-03 2026-03-04; do
  restic backup -q --host mega-backup --time "$d 03:30:00" "$MB_CURRENT" >/dev/null
done
n_before="$(snap_count)"
DRY_RUN=1 run >/dev/null
# The run itself adds tonight's snapshot; dry-run forget must remove nothing.
check "DRY_RUN removes nothing"       [ "$(snap_count)" = $((n_before + 1)) ]
check "  ...but lists what it would"  grep -q 'Would have removed' "$OUT"
run >/dev/null
# Expected: dailies for the 3 newest days (today, 03-04, 03-03); monthlies for
# the 2 newest months (Oct = today, Mar = 03-04).
remaining="$(restic snapshots --json | jq -r '.[].time[:10]' | sort -u | tr '\n' ' ')"
echo "    remaining days: $remaining"
check "January snapshots pruned"      bash -c "! grep -q '2026-01' <<< '$remaining'"
check "latest snapshot kept"          bash -c "restic snapshots --json --latest 1 | jq -e 'length == 1' >/dev/null"
check "February snapshots pruned"     bash -c "! grep -q '2026-02' <<< '$remaining'"
check "2026-03-01/02 pruned"          bash -c "! grep -qE '2026-03-0[12]' <<< '$remaining'"
check "2026-03-03 and 03-04 kept"     bash -c "grep -q '2026-03-03' <<< '$remaining' && grep -q '2026-03-04' <<< '$remaining'"

echo "== stale lock from a killed restic is cleared"
mkfifo "$T/fifo"
restic backup -q --host other --stdin < "$T/fifo" >/dev/null 2>&1 &
RPID=$!
exec 7>"$T/fifo"            # keep the fifo open so restic blocks holding its lock
sleep 3
kill -9 "$RPID"; wait "$RPID" 2>/dev/null; exec 7>&-
check "a lock is left behind"         [ "$(restic list locks --no-lock | wc -l)" -ge 1 ]
check "backup + prune still succeed"  [ "$(run)" = 0 ]
check "  ...forget ran"               grep -q 'restic forget' "$OUT"
check "  ...lock is gone"             [ "$(restic list locks --no-lock | wc -l)" = 0 ]

echo "== only one run at a time"
exec 8>"$MB_CONFIG/backup.lock"; flock -n 8
backup.sh > "$OUT" 2>&1; rc=$?
check "second concurrent run exits 75" [ "$rc" = 75 ]
exec 8>&-

echo "== repo checks"
echo wrong-id > "$MB_CONFIG/restic-repo-id"
check "repo ID mismatch fails"        [ "$(run)" = 1 ]
check "  ...with clear message"       grep -q 'does not match' "$OUT"
rm "$MB_CONFIG/restic-repo-id"
mv "$RESTIC_REPOSITORY" "$T/repo.away"
check "missing repo fails"            [ "$(run)" = 1 ]
check "  ...with clear message"       grep -q 'cannot open restic repo' "$OUT"
mv "$T/repo.away" "$RESTIC_REPOSITORY"

echo "== last-run.json"
check "ok run writes last-run.json"   [ "$(run)" = 0 ]
check "  ...result ok"                jq -e '.result == "ok" and .problems == []' "$MB_CONFIG/last-run.json"
check "  ...with snapshot and counts" jq -e '(.snapshot_id | length) == 64 and .files_total > 0 and .bytes_added != null' "$MB_CONFIG/last-run.json"
check "  ...and the diff"             jq -e '.diff.added != null and .diff.removed != null' "$MB_CONFIG/last-run.json"
mv "$RESTIC_REPOSITORY" "$T/repo.away"
run >/dev/null
mv "$T/repo.away" "$RESTIC_REPOSITORY"
check "failed run: result failed"     jq -e '.result == "failed" and .snapshot_id == null' "$MB_CONFIG/last-run.json"
check "  ...with the problem"         jq -e '.problems[0] | test("cannot open restic repo")' "$MB_CONFIG/last-run.json"
check "no temp files left"            [ -z "$(find "$MB_CONFIG" -name '*.tmp.*')" ]

echo "== settings"
forget_line() { grep -o 'restic forget.*' "$OUT"; }
run >/dev/null
check "env value used (KEEP_DAILY=3)" bash -c "grep -q -- '--keep-daily 3 ' <<< '$(forget_line)'"
echo '{"keep_daily": 7}' > "$MB_CONFIG/settings.json"
run >/dev/null
check "settings.json beats env"       bash -c "grep -q -- '--keep-daily 7 ' <<< '$(forget_line)'"
echo '{"keep_daily": "lots", "keep_monthly": -1}' > "$MB_CONFIG/settings.json"
run >/dev/null
check "invalid values: default used"  bash -c "grep -q -- '--keep-daily 90 --keep-monthly 24 ' <<< '$(forget_line)'"
check "  ...with a warning"           grep -q 'Invalid keep_daily in settings.json' "$OUT"
echo 'not json' > "$MB_CONFIG/settings.json"
run >/dev/null
check "broken settings.json: env used" bash -c "grep -q -- '--keep-daily 3 ' <<< '$(forget_line)'"
check "  ...with a warning"           grep -q 'settings.json is not a valid JSON object' "$OUT"
rm "$MB_CONFIG/settings.json"
KEEP_DAILY=abc run >/dev/null
check "invalid env: default used"     bash -c "grep -q -- '--keep-daily 90 ' <<< '$(forget_line)'"
check "  ...with a warning"           grep -q 'Invalid keep_daily in environment' "$OUT"

echo "== Backup folder must be mounted"
n_before="$(snap_count)"
check "not mounted: run fails"        [ "$(MB_REQUIRE_MOUNTS=1 run)" = 1 ]
check "  ...with a clear message"     grep -q 'no Backup folder' "$OUT"
check "  ...and no snapshot"          [ "$(snap_count)" = "$n_before" ]

echo "== healthcheck pings"
# Stub curl: records the URL and the POST body.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
url="${*: -1}"; body=""
for a in "$@"; do case "$a" in @*) body="$(cat "${a#@}")" ;; esac; done
printf 'URL %s\n%s\n' "$url" "$body" >> "$PING_LOG"
STUB
chmod +x "$T/bin/curl"
export PING_LOG="$T/pings"
mv "$RESTIC_REPOSITORY" "$T/repo.away"
PATH="$T/bin:$PATH" HEALTHCHECK_URL=https://hc.example/abc run >/dev/null
mv "$T/repo.away" "$RESTIC_REPOSITORY"
check "start ping sent"               grep -qx 'URL https://hc.example/abc/start' "$PING_LOG"
check "fail ping sent"                grep -qx 'URL https://hc.example/abc/fail' "$PING_LOG"
check "  ...with the log as body"     grep -q 'cannot open restic repo' "$PING_LOG"
: > "$PING_LOG"
PATH="$T/bin:$PATH" HEALTHCHECK_URL=https://hc.example/abc/ run >/dev/null
check "success ping sent (trailing / ok)" grep -qx 'URL https://hc.example/abc' "$PING_LOG"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
