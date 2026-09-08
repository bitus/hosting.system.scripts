#!/usr/bin/env bash
# Fix 50-04 Phase 7: `repo update` as a fan-out. Spec cases 39-47.
#
# The properties worth defending here are about NOT stopping: one broken
# checkout must not hide the state of the others, and a run in which nothing
# happened must not report as though something did. Both are decided by
# fanout_run, which repo redeploy will share in phase 9 -- so an aggregation
# bug found here is a bug in both commands.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-rupdate
git_global_setup

top()   { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
tcode() { printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }
locs()  { printf '%s' "$LAST_OUT" | jq -r '.locations | length' 2>/dev/null; }
loc_st(){ printf '%s' "$LAST_OUT" | jq -r --arg p "$1" '.locations[] | select(.path == $p) | .status.status' 2>/dev/null; }

echo "=== fixtures ==="
make_repo 1 ru1 ruorg rurepo
printf 'one\n' > "$WORK/seed1/f"
printf 'nginx:1.27-alpine\n' > "$WORK/seed1/.images"
push_seed 1
run 0 "add ru1" repo add ruorg/rurepo/main -n ru1
run 0 "clone to A" repo clone ru1 "$WORK/a"
run 0 "clone to B" repo clone ru1 "$WORK/b"

git clone -q "$WORK/bare1.git" "$WORK/pub"
( cd "$WORK/pub" && git config user.email t@t && git config user.name t )
publish() {
    echo "$1" >> "$WORK/pub/f"
    ( cd "$WORK/pub" && git add -A && git commit -qm "$1" && git push -q origin main )
}

echo "=== 39: every location is updated ==="
publish two
run 0 "update both -> 0" repo update ru1 --output-format json
check "top status Ok" "$( [ "$(top)" = "Ok" ] && echo 1 || echo 0 )"
check "two locations reported" "$( [ "$(locs)" = "2" ] && echo 1 || echo 0 )"
check "A updated" "$( grep -q two "$WORK/a/f" && echo 1 || echo 0 )"
check "B updated" "$( grep -q two "$WORK/b/f" && echo 1 || echo 0 )"
check "A reported Ok" "$( [ "$(loc_st "$WORK/a")" = "Ok" ] && echo 1 || echo 0 )"
check "B reported Ok" "$( [ "$(loc_st "$WORK/b")" = "Ok" ] && echo 1 || echo 0 )"
check "the summary counts them" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q '2 location' && echo 1 || echo 0 )"

echo "=== 40: all up to date -> 22, and the status passes ==="
run 22 "nothing to do -> 22" repo update ru1 --output-format json
check "top status Skipped, not Failed" "$( [ "$(top)" = "Skipped" ] && echo 1 || echo 0 )"
check "top code 22" "$( [ "$(tcode)" = "22" ] && echo 1 || echo 0 )"
check "each location reports Skipped" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.locations[].status.status] == ["Skipped","Skipped"]' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 41: one location fails, the other is still processed ==="
publish three
rm -rf "$WORK/b/.git"          # B is no longer a work tree
run 3 "one broken location -> 3" repo update ru1 --output-format json
check "top status Failed" "$( [ "$(top)" = "Failed" ] && echo 1 || echo 0 )"
check "top code 3" "$( [ "$(tcode)" = "3" ] && echo 1 || echo 0 )"
check "A was still updated -- no early abort" "$( grep -q three "$WORK/a/f" && echo 1 || echo 0 )"
check "A reported Ok" "$( [ "$(loc_st "$WORK/a")" = "Ok" ] && echo 1 || echo 0 )"
check "B reported Failed" "$( [ "$(loc_st "$WORK/b")" = "Failed" ] && echo 1 || echo 0 )"
check "B's own code travels with it (6, not 3)" \
    "$( printf '%s' "$LAST_OUT" | jq -e --arg p "$WORK/b" '.locations[] | select(.path == $p) | .status.code == 6' >/dev/null 2>&1 && echo 1 || echo 0 )"
# a failure anywhere outranks success everywhere else
check "3 wins over A's success" "$( [ "$(tcode)" = "3" ] && echo 1 || echo 0 )"
rm -rf "$WORK/b" && run 0 "re-clone B" repo clone ru1 "$WORK/b"

echo "=== a mix of updated and up-to-date is a success ==="
publish four
run 0 "update A only via a fresh B -> 0" repo update ru1
run 22 "and now both are current" repo update ru1

echo "=== 42: no locations -> 5 ==="
make_repo 2 ru2 ruorg2 rurepo2
echo one > "$WORK/seed2/f"; push_seed 2
run 0 "add ru2 (never cloned)" repo add ruorg2/rurepo2/main -n ru2
run 5 "no locations -> 5" repo update ru2 --output-format json
check "top code 5" "$( [ "$(tcode)" = "5" ] && echo 1 || echo 0 )"
check "locations is present and empty" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations == []' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 43: images are collected once, from the first updated location ==="
printf 'nginx:1.27-alpine\nredis:7-alpine\n' > "$WORK/pub/.images"
publish five
run 0 "update with a changed .images -> 0" repo update ru1
check "images were rewritten from the checkout" \
    "$( images_of ru1 | jq -e 'index("redis:7-alpine") != null' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 44: nothing to do means no image write ==="
store_patch '.repositories["ru1"].images = ["sentinel:1"]'
run 22 "no update -> 22" repo update ru1
check "images untouched when nothing updated" \
    "$( images_of ru1 | jq -e '. == ["sentinel:1"]' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 45: --dry-run reports without changing anything ==="
publish six
BEFORE_A="$(git -C "$WORK/a" rev-parse HEAD)"
store_patch '.repositories["ru1"].images = ["sentinel:2"]'
run 0 "dry run -> 0" repo update ru1 --dry-run --output-format json
check "A did not move" "$( [ "$(git -C "$WORK/a" rev-parse HEAD)" = "$BEFORE_A" ] && echo 1 || echo 0 )"
check "the summary says 'would'" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q 'would' && echo 1 || echo 0 )"
check "no image write under --dry-run" \
    "$( images_of ru1 | jq -e '. == ["sentinel:2"]' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "and the real run applies it" repo update ru1

echo "=== 46: the image write is best-effort ==="
# The store lock is made unusable, so the images step cannot run. The git work
# has already happened by then, and must not be undone or re-reported.
publish seven
printf 'nginx:1.27-alpine\nbusybox:1\n' > "$WORK/pub/.images"
publish eight
LOCK="$HOME/.repositories.json.lock"
touch "$LOCK"; chmod 000 "$LOCK"
run 0 "update with an unusable lock -> still 0" repo update ru1
check "the checkouts were still updated" "$( grep -q eight "$WORK/a/f" && echo 1 || echo 0 )"
check "it warned rather than failing" \
    "$( printf '%s' "$LAST_ERR" | grep -qi 'lock\|images' && echo 1 || echo 0 )"
chmod 600 "$LOCK"; rm -f "$LOCK"

echo "=== 47: arguments ==="
run 2 "--all is gone -> 2" repo update ru1 --all
run 2 "a path argument -> 2" repo update "$WORK/a"
run 2 "no argument -> 2" repo update
run 2 "two positionals -> 2" repo update ru1 ru2
run 5 "unknown repo -> 5" repo update nosuchkey
# Give the full-name form something to actually do, so it proves the target
# resolved AND acted -- an exit of 22 would only prove it found the record.
publish full-name-form
run 0 "by full name -> 0" repo update ruorg/rurepo/main
check "the full-name form really updated" "$( grep -q full-name-form "$WORK/a/f" && echo 1 || echo 0 )"

echo "=== output shape ==="
publish nine
run 0 "json" repo update ru1 --output-format json
check "top-level keys are status and locations" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'keys_unsorted == ["status","locations"]' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "each location is {path,status}" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations | all(keys_unsorted == ["path","status"])' >/dev/null 2>&1 && echo 1 || echo 0 )"

publish ten
run 0 "plain" repo update ru1
check "plain is one line per location" "$( [ "$(printf '%s\n' "$LAST_OUT" | wc -l)" -eq 2 ] && echo 1 || echo 0 )"
check "plain form is '<path> - <status>'" \
    "$( printf '%s' "$LAST_OUT" | head -1 | grep -q "^$WORK/a - Ok" && echo 1 || echo 0 )"
check "no git chatter on stdout" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'HEAD is now at' && echo 0 || echo 1 )"

echo "=== the record's own checks come from repo validate ==="
store_patch 'del(.repositories["ru1"].date_created)'
run 90 "a broken record fails before any location -> 90" repo update ru1 --output-format json
check "top status Failed" "$( [ "$(top)" = "Failed" ] && echo 1 || echo 0 )"
check "no locations were touched" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations == []' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "the reason names the missing field" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q 'date_created' && echo 1 || echo 0 )"

run 0 "repo update -h" repo update -h
check "help says a path is not accepted" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'folder update' && echo 1 || echo 0 )"

gu_total
