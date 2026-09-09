#!/usr/bin/env bash
# Copy the scripts and both test suites to the lab VM.
#
#   tests/lab/push.sh
set -euo pipefail
# shellcheck source=/dev/null  # path is computed at run time
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# shellcheck disable=SC2029  # expanding on the client is the point: the
# remote directory is named by the client's own configuration
ssh "${LAB_SSH_OPTS[@]}" "$LAB_HOST" "mkdir -p '$LAB_REMOTE_DIR/tests/git-utils'"
scp "${LAB_SSH_OPTS[@]}" -q \
    "$REPO_ROOT/system-setup" "$REPO_ROOT/git-utils" \
    "$REPO_ROOT/setup" "$REPO_ROOT/command-shortcuts" \
    "$LAB_HOST:$LAB_REMOTE_DIR/"
scp "${LAB_SSH_OPTS[@]}" -q \
    "$REPO_ROOT"/tests/system-setup/test-*.sh "$REPO_ROOT"/tests/system-setup/run-all.sh \
    "$LAB_HOST:$LAB_REMOTE_DIR/tests/"

# The git-utils suites keep their subdirectory, unlike the system-setup
# ones. lib.sh resolves the script under test as "$HERE/../../git-utils",
# so the layout on the VM has to match the repo's for GU_SRC to land on
# the pushed script rather than on nothing.
scp "${LAB_SSH_OPTS[@]}" -q \
    "$REPO_ROOT"/tests/git-utils/*.sh \
    "$LAB_HOST:$LAB_REMOTE_DIR/tests/git-utils/"

# The repository's .git, so the suites that assert file modes recorded in
# git can actually run here. 17-exec-bit reads `git ls-files -s` to prove
# the executable bit is committed -- the fault behind fix 50-03 -- and with
# only scp'd files there is no index to read. Tarred rather than scp -r:
# a few hundred loose objects over ssh is far slower one file at a time.
tar -C "$REPO_ROOT" -czf - .git \
    | ssh "${LAB_SSH_OPTS[@]}" "$LAB_HOST" "tar -xzf - -C '$LAB_REMOTE_DIR'"

printf 'pushed to %s:%s\n' "$LAB_HOST" "$LAB_REMOTE_DIR"
