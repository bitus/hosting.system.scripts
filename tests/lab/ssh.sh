#!/usr/bin/env bash
# Run a command on the lab VM.
#
#   tests/lab/ssh.sh 'cd ~/ss && bash tests/run-all.sh'
set -euo pipefail
# shellcheck source=/dev/null  # path is computed at run time
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
exec ssh "${LAB_SSH_OPTS[@]}" "$LAB_HOST" "$@"
