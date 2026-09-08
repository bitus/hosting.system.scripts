#!/usr/bin/env bash
# Fix 50-04 Phase 12: the router and the help screens, checked systematically
# rather than command by command.
#
# Six commands were added and four rewritten across this fix, each wiring
# itself into the router and each bringing its own help function. The failure
# mode that survives that kind of work is asymmetry: a command reachable with
# no help, a help function nothing can reach, a usage line for a flag that was
# removed. So this suite derives the command list from the SCRIPT rather than
# repeating it, and fails when the two sides disagree.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-router
git_global_setup

# every "<group> <sub>" the router dispatches, read out of the script itself
mapfile -t ROUTED < <(
    awk '
        /^        repo\|repos\)/       { g = "repo";   next }
        /^        folder\)/            { g = "folder"; next }
        /^            esac/            { g = "";       next }
        g != "" && /^                [a-z|]+\) shift; cmd_/ {
            split($0, a, ")"); split(a[1], b, "|")
            gsub(/ /, "", b[1])
            print g " " b[1]
        }
    ' "$GU"
)
check "the router advertises a plausible number of subcommands" \
    "$( [ "${#ROUTED[@]}" -ge 14 ] && echo 1 || echo 0 )"

echo "=== every routed subcommand answers -h with its own usage line ==="
for entry in "${ROUTED[@]}"; do
    # shellcheck disable=SC2086  # the entry is two known-safe words
    run 0 "$entry -h -> 0" $entry -h
    check "$entry -h names itself" \
        "$( printf '%s' "$LAST_OUT" | grep -q "git-utils $entry" && echo 1 || echo 0 )"
    check "$entry -h wrote nothing to stderr" "$( [ -z "$LAST_ERR" ] && echo 1 || echo 0 )"
done

echo "=== the top-level commands too ==="
for c in setup validate update; do
    run 0 "$c -h -> 0" "$c" -h
    check "$c -h produces usage" "$( printf '%s' "$LAST_OUT" | grep -q 'git-utils' && echo 1 || echo 0 )"
done

echo "=== every help function is reachable from the router ==="
# The other asymmetry: a help_* that nothing dispatches to. help_main is
# reached by the bare invocation, not by a subcommand.
mapfile -t HELPERS < <(grep -o '^help_[a-z_]*' "$GU" | sort -u)
for h in "${HELPERS[@]}"; do
    check "$h is called somewhere" \
        "$( grep -q "^ *$h\b" "$GU" && [ "$(grep -c "\b$h\b" "$GU")" -ge 2 ] && echo 1 || echo 0 )"
done

echo "=== the main help lists every routed subcommand ==="
run 0 "main help -> 0" -h
MAIN="$LAST_OUT"
for entry in "${ROUTED[@]}"; do
    check "main help mentions '$entry'" \
        "$( printf '%s' "$MAIN" | grep -q "git-utils $entry" && echo 1 || echo 0 )"
done

echo "=== and does not advertise anything that was removed ==="
# Each of these was real before fix 50-04 and would mislead if left behind.
for gone in 'repo update \[' 'repo delete \[' 'repo info \[' 'repo_or_path' '\[-a\]'; do
    check "main help no longer shows '$gone'" \
        "$( printf '%s' "$MAIN" | grep -q "$gone" && echo 0 || echo 1 )"
done
check "the update alias is documented as folder update" \
    "$( printf '%s' "$MAIN" | grep -q "same as 'git-utils folder update" && echo 1 || echo 0 )"

echo "=== routing errors ==="
run 2 "bare 'repo' -> 2" repo
run 2 "bare 'folder' -> 2" folder
run 2 "unknown repo subcommand -> 2" repo bogus
run 2 "unknown folder subcommand -> 2" folder bogus
run 2 "unknown top-level command -> 2" bogus
run 2 "no arguments at all -> 2"
run 0 "'repo -h' -> 0" repo -h
run 0 "'folder -h' -> 0" folder -h
run 2 "there is still no 'folders' alias" folders status .
# 'repos list' needs a store, so this alias check waits until the fixtures
# below exist -- see the alias section.

echo "=== the aliases point where they claim to ==="
make_repo 1 rt1 rtorg rtrepo
echo one > "$WORK/seed1/f"; push_seed 1
run 0 "add rt1" repo add rtorg/rtrepo/main -n rt1
run 0 "clone rt1" repo clone rt1 "$WORK/co"

run 0 "'repos' is still an alias for 'repo'" repos list
check "repos list named the repo" "$( printf '%s' "$LAST_OUT" | grep -q rt1 && echo 1 || echo 0 )"

# folder repository == folder repo
run 0 "folder repo" folder repo "$WORK/co"
A="$LAST_OUT"
run 0 "folder repository" folder repository "$WORK/co"
check "the alias gives the same answer" "$( [ "$A" = "$LAST_OUT" ] && echo 1 || echo 0 )"

# git-utils update == git-utils folder update
out1="$(cd "$WORK/co" && bash "$GU" folder update --dry-run </dev/null 2>/dev/null)"; c1=$?
out2="$(cd "$WORK/co" && bash "$GU" update --dry-run </dev/null 2>/dev/null)"; c2=$?
check "the update alias matches folder update" \
    "$( [ "$out1" = "$out2" ] && [ "$c1" -eq "$c2" ] && echo 1 || echo 0 )"

echo "=== every command that emits a document accepts every format ==="
for fmt in json text yaml plain; do
    run 0 "repo info --output-format $fmt" repo info rt1 --output-format "$fmt"
    check "repo info $fmt produced output" "$( [ -n "$LAST_OUT" ] && echo 1 || echo 0 )"
    run 0 "folder validate --output-format $fmt" folder validate "$WORK/co" --output-format "$fmt"
done
for cmd_args in "repo folders rt1" "repo info rt1" "folder validate $WORK/co" "folder repo $WORK/co"; do
    # shellcheck disable=SC2086
    run 2 "'$cmd_args' rejects a bad format" $cmd_args --output-format xml
done

echo "=== the error-code space has no accidental collisions ==="
CODES="$(gu_eval 'printf "%s %s %s %s %s %s %s %s %s %s %s %s %s" \
    "$E_OK" "$E_PRECHECK" "$E_ARGS" "$E_IO" "$E_EXISTS" "$E_NOTFOUND" \
    "$E_GITFOLDER" "$E_MISMATCH" "$E_CMDOUTPUT" "$E_NOCOMPOSE" \
    "$E_NOTRUNNING" "$E_IMAGE" "$E_NOUPDATE"')"
check "thirteen codes, all distinct" \
    "$( [ "$(echo "$CODES" | tr ' ' '\n' | sort -u | wc -l)" -eq 13 ] && echo 1 || echo 0 )"
check "none collides with E_DBFORMAT" \
    "$( echo "$CODES" | tr ' ' '\n' | grep -qx 90 && echo 0 || echo 1 )"
check "none collides with timeout(1)'s 124" \
    "$( echo "$CODES" | tr ' ' '\n' | grep -qx 124 && echo 0 || echo 1 )"

gu_total
