#!/usr/bin/env bash
# Runs every system-setup suite and reports the total.
#
#   bash tests/run-all.sh
#
# Two things it does that running the suites by hand does not:
#
#   1. Reports SKIPPED blocks. A suite that skips `vfat` because fatresize is
#      absent still prints "passed: N   failed: 0", and a green summary that
#      quietly covered less than it looks like is the failure mode this exists
#      to prevent. Phase F shipped two bugs in code that only the skippable
#      cases exercise.
#
#   2. Checks the host is left as it was found. /etc/fstab is compared by
#      md5sum; ~/.bashrc is reconverged, because `setup`, `bootstrap` and
#      `exec-bit` all end on their uninstall cases and would otherwise leave a
#      green run having de-provisioned the host.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/system-setup"
export SCRIPT

SUITES=(validation inspect hdd-list file setup ntp hdd hdd-add hdd-remove
        hdd-expand docker docker-workspace bootstrap exec-bit)

FSTAB_BEFORE="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
TOTAL=0; FAILED=0; SKIPPED=0
declare -a BAD=()
declare -a SKIPS=()

for s in "${SUITES[@]}"; do
    f="$REPO/tests/test-$s.sh"
    [ -f "$f" ] || { printf '%-18s MISSING\n' "$s"; BAD+=("$s: suite not found"); continue; }
    out="$(bash "$f" 2>&1)"
    line="$(grep '^passed:' <<< "$out" | tail -1)"
    p="$(sed -n 's/passed: *\([0-9]*\).*/\1/p' <<< "$line")"
    fl="$(sed -n 's/.*failed: *\([0-9]*\).*/\1/p' <<< "$line")"
    sk="$(grep -c 'skipping' <<< "$out")"
    TOTAL=$((TOTAL + ${p:-0}))
    FAILED=$((FAILED + ${fl:-0}))
    SKIPPED=$((SKIPPED + sk))
    printf '%-18s %-24s' "$s" "${line:-NO RESULT}"
    if [ "$sk" -gt 0 ]; then printf '  (%s skipped block(s))' "$sk"; fi
    printf '\n'
    [ "${fl:-1}" = 0 ] || BAD+=("$s")
    while IFS= read -r l; do
        # strip leading whitespace without shelling out to sed
        [ -z "$l" ] || SKIPS+=("$s: ${l#"${l%%[![:space:]]*}"}")
    done < <(grep 'skipping' <<< "$out")
done

echo
echo "TOTAL passed: $TOTAL   failed: $FAILED   skipped blocks: $SKIPPED"

if [ "$SKIPPED" -gt 0 ]; then
    echo
    echo "SKIPPED - these cases did not run, and contributed no failures either:"
    for l in "${SKIPS[@]}"; do printf '  %s\n' "$l"; done
fi

echo
echo "=== shellcheck ==="
# tests/test-*.sh, NOT tests/*.sh - that glob also matches git-utils' suites,
# which are its own concern.
if (cd "$REPO" && shellcheck setup system-setup command-shortcuts tests/test-*.sh); then
    echo "clean"
else
    BAD+=("shellcheck")
fi

echo
echo "=== host state ==="
FSTAB_AFTER="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
if [ "$FSTAB_BEFORE" = "$FSTAB_AFTER" ]; then
    echo "/etc/fstab   unchanged"
else
    echo "/etc/fstab   CHANGED - a suite did not restore it"
    BAD+=("/etc/fstab was modified by the run")
fi

LEFT="$(sudo find /etc -maxdepth 1 -name 'fstab.*' ! -name 'fstab.bak' 2>/dev/null | wc -l)"
if [ "$LEFT" = 0 ]; then
    echo "/etc         no stray fstab temp files"
else
    echo "/etc         $LEFT stray fstab temp file(s)"
    BAD+=("$LEFT stray temp files in /etc")
fi

# setup, bootstrap and exec-bit all end on an uninstall case, so the blocks are
# gone by now. Put them back rather than leaving the host de-provisioned.
bash "$SCRIPT" setup >/dev/null 2>&1
sudo bash "$SCRIPT" docker >/dev/null 2>&1
BLOCKS="$(grep -c '>>> system-setup' "$HOME/.bashrc" 2>/dev/null || true)"
if [ "$BLOCKS" = 3 ]; then
    echo "\$HOME/.bashrc  reconverged (3 blocks: PATH, shortcuts, docker)"
else
    echo "\$HOME/.bashrc  $BLOCKS block(s) after reconverging, expected 3"
    BAD+=("\$HOME/.bashrc did not reconverge")
fi

echo
if [ "${#BAD[@]}" -eq 0 ]; then
    echo "ALL GREEN"
    exit 0
fi
printf 'PROBLEMS:\n'
for b in "${BAD[@]}"; do printf '  %s\n' "$b"; done
exit 1
