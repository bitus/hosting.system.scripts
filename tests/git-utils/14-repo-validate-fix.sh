#!/usr/bin/env bash
# Fix 50-02 Phase 9: `repo validate --fix` -- prune, backfill, re-read images.
# Spec cases 45-49.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-rv-fix
git_global_setup
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

chk() { echo "$LAST_OUT" | jq -r ".checks.$1.status"; }

mk_repo() {   # mk_repo <dir> <origin>
    mkdir -p "$WORK/$1"
    ( cd "$WORK/$1" && git init -q && git remote add origin "$2" \
        && echo hi > f.txt && git add f.txt && git commit -qm one )
}

echo "=== 45: missing fields are backfilled, fields -> Fixed, exit 0 ==="
mk_repo w1 "https://github.com/myorg/fix.one"
run 0 "adopt fix.one -> 0" folder adopt "$WORK/w1"
store_patch 'del(.repositories["fix.one"].origin)
           | del(.repositories["fix.one"].visibility)
           | del(.repositories["fix.one"].foreign)
           | del(.repositories["fix.one"].date_created)
           | del(.repositories["fix.one"].date_updated)
           | del(.repositories["fix.one"].images)'
run 1 "without --fix it only reports -> 1" repo validate fix.one --output-format json
check "fields Failed before the repair" "$( [ "$(chk fields)" = "Failed" ] && echo 1 || echo 0 )"

run 0 "45: with --fix -> 0" repo validate fix.one --fix --output-format json
check "45: fields Fixed" "$( [ "$(chk fields)" = "Fixed" ] && echo 1 || echo 0 )"
check "45: description lists what was repaired" \
    "$( echo "$LAST_OUT" | jq -e '.checks.fields.description | test("origin") and test("visibility")' >/dev/null && echo 1 || echo 0 )"
check "45: health Ok" "$( [ "$(chk health)" = "Ok" ] && echo 1 || echo 0 )"
check "origin read from the surviving checkout" \
    "$( [ "$(rec_field fix.one origin)" = "https://github.com/myorg/fix.one" ] && echo 1 || echo 0 )"
check "visibility derived from that origin" \
    "$( [ "$(rec_field fix.one visibility)" = "public" ] && echo 1 || echo 0 )"
check "images created as []" "$( [ "$(images_of fix.one)" = "[]" ] && echo 1 || echo 0 )"
check "date_created backfilled" \
    "$( echo "$LAST_OUT" | jq -e '.date_created | test("^[0-9]{4}-")' >/dev/null && echo 1 || echo 0 )"
check "date_updated == date_created when both were missing" \
    "$( [ "$(rec_field fix.one date_created)" = "$(rec_field fix.one date_updated)" ] && echo 1 || echo 0 )"

run 0 "a second --fix has nothing to do -> 0" repo validate fix.one --fix --output-format json
check "reports Ok, not Fixed" "$( [ "$(chk fields)" = "Ok" ] && echo 1 || echo 0 )"
MT="$(stat -c '%Y' "$(store)")"
sleep 1
run 0 "third --fix run" repo validate fix.one --fix
check "a no-op --fix writes nothing" "$( [ "$(stat -c '%Y' "$(store)")" = "$MT" ] && echo 1 || echo 0 )"

echo "=== 46: dead location pruned, backfill uses a survivor ==="
mk_repo w2a "https://github.com/myorg/fix.two"
run 0 "adopt fix.two -> 0" folder adopt "$WORK/w2a"
mk_repo w2b "https://github.com/myorg/fix.two"
run 0 "adopt second checkout -> 0" folder adopt "$WORK/w2b"
check "two locations tracked" "$( [ "$(loc_count fix.two)" = "2" ] && echo 1 || echo 0 )"
# kill the FIRST location and drop origin, so the backfill must use the second
rm -rf "$WORK/w2a"
store_patch 'del(.repositories["fix.two"].origin)'
run 0 "46: --fix prunes and backfills -> 0" repo validate fix.two --fix --output-format json
check "46: dead location pruned" "$( [ "$(loc_count fix.two)" = "1" ] && echo 1 || echo 0 )"
check "46: surviving location kept" "$( [ "$(loc_path fix.two 0)" = "$WORK/w2b" ] && echo 1 || echo 0 )"
check "46: origin read from the survivor" \
    "$( [ "$(rec_field fix.two origin)" = "https://github.com/myorg/fix.two" ] && echo 1 || echo 0 )"
check "46: repair mentions locations" \
    "$( echo "$LAST_OUT" | jq -e '.checks.fields.description | test("locations")' >/dev/null && echo 1 || echo 0 )"
check "46: health Ok afterwards" "$( [ "$(chk health)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== 47: only location dead -> origin composed from the convention ==="
# `repo add` builds the realistic "record exists, was never cloned" shape.
# (Adopting a private origin needs an ssh block, which is a different test.)
run 0 "repo add fix.three -> 0" repo add myorg/fix.three/main
store_patch '.repositories["fix.three"].locations = [{"path":"/tmp/gu-rv-fix/gone-forever"}]'
run 0 "47: --fix with no surviving location -> 0" repo validate fix.three --fix --output-format json
check "47: locations emptied" "$( [ "$(loc_count fix.three)" = "0" ] && echo 1 || echo 0 )"
check "47: origin composed as git@<id>.repo:<org>/<name>.git" \
    "$( [ "$(rec_field fix.three origin)" = "git@fix.three.repo:myorg/fix.three.git" ] && echo 1 || echo 0 )"
check "47: date_created set to something valid" \
    "$( rec_field fix.three date_created | grep -q '^[0-9]\{4\}-' && echo 1 || echo 0 )"
check "47: health Warning (no locations left)" "$( [ "$(chk health)" = "Warning" ] && echo 1 || echo 0 )"
check "47: exit was still 0" "$( echo 1 )"

echo "=== 48: date_created falls back when no birth time is reported ==="
# %W is 0 on many filesystems; whatever this host does, the chain must yield a
# valid timestamp and never abort
mk_repo w4 "https://github.com/myorg/fix.four"
run 0 "adopt fix.four -> 0" folder adopt "$WORK/w4"
store_patch 'del(.repositories["fix.four"].date_created) | del(.repositories["fix.four"].date_updated)'
BIRTH="$(stat -c '%W' "$WORK/w4" 2>/dev/null || echo 0)"
echo "  (this filesystem reports birth time: ${BIRTH:-unset})"
run 0 "48: --fix -> 0" repo validate fix.four --fix --output-format json
check "48: date_created is a valid ISO-8601 UTC stamp" \
    "$( rec_field fix.four date_created | grep -q '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$' && echo 1 || echo 0 )"
check "48: never aborted -- fields report Fixed" "$( [ "$(chk fields)" = "Fixed" ] && echo 1 || echo 0 )"
# and with no location at all, it still produces a stamp
store_patch 'del(.repositories["fix.four"].date_created) | .repositories["fix.four"].locations = []'
run 0 "48: --fix with no locations -> 0" repo validate fix.four --fix
check "48: still a valid stamp" \
    "$( rec_field fix.four date_created | grep -q '^[0-9]\{4\}-' && echo 1 || echo 0 )"

echo "=== 49: backfilled foreign matches what folder adopt would set ==="
# a repo git-utils created: sentinel block present -> not foreign
run 0 "repo add managed.repo -> 0" repo add manorg/managed.repo/main
store_patch 'del(.repositories["managed.repo"].foreign) | del(.repositories["managed.repo"].visibility)'
run 0 "--fix backfills foreign" repo validate managed.repo --fix --output-format json
check "49: sentinel block present -> foreign false" \
    "$( [ "$(rec_field managed.repo foreign)" = "false" ] && echo 1 || echo 0 )"
check "49: visibility private" "$( [ "$(rec_field managed.repo visibility)" = "private" ] && echo 1 || echo 0 )"

# an adopted repo: capture what adopt set, delete it, and see whether the
# backfill independently lands on the same answer
mk_repo w6 "https://github.com/myorg/agree.repo"
run 0 "adopt agree.repo -> 0" folder adopt "$WORK/w6"
ADOPT_FOREIGN="$(rec_field agree.repo foreign)"
check "adopt marked a repo it did not create as foreign" \
    "$( [ "$ADOPT_FOREIGN" = "true" ] && echo 1 || echo 0 )"
store_patch 'del(.repositories["agree.repo"].foreign)'
run 0 "--fix re-derives it" repo validate agree.repo --fix
check "49: --fix agrees with adopt" \
    "$( [ "$(rec_field agree.repo foreign)" = "$ADOPT_FOREIGN" ] && echo 1 || echo 0 )"

echo "=== fields that cannot be inferred stay Failed after --fix ==="
store_patch 'del(.repositories["fix.four"].org)'
run 1 "missing org cannot be repaired -> 1" repo validate fix.four --fix --output-format json
check "fields Failed, not Fixed" "$( [ "$(chk fields)" = "Failed" ] && echo 1 || echo 0 )"
check "description names org" \
    "$( echo "$LAST_OUT" | jq -e '.checks.fields.description | test("org")' >/dev/null && echo 1 || echo 0 )"
check "health Failed" "$( [ "$(chk health)" = "Failed" ] && echo 1 || echo 0 )"
store_patch '.repositories["fix.four"].org = "myorg"'

echo "=== a repaired record survives a normal read ==="
run 0 "repo info on the repaired record -> 0" repo info fix.one --output-format json
check "every required field is present" \
    "$( echo "$LAST_OUT" | jq -e 'has("name") and has("org") and has("branch") and has("visibility") and has("foreign") and has("origin") and has("locations") and has("images") and has("date_created") and has("date_updated")' >/dev/null && echo 1 || echo 0 )"

echo "=== images are re-read only under --fix ==="
mk_repo w5 "https://github.com/myorg/fix.five"
printf 'nginx:1.27-alpine\n' > "$WORK/w5/.images"
( cd "$WORK/w5" && git add -A && git commit -qm images )
run 0 "adopt fix.five -> 0" folder adopt "$WORK/w5"
check "images collected at adoption" "$( [ "$(images_of fix.five)" = '["nginx:1.27-alpine"]' ] && echo 1 || echo 0 )"
printf 'nginx:1.27-alpine\nredis:7\n' > "$WORK/w5/.images"
( cd "$WORK/w5" && git add -A && git commit -qm more )
run 0 "validate without --fix -> 0" repo validate fix.five
check "images NOT re-read without --fix" "$( [ "$(images_of fix.five)" = '["nginx:1.27-alpine"]' ] && echo 1 || echo 0 )"
run 0 "validate with --fix -> 0" repo validate fix.five --fix
check "images re-read under --fix" "$( [ "$(images_of fix.five)" = '["nginx:1.27-alpine","redis:7"]' ] && echo 1 || echo 0 )"

echo "=== date_updated is stamped when other fields are repaired ==="
store_patch '.repositories["fix.five"].date_updated = "2000-01-01T00:00:00Z" | del(.repositories["fix.five"].visibility)'
run 0 "--fix repairs visibility" repo validate fix.five --fix
check "date_updated stamped forward" \
    "$( [ "$(rec_field fix.five date_updated)" != "2000-01-01T00:00:00Z" ] && echo 1 || echo 0 )"

echo "=== flags ==="
run 0 "--fix with --output-format json -> 0" repo validate fix.one --fix --output-format json
run 0 "flag order does not matter -> 0" repo validate --fix fix.one
run 2 "--fix on a path -> 2" repo validate "$WORK/w5" --fix
run 0 "help documents --fix" repo validate -h --fix
check "help mentions --fix" "$( echo "$LAST_OUT" | grep -q '\-\-fix' && echo 1 || echo 0 )"

gu_total
