#!/usr/bin/env bash
# Fix 50-02 Phase 5: the adoption layer, driven directly — no command wires
# it up until phase 6. Spec cases 35, 36 (and the parsing groundwork for
# 23, 24, 30, 31).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-adopt-layer
git_global_setup

# parse <url> -- echoes "visibility host org name", or "FAIL"
parse() {
    gu_eval "if adopt_parse_origin '$1'; then
                 printf '%s %s %s %s\n' \"\$ORIGIN_VISIBILITY\" \"\$ORIGIN_HOST\" \"\$ORIGIN_ORG\" \"\$ORIGIN_NAME\"
             else printf 'FAIL\n'; fi" 2>/dev/null
}

echo "=== adopt_parse_origin: private (ssh alias) form ==="
check "worked example from the spec" \
    "$( [ "$(parse 'git@sites.mysite.com.github.site:myorg/sites.mysite.com.git')" \
        = "private sites.mysite.com.github.site myorg sites.mysite.com" ] && echo 1 || echo 0 )"
check "git-utils' own convention" \
    "$( [ "$(parse 'git@my-repo.repo:my_org/my.repo.name.git')" \
        = "private my-repo.repo my_org my.repo.name" ] && echo 1 || echo 0 )"
check "without the .git suffix" \
    "$( [ "$(parse 'git@host.alias:org/name')" = "private host.alias org name" ] && echo 1 || echo 0 )"
check "trailing slash tolerated" \
    "$( [ "$(parse 'git@host.alias:org/name.git/')" = "private host.alias org name" ] && echo 1 || echo 0 )"

echo "=== adopt_parse_origin: public (https) form ==="
check "https with .git" \
    "$( [ "$(parse 'https://github.com/myorg/hosting.system.scripts.git')" \
        = "public github.com myorg hosting.system.scripts" ] && echo 1 || echo 0 )"
check "https without .git" \
    "$( [ "$(parse 'https://github.com/myorg/hosting.system.scripts')" \
        = "public github.com myorg hosting.system.scripts" ] && echo 1 || echo 0 )"
check "https trailing slash" \
    "$( [ "$(parse 'https://github.com/myorg/repo/')" = "public github.com myorg repo" ] && echo 1 || echo 0 )"
check "non-github https host still parses" \
    "$( [ "$(parse 'https://gitlab.example.com/team/thing')" = "public gitlab.example.com team thing" ] && echo 1 || echo 0 )"

echo "=== adopt_parse_origin: unsupported forms are rejected ==="
for bad in \
    'ssh://git@host/org/name.git' \
    'http://github.com/org/name' \
    'git@host:org' \
    'git@host/org/name.git' \
    '/local/path/repo.git' \
    'file:///srv/git/repo.git' \
    'https://github.com/onlyorg' \
    'not a url at all' \
    ''
do
    check "rejected: '${bad:-<empty>}'" "$( [ "$(parse "$bad")" = "FAIL" ] && echo 1 || echo 0 )"
done
# nested groups cannot be represented by the record schema
check "rejected: gitlab subgroup (ssh)" \
    "$( [ "$(parse 'git@host:org/sub/name.git')" = "FAIL" ] && echo 1 || echo 0 )"
check "rejected: gitlab subgroup (https)" \
    "$( [ "$(parse 'https://gitlab.com/org/sub/name')" = "FAIL" ] && echo 1 || echo 0 )"

echo "=== adopt_current_branch ==="
mkdir -p "$WORK/repo"
( cd "$WORK/repo" && git init -q && echo x > f && git add f && git commit -qm one )
check "reports the checked-out branch" \
    "$( [ "$(gu_eval "adopt_current_branch '$WORK/repo'")" = "main" ] && echo 1 || echo 0 )"
( cd "$WORK/repo" && git checkout -q -b feature.x )
check "reports a non-default branch" \
    "$( [ "$(gu_eval "adopt_current_branch '$WORK/repo'")" = "feature.x" ] && echo 1 || echo 0 )"

echo "--- detached HEAD: prints nothing and exits 0, so it must be caught ---"
SHA="$(cd "$WORK/repo" && git rev-parse HEAD)"
( cd "$WORK/repo" && git checkout -q "$SHA" )
raw="$(cd "$WORK/repo" && git branch --show-current)"; rawcode=$?
check "git itself exits 0 on detached HEAD" "$( [ "$rawcode" -eq 0 ] && echo 1 || echo 0 )"
check "git itself prints nothing" "$( [ -z "$raw" ] && echo 1 || echo 0 )"
gu_eval "adopt_current_branch '$WORK/repo'" >/dev/null 2>&1
check "adopt_current_branch fails on detached HEAD" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
( cd "$WORK/repo" && git checkout -q feature.x )

mkdir -p "$WORK/notarepo"
gu_eval "adopt_current_branch '$WORK/notarepo'" >/dev/null 2>&1
check "fails outside a git repo" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

echo "=== adopt_read_origin ==="
gu_eval "adopt_read_origin '$WORK/repo'" >/dev/null 2>&1
check "fails when there is no origin remote" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
( cd "$WORK/repo" && git remote add origin 'git@some.alias:org/name.git' )
check "reads the origin url" \
    "$( [ "$(gu_eval "adopt_read_origin '$WORK/repo'")" = "git@some.alias:org/name.git" ] && echo 1 || echo 0 )"
( cd "$WORK/repo" && git remote rename origin upstream )
gu_eval "adopt_read_origin '$WORK/repo'" >/dev/null 2>&1
check "a differently-named remote does not count" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

echo "=== 35/36: adopt_find_identity against hand-written config ==="
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
cat > "$HOME/.ssh/config" << EOF
# a hand-maintained config

Host plain.alias
    HostName github.com
    IdentityFile $HOME/.ssh/plain.key

host lower.alias
    hostname github.com
    identityfile ~/.ssh/lower.key

Host first.alias second.alias third.alias
    IdentityFile ~/.ssh/multi.key

Host wild.* *.wild
    IdentityFile ~/.ssh/wildcard.key

Host commented.alias
    IdentityFile ~/.ssh/commented.key   # trailing comment

Host nokey.alias
    HostName github.com

Match host something
    IdentityFile ~/.ssh/matchblock.key

Host after.match
    IdentityFile ~/.ssh/after.key
EOF
chmod 600 "$HOME/.ssh/config"

find_id() { gu_eval "adopt_find_identity '$1'" 2>/dev/null; }

check "absolute IdentityFile" "$( [ "$(find_id plain.alias)" = "$HOME/.ssh/plain.key" ] && echo 1 || echo 0 )"
check "35: leading ~/ expanded to \$HOME" "$( [ "$(find_id lower.alias)" = "$HOME/.ssh/lower.key" ] && echo 1 || echo 0 )"
check "36: lowercase host/identityfile keywords" "$( [ -n "$(find_id lower.alias)" ] && echo 1 || echo 0 )"
for a in first.alias second.alias third.alias; do
    check "36: multi-alias Host line matches '$a'" \
        "$( [ "$(find_id "$a")" = "$HOME/.ssh/multi.key" ] && echo 1 || echo 0 )"
done
check "trailing comment stripped" "$( [ "$(find_id commented.alias)" = "$HOME/.ssh/commented.key" ] && echo 1 || echo 0 )"
check "block after a Match block still found" "$( [ "$(find_id after.match)" = "$HOME/.ssh/after.key" ] && echo 1 || echo 0 )"

find_id nokey.alias >/dev/null 2>&1
check "Host block with no IdentityFile fails" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
find_id absent.alias >/dev/null 2>&1
check "unknown alias fails" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

echo "--- a wildcard Host must not be mistaken for a specific alias ---"
find_id 'anything.wild' >/dev/null 2>&1
check "wild.* does not match anything.wild" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
check "the wildcard block is only found by its literal text" \
    "$( [ "$(find_id 'wild.*')" = "$HOME/.ssh/wildcard.key" ] && echo 1 || echo 0 )"

echo "--- Match ends the preceding block ---"
# matchblock.key sits under `Match host something`, so no Host alias owns it.
# (grep -q, NOT grep -rq: with -r and no file argument grep searches the
# working directory and finds the string in this very test file.)
LEAK="$(find_id nokey.alias; find_id after.match)"
check "no alias leaks the Match block's IdentityFile" \
    "$( printf '%s' "$LEAK" | grep -q matchblock && echo 0 || echo 1 )"

echo "--- absent config file ---"
mv "$HOME/.ssh/config" "$WORK/config.saved"
find_id plain.alias >/dev/null 2>&1
check "missing ~/.ssh/config fails cleanly" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
mv "$WORK/config.saved" "$HOME/.ssh/config"

echo "=== adopt_block_exists: the shared foreign test ==="
gu_eval "adopt_block_exists 'plain.alias'" >/dev/null 2>&1
check "a hand-written Host block is NOT a git-utils sentinel block" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

# `repo add` needs no remote, so no bare-repo fixture here
run 0 "add sentinel1 (writes a real sentinel block) -> 0" repo add testorg1/testrepo1/main -n sentinel1
gu_eval "adopt_block_exists 'sentinel1'" >/dev/null 2>&1
check "repo add's block IS detected" "$( [ $? -eq 0 ] && echo 1 || echo 0 )"
gu_eval "adopt_block_exists 'never-added'" >/dev/null 2>&1
check "an unknown id is not detected" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

run 0 "delete sentinel1 -> 0" repo delete sentinel1
gu_eval "adopt_block_exists 'sentinel1'" >/dev/null 2>&1
check "after repo delete the block is gone again" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

echo "--- a repo id that is a substring of another must not false-positive ---"
run 0 "add id 'abc' -> 0" repo add testorg2/testrepo2/main -n abc
gu_eval "adopt_block_exists 'ab'" >/dev/null 2>&1
check "'ab' does not match the 'abc' block" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

gu_total
