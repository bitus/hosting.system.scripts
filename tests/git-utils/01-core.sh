#!/usr/bin/env bash
# Core suite: routing, name validation, add/list/keys, clone argument paths,
# delete, ssh-config stability, corrupt store, setup.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-core
rm -f /usr/local/sbin/git-utils 2>/dev/null || true

echo "== routing =="
run 2 "bare invocation -> 2"
run 0 "-h -> 0" -h
run 2 "repo bare -> 2" repo
run 2 "repos bare -> 2" repos
run 0 "repo -h -> 0" repo -h

echo "== repo add validation =="
run 2 "2-char org -> 2" repo add ab/myrepo/main
run 2 "bad charset -> 2" repo add 'my org!/myrepo/main'
run 2 "4-segment name -> 2" repo add a/b/c/d
run 2 "1-segment no default org -> 2" repo add justname

echo "== repo add success + 1-char branch =="
run 0 "add with 1-char branch -> 0" repo add myorgxx/myrepo/v -n keyone
check "key file created" "$( [ -e "$HOME/.ssh/keyone.key" ] && echo 1 || echo 0 )"
check "ssh config block present" "$( grep -q 'Host keyone.repo' "$HOME/.ssh/config" && echo 1 || echo 0 )"
check "store is schema 1.1" "$( [ "$(jq -r '.schema' "$(store)")" = "1.1" ] && echo 1 || echo 0 )"

echo "== repo add duplicate key -> 4 =="
run 4 "duplicate key -> 4" repo add myorgxx/myrepo/v -n keyone

echo "== second repo, default key = name =="
run 0 "add my.repo -> 0" repo add myorg/my.repo/main

echo "== repo list / repos list / repo keys =="
run 0 "repo list -> 0" repo list
check "list line keyone" "$( echo "$LAST_OUT" | grep -q "keyone https://github.com/myorgxx/myrepo/v" && echo 1 || echo 0 )"
check "list line my.repo" "$( echo "$LAST_OUT" | grep -q "my.repo https://github.com/myorg/my.repo/main" && echo 1 || echo 0 )"

run 0 "repos list alias -> 0" repos list
ALIAS_OUT="$LAST_OUT"
run 0 "repo list again -> 0" repo list
check "repos list == repo list" "$( [ "$ALIAS_OUT" = "$LAST_OUT" ] && echo 1 || echo 0 )"

run 0 "repo keys -> 0" repo keys
check "keys line" "$( echo "$LAST_OUT" | grep -q "$HOME/.ssh/keyone.key https://github.com/myorgxx/myrepo/v" && echo 1 || echo 0 )"

echo "== repo clone argument handling =="
run 2 "clone with path -> 2" repo clone ./somepath
run 5 "clone nonexistent -> 5" repo clone nosuchkey
run 3 "clone network fail -> 3" repo clone keyone "$WORK/clonedest"
check "destination not created" "$( [ -e "$WORK/clonedest" ] && echo 0 || echo 1 )"
check "no location recorded after failed clone" "$( [ "$(loc_count keyone)" = "0" ] && echo 1 || echo 0 )"

echo "== repo update / delete not found =="
run 5 "update nonexistent key -> 5" repo update nosuchkey2
run 5 "delete nonexistent -> 5" repo delete nosuchkey2

echo "== repo delete by key =="
run 0 "delete keyone -> 0" repo delete keyone
check "key file removed" "$( [ -e "$HOME/.ssh/keyone.key" ] && echo 0 || echo 1 )"
check "ssh config block removed" "$( grep -q keyone "$HOME/.ssh/config" && echo 0 || echo 1 )"
check "record removed" "$( rec_exists keyone && echo 0 || echo 1 )"

echo "== repo delete with already-removed key files -> silent, 0 =="
run 0 "re-add keyone -> 0" repo add myorgxx/myrepo/v -n keyone
rm -f "$HOME/.ssh/keyone.key" "$HOME/.ssh/keyone.key.pub"
run 0 "delete with pre-removed key files -> 0" repo delete keyone

echo "== ssh config byte stability across add/delete cycle =="
cp "$HOME/.ssh/config" "$WORK/config.snapshot1"
run 0 "add keyone again -> 0" repo add myorgxx/myrepo/v -n keyone
run 0 "delete keyone again -> 0" repo delete keyone
check "ssh config byte-identical after cycle" \
    "$( cmp -s "$WORK/config.snapshot1" "$HOME/.ssh/config" && echo 1 || echo 0 )"

echo "== corrupt store -> 3 =="
cp "$(store)" "$WORK/store.good"
echo "{not json" > "$(store)"
run 3 "corrupt json -> 3" repo list
cp "$WORK/store.good" "$(store)"

echo "== setup =="
run 0 "setup -o myorg -b main -> 0" setup -o myorg -b main
check "bashrc org set" "$( grep -q 'GH_DEFAULT_ORG="myorg"' "$HOME/.bashrc" && echo 1 || echo 0 )"
run 0 "setup again -> 0 (idempotent)" setup -o myorg -b main
check "no duplicate bashrc lines" "$( [ "$(grep -c 'GH_DEFAULT_ORG=' "$HOME/.bashrc")" = "1" ] && echo 1 || echo 0 )"
run 0 "setup -o only preserves branch -> 0" setup -o otherorg
check "branch preserved" "$( grep -q 'GH_DEFAULT_BRANCH="main"' "$HOME/.bashrc" && echo 1 || echo 0 )"
run 2 "setup -o invalid -> 2" setup -o 'bad org!'

echo "== unknown flag -> 2 =="
run 2 "unknown flag -> 2" repo add myorg/my.repo/main --bogus

gu_total
