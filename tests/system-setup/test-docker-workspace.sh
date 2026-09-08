#!/usr/bin/env bash
# Host tests for `system-setup docker --workspace` (fixes 2026-08-30, phase G,
# G1-G9).
#
# Assumes Docker is already installed and converged on this host - every case
# here differs only in the workspace, so cmd_docker reaches docker_workspace
# without reinstalling anything.
#
# G6 and G7 are the pair that matter: each plants a file inside the workspace
# owned by somebody else and asserts that file's ownership afterwards. That is
# the assertion a recursive chown would break.
#
#   bash tests/test-docker-workspace.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
DEFAULT_WS="$USER_HOME/docker"
WS=/srv/dk
WS2=/srv/dk2
BASHRC="$USER_HOME/.bashrc"
BASHRC_SAVE=/tmp/ss-dw-bashrc.save
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
assert() { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }

owner() { stat -c '%U' "$1" 2>/dev/null; }
mode()  { stat -c '%a' "$1" 2>/dev/null; }
home_line() { grep -c "^export DOCKER_HOME=\"$1\"$" "$BASHRC" 2>/dev/null || true; }

cleanup_all() {
    sudo rm -rf "$WS" "$WS2" /srv/dk-file
    if [ -f "$BASHRC_SAVE" ]; then cp "$BASHRC_SAVE" "$BASHRC"; rm -f "$BASHRC_SAVE"; fi
}
trap cleanup_all EXIT

echo "### preparing"
cp "$BASHRC" "$BASHRC_SAVE"
sudo mkdir -p /srv
sudo rm -rf "$WS" "$WS2" /srv/dk-file
echo "  user=$USER_NAME  default workspace=$DEFAULT_WS"

echo
echo "=== G3/G4/G5: the value must be an absolute path to a directory ==="
run G3  2 "must be an absolute path" docker --workspace srv/dk
run G3b 2 "must be an absolute path" docker -w ./dk
run G4  2 "refusing to use / as the workspace" docker --workspace /
run G4b 2 "refusing to use / as the workspace" docker --workspace //
sudo touch /srv/dk-file
run G5 2 "exists and is not a directory" docker --workspace /srv/dk-file
sudo rm -f /srv/dk-file
run G0 2 "--workspace requires a value" docker --workspace
run G0b 2 "cannot be combined with --workspace" docker --uninstall --workspace "$WS"

echo
echo "=== G1: a new workspace is created, owned by the user, and exported ==="
run G1 0 "created workspace folder $WS" docker --workspace "$WS"
assert G1b "[ -d '$WS' ]"
assert G1c "[ \"\$(owner '$WS')\" = '$USER_NAME' ]"
assert G1d "[ \"\$(mode '$WS')\" = 755 ]"
assert G1e "[ \"\$(home_line '$WS')\" = 1 ]"
# exactly one DOCKER_HOME line: block_upsert replaces, it does not accumulate
assert G1f "[ \"\$(grep -c '^export DOCKER_HOME=' '$BASHRC')\" = 1 ]"

echo
echo "=== G6: an existing writable workspace is left completely alone ==="
# a file inside, owned by root - the thing a recursive chown would rewrite
sudo touch "$WS/root-owned"
sudo chmod 640 "$WS/root-owned"
sudo chmod 751 "$WS"
sudo chown "$USER_NAME:" "$WS"
WS_MODE="$(mode "$WS")"; WS_OWNER="$(owner "$WS")"
# It may take the convergence shortcut ("already configured") or reach
# docker_workspace and report the folder present - both are "touched nothing".
# What must never appear is a message about creating or repairing it.
OUT="$(bash "$SCRIPT" docker --workspace "$WS" 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "G6: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
if grep -qE "created workspace|fixing the directory" <<< "$OUT"; then
    bad "G6b: it modified a workspace the user could already write :: $OUT"
else ok; fi
assert G6b "[ \"\$(mode '$WS')\" = '$WS_MODE' ]"
assert G6c "[ \"\$(owner '$WS')\" = '$WS_OWNER' ]"
assert G6d "[ \"\$(owner '$WS/root-owned')\" = root ]"
assert G6e "[ \"\$(mode '$WS/root-owned')\" = 640 ]"

echo
echo "=== G7: a workspace the user cannot write is repaired - directory only ==="
sudo chown root: "$WS"
sudo chmod 755 "$WS"
assert G7a "! sudo -u '$USER_NAME' test -w '$WS'"
run G7 0 "nothing inside it was touched" docker --workspace "$WS"
assert G7b "[ \"\$(owner '$WS')\" = '$USER_NAME' ]"
assert G7c "sudo -u '$USER_NAME' test -w '$WS'"
# THE assertion: the file inside kept its original owner and mode
assert G7d "[ \"\$(owner '$WS/root-owned')\" = root ]"
assert G7e "[ \"\$(mode '$WS/root-owned')\" = 640 ]"

echo
echo "=== an unwritable workspace is not reported as already configured ==="
sudo chown root: "$WS"
sudo chmod 700 "$WS"
OUT="$(bash "$SCRIPT" docker --workspace "$WS" 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "W1: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
if grep -q "already configured" <<< "$OUT"; then bad "W1b: reported configured for a workspace the user cannot write"; else ok; fi
assert W1c "sudo -u '$USER_NAME' test -w '$WS'"

echo
echo "=== G8: changing --workspace repoints DOCKER_HOME, old dir stays ==="
run G8 0 "created workspace folder $WS2" docker --workspace "$WS2"
assert G8b "[ \"\$(home_line '$WS2')\" = 1 ]"
assert G8c "[ \"\$(home_line '$WS')\" = 0 ]"
assert G8d "[ \"\$(grep -c '^export DOCKER_HOME=' '$BASHRC')\" = 1 ]"
# this command never deletes data
assert G8e "[ -d '$WS' ]"
assert G8f "[ -f '$WS/root-owned' ]"

echo
echo "=== G9: the same thing through a document ==="
DOC=/tmp/ss-dw.json
sudo rm -rf "$WS"
printf '{"docker":{"workspace":"%s"}}\n' "$WS" > "$DOC"
run G9 0 "docker   ok" file "$DOC"
assert G9b "[ -d '$WS' ]"
assert G9c "[ \"\$(owner '$WS')\" = '$USER_NAME' ]"
assert G9d "[ \"\$(home_line '$WS')\" = 1 ]"

echo "--- and the document form is validated the same way ---"
printf '{"docker":{"workspace":"relative/path"}}\n' > "$DOC"
run G9e 2 "must be an absolute path" file "$DOC"
printf '{"docker":{"enabled":false,"workspace":"%s"}}\n' "$WS" > "$DOC"
run G9f 2 "cannot be combined with docker.enabled: false" file "$DOC"
printf '{"docker":{"workspace":123}}\n' > "$DOC"
run G9g 2 "workspace" file "$DOC"
printf '{"docker":{"nonsense":"x"}}\n' > "$DOC"
run G9h 2 "nonsense" file "$DOC"
rm -f "$DOC"

echo
echo "=== G2: no --workspace still means the default ==="
run G2 0 "" docker
assert G2b "[ \"\$(home_line '$DEFAULT_WS')\" = 1 ]"
assert G2c "[ -d '$DEFAULT_WS' ]"

echo
echo "=== the non-recursive rule is stated where it can be seen ==="
# G6/G7 assert the behaviour; this asserts the warning survives a refactor.
if grep -q 'DO NOT ADD -R' "$SCRIPT"; then ok; else bad "R1: the non-recursive warning is gone"; fi
if grep -nE 'chown[^|]*-R|chmod[^|]*-R' "$SCRIPT" | grep -q .; then
    bad "R2: a recursive chown/chmod appeared in the script"
else ok; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
