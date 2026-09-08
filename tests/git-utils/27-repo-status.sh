#!/usr/bin/env bash
# Fix 50-04 Phase 11: `repo status`. Spec cases 75-89.
#
# The two claims this suite exists for:
#
#  1. The two digest namespaces stay apart. repo status compares REGISTRY
#     digests (pull_available); folder status compares IMAGE IDS
#     (restart_pending). They coincide on a containerd-backed store, so a
#     crossed comparison passes here and is permanently wrong on a host with
#     the classic store. The assertions check the KIND of value, not just
#     that two things match.
#  2. Without -i, no registry call happens at all -- asserted by making the
#     registry unreachable and requiring success anyway.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-rstatus
git_global_setup

st()    { printf '%s' "$LAST_OUT" | jq -r '.status.status' 2>/dev/null; }
tcode() { printf '%s' "$LAST_OUT" | jq -r '.status.code' 2>/dev/null; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi

echo "=== fixtures ==="
make_repo 1 rs1 rsorg rsrepo
echo one > "$WORK/seed1/f"
printf 'alpine:3.20\n' > "$WORK/seed1/.images"
push_seed 1
run 0 "add rs1" repo add rsorg/rsrepo/main -n rs1
run 0 "clone to A" repo clone rs1 "$WORK/a"
run 0 "clone to B" repo clone rs1 "$WORK/b"

make_repo 2 rs2 rsorg2 rsrepo2
echo one > "$WORK/seed2/f"; push_seed 2
run 0 "add rs2 (never cloned)" repo add rsorg2/rsrepo2/main -n rs2

echo "=== 75: a healthy repo is one object, not an array ==="
run 0 "single repo -> 0" repo status rs1 --output-format json
check "top level is an object" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'type == "object"' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "id is first" \
    "$( printf '%s' "$LAST_OUT" | jq -r 'keys_unsorted[0]' | grep -qx id && echo 1 || echo 0 )"
check "the record fields are carried through" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.name == "rsrepo" and .org == "rsorg" and .branch == "main"' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "origin is the stored value, not a derived URL" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.origin | startswith("git@")' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "no remote_url field -- that work is deferred" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'has("remote_url")' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "two locations, each a folder status document" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations | length == 2 and all(has("path") and has("update_available") and has("docker_running"))' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "status Ok" "$( [ "$(st)" = "Ok" ] && echo 1 || echo 0 )"

echo "=== 78: without -i there are no registry fields at all ==="
check "images carry local_digest" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.images | all(has("local_digest"))' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "and NOT remote_digest" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.images | any(has("remote_digest"))' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "and NOT pull_available" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.images | any(has("pull_available"))' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "no built field -- it is not derivable from the store" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.images | any(has("built"))' >/dev/null 2>&1 && echo 0 || echo 1 )"

echo "=== 76: --all is an array ==="
run 0 "--all -> 0" repo status --all --output-format json
check "top level is an array" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'type == "array" and length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "both repos present" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.[].id] | sort == ["rs1","rs2"]' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 0 "-a short form" repo status -a --output-format json

echo "=== 77: --all reports every repo even when one is unhealthy ==="
store_patch 'del(.repositories["rs2"].date_created)'
run 1 "--all with one broken record -> 1" repo status --all --output-format json
check "still two repos reported" \
    "$( printf '%s' "$LAST_OUT" | jq -e 'length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "rs2 is the one that failed" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.[] | select(.id == "rs2") | .status.status == "Failed"' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "rs1 is still Ok -- one bad repo does not poison the rest" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.[] | select(.id == "rs1") | .status.status == "Ok"' >/dev/null 2>&1 && echo 1 || echo 0 )"
run 90 "the same repo alone -> its own code, not 1" repo status rs2 --output-format json
check "single mode returns the status object's code" "$( [ "$(tcode)" = "90" ] && echo 1 || echo 0 )"
store_patch '.repositories["rs2"].date_created = "2026-01-01T00:00:00Z"'

echo "=== 79/80: arguments ==="
run 5 "unknown repo -> 5" repo status nosuchkey
run 2 "neither argument nor --all -> 2" repo status
run 2 "--all with an argument -> 2" repo status --all rs1
run 2 "a path argument -> 2" repo status "$WORK/a"
run 2 "two positionals -> 2" repo status rs1 rs2
run 0 "by full name" repo status rsorg/rsrepo/main

echo "=== 81: status precedence -- record beats location beats image ==="
# A location fault alone surfaces as the repo's status.
rm -rf "$WORK/b/.git"
run 6 "a broken location surfaces -> 6" repo status rs1 --output-format json
check "top code is the location's own 6" "$( [ "$(tcode)" = "6" ] && echo 1 || echo 0 )"
# Add a record fault on top: the record must win.
store_patch 'del(.repositories["rs1"].date_created)'
run 90 "a record fault outranks the location fault -> 90" repo status rs1 --output-format json
check "top code 90" "$( [ "$(tcode)" = "90" ] && echo 1 || echo 0 )"
check "the location is still reported alongside it" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.locations[] | select(.status.code == 6)] | length == 1' >/dev/null 2>&1 && echo 1 || echo 0 )"
store_patch '.repositories["rs1"].date_created = "2026-01-01T00:00:00Z"'
rm -rf "$WORK/b"; run 0 "re-clone B" repo clone rs1 "$WORK/b"

echo "=== 82: no locations is not a failure here ==="
run 0 "a repo with no locations -> 0" repo status rs2 --output-format json
check "locations is empty" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations == []' >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== 83: an empty store ==="
cp "$(store)" "$WORK/store.good"
store_patch '.repositories = {}'
run 5 "--all with no repositories -> 5" repo status --all
cp "$WORK/store.good" "$(store)"

echo "=== image digests ==="
if [ "$HAVE_DOCKER" -eq 0 ]; then
    skip "every image-digest assertion" "no docker daemon"
else
    docker pull -q alpine:3.20 >/dev/null 2>&1 || true
    run 0 "local digest without -i" repo status rs1 --output-format json
    LOCAL_D="$(printf '%s' "$LAST_OUT" | jq -r '.images[0].local_digest')"
    check "local_digest is a repo digest, not an image id" \
        "$( echo "$LOCAL_D" | grep -q '^sha256:[0-9a-f]\{64\}$' && echo 1 || echo 0 )"
    # The namespace claim: this must equal what a PULL recorded, i.e. the
    # RepoDigests entry -- not the image's .Id, which is what folder status
    # compares. On this host the two may coincide; the assertion is that we
    # took it from RepoDigests.
    REPO_D="$(docker image inspect alpine:3.20 --format '{{json .RepoDigests}}' | jq -r '.[0]' | sed 's/^[^@]*@//')"
    check "local_digest comes from RepoDigests" \
        "$( [ "$LOCAL_D" = "$REPO_D" ] && echo 1 || echo 0 )"

    echo "--- 84/85: -i asks the registry ---"
    REG_ERR="$(docker buildx imagetools inspect alpine:3.20 2>&1 >/dev/null || true)"
    if printf '%s' "$REG_ERR" | grep -qiE '429|toomanyrequests|rate limit'; then
        skip "the -i registry assertions" "registry rate limit"
    elif [ -n "$REG_ERR" ]; then
        skip "the -i registry assertions" "registry unreachable"
    else
        run 0 "-i on an up-to-date image -> 0" repo status rs1 -i --output-format json
        check "remote_digest present" \
            "$( printf '%s' "$LAST_OUT" | jq -r '.images[0].remote_digest' | grep -q '^sha256:' && echo 1 || echo 0 )"
        # THE regression guard: index digest vs index digest.
        check "pull_available is false for an up-to-date image" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].pull_available == false' >/dev/null 2>&1 && echo 1 || echo 0 )"
        check "remote equals local" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].remote_digest == .images[0].local_digest' >/dev/null 2>&1 && echo 1 || echo 0 )"
        check "image status Ok" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].status.code == 0' >/dev/null 2>&1 && echo 1 || echo 0 )"

        echo "--- 86: an image the registry does not have -> 18 ---"
        store_patch '.repositories["rs1"].images = ["localhost:1/nope:latest"]'
        run 18 "unreachable registry -> 18" repo status rs1 -i --output-format json
        check "image status carries 18" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].status.code == 18' >/dev/null 2>&1 && echo 1 || echo 0 )"
        check "remote_digest is null, never a fabricated hash" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].remote_digest == null' >/dev/null 2>&1 && echo 1 || echo 0 )"
        check "and pull_available is null, not false" \
            "$( printf '%s' "$LAST_OUT" | jq -e '.images[0].pull_available == null' >/dev/null 2>&1 && echo 1 || echo 0 )"
        store_patch '.repositories["rs1"].images = ["alpine:3.20"]'
    fi

    echo "--- 87: without -i, an unreachable registry is irrelevant ---"
    store_patch '.repositories["rs1"].images = ["localhost:1/nope:latest"]'
    run 0 "no -i, unreachable image -> still 0" repo status rs1 --output-format json
    check "no registry field appeared" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images | any(has("remote_digest"))' >/dev/null 2>&1 && echo 0 || echo 1 )"
    store_patch '.repositories["rs1"].images = ["alpine:3.20"]'

    echo "--- 88: the two namespaces are not confused ---"
    # folder status's restart_pending compares image IDS; repo status's
    # pull_available compares REPO digests. Both appear in one document.
    run 0 "nested folder status alongside repo images" repo status rs1 --output-format json
    check "location images use image ids" \
        "$( printf '%s' "$LAST_OUT" | jq -e '[.locations[].images[]?] | length == 0 or all(has("local_image_id"))' >/dev/null 2>&1 && echo 1 || echo 0 )"
    check "repo images use digests" \
        "$( printf '%s' "$LAST_OUT" | jq -e '.images | all(has("local_digest") and (has("local_image_id") | not))' >/dev/null 2>&1 && echo 1 || echo 0 )"
fi

echo "=== 89: the timeout ==="
run 2 "--timeout with no value -> 2" repo status --timeout
run 2 "non-numeric --timeout -> 2" repo status rs1 -t abc
run 2 "zero --timeout -> 2" repo status rs1 -t 0
run 0 "--timeout=<n> form" repo status rs1 --timeout=60

# A spent budget must still produce a well-formed document: the whole point is
# that a monitoring caller never gets truncated JSON.
mv "$WORK/bare1.git" "$WORK/bare1.gone"
run 10 "an unreachable remote still yields a document -> 10" repo status rs1 --output-format json
check "the document parses" \
    "$( printf '%s' "$LAST_OUT" | jq empty >/dev/null 2>&1 && echo 1 || echo 0 )"
check "every location is still present" \
    "$( printf '%s' "$LAST_OUT" | jq -e '.locations | length == 2' >/dev/null 2>&1 && echo 1 || echo 0 )"
check "the failure is Failed, never Skipped" \
    "$( printf '%s' "$LAST_OUT" | jq -e '[.locations[] | select(.status.status == "Skipped")] | length == 0' >/dev/null 2>&1 && echo 1 || echo 0 )"
mv "$WORK/bare1.gone" "$WORK/bare1.git"

echo "=== output plumbing and help ==="
run 0 "text form" repo status rs1 --output-format text
check "folded output carries the id" \
    "$( printf '%s' "$LAST_OUT" | grep -q '^id: rs1$' && echo 1 || echo 0 )"
run 2 "invalid --output-format -> 2" repo status rs1 --output-format xml
run 0 "repo status -h" repo status -h
check "help explains the two digest questions" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'restart_pending' && echo 1 || echo 0 )"
check "help says the timeout bounds one repo" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'bounds ONE repo' && echo 1 || echo 0 )"
check "help says there is no built field" \
    "$( printf '%s' "$LAST_OUT" | grep -qi 'no .built. field' && echo 1 || echo 0 )"

gu_total
