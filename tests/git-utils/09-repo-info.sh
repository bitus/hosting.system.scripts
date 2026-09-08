#!/usr/bin/env bash
# Fix 50-02 Phase 4: `repo info`. Spec cases 12-14.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-repo-info
git_global_setup

make_repo 1 inf1 infoorg inforepo
echo hi > "$WORK/seed1/f.txt"
push_seed 1
run 0 "add infoorg/inforepo/main -n inf1 -> 0" repo add infoorg/inforepo/main -n inf1
run 0 "clone inf1 -> 0" repo clone inf1 "$WORK/tracked"

echo "=== 12: every target form yields the same record, id first ==="
run 0 "by key -> 0" repo info inf1 --output-format json
BY_KEY="$LAST_OUT"
check "id is the first field" "$( [ "$(echo "$BY_KEY" | jq -r 'keys_unsorted[0]')" = "id" ] && echo 1 || echo 0 )"
check "id has the right value" "$( echo "$BY_KEY" | jq -e '.id == "inf1"' >/dev/null && echo 1 || echo 0 )"

run 0 "by full name -> 0" repo info infoorg/inforepo/main --output-format json
check "full-name form matches by-key" "$( [ "$LAST_OUT" = "$BY_KEY" ] && echo 1 || echo 0 )"

# Fix 50-04 dropped path targets from repo commands. These three forms were
# path, cwd and '.'; each is now an argument error, and each is followed by
# the same lookup through `folder repo`. Keeping both halves is the point:
# the capability moved, it was not lost.
run 2 "by path -> 2" repo info "$WORK/tracked" --output-format json
check "the error names the bridge" "$( printf '%s' "$LAST_ERR" | grep -q 'folder repo' && echo 1 || echo 0 )"
run 2 "explicit . -> 2" repo info . --output-format json

out="$(cd "$WORK/tracked" && bash "$GU" repo info --output-format json </dev/null 2>"$WORK/err.log")"; code=$?
check "no argument is now an error -> 2" "$( [ "$code" -eq 2 ] && echo 1 || echo 0 )"

ID="$(cd "$WORK/tracked" && bash "$GU" folder repo </dev/null 2>/dev/null)"
run 0 "bridged from a path -> 0" repo info "$ID" --output-format json
check "bridged form matches by-key" "$( [ "$LAST_OUT" = "$BY_KEY" ] && echo 1 || echo 0 )"
out="$(cd "$WORK/tracked" && bash "$GU" repo info "$(bash "$GU" folder repo)" --output-format json </dev/null 2>/dev/null)"
check "bridged from cwd matches by-key" "$( [ "$out" = "$BY_KEY" ] && echo 1 || echo 0 )"

echo "=== record content is the stored record ==="
check "name" "$( echo "$BY_KEY" | jq -e '.name == "inforepo"' >/dev/null && echo 1 || echo 0 )"
check "org" "$( echo "$BY_KEY" | jq -e '.org == "infoorg"' >/dev/null && echo 1 || echo 0 )"
check "branch" "$( echo "$BY_KEY" | jq -e '.branch == "main"' >/dev/null && echo 1 || echo 0 )"
check "locations carried through" \
    "$( echo "$BY_KEY" | jq -e --arg p "$WORK/tracked" '.locations[0].path == $p' >/dev/null && echo 1 || echo 0 )"
check "images carried through" "$( echo "$BY_KEY" | jq -e '.images | type == "array"' >/dev/null && echo 1 || echo 0 )"
check "no checks object (that is repo validate's job)" \
    "$( echo "$BY_KEY" | jq -e 'has("checks")' >/dev/null 2>&1 && echo 0 || echo 1 )"

echo "=== 13: untracked targets -> 5 ==="
run 5 "unknown key -> 5" repo info nosuchkey
run 5 "unknown full name -> 5" repo info someorg/somerepo/main
mkdir -p "$WORK/untracked"
( cd "$WORK/untracked" && git init -q )
# These were path lookups that reported 5 for 'no record claims this'.
# repo info no longer takes a path at all, so the argument is rejected (2)
# and `folder repo` is what answers 'which repo?' with 5.
run 2 "untracked git folder is an argument error -> 2" repo info "$WORK/untracked"
run 2 "nonexistent path is an argument error -> 2" repo info "$WORK/no-such-folder"
run 5 "folder repo reports the untracked folder -> 5" folder repo "$WORK/untracked"
run 5 "folder repo on a missing path -> 5" folder repo "$WORK/no-such-folder"
out="$(cd "$WORK/untracked" && bash "$GU" folder repo </dev/null 2>/dev/null)"; code=$?
check "folder repo from an untracked cwd -> 5" "$( [ "$code" -eq 5 ] && echo 1 || echo 0 )"

echo "=== 14: json vs default rendering ==="
run 0 "default (text) -> 0" repo info inf1
TXT="$LAST_OUT"
check "default output is YAML, id first" "$( [ "$(echo "$TXT" | head -1)" = "id: inf1" ] && echo 1 || echo 0 )"
check "default output is not JSON" "$( echo "$TXT" | grep -q '^{' && echo 0 || echo 1 )"
run 0 "--output-format yaml -> 0" repo info inf1 --output-format yaml
check "yaml == text" "$( [ "$LAST_OUT" = "$TXT" ] && echo 1 || echo 0 )"
run 0 "--output-format json -> 0" repo info inf1 --output-format json
check "json is pretty-printed" "$( [ "$(echo "$LAST_OUT" | wc -l)" -gt 1 ] && echo 1 || echo 0 )"
check "json and yaml carry the same data" \
    "$( [ "$(printf '%s' "$TXT" | yq -c -S . 2>/dev/null)" = "$(printf '%s' "$LAST_OUT" | jq -c -S .)" ] && echo 1 || echo 0 )"

echo "=== a record with no status objects folds to a no-op ==="
check "no 'code:' in default output" "$( echo "$TXT" | grep -q 'code:' && echo 0 || echo 1 )"
check "locations array intact in YAML" "$( echo "$TXT" | grep -q -- '- path: ' && echo 1 || echo 0 )"

echo "=== argument and flag handling ==="
run 2 "two positionals -> 2" repo info inf1 inf1
run 2 "unknown flag -> 2" repo info inf1 --bogus
run 2 "invalid --output-format -> 2" repo info inf1 --output-format xml
run 0 "--output-format=json equals form -> 0" repo info inf1 --output-format=json
check "equals form parsed" "$( echo "$LAST_OUT" | jq -e '.id == "inf1"' >/dev/null && echo 1 || echo 0 )"
run 0 "repo info -h -> 0" repo info -h
check "help mentions the command" "$( echo "$LAST_OUT" | grep -q 'git-utils repo info' && echo 1 || echo 0 )"
run 0 "repos info alias works -> 0" repos info inf1 --output-format json
check "alias returns the record" "$( echo "$LAST_OUT" | jq -e '.id == "inf1"' >/dev/null && echo 1 || echo 0 )"
run 0 "main help lists repo info" -h
check "main help mentions repo info" "$( echo "$LAST_OUT" | grep -q 'git-utils repo info' && echo 1 || echo 0 )"

echo "=== store-format gate still applies ==="
cp "$(store)" "$WORK/store.good"
echo '{"my-repo":{"name":"n","org":"o","branch":"main","locations":[]}}' > "$(store)"
run 90 "old-format store -> 90" repo info inf1
cp "$WORK/store.good" "$(store)"

gu_total
