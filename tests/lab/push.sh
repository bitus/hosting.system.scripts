#!/usr/bin/env bash
# Copy the scripts and the system-setup suites to the lab VM.
#
#   tests/lab/push.sh
set -euo pipefail
# shellcheck source=/dev/null  # path is computed at run time
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# shellcheck disable=SC2029  # expanding on the client is the point: the
# remote directory is named by the client's own configuration
ssh "${LAB_SSH_OPTS[@]}" "$LAB_HOST" "mkdir -p '$LAB_REMOTE_DIR/tests'"
scp "${LAB_SSH_OPTS[@]}" -q \
    "$REPO_ROOT/system-setup" "$REPO_ROOT/git-utils" \
    "$REPO_ROOT/setup" "$REPO_ROOT/command-shortcuts" \
    "$LAB_HOST:$LAB_REMOTE_DIR/"
scp "${LAB_SSH_OPTS[@]}" -q \
    "$REPO_ROOT"/tests/system-setup/test-*.sh "$REPO_ROOT"/tests/system-setup/run-all.sh \
    "$LAB_HOST:$LAB_REMOTE_DIR/tests/"
printf 'pushed to %s:%s\n' "$LAB_HOST" "$LAB_REMOTE_DIR"
