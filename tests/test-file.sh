#!/usr/bin/env bash
# Host tests for `system-setup file` (plan phase 13, test cases 70-77).
#
# The validation cases are safe anywhere. The one execution case deliberately
# uses --dry-run plus a tz-only document, so this suite never reconfigures the
# host's network. Full-sequence execution is exercised separately.
#
#   bash tests/test-file.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
TMP=/tmp/ss-file-tests
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# j <name> <json> -- write a document and echo its path
j() { mkdir -p "$TMP"; printf '%s\n' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }

# run <id> <want_rc> <pattern> -- args...
run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: rc=$rc want=$want :: $(tail -4 <<< "$out")"; return; fi
    if [ -n "$pat" ] && ! grep -qE "$pat" <<< "$out"; then bad "$id: missing /$pat/ :: $(tail -4 <<< "$out")"; return; fi
    ok
}
nomatch() {
    local id="$1" pat="$2"; shift 2
    local out
    out="$(bash "$SCRIPT" "$@" 2>&1)"
    if grep -qE "$pat" <<< "$out"; then bad "$id: output unexpectedly matched /$pat/"; else ok; fi
}

trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP"; mkdir -p "$TMP"

echo "=== 70: structural errors ==="
run 70a 2 "unknown root node: 'nope'"        file "$(j unknown_root '{"nope":{}}')"
run 70b 2 "unknown field: hdd.wrong"         file "$(j unknown_field '{"hdd":{"wrong":"x"}}')"
run 70c 2 "aliases for the same field"       file "$(j both_alias '{"network":{"name":"a.b","hostname":"a.b","ip":"10.0.0.1/24"}}')"
run 70d 2 "no configuration nodes"           file "$(j empty '{}')"
run 70e 2 "must be a JSON object"            file "$(j notobj '[1,2,3]')"

echo
echo "=== 71: ntp.server must be an array ==="
run 71a 2 "ntp.server must be an array"      file "$(j ntp_str '{"ntp":{"server":"10.0.0.1"}}')"
run 71b 2 "must not be empty"                file "$(j ntp_empty '{"ntp":{"server":[]}}')"
run 71c 0 ""                                 file --dry-run "$(j ntp_ok '{"ntp":{"server":["10.0.0.1","ntp.my.local"]}}')"
run 71d 2 "invalid ntp.server entry"         file "$(j ntp_bad '{"ntp":{"server":["bad_name.local"]}}')"

echo
echo "=== type checking ==="
run t1 2 "network.dns must be array"         file "$(j dns_str '{"network":{"name":"a.b","ip":"10.0.0.1/24","dns":"10.0.0.2"}}')"
run t2 2 "docker.size must be number"        file "$(j size_str '{"docker":{"network":"10.1.0.0/16","size":"24"}}')"
run t3 2 "network.ipv6 must be boolean"      file "$(j ipv6_str '{"network":{"name":"a.b","ip":"10.0.0.1/24","ipv6":"false"}}')"
run t4 2 "tz must be a string"               file "$(j tz_num '{"tz":123}')"

echo
echo "=== value validation reuses the CLI predicates ==="
run v1 2 "invalid tz"                        file "$(j bad_tz '{"tz":"Nowhere/Nope"}')"
run v2 2 "invalid hdd.type"                  file "$(j bad_fs '{"hdd":{"type":"btrfs"}}')"
run v3 2 "invalid docker.network"            file "$(j bad_cidr '{"docker":{"network":"10.1.0.0"}}')"
run v4 2 "invalid docker.size"               file "$(j bad_size '{"docker":{"network":"10.1.0.0/16","size":8}}')"
run v5 2 "must include the domain"           file "$(j short_name '{"network":{"name":"web01","ip":"10.0.0.1/24"}}')"
run v6 2 "network.name is required"          file "$(j no_name '{"network":{"ip":"10.0.0.1/24"}}')"
run v7 2 "network.ip is required"            file "$(j no_ip '{"network":{"name":"a.b.local"}}')"
run v8 2 "invalid network.gateway"           file "$(j bad_gw '{"network":{"name":"a.b.local","ip":"10.0.0.1/24","gateway":"10.0.0.999"}}')"
run v9 2 "docker.size requires docker.network" file "$(j size_only '{"docker":{"size":24}}')"

echo
echo "=== 72: every problem reported in one run, nothing executed ==="
MULTI="$(j multi '{"tz":"Nowhere/Nope","network":{"name":"web01","ip":"10.0.0.1/24","gateway":"999.1.1.1"}}')"
run 72a 2 "invalid tz"                       file "$MULTI"
run 72b 2 "must include the domain"          file "$MULTI"
run 72c 2 "invalid network.gateway"          file "$MULTI"
run 72d 2 "3 problem\(s\) found"             file "$MULTI"
run 72e 2 "nothing was executed"             file "$MULTI"

echo
echo "=== 74: execution order is fixed regardless of key order ==="
SCRAMBLED="$(j scrambled '{"network":{"name":"a.b.local","ip":"10.9.9.9/24","restart":false},"ntp":{"server":["10.9.9.1"]},"tz":"UTC","docker":{},"hdd":{"device":"/dev/sdb"}}')"
ORDER="$(bash "$SCRIPT" file --dry-run "$SCRAMBLED" 2>&1 | grep -oE '^\[(tz|hdd|docker|ntp|network)\]' | tr -d '[]' | tr '\n' ' ')"
if [ "$ORDER" = "tz hdd docker ntp network " ]; then ok; else bad "74: order was '$ORDER'"; fi
run 74b 0 "plan for .*: tz hdd docker ntp network" file --dry-run "$SCRAMBLED"

echo
echo "=== 75: --dry-run changes nothing ==="
TZ_BEFORE="$(timedatectl show -p Timezone --value)"
DRY="$(j dryrun '{"tz":"America/Denver","hdd":{"device":"/dev/sdb","mount":"/ss-dry"}}')"
run 75a 0 "would run: system-setup tz America/Denver" file --dry-run "$DRY"
run 75b 0 "nothing was changed"                      file --dry-run "$DRY"
if [ "$(timedatectl show -p Timezone --value)" = "$TZ_BEFORE" ]; then ok; else bad "75c: timezone changed during a dry run"; fi
if [ ! -d /ss-dry ]; then ok; else bad "75d: dry run created /ss-dry"; fi

echo
echo "=== aliases are accepted ==="
run a1 0 "would run: system-setup ip 10.9.9.9/24 --hostname a.b.local" \
    file --dry-run "$(j aliases '{"network":{"hostname":"a.b.local","address":"10.9.9.9/24","mask":"255.255.255.0","restart":false}}')"

echo
echo "=== enabled:false maps to --uninstall ==="
run e1 0 "would run: system-setup docker --uninstall" file --dry-run "$(j dis_docker '{"docker":{"enabled":false}}')"
run e2 0 "would run: system-setup ntp --uninstall"    file --dry-run "$(j dis_ntp '{"ntp":{"enabled":false}}')"
run e3 2 "cannot be combined"                         file "$(j dis_conflict '{"ntp":{"enabled":false,"server":["10.0.0.1"]}}')"

echo
echo "=== ipv6/restart: false turns off, true leaves alone ==="
run i1 0 "\-\-no-ipv6"  file --dry-run "$(j v6off '{"network":{"name":"a.b.local","ip":"10.9.9.9/24","ipv6":false,"restart":false}}')"
nomatch i2 "\-\-no-ipv6" file --dry-run "$(j v6on '{"network":{"name":"a.b.local","ip":"10.9.9.9/24","ipv6":true,"restart":false}}')"

echo
echo "=== 76/77: file mode routing ==="
run 76a 5 "file not found"    file /tmp/definitely-missing-xyz.json
run 76b 3 "not valid JSON"    file "$(j broken '{ not json')"
# Implicit file mode takes EXACTLY one argument, so it cannot carry --dry-run.
# Use a document whose only node is already satisfied: it runs for real but
# changes nothing.
TZONLY="$(j tzonly "{\"tz\":\"$TZ_BEFORE\"}")"
run 76c 0 "tz       ok"       "$TZONLY"
printf '%s\n' 'not a command' > "$TMP/docker"
if ( cd "$TMP" && bash "$SCRIPT" docker -h 2>&1 | grep -q "system-setup docker" ); then
    ok
else
    bad "77: a file named 'docker' shadowed the command"
fi

echo
echo "=== 73: a failing node does not stop the sequence ==="
# hdd points at a device that does not exist (exit 5); tz must still run.
FAILSEQ="$(j failseq '{"tz":"UTC","hdd":{"device":"/dev/definitely-not-here"}}')"
run 73a 5 "hdd      failed \(5\)" file "$FAILSEQ"
run 73b 5 "tz       ok"           file "$FAILSEQ"
if [ "$(timedatectl show -p Timezone --value)" = "UTC" ]; then ok; else bad "73c: tz did not actually run"; fi
sudo timedatectl set-timezone "$TZ_BEFORE"

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
