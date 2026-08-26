#!/usr/bin/env bash
# Fix 50-02 Phase 10: `validate`, the old->1.1 conversion, and backups.
# Spec cases 3-7, 57-61 (plus the schema-version edges from 9/10).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-validate
git_global_setup

baks() { ls "$HOME"/.repositories.json.*.bak 2>/dev/null | wc -l; }
bak_one() { ls "$HOME"/.repositories.json.*.bak 2>/dev/null | head -1; }
db() { echo "$LAST_OUT" | jq -r ".database.$1"; }
sch() { echo "$LAST_OUT" | jq -r ".schema.$1"; }

# Real key files, so the converted records are actually healthy and exit 0
# means "the conversion worked" rather than "the fixture was broken anyway".
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/alpha.key"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/beta.key"

# an old flat-format store, exactly the pre-1.1 shape
write_old_store() {
    cat > "$(store)" << EOF
{
  "alpha": {
    "name": "alpha.repo",
    "org": "myorg",
    "branch": "main",
    "private_key": "$HOME/.ssh/alpha.key",
    "public_key": "$HOME/.ssh/alpha.key.pub",
    "locations": []
  },
  "beta": {
    "name": "beta.repo",
    "org": "myorg",
    "branch": "main",
    "private_key": "$HOME/.ssh/beta.key",
    "public_key": "$HOME/.ssh/beta.key.pub",
    "locations": [{"path": "$WORK/gone"}]
  }
}
EOF
}

echo "=== missing store ==="
run 1 "no store at all -> 1" validate --output-format json
check "database Failed" "$( [ "$(db status)" = "Failed" ] && echo 1 || echo 0 )"
check "reason names the file" "$( echo "$LAST_OUT" | jq -e '.database.description | test("not found")' >/dev/null && echo 1 || echo 0 )"

echo "=== unparseable store: reported, never repaired ==="
echo '{not json' > "$(store)"
cp "$(store)" "$WORK/broken.before"
run 1 "unparseable -> 1" validate --output-format json
check "database code 3" "$( [ "$(db code)" = "3" ] && echo 1 || echo 0 )"
check "description matches the spec text" \
    "$( [ "$(db description)" = "Unable to parse database file" ] && echo 1 || echo 0 )"
check "no schema key reported" "$( echo "$LAST_OUT" | jq -e 'has("schema")' >/dev/null 2>&1 && echo 0 || echo 1 )"
run 1 "--fix cannot repair it either -> 1" validate --fix --output-format json
check "still code 3" "$( [ "$(db code)" = "3" ] && echo 1 || echo 0 )"
check "store byte-identical" "$( cmp -s "$WORK/broken.before" "$(store)" && echo 1 || echo 0 )"
check "no backup written" "$( [ "$(baks)" = "0" ] && echo 1 || echo 0 )"

echo "=== 3: old format without --fix -> reported, store unchanged ==="
write_old_store
cp "$(store)" "$WORK/old.before"
run 1 "3: old format -> 1" validate --output-format json
check "3: database Failed" "$( [ "$(db status)" = "Failed" ] && echo 1 || echo 0 )"
check "3: code 90" "$( [ "$(db code)" = "90" ] && echo 1 || echo 0 )"
check "3: description matches the spec text" \
    "$( [ "$(db description)" = "Database is in old format" ] && echo 1 || echo 0 )"
check "3: store unchanged" "$( cmp -s "$WORK/old.before" "$(store)" && echo 1 || echo 0 )"
check "3: no backup written" "$( [ "$(baks)" = "0" ] && echo 1 || echo 0 )"
check "3: no per-repo pass ran" "$( echo "$LAST_OUT" | jq -e 'has("repositories")' >/dev/null 2>&1 && echo 0 || echo 1 )"

echo "=== 4: validate --fix converts, backs up, and backfills ==="
run 0 "4: --fix -> 0" validate --fix --output-format json
check "4: database Fixed" "$( [ "$(db status)" = "Fixed" ] && echo 1 || echo 0 )"
check "4: schema Ok" "$( [ "$(sch status)" = "Ok" ] && echo 1 || echo 0 )"
check "4: store is now schema 1.1" "$( [ "$(jq -r '.schema' "$(store)")" = "1.1" ] && echo 1 || echo 0 )"
check "4: both records survived the move" \
    "$( rec_exists alpha && rec_exists beta && echo 1 || echo 0 )"
check "4: exactly one backup written" "$( [ "$(baks)" = "1" ] && echo 1 || echo 0 )"
BAK="$(bak_one)"
check "4: backup name is timestamped" \
    "$( echo "$BAK" | grep -q '\.repositories\.json\.[0-9]\{8\}T[0-9]\{6\}Z\.bak$' && echo 1 || echo 0 )"
check "4: backup is mode 600" "$( [ "$(stat -c '%a' "$BAK")" = "600" ] && echo 1 || echo 0 )"
check "4: backup holds the ORIGINAL old-format content" \
    "$( cmp -s "$WORK/old.before" "$BAK" && echo 1 || echo 0 )"
check "4: backup path printed in the output" \
    "$( echo "$LAST_OUT" | jq -e --arg b "$BAK" '.database.description | test($b; "x")' >/dev/null 2>&1 || echo "$LAST_OUT" | grep -qF "$BAK" && echo 1 || echo 0 )"
echo "  backup: $BAK"

echo "--- 59: --fix propagated into the records ---"
check "59: alpha got visibility" "$( [ -n "$(rec_field alpha visibility)" ] && echo 1 || echo 0 )"
check "59: alpha got foreign" "$( [ "$(rec_has alpha foreign)" = "true" ] && echo 1 || echo 0 )"
check "59: alpha got origin" "$( [ -n "$(rec_field alpha origin)" ] && echo 1 || echo 0 )"
check "59: alpha origin composed from the convention" \
    "$( [ "$(rec_field alpha origin)" = "git@alpha.repo:myorg/alpha.repo.git" ] && echo 1 || echo 0 )"
check "59: alpha got both timestamps" \
    "$( [ "$(rec_has alpha date_created)" = "true" ] && [ "$(rec_has alpha date_updated)" = "true" ] && echo 1 || echo 0 )"
check "59: alpha got images" "$( [ "$(images_of alpha)" = "[]" ] && echo 1 || echo 0 )"
check "59: beta's dead location was pruned" "$( [ "$(loc_count beta)" = "0" ] && echo 1 || echo 0 )"

echo "=== 5: a second --fix converts nothing and writes no new backup ==="
run 0 "5: second --fix -> 0" validate --fix --output-format json
check "5: database Ok, not Fixed" "$( [ "$(db status)" = "Ok" ] && echo 1 || echo 0 )"
check "5: still exactly one backup" "$( [ "$(baks)" = "1" ] && echo 1 || echo 0 )"

echo "=== 7: two conversions produce two distinct backups ==="
sleep 1
write_old_store
run 0 "7: convert again -> 0" validate --fix --output-format json
check "7: two backups now" "$( [ "$(baks)" = "2" ] && echo 1 || echo 0 )"
check "7: the first backup still holds the original" \
    "$( cmp -s "$WORK/old.before" "$BAK" && echo 1 || echo 0 )"

echo "=== 6: a conversion that fails verification changes nothing ==="
write_old_store
cp "$(store)" "$WORK/before6.json"
BAKS_BEFORE="$(baks)"
# force the verification to reject the freshly built temp file
gu_eval "
    db_format_state() { printf 'invalid\n'; }
    if db_convert_with_backup >/dev/null 2>&1; then exit 0; else exit 7; fi
" >/dev/null 2>&1
check "6: conversion reported failure" "$( [ $? -eq 7 ] && echo 1 || echo 0 )"
check "6: store byte-identical" "$( cmp -s "$WORK/before6.json" "$(store)" && echo 1 || echo 0 )"
check "6: no new backup written" "$( [ "$(baks)" = "$BAKS_BEFORE" ] && echo 1 || echo 0 )"
check "6: no temp file left behind" \
    "$( ls "$HOME"/.repositories.json.?????? 2>/dev/null | grep -q . && echo 0 || echo 1 )"

echo "=== 61: malformed schema value ==="
echo '{"schema":"not-a-version","repositories":{}}' > "$(store)"
run 1 "61: bad schema -> 1" validate --output-format json
check "61: schema Failed" "$( [ "$(sch status)" = "Failed" ] && echo 1 || echo 0 )"
check "61: no per-repo pass" "$( echo "$LAST_OUT" | jq -e 'has("repositories")' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "61: database itself reported Ok (the layout is fine)" \
    "$( [ "$(db status)" = "Ok" ] && echo 1 || echo 0 )"
cp "$(store)" "$WORK/badschema.before"
run 1 "61: --fix does not guess a version -> 1" validate --fix --output-format json
check "61: store left untouched rather than re-wrapped" \
    "$( cmp -s "$WORK/badschema.before" "$(store)" && echo 1 || echo 0 )"
check "61: not nested inside itself" \
    "$( jq -e '.repositories | has("repositories")' "$(store)" >/dev/null 2>&1 && echo 0 || echo 1 )"

# a 1.1-shaped store that merely lost its version marker is stamped, not wrapped
echo '{"repositories":{}}' > "$(store)"
run 0 "lost schema marker is repaired -> 0" validate --fix --output-format json
check "schema stamped in place" "$( [ "$(jq -r '.schema' "$(store)")" = "1.1" ] && echo 1 || echo 0 )"
check "repositories not nested inside itself" \
    "$( jq -e '.repositories | has("repositories")' "$(store)" >/dev/null 2>&1 && echo 0 || echo 1 )"

echo '{"schema":"9.0","repositories":{}}' > "$(store)"
run 1 "schema newer than this script -> 1" validate --output-format json
check "newer schema reported as a schema failure" "$( [ "$(sch status)" = "Failed" ] && echo 1 || echo 0 )"

echo "=== 60: empty store validates clean ==="
echo '{"schema":"1.1","repositories":{}}' > "$(store)"
run 0 "60: empty store -> 0" validate --output-format json
check "60: database Ok" "$( [ "$(db status)" = "Ok" ] && echo 1 || echo 0 )"
check "60: schema Ok" "$( [ "$(sch status)" = "Ok" ] && echo 1 || echo 0 )"
check "60: repositories is an empty array" \
    "$( echo "$LAST_OUT" | jq -e '.repositories == []' >/dev/null && echo 1 || echo 0 )"

echo "=== 57/58: healthy store, then one unhealthy repo ==="
mkdir -p "$WORK/w1"
( cd "$WORK/w1" && git init -q && git remote add origin "https://github.com/myorg/one.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
mkdir -p "$WORK/w2"
( cd "$WORK/w2" && git init -q && git remote add origin "https://github.com/myorg/two.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 0 "adopt one.repo -> 0" folder adopt "$WORK/w1"
run 0 "adopt two.repo -> 0" folder adopt "$WORK/w2"

run 0 "57: healthy store -> 0" validate --output-format json
check "57: database Ok" "$( [ "$(db status)" = "Ok" ] && echo 1 || echo 0 )"
check "57: schema Ok" "$( [ "$(sch status)" = "Ok" ] && echo 1 || echo 0 )"
check "57: both repos reported" "$( [ "$(echo "$LAST_OUT" | jq -r '.repositories | length')" = "2" ] && echo 1 || echo 0 )"
check "57: every repo healthy" \
    "$( echo "$LAST_OUT" | jq -e 'all(.repositories[]; .checks.health.status == "Ok")' >/dev/null && echo 1 || echo 0 )"
check "each entry carries its own id first" \
    "$( echo "$LAST_OUT" | jq -e 'all(.repositories[]; (keys_unsorted[0]) == "id")' >/dev/null && echo 1 || echo 0 )"

( cd "$WORK/w2" && git remote set-url origin "https://github.com/elsewhere/moved" )
run 1 "58: one unhealthy repo -> 1" validate --output-format json
check "58: the broken repo reports Failed" \
    "$( echo "$LAST_OUT" | jq -e '.repositories[] | select(.id == "two.repo") | .checks.health.status == "Failed"' >/dev/null && echo 1 || echo 0 )"
check "58: the healthy one is still reported Ok" \
    "$( echo "$LAST_OUT" | jq -e '.repositories[] | select(.id == "one.repo") | .checks.health.status == "Ok"' >/dev/null && echo 1 || echo 0 )"
check "58: both still present" "$( [ "$(echo "$LAST_OUT" | jq -r '.repositories | length')" = "2" ] && echo 1 || echo 0 )"
( cd "$WORK/w2" && git remote set-url origin "https://github.com/myorg/two.repo" )

echo "=== default output folds the whole tree ==="
run 0 "text output -> 0" validate
check "database folds to a bare Ok" "$( echo "$LAST_OUT" | grep -qx 'database: Ok' && echo 1 || echo 0 )"
check "nested repo health folded too" "$( echo "$LAST_OUT" | grep -q 'health: Ok' && echo 1 || echo 0 )"
check "no raw code: anywhere" "$( echo "$LAST_OUT" | grep -q 'code:' && echo 0 || echo 1 )"

echo "=== plumbing ==="
run 2 "unexpected argument -> 2" validate somerepo
run 2 "unknown flag -> 2" validate --bogus
run 2 "invalid --output-format -> 2" validate --output-format xml
run 0 "validate -h -> 0" validate -h
check "help mentions backups" "$( echo "$LAST_OUT" | grep -qi 'backup' && echo 1 || echo 0 )"
run 0 "main help lists validate" -h
check "main help mentions it" "$( echo "$LAST_OUT" | grep -q 'git-utils validate' && echo 1 || echo 0 )"

echo "=== the store gate directs users here, and this command answers ==="
write_old_store
run 90 "another command refuses an old store -> 90" repo list
check "and names validate --fix" "$( echo "$LAST_ERR" | grep -q 'validate --fix' && echo 1 || echo 0 )"
run 0 "validate --fix then repairs it -> 0" validate --fix
run 0 "repo list works afterwards -> 0" repo list

gu_total
