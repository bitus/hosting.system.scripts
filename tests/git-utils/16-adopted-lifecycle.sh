#!/usr/bin/env bash
# Fix 50-02 Phase 11: the existing commands under the new schema.
# Spec cases 39-41, plus repo add's new fields and repo keys skipping
# keyless records.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-lifecycle
git_global_setup
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

echo "=== repo add writes the new fields ==="
run 0 "repo add managed.repo -> 0" repo add manorg/managed.repo/main
check "visibility private" "$( [ "$(rec_field managed.repo visibility)" = "private" ] && echo 1 || echo 0 )"
check "foreign false" "$( [ "$(rec_field managed.repo foreign)" = "false" ] && echo 1 || echo 0 )"
check "origin composed from the convention" \
    "$( [ "$(rec_field managed.repo origin)" = "git@managed.repo.repo:manorg/managed.repo.git" ] && echo 1 || echo 0 )"
check "date_created set" "$( rec_field managed.repo date_created | grep -q '^[0-9]\{4\}-' && echo 1 || echo 0 )"
check "date_updated set" "$( rec_field managed.repo date_updated | grep -q '^[0-9]\{4\}-' && echo 1 || echo 0 )"
check "locations empty" "$( [ "$(loc_count managed.repo)" = "0" ] && echo 1 || echo 0 )"
check "images empty" "$( [ "$(images_of managed.repo)" = "[]" ] && echo 1 || echo 0 )"
run 0 "a freshly added record validates clean" repo validate managed.repo --output-format json
check "fields Ok straight after repo add" \
    "$( echo "$LAST_OUT" | jq -e '.checks.fields.status == "Ok"' >/dev/null && echo 1 || echo 0 )"
check "health Warning (never cloned)" \
    "$( echo "$LAST_OUT" | jq -e '.checks.health.status == "Warning"' >/dev/null && echo 1 || echo 0 )"

echo "=== repo clone uses the stored origin ==="
git init --bare "$WORK/managed.git" -q
git config --global "url.$WORK/managed.git.insteadOf" "git@managed.repo.repo:manorg/managed.repo.git"
mkdir -p "$WORK/seedm"
( cd "$WORK/seedm" && git init -q && echo hi > f.txt && git add f.txt && git commit -qm one \
    && git remote add origin "$WORK/managed.git" && git push -q origin main )
run 0 "clone a repo-add repo -> 0" repo clone managed.repo "$WORK/managedwork"
check "clone landed" "$( [ -f "$WORK/managedwork/f.txt" ] && echo 1 || echo 0 )"

echo "--- 39: cloning an ADOPTED foreign repo goes through its own origin ---"
# a repo git-utils never made: its own alias, its own key, its own bare origin
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/foreign.key"
cat >> "$HOME/.ssh/config" << EOF

Host foreign.alias
    IdentityFile ~/.ssh/foreign.key
EOF
git init --bare "$WORK/foreign.git" -q
git config --global "url.$WORK/foreign.git.insteadOf" "git@foreign.alias:otherorg/foreign.repo.git"
mkdir -p "$WORK/foreignwork"
( cd "$WORK/foreignwork" && git init -q \
    && git remote add origin "git@foreign.alias:otherorg/foreign.repo.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one && git push -q origin main )
run 0 "adopt foreign.repo -> 0" folder adopt "$WORK/foreignwork"
check "recorded as foreign" "$( [ "$(rec_field foreign.repo foreign)" = "true" ] && echo 1 || echo 0 )"
check "origin kept verbatim" \
    "$( [ "$(rec_field foreign.repo origin)" = "git@foreign.alias:otherorg/foreign.repo.git" ] && echo 1 || echo 0 )"
run 0 "39: clone the adopted foreign repo -> 0" repo clone foreign.repo "$WORK/foreignclone"
check "39: clone succeeded via the stored alias" "$( [ -f "$WORK/foreignclone/f.txt" ] && echo 1 || echo 0 )"
check "39: the clone's own origin is the alias, not <id>.repo" \
    "$( [ "$(cd "$WORK/foreignclone" && git config --get remote.origin.url)" = "git@foreign.alias:otherorg/foreign.repo.git" ] && echo 1 || echo 0 )"
check "39: a composed URL would have been wrong" \
    "$( [ "git@foreign.repo.repo:otherorg/foreign.repo.git" != "$(rec_field foreign.repo origin)" ] && echo 1 || echo 0 )"

echo "--- a public repo clones over https ---"
git init --bare "$WORK/public.git" -q
git config --global "url.$WORK/public.git.insteadOf" "https://github.com/puborg/public.repo"
mkdir -p "$WORK/publicwork"
( cd "$WORK/publicwork" && git init -q \
    && git remote add origin "https://github.com/puborg/public.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one && git push -q origin main )
run 0 "adopt public.repo -> 0" folder adopt "$WORK/publicwork"
run 0 "clone the public repo -> 0" repo clone public.repo "$WORK/publicclone"
check "public clone landed" "$( [ -f "$WORK/publicclone/f.txt" ] && echo 1 || echo 0 )"

echo "=== repo keys skips records with no private_key ==="
run 0 "repo keys -> 0" repo keys
check "managed repo listed" "$( echo "$LAST_OUT" | grep -q 'managed.repo.key' && echo 1 || echo 0 )"
check "foreign private repo listed" "$( echo "$LAST_OUT" | grep -q 'foreign.key' && echo 1 || echo 0 )"
check "public repo NOT listed" "$( echo "$LAST_OUT" | grep -q 'public.repo' && echo 0 || echo 1 )"
check "no blank first column anywhere" \
    "$( echo "$LAST_OUT" | grep -q '^ ' && echo 0 || echo 1 )"
run 0 "repo list still lists all three -> 0" repo list
check "repo list includes the public repo" "$( echo "$LAST_OUT" | grep -q 'public.repo' && echo 1 || echo 0 )"

echo "=== 40: deleting an adopted FOREIGN repo leaves its key material alone ==="
FKEY="$(rec_field foreign.repo private_key)"
cp "$HOME/.ssh/config" "$WORK/cfg.before"
check "40: its key exists beforehand" "$( [ -f "$FKEY" ] && echo 1 || echo 0 )"
run 0 "40: delete foreign.repo -> 0" repo delete foreign.repo
check "40: record gone" "$( rec_exists foreign.repo && echo 0 || echo 1 )"
check "40: private key untouched" "$( [ -f "$FKEY" ] && echo 1 || echo 0 )"
check "40: public key untouched" "$( [ -f "${FKEY}.pub" ] && echo 1 || echo 0 )"
check "40: ~/.ssh/config byte-identical" "$( cmp -s "$WORK/cfg.before" "$HOME/.ssh/config" && echo 1 || echo 0 )"

echo "--- deleting a public repo touches no keys and needs no ~/.ssh access ---"
cp "$HOME/.ssh/config" "$WORK/cfg.before2"
chmod 555 "$HOME/.ssh"
run 0 "delete public.repo with ~/.ssh read-only -> 0" repo delete public.repo
chmod 755 "$HOME/.ssh"
check "record gone" "$( rec_exists public.repo && echo 0 || echo 1 )"
check "~/.ssh/config byte-identical" "$( cmp -s "$WORK/cfg.before2" "$HOME/.ssh/config" && echo 1 || echo 0 )"

echo "=== 41: an adopted repo detected as NON-foreign is cleaned up ==="
# repo add makes it, its record is lost, adoption recovers it as foreign=false
run 0 "repo add recovered.repo -> 0" repo add recorg/recovered.repo/main
RKEY="$(rec_field recovered.repo private_key)"
git init --bare "$WORK/recovered.git" -q
git config --global "url.$WORK/recovered.git.insteadOf" "git@recovered.repo.repo:recorg/recovered.repo.git"
mkdir -p "$WORK/recwork"
( cd "$WORK/recwork" && git init -q \
    && git remote add origin "git@recovered.repo.repo:recorg/recovered.repo.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
store_patch 'del(.repositories["recovered.repo"])'
run 0 "re-adopt it -> 0" folder adopt "$WORK/recwork"
check "41: recovered as foreign=false" "$( [ "$(rec_field recovered.repo foreign)" = "false" ] && echo 1 || echo 0 )"
check "41: sentinel block still present" \
    "$( grep -q 'git-utils recovered.repo' "$HOME/.ssh/config" && echo 1 || echo 0 )"
run 0 "41: delete it -> 0" repo delete recovered.repo
check "41: key removed" "$( [ -f "$RKEY" ] && echo 0 || echo 1 )"
check "41: public key removed" "$( [ -f "${RKEY}.pub" ] && echo 0 || echo 1 )"
check "41: sentinel block removed" \
    "$( grep -q 'git-utils recovered.repo' "$HOME/.ssh/config" && echo 0 || echo 1 )"
check "41: the unrelated foreign key survived it all" "$( [ -f "$FKEY" ] && echo 1 || echo 0 )"

echo "=== a record with no origin still clones, with a warning ==="
store_patch 'del(.repositories["managed.repo"].origin)'
run 0 "clone without a stored origin -> 0" repo clone managed.repo "$WORK/fallbackclone"
check "warned about the missing origin" \
    "$( echo "$LAST_ERR" | grep -q 'has no origin' && echo 1 || echo 0 )"
check "pointed at repo validate --fix" \
    "$( echo "$LAST_ERR" | grep -q 'repo validate' && echo 1 || echo 0 )"
check "fell back to the composed URL and cloned" \
    "$( [ -f "$WORK/fallbackclone/f.txt" ] && echo 1 || echo 0 )"

echo "=== validate notices the origin we removed, and --fix restores it ==="
run 1 "validate reports the gap -> 1" validate --output-format json
check "database Ok (the layout is fine)" \
    "$( echo "$LAST_OUT" | jq -e '.database.status == "Ok"' >/dev/null && echo 1 || echo 0 )"
check "managed.repo is the one flagged" \
    "$( echo "$LAST_OUT" | jq -e '.repositories[] | select(.id == "managed.repo") | .checks.fields.status == "Failed"' >/dev/null && echo 1 || echo 0 )"

run 0 "validate --fix repairs it -> 0" validate --fix --output-format json
check "origin backfilled from a surviving clone" \
    "$( [ "$(rec_field managed.repo origin)" = "git@managed.repo.repo:manorg/managed.repo.git" ] && echo 1 || echo 0 )"
check "every repo now Ok or Warning" \
    "$( echo "$LAST_OUT" | jq -e 'all(.repositories[]; .checks.health.status == "Ok" or .checks.health.status == "Warning")' >/dev/null && echo 1 || echo 0 )"
run 0 "and a plain validate is clean afterwards -> 0" validate

gu_total
