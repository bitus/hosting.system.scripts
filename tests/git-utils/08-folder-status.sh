#!/usr/bin/env bash
# `folder status`. Originally fix 50-02 phase 3 (spec 15-18); REWRITTEN by fix
# 50-04 phase 10 (spec 65-74), which replaced both the command and this suite.
#
# The old command answered one question -- is this folder a tracked git repo --
# with one status object, and the old statuses ("Not Found", "Not Git Folder",
# "Not Tracked") no longer exist: folder validate owns that vocabulary now and
# this command reports its codes instead. What survives from the old suite is
# the check ORDER and the argument handling, both kept below.
#
# The claim worth defending hardest: a remote that cannot be reached must not
# hide the container state. A monitoring command that goes blind on the half
# you can still see is worse than useless.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-folder-status
git_global_setup

st()   { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
code() { printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }
fld()  { printf '%s' "$LAST_OUT" | jq -r ".$1" 2>/dev/null; }
img()  { printf '%s' "$LAST_OUT" | jq -r --arg s "$1" ".images[] | select(.id != null) | .$2" 2>/dev/null; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi

echo "=== fixtures ==="
make_repo 1 fs1 fsorg fsrepo
echo one > "$WORK/seed1/f"
push_seed 1
run 0 "add fs1" repo add fsorg/fsrepo/main -n fs1
run 0 "clone fs1" repo clone fs1 "$WORK/tracked"

git clone -q "$WORK/bare1.git" "$WORK/pub"
( cd "$WORK/pub" && git config user.email t@t && git config user.name t )
publish() {
    echo "$1" >> "$WORK/pub/f"
    ( cd "$WORK/pub" && git add -A && git commit -qm "$1" && git push -q origin main )
}

mkdir -p "$WORK/plain"
( cd "$WORK" && git init -q untracked && cd untracked && git config user.email t@t \
  && git config user.name t && echo a > f && git add f && git commit -qm a )

echo "=== 66: a tracked, non-compose checkout ==="
run 0 "tracked non-compose folder -> 0" folder status --output-format json "$WORK/tracked"
check "status Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"
check "path is reported" "$( [ "$(fld path)" = "$WORK/tracked" ] && echo 1 || echo 0 )"
check "update_available is false" "$( [ "$(fld update_available)" = "false" ] && echo 1 || echo 0 )"
# null, not false: "does this apply" and "is it running" are different questions
check "docker_running is null, not false" "$( [ "$(fld docker_running)" = "null" ] && echo 1 || echo 0 )"
check "images is empty" "$( printf '%s' "$LAST_OUT" | jq -e '.images == []' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "the reason says it is not a compose project" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -qi 'compose' && echo 1 || echo 0 )"

echo "=== 68: behind the remote ==="
publish two
run 0 "behind -> 0" folder status --output-format json "$WORK/tracked"
check "update_available is true" "$( [ "$(fld update_available)" = "true" ] && echo 1 || echo 0 )"
check "still exit 0 -- being behind is not a fault" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== 74: ls-remote must not mutate .git ==="
BEFORE="$(find "$WORK/tracked/.git/refs" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)"
BEFORE_FH="$( [ -e "$WORK/tracked/.git/FETCH_HEAD" ] && echo yes || echo no )"
run 0 "status again" folder status "$WORK/tracked"
AFTER="$(find "$WORK/tracked/.git/refs" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)"
check "refs unchanged" "$( [ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0 )"
check "no FETCH_HEAD appeared" \
    "$( [ "$BEFORE_FH" = "$( [ -e "$WORK/tracked/.git/FETCH_HEAD" ] && echo yes || echo no )" ] && echo 1 || echo 0 )"
run 0 "and the checkout is still behind" folder update --dry-run "$WORK/tracked"

echo "=== 69: an unreachable remote does not hide the rest ==="
mv "$WORK/bare1.git" "$WORK/bare1.gone"
run 10 "unreachable remote -> 10" folder status --output-format json "$WORK/tracked"
check "update_available is null" "$( [ "$(fld update_available)" = "null" ] && echo 1 || echo 0 )"
check "status Failed with 10" "$( [ "$(st)" = "Failed" ] && [ "$(code)" = "10" ] && echo 1 || echo 0 )"
check "path still reported" "$( [ "$(fld path)" = "$WORK/tracked" ] && echo 1 || echo 0 )"
check "docker_running still answered -- the run did not stop at git" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'has("docker_running")' >/dev/null 2>&1 && echo 1 || echo 0 )"
mv "$WORK/bare1.gone" "$WORK/bare1.git"

echo "=== 72: a folder that is not a usable work tree ==="
run 5 "missing folder -> 5" folder status --output-format json "$WORK/nosuch"
check "status Failed 5" "$( [ "$(st)" = "Failed" ] && [ "$(code)" = "5" ] && echo 1 || echo 0 )"
check "every other field is defaulted" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.update_available == null and .docker_running == null and .images == []' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 6 "plain folder -> 6" folder status --output-format json "$WORK/plain"
check "status Failed 6" "$( [ "$(st)" = "Failed" ] && [ "$(code)" = "6" ] && echo 1 || echo 0 )"
run 5 "untracked git repo -> 5" folder status "$WORK/untracked"

# Carried over from the 50-02 suite: check ORDER still decides which code wins.
run 5 "missing beats untracked" folder status "$WORK/plain/deeper/still-missing"

echo "=== the old status vocabulary is gone ==="
# These strings were the 50-02 contract; folder validate owns this ground now.
run 6 "plain folder, text form" folder status --output-format text "$WORK/plain"
check "no 'Not Git Folder' string any more" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'Not Git Folder' && echo 0 || echo 1 )"
check "it reports the folder validate reason instead" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'work tree' && echo 1 || echo 0 )"

echo "=== compose projects ==="
if [ "$HAVE_DOCKER" -eq 0 ]; then
    skip "every compose assertion" "no docker daemon"
else
    IMG=alpine:3.20
    docker pull -q "$IMG" >/dev/null 2>&1 || true
    cat > "$WORK/pub/compose.yml" <<YML
services:
  a:
    image: $IMG
    command: sleep 600
YML
    publish compose-added
    run 0 "pull the compose file into the checkout" folder update "$WORK/tracked"

    echo "--- 67: a compose project that is stopped ---"
    run 0 "stopped compose project -> 0" folder status --output-format json "$WORK/tracked"
    check "docker_running is false, not null" "$( [ "$(fld docker_running)" = "false" ] && echo 1 || echo 0 )"
    check "one image reported" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images | length == 1' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "running_image_id is null while stopped" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].running_image_id == null' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "restart_pending is false -- nothing is running to restart" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].restart_pending == false' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "built is false for a registry image" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].built == false' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "the image id is the compose reference" \
        "$( printf '%s' "$LAST_OUT" | jq -e --arg i "$IMG" '.images[0].id == $i' >/dev/null 2>&1 && echo 1 || echo 0 )"

    echo "--- 65: a running compose project ---"
    ( cd "$WORK/tracked" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
    run 0 "running compose project -> 0" folder status --output-format json "$WORK/tracked"
    check "docker_running is true" "$( [ "$(fld docker_running)" = "true" ] && echo 1 || echo 0 )"
    check "local_image_id looks like an id" \
        "$( printf '%s' "$LAST_OUT" | jq -r '.images[0].local_image_id' | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
    check "running_image_id looks like an id" \
        "$( printf '%s' "$LAST_OUT" | jq -r '.images[0].running_image_id' | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
    check "restart_pending is false right after starting" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].restart_pending == false' >/dev/null 2>&1 && echo 1 || echo 0 )"

    echo "--- 73: pulled but not restarted -> restart_pending ---"
    # Retag a DIFFERENT image to the reference the container is running. The
    # reference now resolves to a new id while the container keeps the old
    # one, which is exactly "pulled but not restarted".
    docker pull -q busybox:1.36 >/dev/null 2>&1 || docker pull -q public.ecr.aws/docker/library/busybox:1.36 >/dev/null 2>&1 || true
    OTHER="$(docker images -q busybox:1.36 2>/dev/null | head -1)"
    [ -n "$OTHER" ] || OTHER="$(docker images -q public.ecr.aws/docker/library/busybox:1.36 2>/dev/null | head -1)"
    if [ -n "$OTHER" ]; then
        docker tag "$OTHER" "$IMG" >/dev/null 2>&1
        run 0 "status after retagging the reference" folder status --output-format json "$WORK/tracked"
        check "local and running ids now differ" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].local_image_id != .images[0].running_image_id' >/dev/null 2>&1 && echo 1 || echo 0 )"
        check "restart_pending is true" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].restart_pending == true' >/dev/null 2>&1 && echo 1 || echo 0 )"
        docker pull -q "$IMG" >/dev/null 2>&1 || true
    else
        skip "restart_pending when pulled but not restarted" "no second image to retag with"
    fi

    echo "--- a built service is marked built ---"
    ( cd "$WORK/tracked" && docker compose down >/dev/null 2>&1 ) || true
    cat > "$WORK/pub/compose.yml" <<'YML'
services:
  a:
    image: alpine:3.20
    command: sleep 600
  b:
    build: .
    command: sleep 600
YML
    printf 'FROM alpine:3.20\nRUN true\n' > "$WORK/pub/Dockerfile"
    publish built-service
    run 0 "pull the two-service compose file" folder update "$WORK/tracked"
    ( cd "$WORK/tracked" && docker compose up -d --quiet-pull >/dev/null 2>&1 )
    run 0 "status with a built service" folder status --output-format json "$WORK/tracked"
    check "two images reported" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images | length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "exactly one is marked built" \
        "$( printf '%s' "$LAST_OUT" | jq -e '[.images[] | select(.built)] | length == 1' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "the built one still has an id and a local image" \
        "$( printf '%s' "$LAST_OUT" | jq -e '[.images[] | select(.built)][0] | .id != null and .local_image_id != null' >/dev/null 2>&1 && echo 1 || echo 0 )"

    echo "--- 71: docker unreachable on a compose folder -> 1 ---"
    out="$(cd "$WORK" && DOCKER_HOST=unix:///nonexistent.sock bash "$GU" folder status --output-format json "$WORK/tracked" </dev/null 2>/dev/null)"
    code=$?
    check "exit 1" "$( [ "$code" -eq 1 ] && echo 1 || echo 0 )"
    check "update_available was still determined" \
        "$( printf '%s' "$out" | jq -e '.update_available != null' >/dev/null 2>&1 && echo 1 || echo 0 )"

    ( cd "$WORK/tracked" && docker compose down >/dev/null 2>&1 ) || true
fi

echo "=== 70: docker absent on a NON-compose folder is irrelevant ==="
out="$(cd "$WORK" && DOCKER_HOST=unix:///nonexistent.sock bash "$GU" folder status "$WORK/untracked" </dev/null 2>/dev/null)"
code=$?
check "an untracked folder still reports 5, not a docker complaint" \
    "$( [ "$code" -eq 5 ] && echo 1 || echo 0 )"

echo "=== timeout and output plumbing ==="
run 2 "--timeout with no value -> 2" folder status --timeout
run 2 "non-numeric --timeout -> 2" folder status -t abc "$WORK/tracked"
run 2 "zero --timeout -> 2" folder status -t 0 "$WORK/tracked"
run 0 "--timeout=<n> form" folder status --timeout=60 "$WORK/tracked"

run 0 "--output-format yaml" folder status "$WORK/tracked" --output-format yaml
YML_OUT="$LAST_OUT"
run 0 "--output-format text" folder status "$WORK/tracked" --output-format text
check "yaml == text" "$( [ "$YML_OUT" = "$LAST_OUT" ] && echo 1 || echo 0 )"
run 2 "invalid --output-format -> 2" folder status "$WORK/tracked" --output-format xml
run 2 "two positionals -> 2" folder status "$WORK/tracked" "$WORK/plain"
run 2 "unknown flag -> 2" folder status --bogus

out="$(cd "$WORK/tracked" && bash "$GU" folder status </dev/null 2>/dev/null)"; code=$?
check "no argument uses cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"

run 0 "folder status -h" folder status -h
check "help explains restart_pending compares image ids" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'IMAGE IDS' && echo 1 || echo 0 )"
check "help says an unreachable remote does not hide the rest" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'does NOT hide' && echo 1 || echo 0 )"

echo "=== store-format gate still applies ==="
cp "$(store)" "$WORK/store.good"
echo '{"my-repo":{"name":"n","org":"o","branch":"main","locations":[]}}' > "$(store)"
run 90 "old-format store -> 90" folder status "$WORK/tracked"
cp "$WORK/store.good" "$(store)"

echo "=== folder command group routing ==="
run 2 "bare 'folder' -> 2" folder
run 0 "'folder -h' -> 0" folder -h
run 2 "unknown subcommand -> 2" folder bogus
run 2 "no 'folders' alias -> 2" folders status "$WORK/tracked"
run 0 "main help lists folder status" -h
check "main help mentions folder status" "$( echo "$LAST_OUT" | grep -q 'git-utils folder status' && echo 1 || echo 0 )"
check "main help notes there is no folders alias" "$( echo "$LAST_OUT" | grep -qi "no 'folders' alias" && echo 1 || echo 0 )"

echo "=== 68: yq absent ==="
# Mirror the real PATH minus yq, so the ONLY difference is the missing
# command. (Symlinking a hand-picked subset is brittle: the first attempt
# omitted bash itself and every invocation died with 127.)
rm -rf "$WORK/nobin"; mkdir -p "$WORK/nobin"
for d in /usr/bin /bin /usr/local/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        b="$(basename "$f")"
        [ "$b" = "yq" ] && continue
        [ -e "$WORK/nobin/$b" ] || ln -s "$f" "$WORK/nobin/$b" 2>/dev/null || true
    done
done
check "yq really is absent from the stub PATH" \
    "$( PATH="$WORK/nobin" command -v yq >/dev/null 2>&1 && echo 0 || echo 1 )"
check "bash is present in the stub PATH" \
    "$( PATH="$WORK/nobin" command -v bash >/dev/null 2>&1 && echo 1 || echo 0 )"

out="$(cd "$WORK" && PATH="$WORK/nobin" bash "$GU" folder status "$WORK/tracked" </dev/null 2>"$WORK/err.log")"; code=$?
ERR="$(cat "$WORK/err.log")"
check "folder status without yq -> 1" "$( [ "$code" -eq 1 ] && echo 1 || echo 0 )"
check "standard missing-command message" "$( echo "$ERR" | grep -q 'those commands not available' && echo 1 || echo 0 )"
check "message names yq" "$( echo "$ERR" | grep -q 'yq' && echo 1 || echo 0 )"
check "apt line names the yq package" "$( echo "$ERR" | grep -q 'apt install.*yq' && echo 1 || echo 0 )"

# yq is a GLOBAL dependency (precheck_common), not scoped to the formatting
# commands, so every store command fails the same way.
for c in "repo list" "repo keys" "repo update fs1"; do
    # shellcheck disable=SC2086
    out="$(cd "$WORK" && PATH="$WORK/nobin" bash "$GU" $c </dev/null 2>"$WORK/err2.log")"; code=$?
    ERR2="$(cat "$WORK/err2.log")"
    check "'$c' without yq -> 1" "$( [ "$code" -eq 1 ] && echo 1 || echo 0 )"
    check "'$c' message names yq" "$( echo "$ERR2" | grep -q 'those commands not available.*yq' && echo 1 || echo 0 )"
done

# repo add folds yq into the same collect-all pass as ssh-keygen
rm -f "$WORK/nobin/ssh-keygen"
out="$(cd "$WORK" && PATH="$WORK/nobin" bash "$GU" repo add neworg/newrepo/main </dev/null 2>"$WORK/err3.log")"; code=$?
ERR3="$(cat "$WORK/err3.log")"
check "repo add without yq or ssh-keygen -> 1" "$( [ "$code" -eq 1 ] && echo 1 || echo 0 )"
check "one message names both missing commands" \
    "$( echo "$ERR3" | grep -q 'yq, ssh-keygen' && echo 1 || echo 0 )"
check "one apt line names both packages" \
    "$( echo "$ERR3" | grep -q 'apt install yq openssh-client' && echo 1 || echo 0 )"


gu_total
