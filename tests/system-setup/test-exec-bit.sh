#!/usr/bin/env bash
# Regression tests for "Permission denied after updating the repo on a host"
# (fixes 2026-08-27).
#
# Pins the mechanism from BOTH directions: that a 100755 file survives a
# reset --hard, and that a 100644 one still loses the bit. The second is the
# original bug, kept as a control - without it a regression in the recorded
# mode would look identical to a pass.
#
#   bash tests/test-exec-bit.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
SBIN=/usr/local/sbin
LINK="$SBIN/system-setup"
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

cleanup() {
    sudo rm -f "$LINK"
    sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$HOME/.bashrc"
    rm -rf /tmp/ss-mode-test
}
trap cleanup EXIT

echo "=== recorded modes in git ==="
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for f in system-setup git-utils setup; do
        MODE="$(git -C "$REPO" ls-files -s "$f" 2>/dev/null | awk '{print $1}')"
        if [ "$MODE" = "100755" ]; then ok; else bad "mode: $f is $MODE, want 100755"; fi
    done
    # command-shortcuts is SOURCED, never executed: it must stay non-executable
    MODE="$(git -C "$REPO" ls-files -s command-shortcuts 2>/dev/null | awk '{print $1}')"
    if [ "$MODE" = "100644" ]; then ok; else bad "mode: command-shortcuts is $MODE, want 100644"; fi
else
    echo "  (not a git checkout, skipping)"
fi

echo
echo "=== the mechanism itself, in a throwaway repo ==="
rm -rf /tmp/ss-mode-test && mkdir -p /tmp/ss-mode-test
(
    cd /tmp/ss-mode-test || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    printf '#!/usr/bin/env bash\necho ran\n' > exec-file
    printf '#!/usr/bin/env bash\necho ran\n' > plain-file
    chmod +x exec-file plain-file
    git add -A >/dev/null 2>&1
    git update-index --chmod=+x exec-file >/dev/null 2>&1
    git update-index --chmod=-x plain-file >/dev/null 2>&1
    git commit -qm init >/dev/null 2>&1
) || { echo "  (git unavailable, skipping)"; }

if [ -d /tmp/ss-mode-test/.git ]; then
    chmod +x /tmp/ss-mode-test/exec-file /tmp/ss-mode-test/plain-file
    ( cd /tmp/ss-mode-test && git reset --hard -q HEAD && git clean -fdq )
    # a 100755 file KEEPS the bit
    if [ -x /tmp/ss-mode-test/exec-file ]; then ok; else bad "mech1: 100755 lost the bit across reset --hard"; fi
    # a 100644 file LOSES it - the original bug, kept as a control
    if [ ! -x /tmp/ss-mode-test/plain-file ]; then ok; else bad "mech2: 100644 kept the bit; the control no longer reproduces the bug"; fi
fi

echo
echo "=== setup installs, and the symlink runs ==="
cleanup
OUT="$(bash "$SCRIPT" setup 2>&1)"
if [ -L "$LINK" ]; then ok; else bad "s1: no symlink created"; fi
if [ -x "$SCRIPT" ]; then ok; else bad "s2: script not executable after setup"; fi
if "$LINK" --help 2>&1 | grep -q "Usage:"; then ok; else bad "s3: symlink not runnable"; fi
if grep -q "installed $LINK" <<< "$OUT"; then ok; else bad "s4: no install message"; fi

echo
echo "=== stripping the bit reproduces the reported failure ==="
chmod -x "$SCRIPT"
ERR="$("$LINK" --help 2>&1 || true)"
if grep -qi "permission denied" <<< "$ERR"; then ok; else bad "b1: expected Permission denied, got: $ERR"; fi

echo
echo "=== re-running setup REPAIRS it, without touching the symlink ==="
LINK_BEFORE="$(readlink -f "$LINK")"
OUT="$(bash "$SCRIPT" setup 2>&1)"
if [ -x "$SCRIPT" ]; then ok; else bad "r1: setup did not restore the executable bit"; fi
if grep -q "restored the executable bit" <<< "$OUT"; then ok; else bad "r2: repair not reported :: $OUT"; fi
if grep -q "already exists" <<< "$OUT"; then ok; else bad "r3: expected the existing-symlink warning"; fi
if [ "$(readlink -f "$LINK")" = "$LINK_BEFORE" ]; then ok; else bad "r4: the symlink was recreated; it should not need to be"; fi
if "$LINK" --help 2>&1 | grep -q "Usage:"; then ok; else bad "r5: still not runnable after repair"; fi

echo
echo "=== a third run is quiet about the bit ==="
OUT="$(bash "$SCRIPT" setup 2>&1)"
if grep -q "restored the executable bit" <<< "$OUT"; then bad "q1: repaired something that was already fine"; else ok; fi
if [ -x "$SCRIPT" ]; then ok; else bad "q2: bit lost on a no-op run"; fi

echo
echo "=== a symlink pointing elsewhere is reported with its real target ==="
sudo rm -f "$LINK"
printf '#!/usr/bin/env bash\ntrue\n' > /tmp/ss-other && chmod +x /tmp/ss-other
sudo ln -s /tmp/ss-other "$LINK"
OUT="$(bash "$SCRIPT" setup 2>&1)"
if grep -q "points at /tmp/ss-other" <<< "$OUT"; then ok; else bad "p1: target not named :: $OUT"; fi
if grep -q "not $SCRIPT" <<< "$OUT"; then ok; else bad "p2: does not say what it should point at"; fi
sudo rm -f "$LINK" /tmp/ss-other

echo
echo "=== the repair works through the bootstrap too ==="
cleanup
bash "$REPO/setup" >/dev/null 2>&1
chmod -x "$SCRIPT"
bash "$REPO/setup" >/dev/null 2>&1
if [ -x "$SCRIPT" ]; then ok; else bad "boot1: bootstrap did not repair the bit"; fi
if "$LINK" --help 2>&1 | grep -q "Usage:"; then ok; else bad "boot2: not runnable after bootstrap repair"; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
