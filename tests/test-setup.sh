#!/usr/bin/env bash
# Host tests for `system-setup setup` (plan phase 12, test case 69).
# Creates a symlink in sbin and edits ~/.bashrc - test VM only.
#
#   bash tests/test-setup.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
BASHRC="$HOME/.bashrc"
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$*] rc=$rc want=$want :: $(tail -3 <<< "$out")"; return; fi
    if [ -n "$pat" ] && ! grep -qE "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $(tail -3 <<< "$out")"; return; fi
    ok
}
assert()      { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }
block_count() { grep -cF "$1" "$BASHRC" 2>/dev/null || true; }

SBIN=/usr/local/sbin
LINK="$SBIN/system-setup"

cleanup() {
    sudo rm -f "$LINK"
    sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$BASHRC"
}
trap cleanup EXIT

echo "### reset"
cleanup
echo "start: link=$( [ -e "$LINK" ] && echo present || echo absent )  blocks=$(block_count '>>> system-setup')"

echo
echo "=== 69a: first run installs the symlink and the PATH block ==="
run 69a 0 "installed $LINK" setup
assert 69b "[ -L '$LINK' ]"
assert 69c "[ \"\$(readlink -f '$LINK')\" = \"\$(realpath '$SCRIPT')\" ]"
assert 69d "[ -x '$SCRIPT' ]"
assert 69e "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert 69f "grep -q 'export PATH=' '$BASHRC'"

echo
echo "=== 69g: second run warns about the symlink and does not duplicate ==="
run 69g 0 "already exists" setup
assert 69h "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert 69i "[ \"\$(grep -c 'export PATH=' '$BASHRC')\" = 1 ]"
assert 69j "[ -L '$LINK' ]"

echo
echo "=== the installed symlink actually runs ==="
run s1 0 "Usage:" --help
if "$LINK" --help 2>&1 | grep -q "Usage:"; then ok; else bad "s2: $LINK is not executable as a command"; fi

echo
echo "=== sbin already in PATH is reported, not re-added ==="
OUT="$(PATH="$PATH:$SBIN" bash "$SCRIPT" setup 2>&1)"
if grep -q "already in PATH" <<< "$OUT"; then ok; else bad "s3: expected 'already in PATH' :: $OUT"; fi
assert s4 "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"

echo
echo "=== 31: the setup and docker blocks must coexist ==="
# cmd_docker maintains an id'd block in the same file; simulate it here so this
# suite does not depend on docker being installed.
printf '%s\n%s\n%s\n' '# >>> system-setup docker >>>' '[ -f /tmp/x ] && . /tmp/x' '# <<< system-setup docker <<<' >> "$BASHRC"
sed -i '/# >>> system-setup >>>/,/# <<< system-setup <<</d' "$BASHRC"
run 31a 0 "" setup
assert 31b "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert 31c "[ \"\$(block_count '>>> system-setup docker >>>')\" = 1 ]"
assert 31d "grep -q '/tmp/x' '$BASHRC'"

echo
echo "=== argument errors ==="
run a1 2 "unknown flag"        setup --nope
run a2 2 "unexpected argument" setup extra
run a3 0 "system-setup setup"  setup -h

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
