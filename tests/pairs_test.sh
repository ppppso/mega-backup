#!/bin/bash
# Offline tests for scripts/pairs.sh (folder pairs), with MEGAcmd faked. Runs inside the image:
#   docker run --rm -u 1000:1000 -v "$PWD/tests:/tests:ro" --entrypoint bash \
#     mega-backup:local /tests/pairs_test.sh
set -uo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export MB_CONFIG="$T/config" MB_CURRENT="$T/current" RESTIC_REPOSITORY="$T/repo"
export MB_REQUIRE_MOUNTS=0 FAKE="$T/fake"
mkdir -p "$MB_CONFIG" "$MB_CURRENT" "$RESTIC_REPOSITORY" "$FAKE" "$T/bin"
export PATH="$T/bin:$PATH"

# Fake MEGAcmd. $FAKE/syncs: "LOCAL|REMOTE" lines. $FAKE/remotes: existing MEGA folders.
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/bin/mega-sync" <<'EOF'
#!/bin/bash
touch "$FAKE/syncs"
echo "$*" >> "$FAKE/calls"
case "${1:-}" in
  -d) grep -vF "$2|" "$FAKE/syncs" > "$FAKE/syncs.new"; mv "$FAKE/syncs.new" "$FAKE/syncs" ;;
  -e) [ -e "$FAKE/fail-enable" ] && { echo "[err: 02:46:22] Remote node is inside Rubbish Bin"; exit 1; }
      sed -i "s#^$2|\([^|]*\)|.*#$2|\1#" "$FAKE/syncs" ;;   # back to Running
  --col-separator=*)
    echo "LOCALPATH|RUN_STATE|STATUS|ERROR|REMOTEPATH"
    # Lines: LOCAL|REMOTE[|RUN_STATE|ERROR]
    while IFS='|' read -r l r run err; do echo "$l|${run:-Running}|Synced|${err:-NO}|$r"; done < "$FAKE/syncs" ;;
  *) [ -e "$FAKE/fail-create" ] && exit 1; echo "$1|$2" >> "$FAKE/syncs" ;;
esac
EOF
cat > "$T/bin/mega-ls" <<'EOF'
#!/bin/bash
grep -qxF "$1" "$FAKE/remotes"
EOF
chmod +x "$T/bin"/*
printf '%s\n' / /Docs /Photos /Photos/2024 /Music > "$FAKE/remotes"

# shellcheck source=../scripts/lib.sh
. /usr/local/bin/lib.sh
# shellcheck source=../scripts/pairs.sh
. /usr/local/bin/pairs.sh
MB_SCHEMA=/usr/local/share/mega-backup/settings-schema.json

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
fails() { ! "$@"; }
reset() {
  rm -rf "${MB_CONFIG:?}"/* "${MB_CONFIG:?}"/.[!.]* "${MB_CURRENT:?}"/* "${MB_CURRENT:?}"/.[!.]* "$FAKE/syncs" "$FAKE/calls" "$FAKE/fail-create" "$FAKE/fail-enable"
  _PAIRS_STATUS_LAST=""; _UNKNOWN_LOGGED=""
}
has_sync() { grep -qxF "$1|$2" "$FAKE/syncs" 2>/dev/null; }
problem_of() { jq -r --arg n "$1" '.problems[$n] // ""' "$MB_CONFIG/pairs-status.json"; }
set_pairs() { printf '%s\n' "$1" > "$PAIRS_FILE"; }

echo "== guard"
reset
check "nothing set up: passes"        pairs_guard
mkdir -p "$PAIR_STATE" "$MB_CURRENT/Docs"; date > "$PAIR_STATE/Docs.established"
pairs_guard; rc=$?
check "established folder empty: refuses" [ "$rc" = 1 ]
check "  ...names the folder"         grep -q '"Docs"' <<< "$GUARD_MSG"
echo x > "$MB_CURRENT/Docs/a.txt"
check "folder has files: passes"      pairs_guard
rm -r "$MB_CURRENT/Docs"
check "folder missing: refuses"       fails pairs_guard
rm "$PAIR_STATE/Docs.established"; date > "$PAIR_STATE/Docs.created"
MB_REQUIRE_MOUNTS=1 pairs_guard; rc=$?
check "MEGA folder not mounted after a sync: refuses" [ "$rc" = 1 ]
check "  ...state folder-missing"     [ "$GUARD_STATE" = folder-missing ]
reset; date > "$SYNC_MARKER"
check "single-folder setup, folder empty: refuses" fails pairs_guard

echo "== migration from the single-folder setup"
reset
echo "$MB_CURRENT|/Docs" > "$FAKE/syncs"
date > "$SYNC_CREATED"; date > "$SYNC_MARKER"
mkdir -p "$MB_CURRENT/Docs" "$MB_CURRENT/sub" "$MB_CURRENT/.debris"
echo a > "$MB_CURRENT/a.txt"; echo h > "$MB_CURRENT/.hidden"; echo inner > "$MB_CURRENT/Docs/inner.txt"
echo s > "$MB_CURRENT/sub/s.txt"; echo d > "$MB_CURRENT/.debris/d.txt"
load_settings
pairs_migrate > "$T/out" 2>&1; rc=$?
check "migration succeeds (rc=$rc)"   [ "$rc" = 0 ]
check "  ...old sync removed"         bash -c "! grep -q '^$MB_CURRENT|' '$FAKE/syncs'"
check "  ...only the pair folder left" [ "$(ls -A "$MB_CURRENT")" = Docs ]
check "  ...files moved"              [ "$(cat "$MB_CURRENT/Docs/a.txt")" = a ]
check "  ...hidden files moved"       [ -e "$MB_CURRENT/Docs/.hidden" ] && [ -e "$MB_CURRENT/Docs/.debris/d.txt" ]
check "  ...same-name folder kept inside" [ "$(cat "$MB_CURRENT/Docs/Docs/inner.txt")" = inner ]
check "  ...pairs.json written"       jq -e '.pairs == [.pairs[0]] and .pairs[0].name == "Docs" and .pairs[0].remote == "/Docs" and .pairs[0].merge == true' "$PAIRS_FILE"
check "  ...markers moved"            [ -e "$PAIR_STATE/Docs.created" ] && [ -e "$PAIR_STATE/Docs.established" ] && [ ! -e "$SYNC_MARKER" ]
check "  ...guard passes"             pairs_guard
pairs_reconcile >/dev/null 2>&1
check "  ...new sync created"         has_sync "$MB_CURRENT/Docs" /Docs
check "  ...no problems"              [ "$(jq '.problems | length' "$MB_CONFIG/pairs-status.json")" = 0 ]
pairs_migrate >/dev/null 2>&1
check "  ...second run does nothing"  [ "$(ls -A "$MB_CURRENT")" = Docs ]

echo "== migration resumes after a crash"
reset
printf 'Music\t/Music\t1\n' > "$MIGRATING"; : > "$MIGRATING.moved"
mkdir -p "$MB_CURRENT/$MIGRATE_TMP"; echo m > "$MB_CURRENT/$MIGRATE_TMP/m.txt"
pairs_migrate >/dev/null 2>&1
check "finishes the rename"           [ "$(cat "$MB_CURRENT/Music/m.txt")" = m ]
check "  ...writes pairs.json"        jq -e '.pairs[0].name == "Music"' "$PAIRS_FILE"
check "  ...clears the marker"        [ ! -e "$MIGRATING" ] && [ ! -e "$MIGRATING.moved" ]

echo "== migration from settings only (no sync yet)"
reset
echo '{"mega_remote_path": "/Photos/2024/"}' > "$MB_CONFIG/settings.json"
load_settings
pairs_migrate >/dev/null 2>&1
check "pair named after the folder"   jq -e '.pairs[0].name == "2024" and .pairs[0].remote == "/Photos/2024" and .pairs[0].merge == false' "$PAIRS_FILE"
reset
echo '{"mega_remote_path": "/"}' > "$MB_CONFIG/settings.json"
load_settings; pairs_migrate >/dev/null 2>&1
check "whole account: pair named MEGA" jq -e '.pairs[0].name == "MEGA"' "$PAIRS_FILE"
reset; load_settings; pairs_migrate >/dev/null 2>&1
check "new install: nothing written"  [ ! -e "$PAIRS_FILE" ]

echo "== adding and removing folder pairs"
reset
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs"}, {"name": "Photos 2024", "remote": "/Photos/2024/"}]}'
pairs_reconcile > "$T/out" 2>&1
check "both syncs created"            has_sync "$MB_CURRENT/Docs" /Docs && has_sync "$MB_CURRENT/Photos 2024" /Photos/2024
check "  ...local folders created"    [ -d "$MB_CURRENT/Docs" ] && [ -d "$MB_CURRENT/Photos 2024" ]
check "  ...created markers"          [ -e "$PAIR_STATE/Photos 2024.created" ]
echo x > "$MB_CURRENT/Docs/x.txt"
pairs_reconcile >/dev/null 2>&1
check "guard armed once it has files" [ -e "$PAIR_STATE/Docs.established" ]
check "  ...not for the empty one"    [ ! -e "$PAIR_STATE/Photos 2024.established" ]
n_calls="$(wc -l < "$FAKE/calls")"
pairs_reconcile >/dev/null 2>&1
check "nothing to do: only lists"     [ "$(( $(wc -l < "$FAKE/calls") - n_calls ))" = 1 ]

set_pairs '{"pairs": [{"name": "Photos 2024", "remote": "/Photos/2024"}], "removed": [{"name": "Docs", "remote": "/Docs"}]}'
pairs_reconcile > "$T/out" 2>&1
check "removed pair: sync deleted"    fails grep -q "^$MB_CURRENT/Docs|" "$FAKE/syncs"
check "  ...files kept"               [ -e "$MB_CURRENT/Docs/x.txt" ]
check "  ...markers removed"          [ ! -e "$PAIR_STATE/Docs.established" ] && [ ! -e "$PAIR_STATE/Docs.created" ]
check "  ...other pair untouched"     has_sync "$MB_CURRENT/Photos 2024" /Photos/2024

echo "== problems are reported, not forced"
reset
mkdir -p "$MB_CURRENT/Docs"; echo x > "$MB_CURRENT/Docs/x.txt"
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs"}, {"name": "Gone", "remote": "/Nope"},
                      {"name": "All", "remote": "/Photos"}, {"name": "Sub", "remote": "/Photos/2024"}]}'
pairs_reconcile > "$T/out" 2>&1
check "non-empty folder without merge: no sync" bash -c "! grep -q '/Docs|' '$FAKE/syncs'"
check "  ...problem says why"         grep -q 'already has files' <<< "$(problem_of Docs)"
check "missing MEGA folder: problem"  grep -q 'does not exist' <<< "$(problem_of Gone)"
check "nested MEGA folders: second one refused" grep -q "inside, or contains" <<< "$(problem_of Sub)"
check "  ...first one created"        has_sync "$MB_CURRENT/All" /Photos
check "problems are logged"           grep -q 'PROBLEM: Folder Docs' "$T/out"
pairs_reconcile > "$T/out" 2>&1
check "  ...but only once"            bash -c "! grep -q PROBLEM '$T/out'"
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs", "merge": true}]}'
pairs_reconcile >/dev/null 2>&1
check "merge confirmed: sync created" has_sync "$MB_CURRENT/Docs" /Docs
check "  ...problem cleared"          [ -z "$(problem_of Docs)" ]
check "  ...other syncs left alone (not in removed)" has_sync "$MB_CURRENT/All" /Photos
check "  ...and logged once"          [ "$(pairs_reconcile 2>&1 | grep -c 'does not manage')" = 0 ]

reset
echo "$MB_CURRENT/Docs|/Music" > "$FAKE/syncs"; mkdir -p "$MB_CURRENT/Docs"
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs"}]}'
pairs_reconcile >/dev/null 2>&1
check "sync points elsewhere: problem, not changed" has_sync "$MB_CURRENT/Docs" /Music
check "  ...problem says so"          grep -q "points to '/Music'" <<< "$(problem_of Docs)"

echo "== MEGA stops a sync (folder deleted on MEGA)"
reset
mkdir -p "$MB_CURRENT/Docs"; echo x > "$MB_CURRENT/Docs/x.txt"
echo "$MB_CURRENT/Docs|//bin/Docs|Disabled|Remote node moved to Rubbish Bin" > "$FAKE/syncs"
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs"}]}'
pairs_reconcile >/dev/null 2>&1
check "problem says it was deleted on MEGA" grep -q "deleted on MEGA" <<< "$(problem_of Docs)"
check "  ...sync not touched"         grep -q "|Disabled|" "$FAKE/syncs"
check "  ...local files kept"         [ -e "$MB_CURRENT/Docs/x.txt" ]
check "  ...not resumed by itself"    fails grep -q -- "^-e" "$FAKE/calls"
date > "$PAIR_STATE/Docs.resume"
touch "$FAKE/fail-enable"                     # still in the Rubbish bin: MEGAcmd refuses
pairs_reconcile >/dev/null 2>&1
check "resume refused: the reason is shown" grep -q "Last resume failed: Remote node is inside Rubbish Bin" <<< "$(problem_of Docs)"
rm "$FAKE/fail-enable"
date > "$PAIR_STATE/Docs.resume"
sed -i "s#//bin/Docs#/Docs#" "$FAKE/syncs"   # restored from the Rubbish bin
pairs_reconcile >/dev/null 2>&1
check "resume asked: sync enabled"    grep -q -- "^-e $MB_CURRENT/Docs" "$FAKE/calls"
check "  ...request cleared"          [ ! -e "$PAIR_STATE/Docs.resume" ]
pairs_reconcile >/dev/null 2>&1
check "  ...problem gone once running" [ -z "$(problem_of Docs)" ]
check "  ...old failure forgotten"   [ ! -e "$PAIR_STATE/Docs.resume-failed" ]

reset
echo "$MB_CURRENT/Docs|/Docs" > "$FAKE/syncs"
echo 'not json' > "$PAIRS_FILE"
pairs_reconcile >/dev/null 2>&1; rc=$?
check "broken pairs.json: fails (rc=$rc)" [ "$rc" = 1 ]
check "  ...no sync removed"          has_sync "$MB_CURRENT/Docs" /Docs
set_pairs '{"pairs": []}'
pairs_reconcile >/dev/null 2>&1
check "empty list: no sync removed"   has_sync "$MB_CURRENT/Docs" /Docs
set_pairs '{"pairs": [{"name": "../evil", "remote": "/Docs"}, {"name": "ok", "remote": "relative"}]}'
pairs_reconcile >/dev/null 2>&1
check "invalid names/paths ignored"   [ ! -e "$T/evil" ] && [ ! -e "$MB_CURRENT/ok" ]

reset
set_pairs '{"pairs": [{"name": "Docs", "remote": "/Docs"}]}'
touch "$FAKE/fail-create"
pairs_reconcile >/dev/null 2>&1
check "MEGAcmd refuses: problem"      grep -q 'could not create' <<< "$(problem_of Docs)"
rm "$FAKE/fail-create"
pairs_reconcile >/dev/null 2>&1
check "  ...retried next time"        has_sync "$MB_CURRENT/Docs" /Docs

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
