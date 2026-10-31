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
# One folder pair "docs": $MB_CURRENT/docs.
P="$MB_CURRENT/docs"
mkdir -p "$MB_CONFIG" "$P"
echo '{"pairs": [{"name": "docs", "remote": "/Docs", "merge": false, "added": "2020-01-01T00:00:00+00:00"}], "removed": []}' \
  > "$MB_CONFIG/pairs.json"
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
make_files() { local i; for i in $(seq 1 "$1"); do echo "file $i $RANDOM" > "$P/f$i.txt"; done; }

echo "== empty source"
check "empty source fails"            [ "$(run)" = 1 ]
check "  ...with a clear message"     grep -q 'is empty or missing' "$OUT"
check "  ...and creates no snapshot"  [ "$(snap_count)" = 0 ]

echo "== first backup"
make_files 50
mkdir -p "$P/.debris" "$P/photos/2024"
echo junk > "$P/.debris/old.txt"
head -c 3000000 /dev/urandom > "$P/photos/2024/big.bin"
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
mv "$P/photos" "$P/pictures"
run >/dev/null
added="$(grep -o '[0-9]* bytes added' "$OUT" | cut -d' ' -f1)"
check "rename added < 100 kB (got $added)" [ "${added:-999999}" -lt 100000 ]

echo "== changed and deleted files"
echo "new content" > "$P/f1.txt"
rm "$P/f2.txt"
check "small change passes the guard" [ "$(run)" = 0 ]
check "  ...diff logged"              grep -q '1 removed' "$OUT"
check "deleted file restorable from first snapshot" \
  bash -c "restic dump $first '$P/f2.txt' | grep -q '^file 2 '"
check "old version of changed file restorable" \
  bash -c "restic dump $first '$P/f1.txt' | grep -q '^file 1 '"

echo "== touching files (metadata only) does not trip the guard"
touch "$P"/f*.txt
check "touch-all run passes"          [ "$(run)" = 0 ]

echo "== mass deletion trips the guard and sets a sticky prune hold"
rm "$P"/f1*.txt "$P"/f2*.txt "$P"/f3*.txt   # ~30 of 50
n_before="$(snap_count)"
check "mass deletion run fails"       [ "$(run)" = 1 ]
check "  ...snapshot still taken"     [ "$(snap_count)" = $((n_before + 1)) ]
check "  ...prune-hold file written"  [ -s "$MB_CONFIG/prune-hold" ]
check "  ...forget skipped"           grep -q 'Skipping forget (prune hold)' "$OUT"
check "next run still fails (sticky)" [ "$(run)" = 1 ]
check "  ...says prune on hold"       grep -q 'prune on hold since' "$OUT"
check "  ...forget still skipped"     bash -c "! grep -q 'restic forget' '$OUT'"
rm "$MB_CONFIG/prune-hold"
check "after clearing hold: passes"   [ "$(run)" = 0 ]

echo "== overwrite with garbage (same file count) trips the guard"
for f in "$P"/f*.txt; do head -c 100 /dev/urandom > "$f"; done
check "mass overwrite run fails"      [ "$(run)" = 1 ]
check "  ...reason is 'changed'"      grep -q 'files changed' "$MB_CONFIG/prune-hold"
rm "$MB_CONFIG/prune-hold"

echo "== retention (KEEP_DAILY=3, KEEP_MONTHLY=2) with synthetic old snapshots"
for d in 2026-01-10 2026-01-20 2026-02-05 2026-02-25 2026-03-01 2026-03-02 2026-03-03 2026-03-04; do
  restic backup -q --host mega-backup --time "$d 03:30:00" "$P" >/dev/null
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
today_n="$(restic snapshots --json | jq --arg d "$(date -u +%F)" '[.[] | select(.time[:10] == $d)] | length')"
check "same-day snapshots kept (keep-within 2d): $today_n" [ "$today_n" -gt 1 ]

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
check "invalid values: default used"  bash -c "grep -q -- '--keep-daily 90 --keep-monthly 24' <<< '$(forget_line)'"
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

echo "== clean-up runs even when a backup had problems"
make_files 50
run >/dev/null
rm -f "$MB_CONFIG/prune-hold"   # rewriting all files trips the guard, as it should
echo secret > "$P/unreadable.txt"; chmod 000 "$P/unreadable.txt"
check "unreadable file: run reports a problem" [ "$(run)" = 1 ]
check "  ...snapshot incomplete (exit 3)"  grep -q 'could not read some files' "$OUT"
check "  ...forget still ran"         grep -q 'restic forget --host' "$OUT"
check "  ...prune still ran"          grep -q 'restic prune' "$OUT"
rm -f "$P/unreadable.txt"

echo "== prune frees the space of forgotten snapshots"
head -c 5000000 /dev/urandom > "$P/big-old.bin"
restic backup -q --host mega-backup --time "2025-01-15 03:30:00" "$P" >/dev/null
rm "$P/big-old.bin"
check "run after deleting the big file passes" [ "$(run)" = 0 ]
check "  ...2025 snapshot forgotten"  bash -c "! restic snapshots --json | jq -r '.[].time' | grep -q '^2025-01'"
check "  ...space freed (>4 MB): $(jq .bytes_freed "$MB_CONFIG/last-run.json")" \
  jq -e '.bytes_freed > 4000000' "$MB_CONFIG/last-run.json"
check "  ...Backup folder size recorded" jq -e '.repo_bytes > 0' "$MB_CONFIG/last-run.json"

set_pairs() { printf '%s\n' "$1" > "$MB_CONFIG/pairs.json"; }
PH="$MB_CURRENT/photos"
echo "== two folders: one snapshot each"
mkdir -p "$PH"; echo cat > "$PH/cat.jpg"; echo dog > "$PH/dog.jpg"
set_pairs '{"pairs": [{"name": "docs", "remote": "/Docs", "added": "2020-01-01T00:00:00+00:00"},
                      {"name": "photos", "remote": "/Photos", "added": "2026-01-01T00:00:00+01:00"}]}'
check "two-folder run passes"         [ "$(run)" = 0 ]
check "  ...snapshot of photos"       bash -c "restic snapshots --json --path '$PH' | jq -e 'length == 1' >/dev/null"
check "  ...tagged with the folder"   bash -c "restic snapshots --json --path '$PH' | jq -e '.[0].tags | index(\"folder:photos\")' >/dev/null"
check "  ...docs snapshot too"        bash -c "restic snapshots --json --latest 1 --path '$P' | jq -e '.[0].time[:10] == \"$(date +%F)\"' >/dev/null"
check "  ...last-run has both folders" jq -e '[.folders[].name] == ["docs", "photos"] and .files_total > 50' "$MB_CONFIG/last-run.json"
check "  ...photos is not compared to docs" bash -c "! grep -q 'photos: since previous' '$OUT'"
run >/dev/null
check "second run compares photos with its own snapshot" grep -q 'photos: since previous snapshot.*2 files' "$OUT"

echo "== an empty folder does not stop the other folders"
mv "$PH" "$T/photos.away"
n_docs="$(restic snapshots --json --path "$P" | jq length)"
check "run with photos missing fails"  [ "$(run)" = 1 ]
check "  ...says which folder"        grep -q 'photos: the folder is empty or missing' "$OUT"
check "  ...docs still backed up"     [ "$(restic snapshots --json --path "$P" | jq length)" -gt "$n_docs" ]
check "  ...last-run: result problems" jq -e '.result == "problems" and (.folders[] | select(.name == "photos") | .result) == "failed"' "$MB_CONFIG/last-run.json"
mv "$T/photos.away" "$PH"

echo "== snapshots of folders that are no longer synced"
mkdir -p "$MB_CURRENT/old"; echo old > "$MB_CURRENT/old/o.txt"
restic backup -q --host mega-backup --time "2024-01-01 03:30:00" "$MB_CURRENT/old" >/dev/null
restic backup -q --host mega-backup --time "2024-02-01 03:30:00" "$MB_CURRENT" >/dev/null   # single-folder setup
mkdir -p "$MB_CURRENT/archive"; echo a > "$MB_CURRENT/archive/a.txt"
restic backup -q --host mega-backup --time "2024-03-01 03:30:00" "$MB_CURRENT/archive" >/dev/null
rm -r "$MB_CURRENT/archive"   # active but empty: no new snapshot
# photos removed today: its snapshots are recent, so they stay for now.
set_pairs '{"pairs": [{"name": "docs", "remote": "/Docs", "added": "2020-01-01T00:00:00+00:00"},
                      {"name": "archive", "remote": "/Archive", "added": "2024-01-01T00:00:00+00:00"}],
            "removed": [{"name": "photos", "remote": "/Photos"}]}'
run >/dev/null
paths="$(restic snapshots --json | jq -r '.[].paths[0]' | sort -u)"
check "old removed folder: snapshots expired"      bash -c "! grep -qx '$MB_CURRENT/old' <<< '$paths'"
check "single-folder snapshots expired"            bash -c "! grep -qx '$MB_CURRENT' <<< '$paths'"
check "recently removed folder: snapshots kept"    grep -qx "$PH" <<< "$paths"
check "active folder's old snapshot kept"          grep -qx "$MB_CURRENT/archive" <<< "$paths"
check "  ...expiry logged"            grep -q 'no longer synced.*removing them' "$OUT"
echo 'not json' > "$MB_CONFIG/pairs.json"
restic backup -q --host mega-backup --time "2024-01-01 03:30:00" "$MB_CURRENT/old" >/dev/null
check "broken folder list: run fails"  [ "$(run)" = 1 ]
check "  ...nothing expired"          bash -c "restic snapshots --json --path '$MB_CURRENT/old' | jq -e 'length == 1' >/dev/null"
set_pairs '{"pairs": [{"name": "docs", "remote": "/Docs", "added": "2020-01-01T00:00:00+00:00"}]}'

echo "== deleting snapshots by hand (forget.sh)"
n="$(snap_count)"
one="$(restic snapshots --json --path "$P" | jq -r '.[0].short_id')"
forget.sh --snapshot "$one" > "$OUT" 2>&1; rc=$?
check "delete one snapshot (rc=$rc)"  [ "$rc" = 0 ]
check "  ...one fewer"                [ "$(snap_count)" = $((n - 1)) ]
check "  ...reports freed bytes"      grep -q '^freed [0-9]*$' "$OUT"
forget.sh --path "$PH" > "$OUT" 2>&1; rc=$?
check "delete a folder's snapshots (rc=$rc)" [ "$rc" = 0 ]
check "  ...none left for it"         bash -c "restic snapshots --json --path '$PH' | jq -e 'length == 0' >/dev/null"
check "  ...docs untouched"           bash -c "restic snapshots --json --path '$P' | jq -e 'length > 0' >/dev/null"
forget.sh --snapshot 'x;rm' > "$OUT" 2>&1; rc=$?
check "bad snapshot ID refused (rc=$rc)" [ "$rc" = 2 ]
exec 8>"$MB_CONFIG/backup.lock"; flock -n 8
forget.sh --path "$PH" > "$OUT" 2>&1; rc=$?
check "refused while a backup runs (rc=$rc)" [ "$rc" = 75 ]
exec 8>&-

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
