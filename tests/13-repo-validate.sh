#!/usr/bin/env bash
# Fix 50-02 Phase 8: `repo validate` without --fix.
# Spec cases 42-44, 50-56. The --fix path lands in phase 9, so --fix is not
# an accepted flag yet.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-repo-validate
git_global_setup
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

chk() { echo "$LAST_OUT" | jq -r ".checks.$1.status"; }
chkcode() { echo "$LAST_OUT" | jq -r ".checks.$1.code"; }

# --- fixtures --------------------------------------------------------------
# A foreign private repo, adopted (so the record is complete).
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/hand.key"
cat > "$HOME/.ssh/config" << EOF
Host hand.alias
    IdentityFile ~/.ssh/hand.key
EOF
chmod 600 "$HOME/.ssh/config"
mkdir -p "$WORK/privwork"
( cd "$WORK/privwork" && git init -q \
    && git remote add origin "git@hand.alias:myorg/priv.repo.git" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 0 "adopt priv.repo -> 0" folder adopt "$WORK/privwork"

# A public repo, adopted.
mkdir -p "$WORK/pubwork"
( cd "$WORK/pubwork" && git init -q \
    && git remote add origin "https://github.com/myorg/pub.repo" \
    && echo hi > f.txt && git add f.txt && git commit -qm one )
run 0 "adopt pub.repo -> 0" folder adopt "$WORK/pubwork"

echo "=== 42: healthy repo -> all applicable checks Ok, exit 0 ==="
run 0 "validate priv.repo -> 0" repo validate priv.repo --output-format json
check "fields Ok" "$( [ "$(chk fields)" = "Ok" ] && echo 1 || echo 0 )"
check "keys Ok" "$( [ "$(chk keys)" = "Ok" ] && echo 1 || echo 0 )"
check "health Ok" "$( [ "$(chk health)" = "Ok" ] && echo 1 || echo 0 )"
check "one location reported" \
    "$( [ "$(echo "$LAST_OUT" | jq -r '.checks.locations | length')" = "1" ] && echo 1 || echo 0 )"
check "that location is all Ok" \
    "$( echo "$LAST_OUT" | jq -e --arg p "$WORK/privwork" '.checks.locations[$p] | .location.status=="Ok" and .tracking.status=="Ok" and .origin.status=="Ok"' >/dev/null && echo 1 || echo 0 )"

echo "=== 53: a foreign private repo skips the ssh check but still checks keys ==="
check "record is foreign" "$( [ "$(rec_field priv.repo foreign)" = "true" ] && echo 1 || echo 0 )"
check "53: ssh Skipped" "$( [ "$(chk ssh)" = "Skipped" ] && echo 1 || echo 0 )"
check "53: keys still evaluated (Ok)" "$( [ "$(chk keys)" = "Ok" ] && echo 1 || echo 0 )"
check "skip reason mentions foreign" \
    "$( echo "$LAST_OUT" | jq -e '.checks.ssh.description | test("[Ff]oreign")' >/dev/null && echo 1 || echo 0 )"

echo "=== 52: a public repo skips both keys and ssh ==="
run 0 "validate pub.repo -> 0" repo validate pub.repo --output-format json
check "52: keys Skipped" "$( [ "$(chk keys)" = "Skipped" ] && echo 1 || echo 0 )"
check "52: ssh Skipped" "$( [ "$(chk ssh)" = "Skipped" ] && echo 1 || echo 0 )"
check "fields Ok" "$( [ "$(chk fields)" = "Ok" ] && echo 1 || echo 0 )"
check "health Ok" "$( [ "$(chk health)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== 54: output shape -- record and checks are distinct ==="
check "id first" "$( [ "$(echo "$LAST_OUT" | jq -r 'keys_unsorted[0]')" = "id" ] && echo 1 || echo 0 )"
check "checks last" "$( [ "$(echo "$LAST_OUT" | jq -r 'keys_unsorted[-1]')" = "checks" ] && echo 1 || echo 0 )"
check "54: record locations is still an ARRAY" \
    "$( echo "$LAST_OUT" | jq -e '.locations | type == "array"' >/dev/null && echo 1 || echo 0 )"
check "54: checks.locations is an OBJECT keyed by path" \
    "$( echo "$LAST_OUT" | jq -e '.checks.locations | type == "object"' >/dev/null && echo 1 || echo 0 )"
check "record fields survive intact" \
    "$( echo "$LAST_OUT" | jq -e '.org == "myorg" and .visibility == "public"' >/dev/null && echo 1 || echo 0 )"
check "the five checks are present in order" \
    "$( [ "$(echo "$LAST_OUT" | jq -r '.checks | keys_unsorted | join(",")')" = "fields,keys,ssh,locations,health" ] && echo 1 || echo 0 )"

echo "=== 43: record with no locations -> health Warning, exit 0 ==="
store_patch '.repositories["pub.repo"].locations = []'
run 0 "no locations -> exit 0" repo validate pub.repo --output-format json
check "43: health Warning" "$( [ "$(chk health)" = "Warning" ] && echo 1 || echo 0 )"
check "43: warning explains why" \
    "$( echo "$LAST_OUT" | jq -e '.checks.health.description == "Repository has no locations"' >/dev/null && echo 1 || echo 0 )"
check "checks.locations is empty" \
    "$( [ "$(echo "$LAST_OUT" | jq -r '.checks.locations | length')" = "0" ] && echo 1 || echo 0 )"
run 0 "default output shows the warning reason" repo validate pub.repo
check "folded warning carries its description" \
    "$( echo "$LAST_OUT" | grep -q 'health: Warning — Repository has no locations' && echo 1 || echo 0 )"
store_patch --argjson p "[{\"path\":\"$WORK/pubwork\"}]" '.repositories["pub.repo"].locations = $p' 2>/dev/null \
    || store_patch ".repositories[\"pub.repo\"].locations = [{\"path\":\"$WORK/pubwork\"}]"

echo "=== 44: missing fields, no --fix -> Failed 90, exit 1, record untouched ==="
BEFORE_MTIME="$(stat -c '%Y' "$(store)")"
store_patch 'del(.repositories["pub.repo"].origin) | del(.repositories["pub.repo"].date_created)'
sleep 1
run 1 "missing fields -> 1" repo validate pub.repo --output-format json
check "44: fields Failed" "$( [ "$(chk fields)" = "Failed" ] && echo 1 || echo 0 )"
check "44: fields code 90" "$( [ "$(chkcode fields)" = "90" ] && echo 1 || echo 0 )"
check "44: description names the missing fields" \
    "$( echo "$LAST_OUT" | jq -e '.checks.fields.description | test("origin") and test("date_created")' >/dev/null && echo 1 || echo 0 )"
check "health Failed" "$( [ "$(chk health)" = "Failed" ] && echo 1 || echo 0 )"
MTIME_AFTER_VALIDATE="$(stat -c '%Y' "$(store)")"
check "44: record not repaired (origin still absent)" \
    "$( [ "$(rec_has pub.repo origin)" = "false" ] && echo 1 || echo 0 )"

echo "=== 55: a no---fix run writes nothing at all ==="
sleep 1
run 1 "validate again -> 1" repo validate pub.repo
check "55: store mtime unchanged by validation" \
    "$( [ "$(stat -c '%Y' "$(store)")" = "$MTIME_AFTER_VALIDATE" ] && echo 1 || echo 0 )"
run 0 "validate the healthy repo too" repo validate priv.repo
check "55: still unchanged after a healthy run" \
    "$( [ "$(stat -c '%Y' "$(store)")" = "$MTIME_AFTER_VALIDATE" ] && echo 1 || echo 0 )"
# restore
store_patch ".repositories[\"pub.repo\"].origin = \"https://github.com/myorg/pub.repo\" | .repositories[\"pub.repo\"].date_created = \"2026-08-26T18:00:00Z\""

echo "=== present-but-falsy fields are not 'missing' ==="
check "foreign is present and false on a non-foreign record" "$( echo 1 )"
store_patch '.repositories["pub.repo"].foreign = false | .repositories["pub.repo"].images = []'
run 0 "foreign=false and images=[] validate clean" repo validate pub.repo --output-format json
check "fields Ok despite falsy values" "$( [ "$(chk fields)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== 50: private repo with its keys deleted ==="
KEY="$(rec_field priv.repo private_key)"
mv "$KEY" "$WORK/key.parked"
run 1 "keys missing -> 1" repo validate priv.repo --output-format json
check "50: keys Failed" "$( [ "$(chk keys)" = "Failed" ] && echo 1 || echo 0 )"
check "50: description names the missing file" \
    "$( echo "$LAST_OUT" | jq -e --arg p "$KEY" '.checks.keys.description | test("not found")' >/dev/null && echo 1 || echo 0 )"
check "health Failed" "$( [ "$(chk health)" = "Failed" ] && echo 1 || echo 0 )"
mv "$WORK/key.parked" "$KEY"
run 0 "keys restored -> 0" repo validate priv.repo

echo "=== 51: private NON-foreign repo missing its sentinel block ==="
run 0 "repo add managed.repo -> 0" repo add manorg/managed.repo/main
# repo add does not write visibility/foreign yet (phase 11), so set them here
store_patch '.repositories["managed.repo"].visibility = "private" | .repositories["managed.repo"].foreign = false'
run 1 "managed repo, block present but fields incomplete -> 1" repo validate managed.repo --output-format json
check "ssh Ok while the sentinel block exists" "$( [ "$(chk ssh)" = "Ok" ] && echo 1 || echo 0 )"
block_delete_manual() { grep -v 'managed.repo' "$HOME/.ssh/config" > "$WORK/cfg.tmp"; mv "$WORK/cfg.tmp" "$HOME/.ssh/config"; }
block_delete_manual
run 1 "sentinel block removed -> 1" repo validate managed.repo --output-format json
check "51: ssh Failed" "$( [ "$(chk ssh)" = "Failed" ] && echo 1 || echo 0 )"
check "51: description names the block" \
    "$( echo "$LAST_OUT" | jq -e '.checks.ssh.description | test("sentinel")' >/dev/null && echo 1 || echo 0 )"

echo "=== a failing location drags health down ==="
run 0 "adopt a second repo for the location test" folder adopt "$WORK/privwork" -n priv.repo 2>/dev/null || true
( cd "$WORK/privwork" && git remote set-url origin "https://github.com/elsewhere/moved" )
run 1 "location origin drift -> 1" repo validate priv.repo --output-format json
check "the location reports Failed" \
    "$( echo "$LAST_OUT" | jq -e --arg p "$WORK/privwork" '.checks.locations[$p].origin.status == "Failed"' >/dev/null && echo 1 || echo 0 )"
check "health Failed because of it" "$( [ "$(chk health)" = "Failed" ] && echo 1 || echo 0 )"
check "fields and keys still Ok" \
    "$( [ "$(chk fields)" = "Ok" ] && [ "$(chk keys)" = "Ok" ] && echo 1 || echo 0 )"
( cd "$WORK/privwork" && git remote set-url origin "git@hand.alias:myorg/priv.repo.git" )

echo "=== 56: argument handling ==="
run 2 "56: path argument -> 2" repo validate "$WORK/privwork"
check "message points at folder validate" "$( echo "$LAST_ERR" | grep -q 'folder validate' && echo 1 || echo 0 )"
run 2 "56: '.' is a path -> 2" repo validate .
run 2 "56: no argument -> 2" repo validate
check "no argument prints help" "$( echo "$LAST_OUT" | grep -q 'git-utils repo validate' && echo 1 || echo 0 )"
run 5 "unknown key -> 5" repo validate nosuchkey
run 0 "by full repo name -> 0" repo validate myorg/priv.repo/main --output-format json
check "full name resolves to the same record" \
    "$( echo "$LAST_OUT" | jq -e '.id == "priv.repo"' >/dev/null && echo 1 || echo 0 )"
run 2 "two positionals -> 2" repo validate priv.repo pub.repo
run 2 "unknown flag -> 2" repo validate priv.repo --bogus
run 0 "--fix is accepted (behaviour covered by 14-repo-validate-fix) -> 0" repo validate priv.repo --fix
run 0 "repo validate -h -> 0" repo validate -h
run 0 "repos validate alias -> 0" repos validate priv.repo
run 0 "main help lists repo validate" -h
check "main help mentions it" "$( echo "$LAST_OUT" | grep -q 'git-utils repo validate' && echo 1 || echo 0 )"

gu_total
