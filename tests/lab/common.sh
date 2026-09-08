#!/usr/bin/env bash
# Shared configuration for the lab helpers. SOURCED, never executed.
#
# Nothing here ships with a value. The host, the key and the remote directory
# are per-operator, so they come from the environment or from gitignored files
# beside this one - which is also why the helpers themselves were repeatedly
# lost before being committed: they lived only in a scratch directory.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # read by push.sh, which sources this file
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"

# Host: $SS_LAB_HOST, else the first non-comment line of tests/lab/target.
if [ -n "${SS_LAB_HOST:-}" ]; then
    LAB_HOST="$SS_LAB_HOST"
elif [ -f "$LAB_DIR/target" ]; then
    LAB_HOST="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LAB_DIR/target" | grep -v '^$' | head -1)"
fi
if [ -z "${LAB_HOST:-}" ]; then
    printf 'error: no lab host configured\n' >&2
    printf '  set SS_LAB_HOST=user@host, or write it to %s/target\n' "$LAB_DIR" >&2
    exit 2
fi

# Where the scripts land on the VM, relative to the remote home.
# shellcheck disable=SC2034  # read by push.sh, which sources this file
LAB_REMOTE_DIR="${SS_LAB_DIR:-ss}"

# BatchMode is the load-bearing option: these helpers are driven from
# non-interactive shells, where a password prompt does not fail - it hangs.
declare -a LAB_SSH_OPTS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$LAB_DIR/known_hosts"
    -o ConnectTimeout=10
)

# Key: $SS_LAB_KEY, else tests/lab/lab_key, else fall back to the agent and
# the default identities. IdentitiesOnly stops ssh wandering through those
# when we have named one.
LAB_KEY="${SS_LAB_KEY:-$LAB_DIR/lab_key}"
if [ -f "$LAB_KEY" ]; then
    LAB_SSH_OPTS+=(-i "$LAB_KEY" -o IdentitiesOnly=yes)
fi
