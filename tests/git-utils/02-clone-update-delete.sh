#!/usr/bin/env bash
# Real clone / update / delete against local bare repos, with git's
# url.<path>.insteadOf redirecting the deploy-key SSH URL so no network or
# GitHub access is needed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-cud
git_global_setup

echo "=== real clone via insteadOf redirect ==="
make_repo 1 clonekey cloneorg cloner.repo
echo hi > "$WORK/seed1/f.txt"
push_seed 1

run 0 "add cloneorg/cloner.repo/main -n clonekey -> 0" repo add cloneorg/cloner.repo/main -n clonekey
run 0 "clone clonekey -> 0" repo clone clonekey "$WORK/dest1"
check "cloned file present" "$( [ -f "$WORK/dest1/f.txt" ] && echo 1 || echo 0 )"
check "location recorded" "$( [ "$(loc_path clonekey 0)" = "$WORK/dest1" ] && echo 1 || echo 0 )"

echo "=== clone into existing dest -> 4 ==="
run 4 "clone to existing dest -> 4" repo clone clonekey "$WORK/dest1"

echo "=== clone to a second location ==="
run 0 "clone to dest2 -> 0" repo clone clonekey "$WORK/dest2"
check "2 locations tracked" "$( [ "$(loc_count clonekey)" = "2" ] && echo 1 || echo 0 )"

echo "=== repo update now always covers every location ==="
# Before fix 50-04 a path target updated just that location and --all
# widened it. Path targets are gone, so `repo update <key>` covers every
# location and there is no narrower form here any more -- updating ONE
# checkout is `folder update <path>`, which arrives in phase 6.
echo more >> "$WORK/seed1/f.txt"
push_seed 1
run 2 "a path target is now an argument error -> 2" repo update "$WORK/dest1"
run 0 "update by key -> 0" repo update clonekey
check "dest1 updated" "$( grep -q more "$WORK/dest1/f.txt" && echo 1 || echo 0 )"
check "dest2 updated too" "$( grep -q more "$WORK/dest2/f.txt" && echo 1 || echo 0 )"

echo "=== delete: dirty tree, non-tty, no --force -> 2 ==="
# The cwd form is gone with path targets. What it really exercised -- a
# dirty checkout refusing to be destroyed without confirmation -- is kept,
# addressed by key through --with-folders.
touch "$WORK/dest1/untracked.txt"
run 2 "dirty tree, no --force -> 2" repo delete clonekey --with-folders
check "dest1 not deleted" "$( [ -d "$WORK/dest1" ] && echo 1 || echo 0 )"
check "record not deleted either" "$( rec_exists clonekey && echo 1 || echo 0 )"

echo "=== delete --with-folders --force removes EVERY location ==="
# The old test asserted dest2 survived, because a path target deleted one
# folder. --with-folders is deliberately wider: the argument names a record,
# so every location goes.
run 0 "force delete -> 0" repo delete clonekey --with-folders --force
check "dest1 folder removed" "$( [ -d "$WORK/dest1" ] && echo 0 || echo 1 )"
check "dest2 folder removed as well" "$( [ -d "$WORK/dest2" ] && echo 0 || echo 1 )"
check "clonekey record removed" "$( rec_exists clonekey && echo 0 || echo 1 )"

gu_total
