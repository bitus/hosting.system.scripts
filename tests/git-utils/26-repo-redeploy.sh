#!/usr/bin/env bash
# Fix 50-04 Phase 9: `repo redeploy`. Spec cases 58-64.
#
# Needs a real docker daemon.
#
# The whole point of this command is its tolerance rule. A repo that mixes a
# compose deployment with an ordinary checkout must not report failure for the
# ordinary one -- 14 and 16 are "nothing to do here", not faults. But a repo
# where EVERY location was skipped must not report success either, or "nothing
# is deployable" and "everything was deployed" become the same answer.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-rredeploy
git_global_setup

top()   { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
tcode() { printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }
loc_st(){ printf '%s' "$LAST_OUT" | jq -r --arg p "$1" '.locations[] | select(.path == $p) | .status.status' 2>/dev/null; }
loc_cd(){ printf '%s' "$LAST_OUT" | jq -r --arg p "$1" '.locations[] | select(.path == $p) | .status.code' 2>/dev/null; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "the whole repo redeploy suite" "no docker daemon"
    gu_total
    exit $?
fi

IMG=alpine:3.20
docker pull -q "$IMG" >/dev/null 2>&1 || true

compose_into() {   # compose_into <dir>
    cat > "$1/compose.yml" <<YML
services:
  a:
    image: $IMG
    command: sleep 600
YML
}
up()   { ( cd "$1" && docker compose up -d --quiet-pull >/dev/null 2>&1 ) || true; }
down() { ( cd "$1" && docker compose down --remove-orphans >/dev/null 2>&1 ) || true; }
running() { [ -n "$(cd "$1" && docker compose ps --status running -q 2>/dev/null)" ]; }

echo "=== fixtures: one repo, two locations, both compose projects ==="
make_repo 1 rr1 rrorg rrrepo
compose_into "$WORK/seed1"
push_seed 1
run 0 "add rr1" repo add rrorg/rrrepo/main -n rr1
run 0 "clone to A" repo clone rr1 "$WORK/a"
run 0 "clone to B" repo clone rr1 "$WORK/b"
up "$WORK/a"; up "$WORK/b"

echo "=== 58: every running location is redeployed ==="
run 0 "redeploy both -> 0" repo redeploy rr1 --output-format json
check "top status Ok" "$( [ "$(top)" = "Ok" ] && echo 1 || echo 0 )"
check "two locations reported" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations | length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "A Ok" "$( [ "$(loc_st "$WORK/a")" = "Ok" ] && echo 1 || echo 0 )"
check "B Ok" "$( [ "$(loc_st "$WORK/b")" = "Ok" ] && echo 1 || echo 0 )"
check "both still up" "$( running "$WORK/a" && running "$WORK/b" && echo 1 || echo 0 )"
check "the summary counts them" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q '2 location' && echo 1 || echo 0 )"

echo "=== 59: a mixed repo -- one compose, one plain checkout ==="
# B stops being a compose project. That is not a fault: the run must succeed
# on A's strength and merely SKIP B.
down "$WORK/b"
rm -f "$WORK/b/compose.yml"
run 0 "mixed repo -> 0, not 3" repo redeploy rr1 --output-format json
check "top status Ok" "$( [ "$(top)" = "Ok" ] && echo 1 || echo 0 )"
check "A Ok" "$( [ "$(loc_st "$WORK/a")" = "Ok" ] && echo 1 || echo 0 )"
check "B Skipped, not Failed" "$( [ "$(loc_st "$WORK/b")" = "Skipped" ] && echo 1 || echo 0 )"
check "B carries 14, its own reason" "$( [ "$(loc_cd "$WORK/b")" = "14" ] && echo 1 || echo 0 )"

echo "=== 60: a stopped location is skipped, not started ==="
compose_into "$WORK/b"          # a compose project again, but never started
run 0 "one running, one stopped -> 0" repo redeploy rr1 --output-format json
check "B Skipped with 16" \
    "$( [ "$(loc_st "$WORK/b")" = "Skipped" ] && [ "$(loc_cd "$WORK/b")" = "16" ] && echo 1 || echo 0 )"
check "B was NOT started" "$( running "$WORK/b" && echo 0 || echo 1 )"

echo "=== 61: EVERY location skipped must not report success ==="
down "$WORK/a"
run 16 "all stopped -> 16, not 0" repo redeploy rr1 --output-format json
check "top status Skipped" "$( [ "$(top)" = "Skipped" ] && echo 1 || echo 0 )"
check "top code is the first skip's own code" "$( [ "$(tcode)" = "16" ] && echo 1 || echo 0 )"
check "the reason explains why nothing happened" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -qi 'running' && echo 1 || echo 0 )"

rm -f "$WORK/a/compose.yml" "$WORK/b/compose.yml"
run 14 "no location is a compose project -> 14" repo redeploy rr1 --output-format json
check "top code 14" "$( [ "$(tcode)" = "14" ] && echo 1 || echo 0 )"
check "the reason names the compose project" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -qi 'compose' && echo 1 || echo 0 )"

echo "=== 62: a real failure outranks any number of skips ==="
compose_into "$WORK/a"; up "$WORK/a"
# B becomes a location that does not exist at all -- a genuine failure
rm -rf "$WORK/b"
run 3 "one failure among skips -> 3" repo redeploy rr1 --output-format json
check "top status Failed" "$( [ "$(top)" = "Failed" ] && echo 1 || echo 0 )"
check "top code 3" "$( [ "$(tcode)" = "3" ] && echo 1 || echo 0 )"
check "A was still redeployed -- no early abort" \
    "$( [ "$(loc_st "$WORK/a")" = "Ok" ] && echo 1 || echo 0 )"
check "B Failed with its own 5" \
    "$( [ "$(loc_st "$WORK/b")" = "Failed" ] && [ "$(loc_cd "$WORK/b")" = "5" ] && echo 1 || echo 0 )"
run 0 "re-clone B" repo clone rr1 "$WORK/b"
compose_into "$WORK/b"; up "$WORK/b"

echo "=== 63: no locations -> 5 ==="
make_repo 2 rr2 rrorg2 rrrepo2
compose_into "$WORK/seed2"
push_seed 2
run 0 "add rr2 (never cloned)" repo add rrorg2/rrrepo2/main -n rr2
run 5 "no locations -> 5" repo redeploy rr2 --output-format json
check "locations present and empty" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations == []' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 64: --dry-run, and the per-folder pull timeout ==="
run 0 "dry run -> 0" repo redeploy rr1 --dry-run --output-format json
check "it says 'would'" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q 'would' && echo 1 || echo 0 )"
check "both still up" "$( running "$WORK/a" && running "$WORK/b" && echo 1 || echo 0 )"
run 2 "-i --dry-run -> 2" repo redeploy rr1 -i --dry-run
run 2 "non-numeric --pull-timeout -> 2" repo redeploy rr1 -t abc
run 0 "-i with a real timeout -> 0" repo redeploy rr1 -i -t 300

echo "=== the record's own defects do not block a redeploy ==="
# repo update refuses on a broken record; redeploy touches containers, not git
# or keys, so it must not.
store_patch 'del(.repositories["rr1"].date_created)'
run 0 "a record missing a field still redeploys -> 0" repo redeploy rr1
run 90 "while repo update refuses it -> 90" repo update rr1
store_patch '.repositories["rr1"].date_created = "2026-01-01T00:00:00Z"'

echo "=== arguments and output shape ==="
run 2 "a path argument -> 2" repo redeploy "$WORK/a"
run 2 "no argument -> 2" repo redeploy
run 5 "unknown repo -> 5" repo redeploy nosuchkey
run 0 "by full name -> 0" repo redeploy rrorg/rrrepo/main
run 2 "two positionals -> 2" repo redeploy rr1 rr2

run 0 "json shape" repo redeploy rr1 --output-format json
check "top-level keys are status and locations" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'keys_unsorted == ["status","locations"]' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "same shape as repo update" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations | all(keys_unsorted == ["path","status"])' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "plain" repo redeploy rr1
check "plain is '<path> - <status>'" \
    "$( printf '%s' "$LAST_OUT" | head -1 | grep -q "^$WORK/a - Ok" && echo 1 || echo 0 )"
check "no compose chatter on stdout" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'network\|container' && echo 0 || echo 1 )"

run 0 "repo redeploy -h" repo redeploy -h
check "help explains the skip rule" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'SKIPPED, not failed' && echo 1 || echo 0 )"
check "help says the timeout is per folder" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'PER folder' && echo 1 || echo 0 )"

down "$WORK/a"; down "$WORK/b"
gu_total
