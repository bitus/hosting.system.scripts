#!/usr/bin/env bash
# Unit tests for the pure validation layer (spec section "IP helper functions",
# plan phase 2, test cases 1-15) plus the router cases that need no host state.
#
# Runs anywhere with bash 5 - no root, no VM, no side effects.
#   bash tests/test-validation.sh

set -uo pipefail

SCRIPT="${SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/system-setup}"
PASS=0
FAIL=0
declare -a FAILURES=()

# The shipped script has no debug subcommands. It guards its `main` call with a
# BASH_SOURCE check, so this suite sources it and calls its functions directly
# - a better entry point than a hidden subcommand, and it leaves the shipped
# artifact free of test scaffolding.
# shellcheck source=/dev/null
source "$SCRIPT"
set +e                  # the script enables -e; this harness must not inherit it
IFS=$' 	
'            # and needs an ordinary IFS for its own word splitting

# v <case> <expected_rc> <expected_out> <fn> [args...]
# expected_out of '-' means "do not check stdout"
v() {
    local case_id="$1" want_rc="$2" want_out="$3"; shift 3
    local rc out
    out="$( "$@" 2>&1 )"; rc=$?

    if [ "$rc" != "$want_rc" ]; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: $* -> rc=$rc, want rc=$want_rc")
        return
    fi
    if [ "$want_out" != "-" ] && [ "$out" != "$want_out" ]; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: $* -> out='$out', want '$want_out'")
        return
    fi
    PASS=$((PASS + 1))
}

# res <case> <expected_rc> <pattern> [ip args...]
# Subshelled: ip_resolve ends failures with die(), which exits - without the
# subshell the first invalid case would kill this suite.
res() {
    local case_id="$1" want_rc="$2" pattern="$3"; shift 3
    local out rc
    out="$( ( ip_resolve "$@" && ip_print_plan ) 2>&1 )"; rc=$?
    if [ "$rc" != "$want_rc" ]; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: [$*] -> rc=$rc, want $want_rc")
        return
    fi
    if [ -n "$pattern" ] && ! grep -qE "$pattern" <<< "$out"; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: [$*] -> output missing /$pattern/")
        return
    fi
    PASS=$((PASS + 1))
}

# r <case> <expected_rc> <grep pattern in combined output> [args to system-setup...]
r() {
    local case_id="$1" want_rc="$2" pattern="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want_rc" ]; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: [$*] -> rc=$rc, want $want_rc")
        return
    fi
    if [ -n "$pattern" ] && ! grep -qE "$pattern" <<< "$out"; then
        FAIL=$((FAIL + 1)); FAILURES+=("$case_id: [$*] -> output missing /$pattern/")
        return
    fi
    PASS=$((PASS + 1))
}

echo "== 1-3: ip_valid =="
v 1a 0 - ip_valid 10.0.0.1
v 1b 0 - ip_valid 255.255.255.255
v 1c 0 - ip_valid 0.0.0.0
v 2a 1 - ip_valid 10.0.0.256
v 2b 1 - ip_valid 10.0.0
v 2c 1 - ip_valid 10.0.0.1.1
v 2d 1 - ip_valid abc
v 2e 1 - ip_valid ''
v 2f 1 - ip_valid 10.0.0.-1
v 3a 1 - ip_valid 010.1.1.1
v 3b 1 - ip_valid 10.10.10.010
v 3c 0 - ip_valid 10.10.10.0

echo "== 4-6: mask_to_bits =="
v 4a 0 24 mask_to_bits 24
v 4b 0 24 mask_to_bits 255.255.255.0
v 4c 0 16 mask_to_bits 255.255.0.0
v 4d 0 8  mask_to_bits 255.0.0.0
v 4e 0 30 mask_to_bits 255.255.255.252
v 5a 1 - mask_to_bits 255.0.255.0
v 5b 1 - mask_to_bits 255.255.0.255
v 6a 1 - mask_to_bits 7
v 6b 1 - mask_to_bits 31
v 6c 1 - mask_to_bits 32
v 6d 1 - mask_to_bits 0
v 6e 1 - mask_to_bits 255.255.255.255
v 6f 1 - mask_to_bits abc

echo "== 7-8: network arithmetic =="
v 7a 0 10.10.10.0    net_addr 10.10.10.10 24
v 7b 0 10.10.10.255  bcast_addr 10.10.10.10 24
v 7c 0 10.10.0.0     net_addr 10.10.10.10 16
v 7d 0 10.10.255.255 bcast_addr 10.10.10.10 16
v 7e 0 10.10.10.8    net_addr 10.10.10.10 30
v 7f 0 10.10.10.11   bcast_addr 10.10.10.10 30
v 7g 0 10.0.0.0      net_addr 10.10.10.10 8
v 8a 0 - same_net 10.10.10.10 10.10.99.1 16
v 8b 1 - same_net 10.10.10.10 10.11.0.1  16
v 8c 1 - same_net 10.10.10.10 10.10.11.1 24
v 8d 0 - same_net 10.10.10.10 10.10.10.254 24

echo "== 9-13: name validation =="
v 9  0 - fqdn_valid web01.vms.domain.local
v 10 1 - fqdn_valid web01
v 11 0 - dns_name_valid web01
v 12a 1 - dns_name_valid -bad.local
v 12b 1 - dns_name_valid bad-.local
v 12c 1 - dns_name_valid "$(printf 'a%.0s' {1..64}).local"
v 12d 0 - dns_name_valid "$(printf 'a%.0s' {1..63}).local"
v 12e 1 - dns_name_valid "$(printf 'a%.0s' {1..250}).abcdef"
v 12f 1 - dns_name_valid 'bad..local'
v 12g 1 - dns_name_valid '.local'
v 12h 1 - dns_name_valid 'local.'
v 12i 1 - dns_name_valid 'under_score.local'
v 13a 1 - dns_name_valid 1.2.3.999
v 13b 0 - dns_name_valid ntp1.my.local
v 13c 0 - fqdn_valid a.b

echo "== 14: tz_valid (path-shape checks only off-target) =="
v 14a 1 - tz_valid ../../etc/passwd
v 14b 1 - tz_valid /etc/passwd
v 14c 1 - tz_valid ''
v 14d 1 - tz_valid 'Nowhere/Nope'

echo "== 15: cidr_valid / pool_size_valid =="
v 15a 0 - cidr_valid 10.100.0.0/16
v 15b 1 - cidr_valid 10.100.0.0
v 15c 1 - cidr_valid 10.100.0.0/31
v 15d 1 - cidr_valid 10.100.0.256/16
v 15e 0 - pool_size_valid 24 16
v 15f 1 - pool_size_valid 8 16
v 15g 1 - pool_size_valid 31 16
v 15h 0 - pool_size_valid 16 16

echo "== 16-22: ip argument resolution =="
# These MUST use res(), never the real `ip`. Cases that expect resolution to
# SUCCEED would otherwise run the real command and reconfigure this host -
# which is exactly what happened once cmd_ip stopped being a stub.
res 16 0 'address:   10\.10\.10\.10/16'   10.10.10.10/24 -n web01.vms.domain.local --mask 16
res 17a 2 'network address'                10.10.10.0/24  -n web01.vms.domain.local
res 17b 2 'broadcast address'              10.10.10.255/24 -n web01.vms.domain.local
res 18 2 'not in the host network'         10.10.10.10/24 -n web01.vms.domain.local -g 10.11.0.1
res 19a 2 'gateway .* is the host IP'      10.10.10.10/24 -n web01.vms.domain.local -g 10.10.10.10
res 19b 2 'is the network address'         10.10.10.10/24 -n web01.vms.domain.local -g 10.10.10.0
res 19c 2 'is the broadcast address'       10.10.10.10/24 -n web01.vms.domain.local -g 10.10.10.255
res 20 2 'collides with the host IP'       10.10.10.254/24 -n web01.vms.domain.local
res 21 0 'dns:       10\.10\.10\.254'      10.10.10.10/24 -n web01.vms.domain.local
res 22 0 'duplicate DNS server'            10.10.10.10/24 -n web01.vms.domain.local -d 10.0.0.1 -d 10.0.0.1

echo "== hostname and mask errors =="
res h1 2 'must be a fully qualified name'  10.10.10.10/24 -n web01
res h2 2 'hostname is required'            10.10.10.10/24
res h3 2 'IP address is required'          -n web01.vms.domain.local
res h4 2 'invalid netmask'                 10.10.10.10 -n web01.vms.domain.local -m 255.0.255.0
res h5 2 'invalid netmask'                 10.10.10.10/31 -n web01.vms.domain.local
res h6 2 'invalid IP address'              10.10.10.999/24 -n web01.vms.domain.local

echo "== docker / ntp / hdd argument validation =="
r d1 2 'unknown flag'                          docker --purge
r d2 2 'requires --network'                    docker --size 24
r d3 2 'invalid --network'                     docker --network 10.100.0.0
r d4 2 'invalid --size'                        docker --network 10.100.0.0/16 --size 8
r d5 2 'unknown flag'                          docker --nope
r n1 2 'takes no positional arguments'         ntp 10.10.10.254
r n2 2 'cannot be combined'                    ntp -u -s 10.10.10.254
r n3 2 'invalid NTP server'                    ntp -s 'bad_name.local'
r n4 2 'unknown flag'                          ntp --nope
r t1 2 'invalid --type'                        hdd --type btrfs
r t2 2 'unexpected argument'                   hdd extra
r t3 2 'unknown flag'                          hdd --nope

echo "== 76-80: router =="
r 78 2 'Usage:'                    # bare invocation
r 79a 0 'Usage:'         --help
r 79b 0 'system-setup ip'          ip --help
r 79c 0 'system-setup hdd'         hdd -h
r 79d 0 'system-setup docker'      docker -h
r 79e 0 'system-setup ntp'         ntp -h
r 79f 0 'system-setup tz'          tz -h
r 79g 0 'system-setup file'        file -h
r 79h 0 'system-setup setup'       setup -h
r 77a 2 'unknown command'          nosuchcommand
r 76a 5 'file not found'           file ./definitely-missing.json
r t4 2 'a timezone is required'    tz
r t5 2 'invalid timezone'          tz Nowhere/Nope

echo
echo "== 83: no development scaffolding in the shipped script =="
# The harnesses used to build the validation and resolution layers must not
# ship. This suite reaches those functions by sourcing, not a subcommand.
if grep -qE "^(__validate|__resolve)\(\)" "$SCRIPT"; then
    FAIL=$((FAIL+1)); FAILURES+=("83: a development subcommand is still defined")
else
    PASS=$((PASS+1))
fi
for sub in __validate __resolve __parse __debug; do
    # No pipeline here: pipefail would take the script's exit 2 and mask the
    # grep result, making every case look like a failure.
    out83="$(bash "$SCRIPT" "$sub" 2>&1)"
    case "$out83" in
        *"unknown command"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILURES+=("83: '$sub' is still reachable as a subcommand") ;;
    esac
done
# and the guard that makes sourcing possible must still be there
# shellcheck disable=SC2016  # fixed-string pattern; expansion would defeat the search
if grep -qF 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then' "$SCRIPT"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILURES+=("83: the source guard is missing")
fi

echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
