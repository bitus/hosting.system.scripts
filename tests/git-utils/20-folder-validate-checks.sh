#!/usr/bin/env bash
# Fix 50-04 Phase 3: the four folder checks, --check-type, per-check exits.
#
# Spec cases 18-29, plus the ripple into repo validate.
#
# Two claims carry this phase. First, `worktree` uses `-e .git` rather than
# `-d`, so a linked worktree and a submodule are recognised as git repos --
# that is the deferred backlog item this retires. Second, single-check mode
# gives the same verdict a batch would: the Skip rules live in the checks
# themselves, so `--check-type origin` on a missing folder is Skipped, not a
# manufactured failure.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-fvchecks
git_global_setup

st() { printf '%s' "$LAST_OUT" | jq -r ".$1.status"; }
code() { printf '%s' "$LAST_OUT" | jq -r ".$1.code"; }

echo "=== fixtures ==="
make_repo 1 fvrepo fvorg fvrepo
echo hi > "$WORK/seed1/f"; push_seed 1
run 0 "repo add" repo add fvorg/fvrepo/main -n fvrepo
run 0 "repo clone" repo clone fvrepo "$WORK/tracked"

mkdir -p "$WORK/plainfolder"
( cd "$WORK" && git init -q untracked && cd untracked && git config user.email t@t && git config user.name t && echo a > f && git add f && git commit -qm a )

echo "=== batch mode: four checks, in order ==="
run 0 "healthy tracked checkout -> 0" folder validate --output-format json "$WORK/tracked"
check "four keys present" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'keys_unsorted == ["location","worktree","tracking","origin"]' >/dev/null 2>&1 && echo 1 || echo 0 )"
for k in location worktree tracking origin; do
    check "$k is Ok" "$( [ "$(st $k)" = "Ok" ] && echo 1 || echo 0 )"
done

echo "=== worktree: the check this phase adds ==="
run 6 "existing non-git folder -> 6" folder validate --output-format json "$WORK/plainfolder"
check "worktree Failed with 6" \
    "$( [ "$(st worktree)" = "Failed" ] && [ "$(code worktree)" = "6" ] && echo 1 || echo 0 )"
check "location still Ok (the folder does exist)" "$( [ "$(st location)" = "Ok" ] && echo 1 || echo 0 )"
# The simplification worktree buys: origin no longer has to report this fault
# itself, so it skips rather than double-counting it.
check "origin Skipped, not a second failure" \
    "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"

echo "--- a linked worktree has .git as a FILE, which the old -d test failed ---"
( cd "$WORK/tracked" && git worktree add -q "$WORK/wt" -b wtbranch 2>/dev/null ) || true
if [ -f "$WORK/wt/.git" ]; then
    run 5 "linked worktree -> untracked, not non-git" folder validate --output-format json "$WORK/wt"
    check "worktree Ok for a linked worktree" "$( [ "$(st worktree)" = "Ok" ] && echo 1 || echo 0 )"
    check "tracking is what fails, not worktree" \
        "$( [ "$(st tracking)" = "Failed" ] && echo 1 || echo 0 )"
else
    skip "linked worktree recognised as a git repo" "worktree fixture unavailable"
fi

echo "--- a submodule's .git is also a file ---"
( cd "$WORK" && git init -q super && cd super && git config user.email t@t && git config user.name t \
  && git -c protocol.file.allow=always submodule add -q "$WORK/bare1.git" sub 2>/dev/null ) || true
if [ -f "$WORK/super/sub/.git" ]; then
    run 5 "submodule -> untracked, not non-git" folder validate --output-format json "$WORK/super/sub"
    check "worktree Ok for a submodule" "$( [ "$(st worktree)" = "Ok" ] && echo 1 || echo 0 )"
else
    skip "submodule recognised as a git repo" "submodule fixture unavailable"
fi

echo "=== location and tracking ==="
run 5 "missing folder -> 5" folder validate --output-format json "$WORK/nosuch"
check "location Failed 5" "$( [ "$(st location)" = "Failed" ] && [ "$(code location)" = "5" ] && echo 1 || echo 0 )"
check "worktree Skipped" "$( [ "$(st worktree)" = "Skipped" ] && echo 1 || echo 0 )"
check "origin Skipped" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"
# tracking is deliberately NOT skipped for a missing folder: a record pointing
# at a path that no longer exists is the interesting case, not a distraction.
check "tracking still evaluated for a missing folder" \
    "$( [ "$(st tracking)" != "Skipped" ] && echo 1 || echo 0 )"

run 5 "untracked git repo -> 5" folder validate --output-format json "$WORK/untracked"
check "tracking Failed 5" "$( [ "$(st tracking)" = "Failed" ] && [ "$(code tracking)" = "5" ] && echo 1 || echo 0 )"
check "worktree Ok" "$( [ "$(st worktree)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== origin mismatch -> 8 ==="
( cd "$WORK/tracked" && git remote set-url origin "git@elsewhere.repo:other/other.git" )
run 8 "origin mismatch -> 8" folder validate --output-format json "$WORK/tracked"
check "origin Failed 8" "$( [ "$(st origin)" = "Failed" ] && [ "$(code origin)" = "8" ] && echo 1 || echo 0 )"
( cd "$WORK/tracked" && git remote set-url origin "git@fvrepo.repo:fvorg/fvrepo.git" )

run 0 "restored -> 0" folder validate --output-format json "$WORK/tracked"
( cd "$WORK/tracked" && git checkout -qb other )
run 8 "branch mismatch -> 8" folder validate --output-format json "$WORK/tracked"
check "origin reports the branch" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.origin.description' | grep -q "other" && echo 1 || echo 0 )"
( cd "$WORK/tracked" && git checkout -q main )

echo "=== exit code is the FIRST failure in check order ==="
# A missing folder fails both location (5) and tracking (5); an existing
# non-git tracked folder would fail worktree (6). The order location ->
# worktree -> tracking -> origin decides which code surfaces.
run 6 "worktree beats tracking in the exit code" folder validate "$WORK/plainfolder"

echo "=== single mode: --check-type ==="
run 0 "--check-type worktree on a good folder" folder validate -c worktree --output-format json "$WORK/tracked"
check "single mode emits ONE bare status object" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'has("code") and has("status") and (has("location") | not)' >/dev/null 2>&1 && echo 1 || echo 0 )"

run 6 "--check-type worktree on a non-git folder -> 6" folder validate --check-type worktree "$WORK/plainfolder"
run 5 "--check-type location on a missing folder -> 5" folder validate -c location "$WORK/nosuch"
run 5 "--check-type tracking on an untracked repo -> 5" folder validate -c tracking "$WORK/untracked"

# The claim that single mode does not fabricate failures: origin cannot be
# evaluated without a folder, so it is Skipped and exits 0 -- exactly as it
# would inside a batch.
run 0 "--check-type origin on a missing folder -> Skipped, 0" folder validate -c origin --output-format json "$WORK/nosuch"
check "origin is Skipped, not Failed" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status' | grep -qx Skipped && echo 1 || echo 0 )"

run 0 "--check-type=origin form" folder validate --check-type=origin --output-format json "$WORK/tracked"
run 2 "--check-type with no value -> 2" folder validate --check-type
run 2 "invalid --check-type -> 2" folder validate -c bogus
run 2 "invalid --check-type= form -> 2" folder validate --check-type=nope
check "the error names the valid checks" \
    "$( printf '%s' "$LAST_ERR" | grep -q 'location worktree tracking origin' && echo 1 || echo 0 )"

echo "=== the ripple: repo validate embeds the folder checks ==="
run 0 "repo validate -> 0" repo validate fvrepo --output-format json
check "checks.locations gains a worktree key" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.checks.locations | to_entries[0].value | has("worktree")' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "and still has the original three" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.checks.locations | to_entries[0].value | has("location") and has("tracking") and has("origin")' >/dev/null 2>&1 && echo 1 || echo 0 )"

run 0 "validate -> 0" validate --output-format json
check "whole-store validate carries worktree too" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.. | objects | select(has("worktree"))] | length >= 1' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== default output still folds ==="
run 6 "text output on a non-git folder" folder validate --output-format text "$WORK/plainfolder"
check "folded status carries the reason" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'Failed — Folder is not a git work tree' && echo 1 || echo 0 )"
check "skipped checks carry their reason too" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'Skipped — ' && echo 1 || echo 0 )"

gu_total
