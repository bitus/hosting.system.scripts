#!/usr/bin/env bash
# Host tests for `system-setup ntp` (plan phase 6, test cases 59-67).
# MUTATES /etc/systemd/timesyncd.conf - run on the disposable test VM only.
#
#   bash tests/test-ntp.sh

set -uo pipefail

SCRIPT="${SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/system-setup}"
CONF=/etc/systemd/timesyncd.conf
BAK=/etc/systemd/timesyncd.conf.bak
PASS=0; FAIL=0
declare -a FAILURES=()

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# run <case> <want_rc> <pattern> -- args...
run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$*] rc=$rc want=$want :: $out"; return; fi
    if [ -n "$pat" ] && ! grep -qE "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $out"; return; fi
    ok
}

# conf_ntp -- the effective NTP= line
conf_ntp() { sudo sed -n 's/^[[:space:]]*NTP[[:space:]]*=[[:space:]]*//p' "$CONF" | head -1; }

expect_ntp() {
    local id="$1" want="$2" got
    got="$(conf_ntp)"
    if [ "$got" = "$want" ]; then ok; else bad "$id: NTP='$got' want='$want'"; fi
}

echo "=== reset to a pristine state ==="
sudo rm -f "$BAK"
sudo cp /usr/lib/systemd/timesyncd.conf "$CONF" 2>/dev/null \
    || sudo tee "$CONF" >/dev/null <<'EOF'
#  This file is part of systemd.
[Time]
#NTP=
#FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org
EOF
echo "start: NTP='$(conf_ntp)'  bak=$( [ -f "$BAK" ] && echo present || echo absent )"

echo
echo "=== 59: default server is the gateway ==="
GW="$(ip route show default 0.0.0.0/0 | awk '{print $3; exit}')"
echo "default gateway: $GW"
run 59 0 "ntp configured: $GW" ntp
expect_ntp 59b "$GW"
# the pristine backup must now exist and must NOT contain our value
if [ -f "$BAK" ] && ! sudo grep -qE "^NTP=$GW" "$BAK"; then ok; else bad "59c: $BAK missing or already polluted"; fi

echo
echo "=== 61: a server that is one of this host's own addresses ==="
SELF_IP="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
echo "host address: $SELF_IP"
run 61 2 "is an address of this host" ntp -s "$SELF_IP"

echo
echo "=== 62: multiple servers, order preserved, one NTP= line ==="
run 62 0 "ntp configured: ntp1.my.local ntp2.my.local" ntp -s ntp1.my.local -s ntp2.my.local
expect_ntp 62b "ntp1.my.local ntp2.my.local"
LINES="$(sudo grep -c '^NTP=' "$CONF")"
if [ "$LINES" = "1" ]; then ok; else bad "62c: expected exactly 1 NTP= line, found $LINES"; fi

echo
echo "=== 63: same servers reversed is NOT 'already configured' ==="
run 63 0 "ntp configured: ntp2.my.local ntp1.my.local" ntp -s ntp2.my.local -s ntp1.my.local
expect_ntp 63b "ntp2.my.local ntp1.my.local"

echo
echo "=== idempotency: identical re-run changes nothing ==="
run i1 0 "already configured" ntp -s ntp2.my.local -s ntp1.my.local
expect_ntp i2 "ntp2.my.local ntp1.my.local"

echo
echo "=== duplicate collapse ==="
run d1 0 "duplicate NTP server" ntp -s 10.9.9.9 -s 10.9.9.9 -s 10.9.9.8
expect_ntp d2 "10.9.9.9 10.9.9.8"

echo
echo "=== mixed IP and name forms ==="
run m1 0 "ntp configured: 10.9.9.9 ntp1.my.local" ntp -s 10.9.9.9 -s ntp1.my.local
expect_ntp m2 "10.9.9.9 ntp1.my.local"

echo
echo "=== 65: uninstall restores the pristine backup byte-for-byte ==="
sudo cp "$BAK" /tmp/ntp-expected.conf
run 65 0 "returned to the distribution default" ntp -u
if sudo cmp -s /tmp/ntp-expected.conf "$CONF"; then ok; else bad "65b: $CONF differs from the pristine backup"; fi

echo
echo "=== 66: uninstall with no backup writes a bare [Time] ==="
sudo rm -f "$BAK"
run 66 0 "not found; writing a bare" ntp -u
if sudo grep -q '^\[Time\]$' "$CONF" && ! sudo grep -q '^NTP=' "$CONF"; then ok; else bad "66b: unexpected $CONF content"; fi

echo
echo "=== 67 / argument errors ==="
run 67 2 "takes no positional arguments" ntp 10.10.10.254
run a1 2 "cannot be combined"            ntp -u -s 10.10.10.254
run a2 2 "invalid NTP server"            ntp -s 'bad_name.local'

echo
echo "=== service is actually running and enabled ==="
bash "$SCRIPT" ntp >/dev/null 2>&1
if systemctl is-active --quiet systemd-timesyncd; then ok; else bad "svc: systemd-timesyncd is not active"; fi
if [ "$(timedatectl show -p NTP --value)" = "yes" ]; then ok; else bad "svc2: NTP not enabled"; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
