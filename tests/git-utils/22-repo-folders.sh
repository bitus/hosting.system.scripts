#!/usr/bin/env bash
# Fix 50-04 Phase 5: `repo folders`. Spec case 92, plus the properties the
# two fan-out commands rely on.
#
# The claim worth testing hardest is what this command does NOT do. It reports
# what the store says, not what the disk agrees with: a location that was
# deleted an hour ago is still listed, because pruning is validate --fix's job
# and repo update/redeploy need to see -- and report on -- locations that have
# rotted.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-folders
git_global_setup

echo "=== fixtures ==="
make_repo 1 rf1 rforg rfrepo
echo hi > "$WORK/seed1/f"; push_seed 1
run 0 "add rf1" repo add rforg/rfrepo/main -n rf1
run 0 "clone rf1 to A" repo clone rf1 "$WORK/a"
run 0 "clone rf1 to B" repo clone rf1 "$WORK/b"

make_repo 2 rf2 rforg2 rfrepo2
echo hi > "$WORK/seed2/f"; push_seed 2
run 0 "add rf2" repo add rforg2/rfrepo2/main -n rf2
run 0 "clone rf2" repo clone rf2 "$WORK/c"

# a repo with no locations at all
make_repo 3 rf3 rforg3 rfrepo3
echo hi > "$WORK/seed3/f"; push_seed 3
run 0 "add rf3 (never cloned)" repo add rforg3/rfrepo3/main -n rf3

echo "=== one repo ==="
run 0 "by key -> 0" repo folders rf1 --output-format json
check "two entries" "$( printf '%s' "$LAST_OUT" | jq -e 'length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "each entry is {id, path}" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'all(keys_unsorted == ["id","path"])' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "id is the store key" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'all(.id == "rf1")' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "paths are the clone destinations" \
    "$( printf '%s' "$LAST_OUT" | jq -e --arg a "$WORK/a" --arg b "$WORK/b" '[.[].path] == [$a,$b]' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "location order is preserved" \
    "$( printf '%s' "$LAST_OUT" | jq -e --arg a "$WORK/a" '.[0].path == $a' >/dev/null 2>&1 && echo 1 || echo 0 )"

run 0 "by full name -> 0" repo folders rforg/rfrepo/main --output-format json
check "full name gives the same answer" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'length == 2 and all(.id == "rf1")' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== --all ==="
run 0 "--all -> 0" repo folders --all --output-format json
check "four locations across three repos" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'length == 3' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "rf1 contributes two" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.[] | select(.id == "rf1")] | length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "rf2 contributes one" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.[] | select(.id == "rf2")] | length == 1' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "rf3 contributes none, and is simply absent" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.[] | select(.id == "rf3")] | length == 0' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "-a short form" repo folders -a --output-format json

echo "=== a repo with no locations is empty, not an error ==="
run 0 "rf3 -> 0" repo folders rf3 --output-format json
check "empty array" "$( printf '%s' "$LAST_OUT" | jq -e '. == []' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "rf3 plain prints nothing" repo folders rf3
check "no output at all" "$( [ -z "$LAST_OUT" ] && echo 1 || echo 0 )"

echo "=== 92: the plain form, and the parsing rule it promises ==="
run 0 "plain is the default" repo folders rf1
check "two lines" "$( [ "$(printf '%s\n' "$LAST_OUT" | wc -l)" -eq 2 ] && echo 1 || echo 0 )"
check "first line is 'id path'" \
    "$( [ "$(printf '%s' "$LAST_OUT" | head -1)" = "rf1 $WORK/a" ] && echo 1 || echo 0 )"

# The documented rule: a key cannot contain a space, a path can, so a consumer
# splits on the FIRST space. Proven with a path that really has one.
mkdir -p "$WORK/with space"
run 0 "clone into a path containing a space" repo clone rf2 "$WORK/with space/d"
run 0 "plain output with a spaced path" repo folders rf2
SPACED="$(printf '%s' "$LAST_OUT" | grep 'with space')"
check "the spaced path is on one line" "$( [ -n "$SPACED" ] && echo 1 || echo 0 )"
check "key is everything before the first space" \
    "$( [ "${SPACED%% *}" = "rf2" ] && echo 1 || echo 0 )"
check "path is everything after it, space intact" \
    "$( [ "${SPACED#* }" = "$WORK/with space/d" ] && echo 1 || echo 0 )"

echo "=== it reports the store, not the disk ==="
# The property the fan-out commands depend on: a location that no longer
# exists must still be listed, so they can report on it rather than skip it.
rm -rf "$WORK/b"
run 0 "vanished location -> 0" repo folders rf1 --output-format json
check "still two entries" "$( printf '%s' "$LAST_OUT" | jq -e 'length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "the vanished path is still listed" \
    "$( printf '%s' "$LAST_OUT" | jq -e --arg b "$WORK/b" 'any(.path == $b)' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "and no warning was emitted about it" "$( [ -z "$LAST_ERR" ] && echo 1 || echo 0 )"

echo "=== arguments ==="
run 5 "unknown key -> 5" repo folders nosuchkey
run 5 "unknown full name -> 5" repo folders noorg/norepo/main
run 2 "a path argument -> 2" repo folders "$WORK/a"
run 2 "neither argument nor --all -> 2" repo folders
check "the error asks for a key or --all" \
    "$( printf '%s' "$LAST_ERR" | grep -q -- '--all' && echo 1 || echo 0 )"
run 2 "--all with an argument -> 2" repo folders --all rf1
run 2 "two positionals -> 2" repo folders rf1 rf2
run 2 "unknown flag -> 2" repo folders --bogus rf1
run 2 "invalid --output-format -> 2" repo folders rf1 --output-format xml

echo "=== output formats ==="
run 0 "json" repo folders rf1 --output-format json
check "valid json" "$( printf '%s' "$LAST_OUT" | jq empty >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "text" repo folders rf1 --output-format text
check "text is yaml, not the plain line form" \
    "$( printf '%s' "$LAST_OUT" | grep -q '^- id: rf1$' && echo 1 || echo 0 )"
run 0 "yaml matches text" repo folders rf1 --output-format yaml
YML="$LAST_OUT"
run 0 "text again" repo folders rf1 --output-format text
check "yaml == text" "$( [ "$YML" = "$LAST_OUT" ] && echo 1 || echo 0 )"

echo "=== help and the store gate ==="
run 0 "repo folders -h" repo folders -h
check "help documents the split rule" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'FIRST space' && echo 1 || echo 0 )"
cp "$(store)" "$WORK/store.good"
echo '{"my-repo":{"name":"n","org":"o","branch":"main","locations":[]}}' > "$(store)"
run 90 "old-format store -> 90" repo folders --all
cp "$WORK/store.good" "$(store)"

gu_total
