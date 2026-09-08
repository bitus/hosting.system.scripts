#!/usr/bin/env bash
# Fix 50-02 Phase 7: `folder validate`. Spec cases 19-22.
#
# Updated by fix 50-04 phase 3, which changed this command's contract twice
# over: a fourth check (`worktree`) was added, and the exit code became the
# first failed check's own code rather than a bare 1. Every assertion below
# keeps its original intent; only the expected code and check count moved.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-folder-validate
git_global_setup

# fixtures are built with `folder adopt`, which writes a complete record
# (origin included), so the origin check has something real to compare against
mk_adopted() {   # mk_adopted <dir> <origin-url>
    mkdir -p "$WORK/$1"
    ( cd "$WORK/$1" && git init -q && git remote add origin "$2" \
        && echo hi > f.txt && git add f.txt && git commit -qm one )
}

mk_adopted healthy "https://github.com/myorg/healthy.repo"
run 0 "adopt healthy.repo -> 0" folder adopt "$WORK/healthy"

# convenience: run folder validate and capture the JSON
fv() { run "$1" "$2" folder validate "$3" --output-format json; }
st() { echo "$LAST_OUT" | jq -r ".$1.status"; }
cd_() { echo "$LAST_OUT" | jq -r ".$1.code"; }

echo "=== 19: healthy tracked folder -> all Ok, exit 0 ==="
fv 0 "healthy folder -> 0" "$WORK/healthy"
check "location Ok" "$( [ "$(st location)" = "Ok" ] && echo 1 || echo 0 )"
check "worktree Ok" "$( [ "$(st worktree)" = "Ok" ] && echo 1 || echo 0 )"
check "tracking Ok" "$( [ "$(st tracking)" = "Ok" ] && echo 1 || echo 0 )"
check "origin Ok" "$( [ "$(st origin)" = "Ok" ] && echo 1 || echo 0 )"
run 0 "default output form -> 0" folder validate "$WORK/healthy"
check "folds to four bare Ok lines" \
    "$( [ "$(echo "$LAST_OUT" | grep -c ': Ok$')" = "4" ] && echo 1 || echo 0 )"

out="$(cd "$WORK/healthy" && bash "$GU" folder validate </dev/null 2>"$WORK/err.log")"; code=$?
check "no argument uses cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"

echo "=== 20: folder deleted from disk ==="
mk_adopted gone "https://github.com/myorg/gone.repo"
run 0 "adopt gone.repo -> 0" folder adopt "$WORK/gone"
rm -rf "$WORK/gone"
fv 5 "deleted folder -> 5" "$WORK/gone"
check "location Failed" "$( [ "$(st location)" = "Failed" ] && echo 1 || echo 0 )"
check "location code 5" "$( [ "$(cd_ location)" = "5" ] && echo 1 || echo 0 )"
check "tracking still Ok (the record still lists it)" "$( [ "$(st tracking)" = "Ok" ] && echo 1 || echo 0 )"
check "worktree Skipped (no folder to look in)" "$( [ "$(st worktree)" = "Skipped" ] && echo 1 || echo 0 )"
check "20: origin Skipped, not Failed" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"
check "skip reason given" \
    "$( echo "$LAST_OUT" | jq -e '.origin.description | test("does not exist")' >/dev/null && echo 1 || echo 0 )"

echo "=== 21: remote URL changed behind git-utils' back ==="
mk_adopted moved "https://github.com/myorg/moved.repo"
run 0 "adopt moved.repo -> 0" folder adopt "$WORK/moved"
( cd "$WORK/moved" && git remote set-url origin "https://github.com/otherorg/moved.repo" )
fv 8 "changed remote -> 8" "$WORK/moved"
check "location Ok" "$( [ "$(st location)" = "Ok" ] && echo 1 || echo 0 )"
check "tracking Ok" "$( [ "$(st tracking)" = "Ok" ] && echo 1 || echo 0 )"
check "21: origin Failed" "$( [ "$(st origin)" = "Failed" ] && echo 1 || echo 0 )"
check "21: origin code 8" "$( [ "$(cd_ origin)" = "8" ] && echo 1 || echo 0 )"
check "reason mentions the record" \
    "$( echo "$LAST_OUT" | jq -e '.origin.description | test("does not match")' >/dev/null && echo 1 || echo 0 )"

echo "=== 22: checked-out branch differs from the record ==="
mk_adopted branched "https://github.com/myorg/branched.repo"
run 0 "adopt branched.repo -> 0" folder adopt "$WORK/branched"
( cd "$WORK/branched" && git checkout -q -b somewhere.else )
fv 8 "branch drift -> 8" "$WORK/branched"
check "22: origin Failed" "$( [ "$(st origin)" = "Failed" ] && echo 1 || echo 0 )"
check "22: origin code 8" "$( [ "$(cd_ origin)" = "8" ] && echo 1 || echo 0 )"
check "reason names both branches" \
    "$( echo "$LAST_OUT" | jq -e '.origin.description | test("somewhere.else") and test("main")' >/dev/null && echo 1 || echo 0 )"
( cd "$WORK/branched" && git checkout -q main )
fv 0 "back on the recorded branch -> 0" "$WORK/branched"

echo "=== untracked folder ==="
mkdir -p "$WORK/untracked"
( cd "$WORK/untracked" && git init -q && git remote add origin "https://github.com/x/y" )
fv 5 "untracked git repo -> 5" "$WORK/untracked"
check "location Ok" "$( [ "$(st location)" = "Ok" ] && echo 1 || echo 0 )"
check "tracking Failed" "$( [ "$(st tracking)" = "Failed" ] && echo 1 || echo 0 )"
check "tracking code 5" "$( [ "$(cd_ tracking)" = "5" ] && echo 1 || echo 0 )"
check "worktree Ok (a real git repo, just unknown to us)" "$( [ "$(st worktree)" = "Ok" ] && echo 1 || echo 0 )"
check "origin Skipped (nothing to compare against)" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"

echo "=== nonexistent and untracked at once ==="
fv 5 "missing + untracked -> 5" "$WORK/never-existed"
check "location Failed" "$( [ "$(st location)" = "Failed" ] && echo 1 || echo 0 )"
check "tracking Failed" "$( [ "$(st tracking)" = "Failed" ] && echo 1 || echo 0 )"
check "origin Skipped" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"

echo "=== a tracked location that stopped being a git repo must NOT pass ==="
# Unchanged in intent, moved in mechanism. Before fix 50-04 `origin` had to
# report this itself, because nothing else would; `worktree` reports it now,
# so origin Skips rather than counting the same fault a second time.
mk_adopted derotted "https://github.com/myorg/derotted.repo"
run 0 "adopt derotted.repo -> 0" folder adopt "$WORK/derotted"
rm -rf "$WORK/derotted/.git"
fv 6 "tracked folder, .git removed -> 6" "$WORK/derotted"
check "location Ok (the folder is still there)" "$( [ "$(st location)" = "Ok" ] && echo 1 || echo 0 )"
check "tracking Ok" "$( [ "$(st tracking)" = "Ok" ] && echo 1 || echo 0 )"
check "worktree Failed" "$( [ "$(st worktree)" = "Failed" ] && echo 1 || echo 0 )"
check "worktree code 6 (not a git work tree)" "$( [ "$(cd_ worktree)" = "6" ] && echo 1 || echo 0 )"
check "origin Skipped, since worktree already explains it" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"

echo "=== tracked repo whose origin remote was removed ==="
mk_adopted noremote "https://github.com/myorg/noremote.repo"
run 0 "adopt noremote.repo -> 0" folder adopt "$WORK/noremote"
( cd "$WORK/noremote" && git remote remove origin )
fv 8 "origin remote removed -> 8" "$WORK/noremote"
check "origin Failed" "$( [ "$(st origin)" = "Failed" ] && echo 1 || echo 0 )"
check "reason says there is no origin remote" \
    "$( echo "$LAST_OUT" | jq -e '.origin.description | test("no .origin. remote")' >/dev/null && echo 1 || echo 0 )"

echo "=== record with no origin field is the record's problem, not the folder's ==="
store_patch 'del(.repositories["healthy.repo"].origin)'
fv 0 "record missing origin -> 0" "$WORK/healthy"
check "origin Skipped" "$( [ "$(st origin)" = "Skipped" ] && echo 1 || echo 0 )"
check "reason blames the record" \
    "$( echo "$LAST_OUT" | jq -e '.origin.description | test("Record has no origin")' >/dev/null && echo 1 || echo 0 )"

echo "=== output shape and plumbing ==="
fv 0 "json keys" "$WORK/branched"
check "exactly four checks, in check order" "$( [ "$(echo "$LAST_OUT" | jq -r 'keys_unsorted | join(",")')" = "location,worktree,tracking,origin" ] && echo 1 || echo 0 )"
run 0 "--output-format yaml -> 0" folder validate "$WORK/branched" --output-format yaml
YML="$LAST_OUT"
run 0 "--output-format text -> 0" folder validate "$WORK/branched" --output-format text
check "yaml == text" "$( [ "$YML" = "$LAST_OUT" ] && echo 1 || echo 0 )"
run 2 "invalid --output-format -> 2" folder validate "$WORK/branched" --output-format xml
run 2 "two positionals -> 2" folder validate "$WORK/branched" "$WORK/healthy"
run 2 "unknown flag -> 2" folder validate --bogus
run 2 "no --fix switch exists -> 2" folder validate "$WORK/branched" --fix
run 0 "folder validate -h -> 0" folder validate -h
check "help mentions the command" "$( echo "$LAST_OUT" | grep -q 'git-utils folder validate' && echo 1 || echo 0 )"
run 0 "main help lists it" -h
check "main help mentions it" "$( echo "$LAST_OUT" | grep -q 'git-utils folder validate' && echo 1 || echo 0 )"

echo "=== store-format gate applies ==="
cp "$(store)" "$WORK/store.good"
echo '{"my-repo":{"name":"n","org":"o","branch":"main","locations":[]}}' > "$(store)"
run 90 "old-format store -> 90" folder validate "$WORK/healthy"
cp "$WORK/store.good" "$(store)"

gu_total
