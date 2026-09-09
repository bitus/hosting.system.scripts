#!/usr/bin/env bash
# Fix 50-04 Phase 2: the deadline and docker layers.
#
# No command uses either yet, so both are driven directly. The docker half
# needs a working daemon, the same requirement suites 04 and 05 already have.
#
# The load-bearing test in this file is the digest pair: image_remote_digest
# must equal image_repo_digest for an image that is up to date. The obvious
# implementation (per-platform selection out of `docker manifest inspect`)
# returns a different digest for every multi-arch image and would report
# "update available" forever.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-deadline

# ev <snippet> -- run in the script's environment, echo the exit code
ev_code() { gu_eval "$1" >/dev/null 2>&1; echo $?; }

echo "=== deadline: unbounded by default ==="
check "DEADLINE starts at 0" \
    "$( [ "$(gu_eval 'printf "%s" "$DEADLINE"')" = "0" ] && echo 1 || echo 0 )"
check "remaining prints '-' when unbounded" \
    "$( [ "$(gu_eval 'deadline_remaining')" = "-" ] && echo 1 || echo 0 )"
check "remaining returns 0 when unbounded" \
    "$( [ "$(ev_code 'deadline_remaining')" = "0" ] && echo 1 || echo 0 )"

echo "=== deadline: set, spend, clear ==="
OUT="$(gu_eval 'deadline_set 30; deadline_remaining')"
check "remaining is a number after deadline_set" \
    "$( [ "$OUT" -ge 29 ] 2>/dev/null && [ "$OUT" -le 30 ] && echo 1 || echo 0 )"
check "spent budget returns 1" \
    "$( [ "$(ev_code 'deadline_set 30; DEADLINE=1; deadline_remaining')" = "1" ] && echo 1 || echo 0 )"
check "spent budget prints nothing" \
    "$( [ -z "$(gu_eval 'DEADLINE=1; deadline_remaining' 2>/dev/null || true)" ] && echo 1 || echo 0 )"
# deadline_set 0 means "no time at all", which must NOT read as "unbounded"
check "deadline_set 0 is spent, not unbounded" \
    "$( [ "$(ev_code 'deadline_set 0; deadline_remaining')" = "1" ] && echo 1 || echo 0 )"
check "deadline_clear restores unbounded" \
    "$( [ "$(gu_eval 'deadline_set 30; deadline_clear; deadline_remaining')" = "-" ] && echo 1 || echo 0 )"

echo "=== run_bounded: transparent when unbounded ==="
check "runs the command" \
    "$( [ "$(gu_eval 'run_bounded printf hello')" = "hello" ] && echo 1 || echo 0 )"
check "passes the command's exit code through" \
    "$( [ "$(ev_code 'run_bounded false')" = "1" ] && echo 1 || echo 0 )"
check "passes a non-1 exit code through" \
    "$( [ "$(ev_code 'run_bounded bash -c "exit 7"')" = "7" ] && echo 1 || echo 0 )"

echo "=== run_bounded: enforces the deadline ==="
check "a slow command is killed with TIMEOUT_EXIT" \
    "$( [ "$(ev_code 'deadline_set 1; run_bounded sleep 5')" = "124" ] && echo 1 || echo 0 )"
check "a fast command still succeeds under a deadline" \
    "$( [ "$(ev_code 'deadline_set 30; run_bounded true')" = "0" ] && echo 1 || echo 0 )"
check "stdout survives a bounded run" \
    "$( [ "$(gu_eval 'deadline_set 30; run_bounded printf hello')" = "hello" ] && echo 1 || echo 0 )"

echo "=== run_bounded: a spent budget does not run the command ==="
# The distinction that matters: 124 must mean "did not complete", whether the
# call was killed or never started. Proven by a command with a side effect.
rm -f "$WORK/sideeffect"
CODE="$(ev_code "DEADLINE=1; run_bounded touch '$WORK/sideeffect'")"
check "spent budget returns 124" "$( [ "$CODE" = "124" ] && echo 1 || echo 0 )"
check "spent budget ran nothing" "$( [ ! -e "$WORK/sideeffect" ] && echo 1 || echo 0 )"

echo "=== docker probes ==="
if ! command -v docker >/dev/null 2>&1; then
    skip "the whole docker layer" "docker not installed"
    gu_total
    exit $?
fi

check "docker_available" "$( [ "$(ev_code 'docker_available')" = "0" ] && echo 1 || echo 0 )"
check "compose_available" "$( [ "$(ev_code 'compose_available')" = "0" ] && echo 1 || echo 0 )"
check "buildx_available" "$( [ "$(ev_code 'buildx_available')" = "0" ] && echo 1 || echo 0 )"
check "docker_daemon_ok" "$( [ "$(ev_code 'docker_daemon_ok')" = "0" ] && echo 1 || echo 0 )"

# A plugin probe must not need the daemon. Proven by pointing DOCKER_HOST at
# nothing: `compose version` still answers, `docker info` does not.
check "compose_available does not touch the daemon" \
    "$( [ "$(ev_code 'export DOCKER_HOST=unix:///nonexistent.sock; compose_available')" = "0" ] && echo 1 || echo 0 )"
check "docker_daemon_ok does touch the daemon" \
    "$( [ "$(ev_code 'export DOCKER_HOST=unix:///nonexistent.sock; docker_daemon_ok')" != "0" ] && echo 1 || echo 0 )"

echo "=== compose project fixtures ==="
PROJ="$WORK/proj"
mkdir -p "$PROJ"
cat > "$PROJ/compose.yml" <<'YML'
services:
  a:
    image: alpine:3.20
    command: sleep 300
YML
NOTPROJ="$WORK/notproj"; mkdir -p "$NOTPROJ"

docker pull -q alpine:3.20 >/dev/null 2>&1
( cd "$PROJ" && docker compose up -d --quiet-pull >/dev/null 2>&1 )

check "compose_running -> 0 while up" \
    "$( [ "$(ev_code "compose_running '$PROJ'")" = "0" ] && echo 1 || echo 0 )"

PSJSON="$(gu_eval "compose_ps_json '$PROJ'")"
check "compose_ps_json returns an array (JSON Lines slurped)" \
    "$( printf '%s' "$PSJSON" | jq -e 'type == "array" and length >= 1' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "compose_ps_json carries the image reference" \
    "$( printf '%s' "$PSJSON" | jq -e '.[0].Image == "alpine:3.20"' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== image IDs: the restart_pending pair ==="
CID="$(cd "$PROJ" && docker compose ps -q a)"
LOCAL_ID="$(gu_eval "image_id_local alpine:3.20")"
RUN_ID="$(gu_eval "container_image_id '$CID'")"
check "image_id_local looks like an id" \
    "$( echo "$LOCAL_ID" | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
check "container_image_id looks like an id" \
    "$( echo "$RUN_ID" | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
check "a freshly started container matches its image (restart_pending false)" \
    "$( [ "$LOCAL_ID" = "$RUN_ID" ] && echo 1 || echo 0 )"

echo "=== image_ref_repo: tag stripped, registry port kept ==="
for pair in \
    "alpine:3.20|alpine" \
    "alpine|alpine" \
    "public.ecr.aws/docker/library/alpine:3.20|public.ecr.aws/docker/library/alpine" \
    "localhost:5000/foo:1|localhost:5000/foo" \
    "localhost:5000/foo|localhost:5000/foo" \
    "alpine@sha256:abc|alpine"
do
    REF="${pair%%|*}"; WANT="${pair##*|}"
    GOT="$(gu_eval "image_ref_repo '$REF'")"
    check "image_ref_repo $REF -> $WANT" "$( [ "$GOT" = "$WANT" ] && echo 1 || echo 0 )"
done

echo "=== repo digests: the pull_available pair ==="
# Fixture is ECR Public rather than Docker Hub: it is a second registry, and
# it does not share Hub's anonymous per-IP quota. A 429 from either is not
# evidence about this code, so it skips rather than failing.
ECR_REF=public.ecr.aws/docker/library/alpine:3.20
docker pull -q "$ECR_REF" >/dev/null 2>&1
REG_ERR="$(docker buildx imagetools inspect "$ECR_REF" 2>&1 >/dev/null || true)"
if printf '%s' "$REG_ERR" | grep -qiE '429|toomanyrequests|rate limit'; then
    skip "registry digest assertions" "registry rate limit"
elif [ -n "$REG_ERR" ]; then
    skip "registry digest assertions" "registry unreachable"
else
    REPO_D="$(gu_eval "image_repo_digest '$ECR_REF'")"
    REMOTE_D="$(gu_eval "image_remote_digest '$ECR_REF'")"
    check "image_repo_digest strips the name@ prefix" \
        "$( echo "$REPO_D" | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
    check "image_remote_digest yields a bare digest" \
        "$( echo "$REMOTE_D" | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
    # THE regression guard for the whole digest design.
    check "multi-arch: remote digest == local repo digest when up to date" \
        "$( [ "$REPO_D" = "$REMOTE_D" ] && echo 1 || echo 0 )"

    # This image carries TWO RepoDigests -- one for the mirror, one for the
    # upstream name. Taking .[0] was the bug; the entry has to be chosen by
    # repository. Only meaningful while the fixture really does have both.
    NDIGESTS="$(docker image inspect "$ECR_REF" --format '{{json .RepoDigests}}' | jq 'length')"
    if [ "${NDIGESTS:-0}" -ge 2 ]; then
        check "image_repo_digest picks the entry matching the ref, not .[0]" \
            "$( docker image inspect "$ECR_REF" --format '{{json .RepoDigests}}' \
                 | jq -e --arg d "$REPO_D" \
                   '[.[] | select(startswith("public.ecr.aws/"))][0] == ("public.ecr.aws/docker/library/alpine@" + $d)' \
                 >/dev/null 2>&1 && echo 1 || echo 0 )"
    else
        skip "image_repo_digest picks the matching entry" "fixture has one RepoDigest"
    fi

    # The control: the recipe this replaced returns a DIFFERENT digest for the
    # same up-to-date image. If it ever stops differing, the guard above has
    # gone vacuous.
    PLAT_D="$(docker manifest inspect "$ECR_REF" 2>/dev/null | jq -r '.manifests[]? | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest')"
    if [ -z "$PLAT_D" ]; then
        skip "control: per-platform digest differs" "manifest inspect returned nothing"
    else
        check "control: per-platform digest differs from the index digest" \
            "$( [ "$PLAT_D" != "$REPO_D" ] && echo 1 || echo 0 )"
    fi
fi

echo "=== an unreachable registry must not yield a digest ==="
# The trap this guards: `imagetools inspect --raw | sha256sum` hashes whatever
# came back -- error text, or nothing -- into a well-formed digest that can
# never match. e3b0c442... is the hash of zero bytes.
BAD="$(gu_eval "image_remote_digest 'localhost:1/nope:latest'" 2>/dev/null || true)"
check "unreachable registry returns no digest" "$( [ -z "$BAD" ] && echo 1 || echo 0 )"
check "unreachable registry returns non-zero" \
    "$( [ "$(ev_code "image_remote_digest 'localhost:1/nope:latest'")" != "0" ] && echo 1 || echo 0 )"
check "and never the empty-input hash" \
    "$( [ "$BAD" != "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ] && echo 1 || echo 0 )"

echo "=== compose_running distinguishes stopped from undeterminable ==="
( cd "$PROJ" && docker compose down >/dev/null 2>&1 )
check "stopped project -> 1" \
    "$( [ "$(ev_code "compose_running '$PROJ'")" = "1" ] && echo 1 || echo 0 )"
check "daemon unreachable -> 2, not 1" \
    "$( [ "$(ev_code "export DOCKER_HOST=unix:///nonexistent.sock; compose_running '$PROJ'")" = "2" ] && echo 1 || echo 0 )"
check "not a compose project -> 2" \
    "$( [ "$(ev_code "compose_running '$NOTPROJ'")" = "2" ] && echo 1 || echo 0 )"

echo "=== docker calls honour the deadline ==="
check "a spent budget short-circuits a docker call" \
    "$( [ "$(ev_code 'DEADLINE=1; image_id_local alpine:3.20')" = "124" ] && echo 1 || echo 0 )"

echo "=== missing image is an error, not empty success ==="
check "image_id_local on an absent image fails" \
    "$( [ "$(ev_code 'image_id_local no-such-image:nope')" != "0" ] && echo 1 || echo 0 )"

gu_total
