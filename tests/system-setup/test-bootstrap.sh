#!/usr/bin/env bash
# Host tests for the `setup` bootstrap script (fixes 2026-08-26, phase A, A1-A6).
#
# Installs packages and runs both tools' setup - test VM only.
#
#   bash tests/test-bootstrap.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="${BOOTSTRAP:-$REPO/setup}"
BASHRC="$HOME/.bashrc"
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }
assert() { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }
block_count() { grep -cF "$1" "$BASHRC" 2>/dev/null || true; }

cleanup() {
    sudo rm -f /usr/local/sbin/system-setup /usr/local/sbin/git-utils
    sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$BASHRC"
    sed -i '/# >>> git-utils/,/# <<< git-utils/d'       "$BASHRC"
}

echo "### reset"
cleanup
echo "start: symlinks=$(find /usr/local/sbin -maxdepth 1 \( -name git-utils -o -name system-setup \) 2>/dev/null | wc -l)  blocks=$(grep -c '>>> ' "$BASHRC" 2>/dev/null || echo 0)"

echo
echo "=== A1: first run installs prerequisites and runs both setups ==="
OUT="$(bash "$BOOTSTRAP" 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "A1: rc=$RC :: $(tail -5 <<< "$OUT")"; fi
if grep -q "bootstrap complete" <<< "$OUT"; then ok; else bad "A1b: no completion message"; fi
for p in git jq yq; do
    if command -v "$p" >/dev/null 2>&1; then ok; else bad "A1c: $p not installed"; fi
done
assert A1d "[ -L /usr/local/sbin/git-utils ]"
assert A1e "[ -L /usr/local/sbin/system-setup ]"

echo
echo "=== A3: both tools' bashrc blocks present, exactly one each ==="
assert A3a "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert A3b "[ \"\$(block_count '>>> git-utils >>>')\" = 1 ]"
# the two tools must not have eaten each other's block - the exact class of
# bug that hit the docker/setup blocks during the original build
assert A3c "grep -q 'usr/local/sbin' '$BASHRC'"

echo
echo "=== A2: re-run is idempotent ==="
OUT2="$(bash "$BOOTSTRAP" 2>&1)"; RC2=$?
if [ "$RC2" = 0 ]; then ok; else bad "A2: rc=$RC2 :: $(tail -5 <<< "$OUT2")"; fi
assert A2b "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert A2c "[ \"\$(block_count '>>> git-utils >>>')\" = 1 ]"
if grep -q "already exists" <<< "$OUT2"; then ok; else bad "A2d: expected a symlink-exists warning on re-run"; fi

echo
echo "=== the installed symlinks actually run ==="
if /usr/local/sbin/system-setup --help 2>&1 | grep -q "Usage:"; then ok; else bad "s1: system-setup symlink not runnable"; fi
if /usr/local/sbin/git-utils --help 2>&1 | grep -q "Usage:"; then ok; else bad "s2: git-utils symlink not runnable"; fi

echo
echo "=== A4: run under sudo - blocks must land in the INVOKING user's home ==="
cleanup
sudo rm -rf /root/.bashrc.a4-backup
sudo cp /root/.bashrc /root/.bashrc.a4-backup 2>/dev/null || true
ROOT_BEFORE="$(sudo grep -c '>>> ' /root/.bashrc 2>/dev/null || echo 0)"
OUT4="$(sudo bash "$BOOTSTRAP" 2>&1)"; RC4=$?
if [ "$RC4" = 0 ]; then ok; else bad "A4: rc=$RC4 :: $(tail -5 <<< "$OUT4")"; fi
if grep -q "will run as '$USER'" <<< "$OUT4"; then ok; else bad "A4b: no drop-back message"; fi
# the invoking user got the blocks...
assert A4c "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert A4d "[ \"\$(block_count '>>> git-utils >>>')\" = 1 ]"
# ...and root did NOT
ROOT_AFTER="$(sudo grep -c '>>> ' /root/.bashrc 2>/dev/null || echo 0)"
if [ "$ROOT_BEFORE" = "$ROOT_AFTER" ]; then ok; else bad "A4e: root's .bashrc gained blocks ($ROOT_BEFORE -> $ROOT_AFTER)"; fi
# and the files are owned by the invoking user, not root
assert A4f "[ \"\$(stat -c '%U' '$BASHRC')\" = \"$USER\" ]"

echo
echo "=== A5: a failing sub-setup is reported and stops the run ==="
TMPD="$(mktemp -d)"
cp "$BOOTSTRAP" "$TMPD/setup"
cp "$REPO/system-setup" "$TMPD/system-setup"
printf '#!/usr/bin/env bash\nexit 7\n' > "$TMPD/git-utils"
chmod +x "$TMPD/git-utils"
OUT5="$(bash "$TMPD/setup" 2>&1)"; RC5=$?
if [ "$RC5" = 3 ]; then ok; else bad "A5: rc=$RC5 want 3 :: $(tail -3 <<< "$OUT5")"; fi
if grep -q "'git-utils setup' failed" <<< "$OUT5"; then ok; else bad "A5b: message does not name the failing sub-setup"; fi
if grep -q "system-setup setup" <<< "$OUT5"; then bad "A5c: continued past the failure"; else ok; fi
rm -rf "$TMPD"

echo
echo "=== missing sibling is a pre-check failure ==="
TMPD2="$(mktemp -d)"
cp "$BOOTSTRAP" "$TMPD2/setup"
OUT6="$(bash "$TMPD2/setup" 2>&1)"; RC6=$?
if [ "$RC6" = 1 ]; then ok; else bad "m1: rc=$RC6 want 1"; fi
if grep -q "not found beside this script" <<< "$OUT6"; then ok; else bad "m2: unhelpful message :: $OUT6"; fi
rm -rf "$TMPD2"

echo
echo "=== A6: lint and line endings ==="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$BOOTSTRAP" >/dev/null 2>&1; then ok; else bad "A6a: shellcheck findings in $BOOTSTRAP"; fi
else
    echo "  (shellcheck not installed, skipping)"
fi
if LC_ALL=C grep -q "$(printf '\r')" "$BOOTSTRAP"; then bad "A6b: setup has CRLF line endings"; else ok; fi
if bash -n "$BOOTSTRAP" 2>/dev/null; then ok; else bad "A6c: setup is not valid bash"; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
