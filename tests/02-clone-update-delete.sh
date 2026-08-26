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

echo "=== repo update, path target without --all ==="
echo more >> "$WORK/seed1/f.txt"
push_seed 1
run 0 "update dest1 -> 0" repo update "$WORK/dest1"
check "dest1 updated" "$( grep -q more "$WORK/dest1/f.txt" && echo 1 || echo 0 )"
check "dest2 untouched (no --all)" "$( grep -q more "$WORK/dest2/f.txt" 2>/dev/null && echo 0 || echo 1 )"

echo "=== repo update --all ==="
run 0 "update --all -> 0" repo update "$WORK/dest1" --all
check "dest2 updated with --all" "$( grep -q more "$WORK/dest2/f.txt" && echo 1 || echo 0 )"

echo "=== delete . with untracked files, non-tty, no -f -> 2 ==="
touch "$WORK/dest1/untracked.txt"
out="$(cd "$WORK/dest1" && bash "$GU" repo delete </dev/null 2>"$WORK/err.log")"; code=$?
check "delete untracked non-tty -> 2" "$( [ "$code" -eq 2 ] && echo 1 || echo 0 )"
check "dest1 not deleted" "$( [ -d "$WORK/dest1" ] && echo 1 || echo 0 )"

echo "=== delete . with untracked files, --force -> 0 ==="
out="$(cd "$WORK/dest1" && bash "$GU" repo delete --force </dev/null 2>"$WORK/err.log")"; code=$?
check "force delete -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "dest1 folder removed" "$( [ -d "$WORK/dest1" ] && echo 0 || echo 1 )"
check "clonekey record removed" "$( rec_exists clonekey && echo 0 || echo 1 )"
check "dest2 (other location) left on disk" "$( [ -d "$WORK/dest2" ] && echo 1 || echo 0 )"

gu_total
