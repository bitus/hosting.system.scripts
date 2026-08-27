#!/usr/bin/env bash
# Runs every git-utils suite and prints a summary.
#
#   bash tests/run-all.sh            # all suites
#   bash tests/run-all.sh 01 06      # only the named ones
#
# Requires: git, jq, flock, ssh-keygen, docker compose (v2), yq.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [ "$#" -gt 0 ]; then
    mapfile -t SUITES < <(for p in "$@"; do ls "$p"*.sh 2>/dev/null; done)
else
    mapfile -t SUITES < <(ls [0-9][0-9]-*.sh 2>/dev/null)
fi

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()

for s in "${SUITES[@]}"; do
    echo "═══ $s ═══"
    out="$(bash "$s" 2>&1)"
    echo "$out" | grep -E '^(FAIL|TOTAL)' || true
    line="$(echo "$out" | grep '^TOTAL:' | tail -1)"
    p="$(echo "$line" | sed -n 's/^TOTAL: \([0-9]*\) passed.*/\1/p')"
    f="$(echo "$line" | sed -n 's/.* \([0-9]*\) failed$/\1/p')"
    TOTAL_PASS=$(( TOTAL_PASS + ${p:-0} ))
    TOTAL_FAIL=$(( TOTAL_FAIL + ${f:-0} ))
    [ "${f:-0}" -eq 0 ] || FAILED_SUITES+=("$s")
    echo
done

echo "═══════════════════════════════"
echo "GRAND TOTAL: $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ "${#FAILED_SUITES[@]}" -gt 0 ]; then
    echo "failing suites: ${FAILED_SUITES[*]}"
    exit 1
fi
