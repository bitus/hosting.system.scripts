#!/usr/bin/env bash
# Fix 50-04 Phase 8: `folder redeploy`. Spec cases 48-57.
#
# Needs a real docker daemon, like suites 04, 05 and 19.
#
# Two things are asserted harder than the rest. First, check ORDER: "is this a
# compose project" is a filesystem test and must precede the docker probe, so
# a plain folder on a host with no docker still answers 14 rather than
# complaining about docker. Second, a STOPPED stack is never started -- 16
# means "nothing to refresh", and the command must leave it stopped.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-fredeploy
git_global_setup

st()   { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
tcode(){ printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }
desc() { printf '%s' "$LAST_OUT" | jq -r '.status.description' 2>/dev/null; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "the whole folder redeploy suite" "no docker daemon"
    gu_total
    exit $?
fi

IMG=alpine:3.20
docker pull -q "$IMG" >/dev/null 2>&1 || true

mk_project() {   # mk_project <dir>
    mkdir -p "$WORK/$1"
    cat > "$WORK/$1/compose.yml" <<YML
services:
  a:
    image: $IMG
    command: sleep 600
YML
}
down() { ( cd "$WORK/$1" && docker compose down --remove-orphans >/dev/null 2>&1 ) || true; }

echo "=== 48: a running project is redeployed ==="
mk_project up1
( cd "$WORK/up1" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
CID_BEFORE="$(cd "$WORK/up1" && docker compose ps -q a)"
run 0 "redeploy a running project -> 0" folder redeploy --output-format json "$WORK/up1"
check "status Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"
check "it says redeployed" "$( desc | grep -qi 'redeploy' && echo 1 || echo 0 )"
check "the project is still up afterwards" \
    "$( [ -n "$(cd "$WORK/up1" && docker compose ps --status running -q)" ] && echo 1 || echo 0 )"
check "no compose chatter on stdout" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'container\|network' && echo 0 || echo 1 )"
CID_AFTER="$(cd "$WORK/up1" && docker compose ps -q a)"
check "the container id is unchanged for an unchanged config" \
    "$( [ "$CID_BEFORE" = "$CID_AFTER" ] && echo 1 || echo 0 )"

echo "=== 49: not a compose project -> 14, without asking about docker ==="
mkdir -p "$WORK/plain"
run 14 "plain folder -> 14" folder redeploy --output-format json "$WORK/plain"
check "status Skipped, not Failed" "$( [ "$(st)" = "Skipped" ] && echo 1 || echo 0 )"
check "code 14" "$( [ "$(tcode)" = "14" ] && echo 1 || echo 0 )"
# The order claim: with docker made unreachable, a plain folder must STILL
# answer 14. If the docker probe came first this would be 1.
out="$(cd "$WORK" && DOCKER_HOST=unix:///nonexistent.sock bash "$GU" folder redeploy "$WORK/plain" </dev/null 2>/dev/null)"
code=$?
check "still 14 with docker unreachable -- the compose test comes first" \
    "$( [ "$code" -eq 14 ] && echo 1 || echo 0 )"

echo "=== 50: a stopped project -> 16, and stays stopped ==="
mk_project down1
( cd "$WORK/down1" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
down down1
run 16 "stopped project -> 16" folder redeploy --output-format json "$WORK/down1"
check "status Skipped" "$( [ "$(st)" = "Skipped" ] && echo 1 || echo 0 )"
check "it was NOT started" \
    "$( [ -z "$(cd "$WORK/down1" && docker compose ps --status running -q)" ] && echo 1 || echo 0 )"

echo "=== 51: missing folder -> 5 ==="
run 5 "missing folder -> 5" folder redeploy --output-format json "$WORK/nosuch"
check "status Failed" "$( [ "$(st)" = "Failed" ] && echo 1 || echo 0 )"

echo "=== 52: docker unreachable on a real compose project -> 1 ==="
out="$(cd "$WORK" && DOCKER_HOST=unix:///nonexistent.sock bash "$GU" folder redeploy --output-format json "$WORK/up1" </dev/null 2>/dev/null)"
code=$?
check "daemon unreachable -> 1" "$( [ "$code" -eq 1 ] && echo 1 || echo 0 )"
check "and it is reported as a failure, not a skip" \
    "$( printf '%s' "$out" | jq -e '.status.status == "Failed"' >/dev/null 2>&1 && echo 1 || echo 0 )"
# The distinction compose_running's third code exists for: an unreachable
# daemon must not read as "the stack is stopped".
check "the reason names the daemon, not a stopped stack" \
    "$( printf '%s' "$out" | jq -r '.status.description' | grep -qi 'daemon' && echo 1 || echo 0 )"

echo "=== 53: --dry-run runs every check and executes nothing ==="
mk_project dry1
( cd "$WORK/dry1" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
CID_BEFORE="$(cd "$WORK/dry1" && docker compose ps -q a)"
run 0 "dry run on a running project -> 0" folder redeploy --dry-run --output-format json "$WORK/dry1"
check "status Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"
check "it says 'would'" "$( desc | grep -qi 'would' && echo 1 || echo 0 )"
check "the container was not touched" \
    "$( [ "$(cd "$WORK/dry1" && docker compose ps -q a)" = "$CID_BEFORE" ] && echo 1 || echo 0 )"
run 16 "dry run still reports a stopped project as 16" folder redeploy --dry-run "$WORK/down1"
run 14 "dry run still reports a plain folder as 14" folder redeploy --dry-run "$WORK/plain"

echo "=== 54: -i with --dry-run is refused ==="
run 2 "-i --dry-run -> 2" folder redeploy -i --dry-run "$WORK/dry1"
check "the reason says why" \
    "$( printf '%s' "$LAST_ERR" | grep -q -- '--pull-images cannot be combined' && echo 1 || echo 0 )"
run 2 "--pull-images --dry-run long form -> 2" folder redeploy --pull-images --dry-run "$WORK/dry1"

echo "=== 55: --pull-images pulls, and its timeout is validated ==="
run 0 "-i on a running project -> 0" folder redeploy -i --output-format json "$WORK/up1"
check "still Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"
run 2 "--pull-timeout with no value -> 2" folder redeploy --pull-timeout
run 2 "non-numeric --pull-timeout -> 2" folder redeploy -t abc "$WORK/up1"
run 2 "zero --pull-timeout -> 2" folder redeploy -t 0 "$WORK/up1"
run 2 "negative --pull-timeout -> 2" folder redeploy -t -5 "$WORK/up1"
run 0 "--pull-timeout=<n> form" folder redeploy -i --pull-timeout=300 "$WORK/up1"

echo "=== 56: a pull that exceeds the timeout is 18, not 10 ==="
# 1 second is not enough to pull a fresh image, so the timeout fires. The
# image is removed first, or an already-present one would make the pull
# instant and the case unreachable.
mk_project slow1
cat > "$WORK/slow1/compose.yml" <<'YML'
services:
  a:
    image: public.ecr.aws/docker/library/busybox:1.36
    command: sleep 600
YML
( cd "$WORK/slow1" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
if [ -n "$(cd "$WORK/slow1" && docker compose ps --status running -q)" ]; then
    docker rmi -f public.ecr.aws/docker/library/busybox:1.36 >/dev/null 2>&1 || true
    run 18 "pull exceeding --pull-timeout -> 18" folder redeploy -i -t 1 --output-format json "$WORK/slow1"
    check "status Failed" "$( [ "$(st)" = "Failed" ] && echo 1 || echo 0 )"
    check "the reason says it timed out" "$( desc | grep -qi 'timed out' && echo 1 || echo 0 )"
    check "18, not the generic command failure 10" "$( [ "$(tcode)" = "18" ] && echo 1 || echo 0 )"
else
    skip "pull timeout maps to 18" "could not start the busybox fixture"
fi
down slow1

echo "=== 57: a compose failure is 10 ==="
# The failure has to happen at BUILD time. An unparseable compose file is
# caught earlier -- compose_running cannot answer, so it is 1 -- which is
# correct but tests a different path. A valid file with a broken Dockerfile
# starts fine and then fails the rebuild, which is the 10 mapping.
mkdir -p "$WORK/bad1"
cat > "$WORK/bad1/compose.yml" <<'YML'
services:
  a:
    build: .
    command: sleep 600
YML
printf 'FROM alpine:3.20
RUN true
' > "$WORK/bad1/Dockerfile"
( cd "$WORK/bad1" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
if [ -n "$(cd "$WORK/bad1" && docker compose ps --status running -q)" ]; then
    printf 'FROM alpine:3.20
RUN exit 3
' > "$WORK/bad1/Dockerfile"
    run 10 "a build failure at redeploy time -> 10" folder redeploy --output-format json "$WORK/bad1"
    check "status Failed" "$( [ "$(st)" = "Failed" ] && echo 1 || echo 0 )"
    check "the reason names the compose step" \
        "$( desc | grep -qi 'compose' && echo 1 || echo 0 )"
else
    skip "a build failure maps to 10" "could not start the build fixture"
fi

echo "=== an unparseable compose file cannot be assessed -> 1 ==="
mkdir -p "$WORK/unparseable"
printf 'services:
  a:
   bad indent: [
' > "$WORK/unparseable/compose.yml"
run 1 "unparseable compose file -> 1" folder redeploy --output-format json "$WORK/unparseable"
check "the reason says it could not be determined" \
    "$( desc | grep -qi 'determine' && echo 1 || echo 0 )"

echo "=== arguments, cwd and help ==="
out="$(cd "$WORK/up1" && bash "$GU" folder redeploy </dev/null 2>/dev/null)"; code=$?
check "no argument uses cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
run 2 "two positionals -> 2" folder redeploy "$WORK/up1" "$WORK/dry1"
run 2 "unknown flag -> 2" folder redeploy --bogus
run 0 "folder redeploy -h" folder redeploy -h
check "help says a stopped stack is not started" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'never started' && echo 1 || echo 0 )"
check "help says only the pull is bounded" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'unbounded' && echo 1 || echo 0 )"
check "help mentions profiles are not handled" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'profile' && echo 1 || echo 0 )"

down up1; down dry1; down down1; down bad1
gu_total
