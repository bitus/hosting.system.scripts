#!/usr/bin/env bash
# Fix 50-02 Phase 3: `folder status`, the folder command group, and spec 68
# (yq absent), which needed a command calling precheck_output.
# Spec cases 15-18, 68.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-folder-status
mkdir -p "$WORK/nobin"
git_global_setup

make_repo 1 fs1
echo hi > "$WORK/seed1/f.txt"
push_seed 1
run 0 "add fs1 -> 0" repo add testorg1/testrepo1/main -n fs1
run 0 "clone fs1 -> 0" repo clone fs1 "$WORK/tracked"

echo "=== 15: tracked git folder -> Ok, exit 0 ==="
run 0 "folder status <tracked> -> 0" folder status "$WORK/tracked"
check "status: Ok" "$( echo "$LAST_OUT" | grep -qx 'status: Ok' && echo 1 || echo 0 )"

out="$(cd "$WORK/tracked" && bash "$GU" folder status </dev/null 2>"$WORK/err.log")"; code=$?
check "no argument defaults to cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "cwd default reports Ok" "$( echo "$out" | grep -qx 'status: Ok' && echo 1 || echo 0 )"

out="$(cd "$WORK/tracked" && bash "$GU" folder status . </dev/null 2>"$WORK/err.log")"; code=$?
check "explicit '.' -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"

echo "=== 16: nonexistent path -> Not Found (5), exit 1 ==="
run 1 "folder status <missing> -> 1" folder status "$WORK/no-such-folder"
check "status is Not Found" "$( echo "$LAST_OUT" | grep -q 'Not Found' && echo 1 || echo 0 )"
check "reason present in default output" "$( echo "$LAST_OUT" | grep -q 'Folder doesnt exist' && echo 1 || echo 0 )"
run 1 "json form -> 1" folder status "$WORK/no-such-folder" --output-format json
check "json carries code 5" "$( echo "$LAST_OUT" | jq -e '.status.code == 5' >/dev/null && echo 1 || echo 0 )"
check "json carries status string" "$( echo "$LAST_OUT" | jq -e '.status.status == "Not Found"' >/dev/null && echo 1 || echo 0 )"

echo "=== 17: existing non-git folder -> Not Git Folder (6), exit 1 ==="
mkdir -p "$WORK/plain"
run 1 "folder status <plain dir> -> 1" folder status "$WORK/plain"
check "status is Not Git Folder" "$( echo "$LAST_OUT" | grep -q 'Not Git Folder' && echo 1 || echo 0 )"
run 1 "json form -> 1" folder status "$WORK/plain" --output-format json
check "json carries code 6" "$( echo "$LAST_OUT" | jq -e '.status.code == 6' >/dev/null && echo 1 || echo 0 )"

echo "=== 18: untracked git repo -> Not Tracked (5), exit 1 ==="
mkdir -p "$WORK/untracked"
( cd "$WORK/untracked" && git init -q )
run 1 "folder status <untracked repo> -> 1" folder status "$WORK/untracked"
check "status is Not Tracked" "$( echo "$LAST_OUT" | grep -q 'Not Tracked' && echo 1 || echo 0 )"
run 1 "json form -> 1" folder status "$WORK/untracked" --output-format json
check "json carries code 5" "$( echo "$LAST_OUT" | jq -e '.status.code == 5' >/dev/null && echo 1 || echo 0 )"

echo "=== check order: a missing folder wins over not-tracked ==="
run 1 "missing beats untracked" folder status "$WORK/plain/deeper/still-missing"
check "reports Not Found, not Not Tracked" \
    "$( echo "$LAST_OUT" | grep -q 'Not Found' && echo 1 || echo 0 )"

echo "=== worktree (.git is a file, not a directory) counts as a git repo ==="
( cd "$WORK/tracked" && git worktree add -q "$WORK/wt" -b wtbranch 2>/dev/null ) || true
if [ -f "$WORK/wt/.git" ]; then
    run 1 "worktree -> Not Tracked, not Not Git Folder" folder status "$WORK/wt"
    check "worktree recognised as a git repo" \
        "$( echo "$LAST_OUT" | grep -q 'Not Tracked' && echo 1 || echo 0 )"
else
    echo "SKIP worktree fixture unavailable"
fi

echo "=== output format plumbing ==="
run 0 "--output-format yaml -> 0" folder status "$WORK/tracked" --output-format yaml
YML="$LAST_OUT"
run 0 "--output-format text -> 0" folder status "$WORK/tracked" --output-format text
check "yaml == text" "$( [ "$YML" = "$LAST_OUT" ] && echo 1 || echo 0 )"
run 0 "--output-format=json (equals form) -> 0" folder status "$WORK/tracked" --output-format=json
check "equals form parsed" "$( echo "$LAST_OUT" | jq -e '.status.status == "Ok"' >/dev/null && echo 1 || echo 0 )"
run 2 "invalid --output-format -> 2" folder status "$WORK/tracked" --output-format xml
run 2 "--output-format with no value -> 2" folder status "$WORK/tracked" --output-format

echo "=== argument and flag handling ==="
run 2 "two positionals -> 2" folder status "$WORK/tracked" "$WORK/plain"
run 2 "unknown flag -> 2" folder status --bogus
run 0 "folder status -h -> 0" folder status -h
check "help mentions the command" "$( echo "$LAST_OUT" | grep -q 'git-utils folder status' && echo 1 || echo 0 )"

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
