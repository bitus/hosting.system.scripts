#!/usr/bin/env bash
# Fix 50-04 Phase 6: `folder update`. Spec cases 30-38.
#
# The load-bearing case is DIVERGED. `git status -uno | grep behind` -- the
# obvious implementation -- reports nothing to do for a diverged branch,
# because git says "have diverged" with no "behind" in it. That is precisely
# the checkout `reset --hard` exists to repair, so the wrong implementation
# fails silently and forever on exactly the case that matters. The locale case
# is the same bug from the other direction: git status is translated.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-fupdate
git_global_setup

st()   { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
code() { printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }
head_of() { git -C "$1" rev-parse HEAD; }

echo "=== fixtures ==="
make_repo 1 fu1 fuorg furepo
echo one > "$WORK/seed1/f"; push_seed 1
run 0 "add fu1" repo add fuorg/furepo/main -n fu1
run 0 "clone fu1" repo clone fu1 "$WORK/co"

# a second clone of the same bare repo, used to publish commits behind the
# checkout's back
git clone -q "$WORK/bare1.git" "$WORK/other"
( cd "$WORK/other" && git config user.email t@t && git config user.name t )

publish() {   # publish <text> -- add a commit to the remote
    echo "$1" >> "$WORK/other/f"
    ( cd "$WORK/other" && git add -A && git commit -qm "$1" && git push -q origin main )
}

echo "=== 30: behind by one commit ==="
publish two
BEFORE="$(head_of "$WORK/co")"
run 0 "update a behind checkout -> 0" folder update --output-format json "$WORK/co"
check "status Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"
check "HEAD moved" "$( [ "$(head_of "$WORK/co")" != "$BEFORE" ] && echo 1 || echo 0 )"
check "the new content arrived" "$( grep -q two "$WORK/co/f" && echo 1 || echo 0 )"
check "the description says how many commits" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q '1 commit' && echo 1 || echo 0 )"

echo "=== 31: already up to date -> 22 ==="
BEFORE="$(head_of "$WORK/co")"
run 22 "up to date -> 22" folder update --output-format json "$WORK/co"
check "HEAD unchanged" "$( [ "$(head_of "$WORK/co")" = "$BEFORE" ] && echo 1 || echo 0 )"
# 22 is a success in the everyday sense, so the status must not read as failure
check "status is Skipped, not Failed" "$( [ "$(st)" = "Skipped" ] && echo 1 || echo 0 )"
check "code is 22" "$( [ "$(code)" = "22" ] && echo 1 || echo 0 )"

echo "=== 32: DIVERGED -- the case grep 'behind' gets wrong ==="
publish three
echo local-only >> "$WORK/co/f"
( cd "$WORK/co" && git add -A && git commit -qm "local commit" )
# git cannot report divergence until it has seen the remote commit, and
# folder update fetches internally -- so the fixture check must fetch too,
# or it would be asserting 'ahead by 1' and proving nothing.
( cd "$WORK/co" && git fetch -q origin )
# prove the fixture really is diverged, so the assertion below means something
check "fixture: git status says diverged, not behind" \
    "$( ( cd "$WORK/co" && git status -uno ) | grep -q 'diverged' && echo 1 || echo 0 )"
check "fixture: the word 'behind' does not appear" \
    "$( ( cd "$WORK/co" && git status -uno ) | grep -q 'behind' && echo 0 || echo 1 )"
run 0 "diverged checkout is updated -> 0" folder update --output-format json "$WORK/co"
check "the local commit was discarded" \
    "$( grep -q local-only "$WORK/co/f" && echo 0 || echo 1 )"
check "the remote commit arrived" "$( grep -q three "$WORK/co/f" && echo 1 || echo 0 )"

echo "=== 33: a non-English locale must not change the answer ==="
if locale -a 2>/dev/null | grep -qi '^fr_FR\.utf-\?8$'; then
    publish four
    # the guard: assert the locale actually takes effect, or the test proves
    # nothing at all
    FR="$(cd "$WORK/co" && LC_ALL=fr_FR.UTF-8 git status -uno 2>/dev/null | head -2)"
    if printf '%s' "$FR" | grep -qi 'branche\|retard'; then
        out="$(cd "$WORK" && LC_ALL=fr_FR.UTF-8 bash "$GU" folder update "$WORK/co" </dev/null 2>/dev/null)"
        code=$?
        check "updates under fr_FR -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
        check "the content arrived" "$( grep -q four "$WORK/co/f" && echo 1 || echo 0 )"
    else
        skip "locale-independence of the behind check" "fr_FR.UTF-8 present but git is not translated"
    fi
else
    skip "locale-independence of the behind check" "fr_FR.UTF-8 not generated on this host"
fi

echo "=== 34: --dry-run ==="
publish five
BEFORE="$(head_of "$WORK/co")"
run 0 "dry run when behind -> 0" folder update --dry-run --output-format json "$WORK/co"
check "HEAD did NOT move" "$( [ "$(head_of "$WORK/co")" = "$BEFORE" ] && echo 1 || echo 0 )"
check "working tree untouched" "$( grep -q five "$WORK/co/f" && echo 0 || echo 1 )"
check "status Ok with the count" \
    "$( [ "$(st)" = "Ok" ] && printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -q 'available' && echo 1 || echo 0 )"

run 0 "the real update then applies it" folder update "$WORK/co"
run 22 "dry run when up to date -> 22" folder update --dry-run --output-format json "$WORK/co"
check "still Skipped" "$( [ "$(st)" = "Skipped" ] && echo 1 || echo 0 )"

echo "=== 35: git failures -> 10 ==="
# The fixture has to break the REMOTE while leaving the URL matching the
# record. Repointing origin at a bad URL instead makes folder validate fail
# its origin check (8) and the fetch never happens -- correct behaviour, but
# it tests the wrong thing. Moving the bare repo away leaves everything
# consistent and only the network unreachable.
make_repo 2 fu2 fuorg2 furepo2
echo one > "$WORK/seed2/f"; push_seed 2
run 0 "add fu2" repo add fuorg2/furepo2/main -n fu2
run 0 "clone fu2" repo clone fu2 "$WORK/broken"
mv "$WORK/bare2.git" "$WORK/bare2.gone"
run 10 "unreachable remote -> 10" folder update --output-format json "$WORK/broken"
check "status Failed" "$( [ "$(st)" = "Failed" ] && echo 1 || echo 0 )"
check "the reason names fetch" \
    "$( printf '%s' "$LAST_OUT" | jq -r '.status.description' | grep -qi 'fetch' && echo 1 || echo 0 )"
mv "$WORK/bare2.gone" "$WORK/bare2.git"
run 22 "and it recovers once the remote is back -> 22" folder update "$WORK/broken"

echo "=== 36: a folder that does not validate is never reset ==="
mkdir -p "$WORK/plain"
run 6 "non-git folder -> 6" folder update "$WORK/plain"
check "no fetch was attempted" "$( [ ! -e "$WORK/plain/.git" ] && echo 1 || echo 0 )"

( cd "$WORK" && git init -q untracked && cd untracked && git config user.email t@t \
  && git config user.name t && echo a > f && git add f && git commit -qm a )
run 5 "untracked git repo -> 5" folder update "$WORK/untracked"
check "no FETCH_HEAD was created -- it stopped before fetching" \
    "$( [ ! -e "$WORK/untracked/.git/FETCH_HEAD" ] && echo 1 || echo 0 )"
run 5 "missing folder -> 5" folder update "$WORK/nosuch"

echo "=== 37: the document is the product, git's chatter is not ==="
publish six
run 0 "update with plain output" folder update "$WORK/co"
check "stdout parses as the folded document" \
    "$( printf '%s' "$LAST_OUT" | grep -q '^status: ' && echo 1 || echo 0 )"
check "no 'HEAD is now at' on stdout" \
    "$( printf '%s' "$LAST_OUT" | grep -q 'HEAD is now at' && echo 0 || echo 1 )"
publish seven
run 0 "update with json output" folder update --output-format json "$WORK/co"
check "stdout is valid json" \
    "$( printf '%s' "$LAST_OUT" | jq empty >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 38: cwd, the alias, and arguments ==="
publish eight
out="$(cd "$WORK/co" && bash "$GU" folder update </dev/null 2>/dev/null)"; code=$?
check "no argument uses cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "it really updated" "$( grep -q eight "$WORK/co/f" && echo 1 || echo 0 )"

publish nine
out="$(cd "$WORK/co" && bash "$GU" update </dev/null 2>/dev/null)"; code=$?
check "git-utils update is folder update now -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
# The alias used to be repo update, where `fu1` is a valid repo key. To
# folder update a bare token is a relative PATH, so it resolves to a folder
# that does not exist and fails the location check. Exit 5 rather than 0 is
# what proves the alias moved.
run 5 "a repo key is read as a path by the alias -> 5" update fu1

run 2 "two positionals -> 2" folder update "$WORK/co" "$WORK/other"
run 2 "unknown flag -> 2" folder update --bogus
run 0 "folder update -h -> 0" folder update -h
check "help warns that local work is discarded" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'discard' && echo 1 || echo 0 )"

echo "=== repo update still routes to the repo command ==="
run 2 "repo update <path> is still an argument error" repo update "$WORK/co"

gu_total
