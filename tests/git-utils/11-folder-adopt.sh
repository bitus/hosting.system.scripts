#!/usr/bin/env bash
# Fix 50-02 Phase 6: `folder adopt`. Spec cases 23-34, 37, 38.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-folder-adopt
git_global_setup
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

# A repo that git-utils never created: its own bare origin, its own Host alias
# and key pair, written by hand.
ssh-keygen -q -t ed25519 -N '' -C 'hand-made' -f "$HOME/.ssh/sites.hand.key"
cat > "$HOME/.ssh/config" << EOF
Host sites.mysite.com.github.site
    HostName github.com
    IdentityFile ~/.ssh/sites.hand.key
EOF
chmod 600 "$HOME/.ssh/config"

# private fixture: a real working copy whose origin is the ssh alias, pushed
# through insteadOf so the bare repo has content for the second checkout later
git init --bare "$WORK/priv.git" -q
git config --global "url.$WORK/priv.git.insteadOf" "git@sites.mysite.com.github.site:myorg/sites.mysite.com.git"
mkdir -p "$WORK/privwork"
( cd "$WORK/privwork" && git init -q \
    && git remote add origin "git@sites.mysite.com.github.site:myorg/sites.mysite.com.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one \
    && git push -q origin main )

# public fixture
mkdir -p "$WORK/pubwork"
( cd "$WORK/pubwork" && git init -q \
    && git remote add origin "https://github.com/myorg/hosting.system.scripts" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )

echo "=== 23: private repo with a discoverable key pair ==="
run 0 "adopt private -> 0" folder adopt "$WORK/privwork"
run 0 "repo info -> 0" repo info sites.mysite.com --output-format json
REC="$LAST_OUT"
check "record keyed by the parsed name" "$( echo "$REC" | jq -e '.id == "sites.mysite.com"' >/dev/null && echo 1 || echo 0 )"
check "org parsed" "$( echo "$REC" | jq -e '.org == "myorg"' >/dev/null && echo 1 || echo 0 )"
check "name parsed" "$( echo "$REC" | jq -e '.name == "sites.mysite.com"' >/dev/null && echo 1 || echo 0 )"
check "branch from the checkout" "$( echo "$REC" | jq -e '.branch == "main"' >/dev/null && echo 1 || echo 0 )"
check "visibility private" "$( echo "$REC" | jq -e '.visibility == "private"' >/dev/null && echo 1 || echo 0 )"
check "foreign true" "$( echo "$REC" | jq -e '.foreign == true' >/dev/null && echo 1 || echo 0 )"
check "origin stored verbatim" \
    "$( echo "$REC" | jq -e '.origin == "git@sites.mysite.com.github.site:myorg/sites.mysite.com.git"' >/dev/null && echo 1 || echo 0 )"
check "private_key points at the hand-made key" \
    "$( echo "$REC" | jq -e --arg p "$HOME/.ssh/sites.hand.key" '.private_key == $p' >/dev/null && echo 1 || echo 0 )"
check "public_key derived" \
    "$( echo "$REC" | jq -e --arg p "$HOME/.ssh/sites.hand.key.pub" '.public_key == $p' >/dev/null && echo 1 || echo 0 )"
check "location recorded" \
    "$( echo "$REC" | jq -e --arg p "$WORK/privwork" '.locations[0].path == $p' >/dev/null && echo 1 || echo 0 )"
check "images collected" "$( echo "$REC" | jq -e '.images | type == "array"' >/dev/null && echo 1 || echo 0 )"
check "date_created set" "$( echo "$REC" | jq -e '.date_created | test("^[0-9]{4}-")' >/dev/null && echo 1 || echo 0 )"
check "date_updated set" "$( echo "$REC" | jq -e '.date_updated | test("^[0-9]{4}-")' >/dev/null && echo 1 || echo 0 )"

echo "=== 24: public https repo ==="
run 0 "adopt public -> 0" folder adopt "$WORK/pubwork"
run 0 "repo info -> 0" repo info hosting.system.scripts --output-format json
PREC="$LAST_OUT"
check "visibility public" "$( echo "$PREC" | jq -e '.visibility == "public"' >/dev/null && echo 1 || echo 0 )"
check "foreign true" "$( echo "$PREC" | jq -e '.foreign == true' >/dev/null && echo 1 || echo 0 )"
check "private_key absent (not empty)" "$( echo "$PREC" | jq -e 'has("private_key")' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "public_key absent" "$( echo "$PREC" | jq -e 'has("public_key")' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "origin is the https url" \
    "$( echo "$PREC" | jq -e '.origin == "https://github.com/myorg/hosting.system.scripts"' >/dev/null && echo 1 || echo 0 )"

echo "=== 27/28: same folder again ==="
run 0 "adopt the same folder twice -> 0 no-op" folder adopt "$WORK/privwork"
check "message says already tracked" "$( echo "$LAST_OUT" | grep -qi 'already tracked' && echo 1 || echo 0 )"
check "still exactly one location" "$( [ "$(loc_count sites.mysite.com)" = "1" ] && echo 1 || echo 0 )"
run 8 "same folder with a different -n -> 8" folder adopt "$WORK/privwork" -n other.id

echo "=== 26: -n supplies a custom id ==="
mkdir -p "$WORK/customwork"
( cd "$WORK/customwork" && git init -q \
    && git remote add origin "https://github.com/myorg/custom.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 0 "adopt with -n -> 0" folder adopt "$WORK/customwork" -n my.custom.id
check "record keyed by the -n value" "$( rec_exists my.custom.id && echo 1 || echo 0 )"
check "name still comes from the origin" \
    "$( [ "$(rec_field my.custom.id name)" = "custom.repo" ] && echo 1 || echo 0 )"
run 0 "--name= equals form -> 0" folder adopt "$WORK/customwork" --name=my.custom.id

echo "=== 29/30: a second checkout of an already-adopted repo ==="
git clone -q "$WORK/priv.git" "$WORK/privwork2" 2>/dev/null
( cd "$WORK/privwork2" && git remote set-url origin "git@sites.mysite.com.github.site:myorg/sites.mysite.com.git" )
# 30: remove the ssh config entry first -- the append path must not need keys
mv "$HOME/.ssh/config" "$WORK/config.parked"
run 0 "second checkout adopts with no ssh config -> 0" folder adopt "$WORK/privwork2"
check "message says location added" "$( echo "$LAST_OUT" | grep -qi 'added location' && echo 1 || echo 0 )"
check "now two locations" "$( [ "$(loc_count sites.mysite.com)" = "2" ] && echo 1 || echo 0 )"
check "still one record" "$( [ "$(jq -r '.repositories | length' "$(store)")" = "3" ] && echo 1 || echo 0 )"
mv "$WORK/config.parked" "$HOME/.ssh/config"

echo "=== 31: existing id, different repo -> 8 ==="
mkdir -p "$WORK/impostor"
( cd "$WORK/impostor" && git init -q \
    && git remote add origin "https://github.com/otherorg/custom.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 8 "same id, different org -> 8" folder adopt "$WORK/impostor" -n my.custom.id
check "no location leaked into the existing record" \
    "$( [ "$(loc_count my.custom.id)" = "1" ] && echo 1 || echo 0 )"

mkdir -p "$WORK/branchdiff"
( cd "$WORK/branchdiff" && git init -q \
    && git remote add origin "https://github.com/myorg/custom.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one && git checkout -q -b other )
run 8 "same id and origin, different branch -> 8" folder adopt "$WORK/branchdiff" -n my.custom.id

echo "=== 32: folder problems ==="
run 5 "nonexistent folder -> 5" folder adopt "$WORK/no-such-folder"
mkdir -p "$WORK/plain"
run 6 "not a git repo -> 6" folder adopt "$WORK/plain"

echo "=== 33: detached HEAD -> 10 ==="
mkdir -p "$WORK/detached"
( cd "$WORK/detached" && git init -q \
    && git remote add origin "https://github.com/myorg/detached.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
SHA="$(cd "$WORK/detached" && git rev-parse HEAD)"
( cd "$WORK/detached" && git checkout -q "$SHA" )
run 10 "detached HEAD -> 10" folder adopt "$WORK/detached"
check "no record written" "$( rec_exists detached.repo && echo 0 || echo 1 )"

echo "=== 34: unusable origin -> 10 ==="
mkdir -p "$WORK/noremote"
( cd "$WORK/noremote" && git init -q && echo hi > f.txt && git add f.txt && git commit -qm one )
run 10 "no origin remote -> 10" folder adopt "$WORK/noremote"
( cd "$WORK/noremote" && git remote add origin "ssh://git@host/org/name.git" )
run 10 "unsupported origin form -> 10" folder adopt "$WORK/noremote"

echo "=== 37: private repo with no key pair on disk -> 3, no record ==="
mkdir -p "$WORK/nokeys"
( cd "$WORK/nokeys" && git init -q \
    && git remote add origin "git@absent.alias:myorg/nokeys.repo.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 3 "no Host block for the alias -> 3" folder adopt "$WORK/nokeys"
check "no record written" "$( rec_exists nokeys.repo && echo 0 || echo 1 )"
check "error names the config file" "$( echo "$LAST_ERR" | grep -q "$HOME/.ssh/config" && echo 1 || echo 0 )"

cat >> "$HOME/.ssh/config" << EOF

Host absent.alias
    IdentityFile ~/.ssh/never-generated.key
EOF
run 3 "Host block present but key file missing -> 3" folder adopt "$WORK/nokeys"
check "no record written" "$( rec_exists nokeys.repo && echo 0 || echo 1 )"

echo "=== 25: a repo that still has its git-utils sentinel block -> foreign false ==="
run 0 "repo add recovered.repo -> 0" repo add recoverorg/recovered.repo/main
KEYPATH="$(rec_field recovered.repo private_key)"
mkdir -p "$WORK/recovered"
( cd "$WORK/recovered" && git init -q \
    && git remote add origin "git@recovered.repo.repo:recoverorg/recovered.repo.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
# lose the record, keep the keys and the sentinel block
store_patch 'del(.repositories["recovered.repo"])'
check "record removed, key still on disk" \
    "$( ! rec_exists recovered.repo && [ -f "$KEYPATH" ] && echo 1 || echo 0 )"
run 0 "re-adopt it -> 0" folder adopt "$WORK/recovered"
check "25: recovered as foreign=false" \
    "$( [ "$(rec_field recovered.repo foreign)" = "false" ] && echo 1 || echo 0 )"
check "keys relinked from the sentinel block" \
    "$( [ "$(rec_field recovered.repo private_key)" = "$KEYPATH" ] && echo 1 || echo 0 )"

echo "=== 38: adopt never touches the repo or ~/.ssh/config ==="
cp "$HOME/.ssh/config" "$WORK/cfg.before"
cp "$WORK/pubwork/.git/config" "$WORK/gitcfg.before"
mkdir -p "$WORK/untouched"
( cd "$WORK/untouched" && git init -q \
    && git remote add origin "https://github.com/myorg/untouched.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
cp "$WORK/untouched/.git/config" "$WORK/newgitcfg.before"
run 0 "adopt untouched.repo -> 0" folder adopt "$WORK/untouched"
check "~/.ssh/config byte-identical" "$( cmp -s "$WORK/cfg.before" "$HOME/.ssh/config" && echo 1 || echo 0 )"
check "adopted repo's git config byte-identical" \
    "$( cmp -s "$WORK/newgitcfg.before" "$WORK/untouched/.git/config" && echo 1 || echo 0 )"
check "no key files created for a public repo" \
    "$( ls "$HOME/.ssh" | grep -q 'untouched' && echo 0 || echo 1 )"

echo "=== argument and flag handling ==="
run 2 "two positionals -> 2" folder adopt "$WORK/pubwork" "$WORK/privwork"
run 2 "unknown flag -> 2" folder adopt --bogus
run 2 "-n with no value -> 2" folder adopt "$WORK/pubwork" -n
run 2 "id too short -> 2" folder adopt "$WORK/pubwork" -n ab
run 2 "id bad charset -> 2" folder adopt "$WORK/pubwork" -n 'bad id!'
run 0 "folder adopt -h -> 0" folder adopt -h
check "help mentions the command" "$( echo "$LAST_OUT" | grep -q 'git-utils folder adopt' && echo 1 || echo 0 )"
run 0 "main help lists folder adopt" -h
check "main help mentions it" "$( echo "$LAST_OUT" | grep -q 'git-utils folder adopt' && echo 1 || echo 0 )"

echo "=== adopting from inside the folder (no argument) ==="
mkdir -p "$WORK/cwdwork"
( cd "$WORK/cwdwork" && git init -q \
    && git remote add origin "https://github.com/myorg/cwd.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
out="$(cd "$WORK/cwdwork" && bash "$GU" folder adopt </dev/null 2>"$WORK/err.log")"; code=$?
check "no-argument adopt uses cwd -> 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "record created for cwd.repo" "$( rec_exists cwd.repo && echo 1 || echo 0 )"

echo "=== adopted repo is visible to the rest of the tool ==="
run 0 "folder status on an adopted folder -> 0" folder status "$WORK/privwork"
check "reports Ok" "$( echo "$LAST_OUT" | grep -qx 'status: Ok' && echo 1 || echo 0 )"
run 0 "repo list includes adopted repos -> 0" repo list
check "list shows the adopted private repo" "$( echo "$LAST_OUT" | grep -q 'sites.mysite.com' && echo 1 || echo 0 )"

gu_total
