#!/usr/bin/env bash
# Host tests for `system-setup docker` (plan phase 7, test cases 31-42).
# INSTALLS AND REMOVES DOCKER - run on the disposable test VM only.
#
#   bash tests/test-docker.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
BASHRC="$HOME/.bashrc"
WS="$HOME/docker"
DAEMON=/etc/docker/daemon.json
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

# run_alt <script> <id> <want_rc> <pattern> -- args...
run_alt() {
    local alt="$1" id="$2" want="$3" pat="$4"; shift 4
    local out rc
    out="$(bash "$alt" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$alt $*] rc=$rc want=$want :: $(tail -3 <<< "$out")"; return; fi
    if [ -n "$pat" ] && ! grep -qE "$pat" <<< "$out"; then bad "$id: [$alt $*] missing /$pat/"; return; fi
    ok
}

assert()     { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }
block_count(){ grep -cF "$1" "$BASHRC" 2>/dev/null || true; }

echo "### reset to a known state (this suite must be re-runnable)"
# Test 31 appends an id-less block unconditionally, so a second run would
# otherwise start with two of them and fail its own count assertion.
sed -i '/# >>> system-setup/,/# <<< system-setup/d' "$BASHRC"
echo "installing/converging docker..."
bash "$SCRIPT" docker >/dev/null 2>&1 || { echo "FATAL: install failed"; exit 1; }

echo
echo "=== 32: second run is idempotent ==="
run 32 0 "already configured" docker
assert 32b "[ \"\$(block_count '>>> system-setup docker >>>')\" = 1 ]"

echo
echo "=== 33: pre-existing workspace keeps its ownership and mode ==="
sudo chmod 700 "$WS"; sudo chown nobody: "$WS"
BEFORE="$(stat -c '%U:%G %a' "$WS")"
run 33 0 "" docker
AFTER="$(stat -c '%U:%G %a' "$WS")"
if [ "$BEFORE" = "$AFTER" ]; then ok; else bad "33: workspace changed $BEFORE -> $AFTER"; fi
sudo chown "$USER:" "$WS"; sudo chmod 755 "$WS"

echo
echo "=== 34: workspace belongs to the invoking user, not root ==="
assert 34 "[ \"\$(stat -c '%U' '$WS')\" = \"$USER\" ]"
assert 34b "[ \"\$(dirname '$WS')\" = \"\$HOME\" ]"
assert 34c "id -nG $USER | grep -qw docker"

echo
echo "=== 31: the docker and setup .bashrc blocks must not eat each other ==="
# cmd_setup is phase 12; simulate its id-less block to prove block isolation.
# shellcheck disable=SC2016  # the literal $PATH is the point: this mimics what cmd_setup writes
printf '%s\n%s\n%s\n' '# >>> system-setup >>>' 'export PATH="$PATH:/usr/local/sbin"' '# <<< system-setup <<<' >> "$BASHRC"
run 31 0 "" docker
assert 31b "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert 31c "[ \"\$(block_count '>>> system-setup docker >>>')\" = 1 ]"
assert 31d "grep -q 'export PATH=' '$BASHRC'"

echo
echo "=== the resulting ~/.bashrc must source without errors ==="
# The block being present is not enough: a CRLF-terminated shortcuts file
# parses fine as a filename and breaks every login shell that sources it.
# -i, not -l: Debian's ~/.bashrc returns immediately when not interactive,
# so a login shell would source nothing and the check would pass vacuously.
# bash -i without a tty always emits job-control notices; those are the
# harness's own noise, not anything ~/.bashrc did. Filter only those.
SHELL_ERR="$(bash -ic true 2>&1 | grep -vE '^$|cannot set terminal process group|no job control in this shell')"
if [ -z "$SHELL_ERR" ]; then ok; else bad "sh1: login shell emits errors :: $SHELL_ERR"; fi
if bash -n "$REPO/docker-shortcuts" 2>/dev/null; then ok; else bad "sh2: docker-shortcuts is not valid bash"; fi
if LC_ALL=C grep -q "$(printf '\r')" "$REPO/docker-shortcuts"; then bad "sh3: docker-shortcuts has CRLF line endings"; else ok; fi

echo
echo "=== 36: a moved repository is reconciled to the new path ==="
cp -a "$REPO" /tmp/ss-moved
run_alt /tmp/ss-moved/system-setup 36 0 "shell shortcuts" docker
assert 36b "grep -q '/tmp/ss-moved/docker-shortcuts' '$BASHRC'"
assert 36c "[ \"\$(block_count '>>> system-setup docker >>>')\" = 1 ]"
# put it back
run 36d 0 "" docker
assert 36e "grep -q '$REPO/docker-shortcuts' '$BASHRC'"
rm -rf /tmp/ss-moved

echo
echo "=== 35: missing docker-shortcuts warns but does not fail ==="
mv "$REPO/docker-shortcuts" /tmp/docker-shortcuts.hidden
run 35 0 "not found beside the script" docker
mv /tmp/docker-shortcuts.hidden "$REPO/docker-shortcuts"
run 35b 0 "" docker

echo
echo "=== 37: daemon.json merge preserves unrelated keys ==="
sudo rm -f "$DAEMON" "$DAEMON.bak"
sudo mkdir -p /etc/docker
printf '%s\n' '{"log-driver":"json-file","log-opts":{"max-size":"10m"}}' | sudo tee "$DAEMON" >/dev/null
run 37 0 "address pool set to 10.100.0.0/16" docker --network 10.100.0.0/16 --size 24
assert 37b "[ \"\$(sudo jq -r '.[\"log-driver\"]' $DAEMON)\" = 'json-file' ]"
assert 37c "[ \"\$(sudo jq -r '.[\"log-opts\"][\"max-size\"]' $DAEMON)\" = '10m' ]"
assert 37d "[ \"\$(sudo jq -c '.[\"default-address-pools\"]' $DAEMON)\" = '[{\"base\":\"10.100.0.0/16\",\"size\":24}]' ]"
assert 37e "sudo test -f $DAEMON.bak"
echo "--- pool idempotency ---"
run 37f 0 "already configured" docker --network 10.100.0.0/16 --size 24
echo "--- a different pool reconfigures ---"
run 37g 0 "address pool set to 10.200.0.0/16" docker --network 10.200.0.0/16
assert 37h "[ \"\$(sudo jq -c '.[\"default-address-pools\"]' $DAEMON)\" = '[{\"base\":\"10.200.0.0/16\",\"size\":24}]' ]"

echo
echo "=== 38: malformed daemon.json is refused, file untouched ==="
printf '%s' '{ not json' | sudo tee "$DAEMON" >/dev/null
SUM_BEFORE="$(sudo md5sum "$DAEMON" | cut -d' ' -f1)"
run 38 3 "not valid JSON" docker --network 10.111.0.0/16
SUM_AFTER="$(sudo md5sum "$DAEMON" | cut -d' ' -f1)"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then ok; else bad "38b: $DAEMON was modified"; fi
sudo rm -f "$DAEMON"; sudo cp "$DAEMON.bak" "$DAEMON" 2>/dev/null || true

echo
echo "=== --purge no longer exists ==="
run p1 2 "unknown flag" docker -u --purge

echo
echo "=== 40: uninstall keeps /var/lib/docker and the workspace ==="
run 40 0 "Docker removed" docker -u
assert 40b "! dpkg-query -W -f='\${Status}' docker-ce 2>/dev/null | grep -q '^install ok installed$'"
assert 40c "test -d /var/lib/docker"
assert 40d "test -d '$WS'"
assert 40e "[ \"\$(block_count '>>> system-setup docker >>>')\" = 0 ]"
assert 40f "[ \"\$(block_count '>>> system-setup >>>')\" = 1 ]"
assert 40h "! test -f /etc/apt/sources.list.d/docker.list"

echo
echo "=== uninstall is non-destructive and says so ==="
run r1 0 "Docker installed" docker
touch "$WS/keep-me.txt"
run u1 0 "NOT removed and are left for you to handle" docker -u
assert u2 "test -d /var/lib/docker"
assert u3 "test -d '$WS'"
assert u4 "test -f '$WS/keep-me.txt'"
assert u5 "! command -v docker >/dev/null"
rm -f "$WS/keep-me.txt"

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
