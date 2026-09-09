#!/usr/bin/env bash
# Fix 50-04 Phase 4: the folder/repo address split, `folder repo`, and
# `repo delete --with-folders`. Spec cases 1-17.
#
# The split's claim is that nothing is lost: every path-addressed use of a
# repo command still works through the bridge. The delete flag's claim is
# narrower and sharper -- destruction is now asked for explicitly instead of
# being implied by the shape of an argument, and declining leaves EVERYTHING
# in place, record included.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-split
git_global_setup

echo "=== fixtures ==="
make_repo 1 sp1 sporg sprepo
echo hi > "$WORK/seed1/f"; push_seed 1
run 0 "repo add" repo add sporg/sprepo/main -n sp1
run 0 "repo clone" repo clone sp1 "$WORK/co"

mkdir -p "$WORK/plain"
( cd "$WORK" && git init -q loose && cd loose && git config user.email t@t && git config user.name t \
  && echo a > f && git add f && git commit -qm a )

echo "=== 1: repo commands no longer accept a path ==="
run 2 "repo info <path> -> 2" repo info "$WORK/co"
check "the error points at the bridge" \
    "$( printf '%s' "$LAST_ERR" | grep -q 'folder repo' && echo 1 || echo 0 )"
run 2 "repo validate <path> -> 2" repo validate "$WORK/co"
run 2 "repo delete <path> -> 2" repo delete "$WORK/co"
run 2 "repo update <path> -> 2" repo update "$WORK/co"
run 2 "repo info . -> 2" repo info .
run 2 "repo info with no argument -> 2" repo info
check "the no-argument error asks for a key" \
    "$( printf '%s' "$LAST_ERR" | grep -q 'repo key or full repo name' && echo 1 || echo 0 )"
# a relative path that happens to exist is caught too, not read as a full name
( cd "$WORK" && mkdir -p sporg/sprepo )
run 2 "an existing relative dir -> 2" repo info sporg/sprepo

echo "=== the key and full-name forms still work ==="
run 0 "repo info <key> -> 0" repo info sp1
run 0 "repo info <org/name/branch> -> 0" repo info sporg/sprepo/main

echo "=== 2-6: folder repo ==="
run 0 "folder repo in a tracked checkout -> 0" folder repo "$WORK/co"
check "plain output is the bare id" "$( [ "$LAST_OUT" = "sp1" ] && echo 1 || echo 0 )"
run 0 "folder repo --output-format json" folder repo "$WORK/co" --output-format json
check "json is {id}" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.id == "sp1" and (keys == ["id"])' >/dev/null 2>&1 && echo 1 || echo 0 )"

out="$(cd "$WORK/co" && bash "$GU" folder repo </dev/null 2>/dev/null)"; code=$?
check "no argument uses cwd" "$( [ "$code" -eq 0 ] && [ "$out" = "sp1" ] && echo 1 || echo 0 )"

run 5 "untracked git repo -> 5" folder repo "$WORK/loose"
check "and prints nothing" "$( [ -z "$LAST_OUT" ] && echo 1 || echo 0 )"
run 6 "non-git folder -> 6" folder repo "$WORK/plain"
check "and prints nothing" "$( [ -z "$LAST_OUT" ] && echo 1 || echo 0 )"
run 5 "missing folder -> 5" folder repo "$WORK/nosuch"

# An origin mismatch still resolves: the record is identifiable, it merely
# disagrees -- and repo validate is exactly where a caller pipes it next.
( cd "$WORK/co" && git remote set-url origin "git@elsewhere.repo:x/y.git" )
run 0 "origin mismatch still names the repo -> 0" folder repo "$WORK/co"
check "still the right id" "$( [ "$LAST_OUT" = "sp1" ] && echo 1 || echo 0 )"
( cd "$WORK/co" && git remote set-url origin "git@sp1.repo:sporg/sprepo.git" )

run 0 "folder repository alias" folder repository "$WORK/co"
run 0 "folder repo -h" folder repo -h
check "help mentions the bridge" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'git-utils folder repo' && echo 1 || echo 0 )"

echo "=== 7: the round trip replaces every dropped path use ==="
ID="$(cd "$WORK/co" && bash "$GU" folder repo </dev/null 2>/dev/null)"
run 0 "repo info via the bridge" repo info "$ID"
BRIDGED="$LAST_OUT"
run 0 "repo info by key directly" repo info sp1
check "bridge and key give identical output" "$( [ "$BRIDGED" = "$LAST_OUT" ] && echo 1 || echo 0 )"
run 0 "repo validate via the bridge" repo validate "$ID"

echo "=== 9-17: repo delete ==="
echo "--- without --with-folders the checkouts survive ---"
make_repo 2 sp2 sporg2 sprepo2
echo hi > "$WORK/seed2/f"; push_seed 2
run 0 "add sp2" repo add sporg2/sprepo2/main -n sp2
run 0 "clone sp2" repo clone sp2 "$WORK/keepme"
run 0 "delete without the flag" repo delete sp2 --force
check "record gone" "$( rec_exists sp2 && echo 0 || echo 1 )"
check "checkout still on disk" "$( [ -d "$WORK/keepme" ] && echo 1 || echo 0 )"
check "and still a git repo" "$( [ -e "$WORK/keepme/.git" ] && echo 1 || echo 0 )"

echo "--- --with-folders removes every recorded location ---"
make_repo 3 sp3 sporg3 sprepo3
echo hi > "$WORK/seed3/f"; push_seed 3
run 0 "add sp3" repo add sporg3/sprepo3/main -n sp3
run 0 "clone sp3 to A" repo clone sp3 "$WORK/three-a"
run 0 "clone sp3 to B" repo clone sp3 "$WORK/three-b"
check "two locations recorded" "$( [ "$(loc_count sp3)" = "2" ] && echo 1 || echo 0 )"
run 0 "delete --with-folders" repo delete sp3 --with-folders --force
check "record gone" "$( rec_exists sp3 && echo 0 || echo 1 )"
check "location A removed" "$( [ ! -e "$WORK/three-a" ] && echo 1 || echo 0 )"
check "location B removed too -- the flag is not per-folder" \
    "$( [ ! -e "$WORK/three-b" ] && echo 1 || echo 0 )"

echo "--- a missing location is a warning, not a failure ---"
make_repo 4 sp4 sporg4 sprepo4
echo hi > "$WORK/seed4/f"; push_seed 4
run 0 "add sp4" repo add sporg4/sprepo4/main -n sp4
run 0 "clone sp4 to A" repo clone sp4 "$WORK/four-a"
run 0 "clone sp4 to B" repo clone sp4 "$WORK/four-b"
rm -rf "$WORK/four-a"
run 0 "delete --with-folders with one location already gone" repo delete sp4 --with-folders --force
check "warned about the vanished location" \
    "$( printf '%s' "$LAST_ERR" | grep -q 'no longer exists' && echo 1 || echo 0 )"
check "the surviving location was still removed" "$( [ ! -e "$WORK/four-b" ] && echo 1 || echo 0 )"

echo "--- declining the confirmation deletes NOTHING ---"
make_repo 5 sp5 sporg5 sprepo5
echo hi > "$WORK/seed5/f"; push_seed 5
run 0 "add sp5" repo add sporg5/sprepo5/main -n sp5
run 0 "clone sp5" repo clone sp5 "$WORK/five"
echo junk > "$WORK/five/untracked.txt"
# no TTY and no --force: confirm() refuses rather than proceeding
run 2 "dirty tree without --force -> 2" repo delete sp5 --with-folders
check "record still present" "$( rec_exists sp5 && echo 1 || echo 0 )"
check "folder still present" "$( [ -d "$WORK/five" ] && echo 1 || echo 0 )"
check "the message names a TTY or --force" \
    "$( printf '%s' "$LAST_ERR" | grep -qi 'tty\|force' && echo 1 || echo 0 )"

echo "--- and the confirmation is asked before the store is touched ---"
run 0 "same delete with --force" repo delete sp5 --with-folders --force
check "record gone" "$( rec_exists sp5 && echo 0 || echo 1 )"
check "folder gone" "$( [ ! -e "$WORK/five" ] && echo 1 || echo 0 )"

echo "--- a dirty tree is what triggers the prompt, a clean one is not ---"
make_repo 6 sp6 sporg6 sprepo6
echo hi > "$WORK/seed6/f"; push_seed 6
run 0 "add sp6" repo add sporg6/sprepo6/main -n sp6
run 0 "clone sp6" repo clone sp6 "$WORK/six"
run 0 "clean tree needs no confirmation" repo delete sp6 --with-folders
check "folder gone without --force" "$( [ ! -e "$WORK/six" ] && echo 1 || echo 0 )"

echo "--- $HOME and / are refused outright ---"
make_repo 7 sp7 sporg7 sprepo7
echo hi > "$WORK/seed7/f"; push_seed 7
run 0 "add sp7" repo add sporg7/sprepo7/main -n sp7
run 0 "clone sp7" repo clone sp7 "$WORK/seven"
store_patch '.repositories["sp7"].locations = [{"path": env.HOME}]'
run 3 "a location of $HOME -> 3" repo delete sp7 --with-folders --force
check "HOME still exists" "$( [ -d "$HOME" ] && echo 1 || echo 0 )"
check "record NOT deleted -- the guard runs first" "$( rec_exists sp7 && echo 1 || echo 0 )"

echo "=== help ==="
run 0 "repo delete -h" repo delete -h
check "help documents --with-folders" \
    "$( printf '%s' "$LAST_OUT" | grep -q -- '--with-folders' && echo 1 || echo 0 )"
check "help says a path is not accepted" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'folder repo' && echo 1 || echo 0 )"
check "help warns it removes ALL locations" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'ALL' && echo 1 || echo 0 )"
run 0 "main help" -h
check "main help lists folder repo" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'folder repo' && echo 1 || echo 0 )"

gu_total
