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
    if [ -n "$pat" ] && ! grep -qE -- "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $(tail -3 <<< "$out")"; return; fi
    ok
}
assert()      { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }
block_count() { grep -cF "$1" "$BASHRC" 2>/dev/null || true; }

# Count PATH exports INSIDE the system-setup block only. git-utils writes its
# own block with an identical line, so a whole-file grep counts both and this
# assertion is about system-setup not duplicating its own.
path_lines_in_block() {
    awk '/^# >>> system-setup >>>$/{f=1;next} /^# <<< system-setup <<<$/{f=0} f' "$BASHRC" \
        | grep -c 'export PATH=' || true
}

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
assert 69i "[ \"\$(path_lines_in_block)\" = 1 ]"
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
echo "=== B1-B4: command-shortcuts installed by setup ==="
assert B1  "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"
assert B1b "grep -q 'command-shortcuts' '$BASHRC'"
run B2 0 "" setup
assert B2b "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"

echo "--- B3: a missing file warns but setup still succeeds ---"
mv "$REPO/command-shortcuts" /tmp/cs.hidden
sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$BASHRC"
run B3 0 "not found beside the script" setup
mv /tmp/cs.hidden "$REPO/command-shortcuts"

echo "--- B4: CRLF is refused and no block is written ---"
sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$BASHRC"
cp "$REPO/command-shortcuts" /tmp/cs.lf
# GNU sed renders \r in the replacement as a real carriage return
sed -i 's/$/\r/' "$REPO/command-shortcuts"
run B4 0 "CRLF line endings" setup
assert B4b "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 0 ]"
cp /tmp/cs.lf "$REPO/command-shortcuts"; rm -f /tmp/cs.lf
run B4c 0 "shell shortcuts sourced" setup

echo
echo "=== B5/B6: the legacy docker-shortcuts block is migrated away ==="
cleanup
cat >> "$BASHRC" <<'LEGACY'
# >>> system-setup docker >>>
[ -f "/old/path/docker-shortcuts" ] && . "/old/path/docker-shortcuts"
# <<< system-setup docker <<<
LEGACY
run B5 0 "removed the legacy docker-shortcuts block" setup
assert B5b "[ \"$(block_count '>>> system-setup docker >>>')\" = 0 ]"
assert B5c "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"
assert B5d "! grep -q '/old/path' '$BASHRC'"
echo "--- B6: migrating again is a no-op ---"
run B6 0 "" setup
assert B6b "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"

echo
echo "=== B7: a DOCKER_HOME-style docker block must NOT be migrated away ==="
# The docker sentinel id is reused for the DOCKER_HOME export (phase C).
# Migration keys on CONTENT, so a block that only exports must survive.
cat >> "$BASHRC" <<'DHOME'
# >>> system-setup docker >>>
export DOCKER_HOME="/home/x/docker"
# <<< system-setup docker <<<
DHOME
run B7 0 "" setup
assert B7b "[ \"$(block_count '>>> system-setup docker >>>')\" = 1 ]"
assert B7c "grep -q 'DOCKER_HOME' '$BASHRC'"
sed -i '/# >>> system-setup docker/,/# <<< system-setup docker/d' "$BASHRC"

echo
echo "=== B9: a moved repository is reconciled ==="
cp -a "$REPO" /tmp/ss-moved-b
OUTM="$(bash /tmp/ss-moved-b/system-setup setup 2>&1)"
if grep -q '/tmp/ss-moved-b/command-shortcuts' "$BASHRC"; then ok; else bad "B9: not reconciled :: $OUTM"; fi
assert B9b "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"
rm -rf /tmp/ss-moved-b
run B9c 0 "" setup
assert B9d "grep -q '$REPO/command-shortcuts' '$BASHRC'"

echo
echo "=== B10: the resulting ~/.bashrc sources cleanly ==="
# -i, not -l: Debian's ~/.bashrc returns immediately when not interactive, so
# a login shell would source nothing and this would pass vacuously.
SHELL_ERR="$(bash -ic true 2>&1 | grep -vE '^$|cannot set terminal process group|no job control in this shell')"
if [ -z "$SHELL_ERR" ]; then ok; else bad "B10: login shell emits errors :: $SHELL_ERR"; fi
if bash -n "$REPO/command-shortcuts" 2>/dev/null; then ok; else bad "B10b: command-shortcuts is not valid bash"; fi
if LC_ALL=C grep -q "$(printf '\r')" "$REPO/command-shortcuts"; then bad "B10c: CRLF in command-shortcuts"; else ok; fi


echo
echo "=== B11: command-shortcuts-custom, the per-host file ==="
CUSTOM="$REPO/command-shortcuts-custom"
CUSTOM_LINE="[ -f \"$CUSTOM\" ] && . \"$CUSTOM\""
rm -f "$CUSTOM"

echo "--- B11: the line is written even though the file does not exist ---"
# That is the whole design: an admin drops the file in later and it loads at
# the next login, with no second `setup` run.
run B11 0 "per-host shortcuts will load from" setup
if grep -qF "$CUSTOM_LINE" "$BASHRC"; then ok; else bad "B11b: custom source line absent from $BASHRC"; fi
assert B11c "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"
# it must be guarded, or a missing file breaks every login shell
if grep -qF "[ -f \"$CUSTOM\" ] &&" "$BASHRC"; then ok; else bad "B11d: the custom line is not guarded on existence"; fi

echo "--- B12: a login shell is clean with the file absent ---"
SHELL_ERR="$(bash -ic true 2>&1 | grep -vE '^$|cannot set terminal process group|no job control in this shell')"
if [ -z "$SHELL_ERR" ]; then ok; else bad "B12: shell errors with no custom file :: $SHELL_ERR"; fi

echo "--- B13: creating it later takes effect with no re-run ---"
printf 'ss_custom_marker() { echo CUSTOM_OK; }\n' > "$CUSTOM"
OUT="$(bash -ic 'ss_custom_marker' 2>&1)"
if grep -q CUSTOM_OK <<< "$OUT"; then ok; else bad "B13: custom shortcuts not loaded :: $OUT"; fi

echo "--- B14: it is sourced AFTER the shipped file, so it can override ---"
SN="$(grep -nF "[ -f \"$REPO/command-shortcuts\" ]" "$BASHRC" | head -1 | cut -d: -f1)"
CN="$(grep -nF "$CUSTOM_LINE" "$BASHRC" | head -1 | cut -d: -f1)"
if [ -n "$SN" ] && [ -n "$CN" ] && [ "$CN" -gt "$SN" ]; then ok; else bad "B14: custom line at $CN is not after the shipped line at $SN"; fi

echo "--- B15: re-running setup is idempotent with the file present ---"
run B15 0 "per-host shortcuts sourced from" setup
assert B15b "[ \"$(block_count '>>> system-setup shortcuts >>>')\" = 1 ]"
if [ "$(grep -cF "$CUSTOM_LINE" "$BASHRC")" = 1 ]; then ok; else bad "B15c: the custom line was duplicated"; fi

echo "--- B16: a host whose block predates this change re-converges ---"
# cmd_setup calls shortcuts_install unconditionally and block_upsert replaces
# the block wholesale, so a block carrying only the shipped line is repaired
# on the next run. (shortcuts_present would answer this too, but nothing
# calls it - the convergence here is block_upsert's, not a predicate's.)
grep -vF "$CUSTOM_LINE" "$BASHRC" > /tmp/ss-br.tmp && mv /tmp/ss-br.tmp "$BASHRC"
if grep -qF "$CUSTOM_LINE" "$BASHRC"; then bad "B16a: could not strip the custom line for the test"; else ok; fi
run B16 0 "shell shortcuts sourced" setup
if grep -qF "$CUSTOM_LINE" "$BASHRC"; then ok; else bad "B16b: setup did not restore the custom line"; fi

echo "--- B17: a CRLF custom file warns but is still wired up ---"
printf 'ss_custom_marker() { echo CUSTOM_OK; }\r\n' > "$CUSTOM"
OUT="$(bash "$SCRIPT" setup 2>&1)"
if grep -q "CRLF line endings" <<< "$OUT"; then ok; else bad "B17: no CRLF warning for the custom file :: $OUT"; fi
if grep -qF "$CUSTOM_LINE" "$BASHRC"; then ok; else bad "B17b: the line was dropped; it should be installed either way"; fi
printf 'ss_custom_marker() { echo CUSTOM_OK; }\n' > "$CUSTOM"

echo "--- B18: the file is git-untracked and ignored ---"
# Only meaningful in a checkout. The lab host runs from a plain copy of the
# scripts, so this asserts nothing there and says so rather than failing.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$REPO" check-ignore -q command-shortcuts-custom 2>/dev/null; then ok; else
        bad "B18: command-shortcuts-custom is not gitignored - a host-specific file would be committed"
    fi
    if [ -z "$(git -C "$REPO" ls-files command-shortcuts-custom 2>/dev/null)" ]; then ok; else
        bad "B18b: command-shortcuts-custom is tracked in git"
    fi
else
    echo "  (not a git checkout, skipping)"
fi
rm -f "$CUSTOM"

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
