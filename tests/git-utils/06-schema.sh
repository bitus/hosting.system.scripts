#!/usr/bin/env bash
# Fix 50-02 Phase 1: schema wrapper, format gate, store skeleton.
# Spec cases 1, 2, 8, 9, 10 (3-7 need `validate`, which lands in phase 10).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-schema

echo "=== 8: repo add with no store present creates the new skeleton ==="
run 0 "add -> 0" repo add someorg/somerepo/main -n skel
check "schema is the string \"1.1\"" \
    "$( [ "$(jq -r '.schema' "$(store)")" = "1.1" ] && [ "$(jq -r '.schema | type' "$(store)")" = "string" ] && echo 1 || echo 0 )"
check "records live under .repositories" "$( rec_exists skel && echo 1 || echo 0 )"
check "no record at the root" "$( jq -e 'has("skel")' "$(store)" >/dev/null 2>&1 && echo 0 || echo 1 )"
cp "$(store)" "$WORK/store.good"

echo "=== 2: unparseable JSON -> 3 ==="
echo '{not json' > "$(store)"
run 3 "repo list on unparseable store -> 3" repo list
run 3 "repo update on unparseable store -> 3" repo update somekey

echo "=== 1: old flat format -> 90, message names 'validate --fix' ==="
cat > "$(store)" << 'EOF'
{
  "my-repo": {
    "name": "my.repo.name",
    "org": "my_org",
    "branch": "main",
    "private_key": "/home/user/.ssh/my-repo.key",
    "public_key": "/home/user/.ssh/my-repo.key.pub",
    "locations": []
  }
}
EOF
run 90 "repo list on old-format store -> 90" repo list
check "message names 'validate --fix'" "$( echo "$LAST_ERR" | grep -q 'validate --fix' && echo 1 || echo 0 )"
run 90 "repo delete on old-format store -> 90" repo delete my-repo
run 90 "repo keys on old-format store -> 90" repo keys
run 90 "repo info on old-format store -> 90" repo info my-repo
run 90 "folder status on old-format store -> 90" folder status "$WORK"
# repo add and folder adopt create the store when absent, so they skip the
# "must exist" check -- but they must still refuse a store they cannot use.
# Without the gate, repo add would write .repositories[id] alongside the
# existing root-level records and leave the file half in each layout.
run 90 "repo add on old-format store -> 90" repo add neworg/newrepo/main
run 90 "folder adopt on old-format store -> 90" folder adopt "$WORK"
check "old store not modified by any of the refusals" \
    "$( jq -e 'has("my-repo")' "$(store)" >/dev/null 2>&1 && echo 1 || echo 0 )"
check "no .repositories key was grafted on" \
    "$( jq -e 'has("repositories")' "$(store)" >/dev/null 2>&1 && echo 0 || echo 1 )"

echo "=== missing schema / missing repositories -> 90 ==="
echo '{"repositories":{}}' > "$(store)"
run 90 "no schema key -> 90" repo list
echo '{"schema":"1.1"}' > "$(store)"
run 90 "no repositories key -> 90" repo list
echo '{"schema":"not-a-version","repositories":{}}' > "$(store)"
run 90 "malformed schema value -> 90" repo list

echo "=== 9: schema major newer than the script -> 90 ==="
echo '{"schema":"9.0","repositories":{}}' > "$(store)"
run 90 "schema 9.0 -> 90" repo list
check "message names a newer git-utils" "$( echo "$LAST_ERR" | grep -qi 'newer git-utils' && echo 1 || echo 0 )"

echo "=== 10: newer minor accepted, unknown sibling fields survive a write ==="
cp "$WORK/store.good" "$(store)"
store_patch '.schema = "1.2" | .repositories.skel.future_field = "keep me"'
run 0 "schema 1.2 accepted -> 0" repo list
# proves the gate let it through: it reaches git clone and fails there (3),
# rather than being refused at the schema check (90)
run 3 "clone against 1.2 store reaches git, fails on network -> 3" repo clone skel "$WORK/nope"
check "failed at clone, not at the schema gate" \
    "$( echo "$LAST_ERR" | grep -q 'git clone failed' && echo 1 || echo 0 )"
# a real write: append a location the same way repo clone's bookkeeping does
store_patch '.repositories.skel.locations = [{"path":"/tmp/x"}]'
run 0 "repo list still fine after write" repo list
check "unknown sibling field survived" \
    "$( [ "$(rec_field skel future_field)" = "keep me" ] && echo 1 || echo 0 )"
check "schema still 1.2" "$( [ "$(jq -r '.schema' "$(store)")" = "1.2" ] && echo 1 || echo 0 )"

echo "=== empty store is usable ==="
echo '{"schema":"1.1","repositories":{}}' > "$(store)"
run 0 "repo list on empty store -> 0" repo list
check "no output for empty store" "$( [ -z "$LAST_OUT" ] && echo 1 || echo 0 )"
run 0 "repo keys on empty store -> 0" repo keys
run 5 "repo update on empty store -> 5" repo update nosuch

gu_total
