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

# y <name> <yaml> -- write a YAML document and echo its path
y() { mkdir -p "$TMP"; printf '%s\n' "$2" > "$TMP/$1.yaml"; printf '%s' "$TMP/$1.yaml"; }

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
run 76b 3 "neither valid JSON nor valid YAML" file "$(j broken '{ not json')"
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
echo "=== D: YAML input ==="

echo "--- D1: a JSON document must not need yq at all ---"
# Temporarily hide yq: a JSON-only operator must never be forced to install it.
YQ_REAL="$(command -v yq || true)"
if [ -n "$YQ_REAL" ]; then
    sudo mv "$YQ_REAL" "$YQ_REAL.hidden"
    run D1 0 "would run: system-setup tz UTC" file --dry-run "$(j d1 '{"tz":"UTC"}')"
    sudo mv "$YQ_REAL.hidden" "$YQ_REAL"
else
    echo "  (yq not installed, skipping)"
fi

echo "--- D2: equivalent YAML and JSON produce identical plans ---"
JDOC="$(j d2j '{"tz":"UTC","ntp":{"server":["10.0.0.1"]}}')"
YDOC="$(y d2y 'tz: UTC
ntp:
  server:
    - 10.0.0.1')"
PJ="$(bash "$SCRIPT" file --dry-run "$JDOC" 2>&1 | grep 'would run' | sed 's#/tmp/[^ ]*##')"
PY_="$(bash "$SCRIPT" file --dry-run "$YDOC" 2>&1 | grep 'would run' | sed 's#/tmp/[^ ]*##')"
if [ "$PJ" = "$PY_" ] && [ -n "$PJ" ]; then ok; else bad "D2: plans differ:: J=$PJ Y=$PY_"; fi

echo "--- D3: a full YAML document validates ---"
FULL="$(y d3 'tz: America/Denver
hdd:
  device: /dev/sdb
  mount: /data
  type: ext4
docker:
  network: 10.100.0.0/16
  size: 24
ntp:
  server:
    - 10.127.1.254
network:
  name: test.home.local
  ip: 10.9.9.9/24
  gateway: 10.9.9.254
  dns:
    - 10.9.9.254
  ipv6: false
  restart: false')"
run D3 0 "plan for .*: tz hdd docker ntp network" file --dry-run "$FULL"
run D3b 0 "would run: system-setup ip 10.9.9.9/24 --hostname test.home.local" file --dry-run "$FULL"

echo "--- D4/D5: the strict rules survive the conversion ---"
run D4 2 "unknown field: hdd.wrong"     file "$(y d4 'hdd:
  wrong: x')"
run D5 2 "ntp.server must be an array"  file "$(y d5 'ntp:
  server: 10.0.0.1')"
run D5b 2 "unknown root node"           file "$(y d5b 'nope: {}')"
run D5c 2 "must include the domain"     file "$(y d5c 'network:
  name: web01
  ip: 10.0.0.1/24')"

echo "--- D6/D7: malformed input ---"
run D6 3 "neither valid JSON nor valid YAML" file "$(y d6 'tz: [unclosed')"
# Nearly any single line of text is a VALID YAML scalar, so it converts
# cleanly and is then rejected downstream for not being an object. "Invalid
# YAML" is a much narrower category than it looks - it needs genuinely
# malformed structure, as in D6.
run D7 2 "must be a JSON object" file "$(j d7 'this is not markup at all')"

echo "--- D8: content decides, not the extension ---"
# a .json file that actually contains YAML must still work
YAML_IN_JSON="$TMP/d8.json"
printf 'tz: UTC' > "$YAML_IN_JSON"
run D8 0 "would run: system-setup tz UTC" file --dry-run "$YAML_IN_JSON"

echo "--- D9: messages quote the SOURCE, never the temp conversion ---"
D9OUT="$(bash "$SCRIPT" file "$(y d9 'tz: Nowhere/Nope')" 2>&1)"
if grep -q "d9.yaml" <<< "$D9OUT"; then ok; else bad "D9: source path not quoted :: $D9OUT"; fi
if grep -q "/tmp/ss-file\." <<< "$D9OUT"; then bad "D9b: leaked the temp conversion path :: $D9OUT"; else ok; fi

echo "--- D10: the temp conversion is cleaned up ---"
BEFORE_N="$(find /tmp -maxdepth 1 -name 'ss-file.*.json' 2>/dev/null | wc -l)"
bash "$SCRIPT" file --dry-run "$(y d10 'tz: UTC')" >/dev/null 2>&1
AFTER_N="$(find /tmp -maxdepth 1 -name 'ss-file.*.json' 2>/dev/null | wc -l)"
if [ "$BEFORE_N" = "$AFTER_N" ]; then ok; else bad "D10: temp files left behind ($BEFORE_N -> $AFTER_N)"; fi

echo "--- D11: yq flavour detection ---"
FLAV="$(bash -c "source '$SCRIPT'; yq_flavour")"
case "$FLAV" in
    kislyuk|mikefarah) ok ;;
    *) bad "D11: unrecognised yq flavour '$FLAV'" ;;
esac

echo "--- D12: duplicate YAML keys are last-wins, by design ---"
# Pinned deliberately. yq resolves duplicates during the conversion, so no
# downstream check can see them. Making this strict later is a visible change,
# not an accident. See the backlog.
run D12 0 "would run: system-setup tz UTC" file --dry-run "$(y d12 'tz: America/Denver
tz: UTC')"


echo
echo "=== E: configuration on stdin ==="
TZNOW="$(timedatectl show -p Timezone --value)"

echo "--- E1/E2: JSON and YAML piped to a bare invocation ---"
OUT="$(printf '{"tz":"%s"}' "$TZNOW" | bash "$SCRIPT" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'tz       ok' <<< "$OUT"; then ok; else bad "E1: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
OUT="$(printf 'tz: %s' "$TZNOW" | bash "$SCRIPT" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'tz       ok' <<< "$OUT"; then ok; else bad "E2: rc=$RC :: $(tail -3 <<< "$OUT")"; fi

echo "--- E3: the explicit file - form ---"
OUT="$(printf 'tz: %s' "$TZNOW" | bash "$SCRIPT" file - 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'tz       ok' <<< "$OUT"; then ok; else bad "E3: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
OUT="$(printf 'tz: %s' "$TZNOW" | bash "$SCRIPT" file - --dry-run 2>&1)"
if grep -q 'nothing was changed' <<< "$OUT"; then ok; else bad "E3b: --dry-run with - :: $(tail -3 <<< "$OUT")"; fi

echo "--- E4: --verbose is honoured through stdin ---"
OUT="$(printf 'tz: %s' "$TZNOW" | bash "$SCRIPT" --verbose 2>&1)"
if grep -q 'debug:' <<< "$OUT"; then ok; else bad "E4: no debug output"; fi

echo "--- E5: as a NON-ROOT user, the document must survive the sudo re-exec ---"
# This is the case that matters. Everything works as root; only a non-root run
# exercises the re-exec that would otherwise hand the child a drained stdin.
if [ "$EUID" -ne 0 ]; then
    OUT="$(printf 'tz: %s' "$TZNOW" | bash "$SCRIPT" 2>&1)"; RC=$?
    if [ "$RC" = 0 ] && grep -q 'tz       ok' <<< "$OUT"; then ok; else bad "E5: rc=$RC :: $(tail -5 <<< "$OUT")"; fi
    if grep -qi 'no configuration received' <<< "$OUT"; then bad "E5b: stdin was lost across the re-exec"; else ok; fi
else
    echo "  (running as root, cannot exercise the re-exec)"
fi

echo "--- E6/E7: empty and unusable stdin ---"
OUT="$(printf '' | bash "$SCRIPT" 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q 'no configuration received on stdin' <<< "$OUT"; then ok; else bad "E6: rc=$RC :: $OUT"; fi
OUT="$(printf 'tz: [unclosed' | bash "$SCRIPT" 2>&1)"; RC=$?
if [ "$RC" = 3 ]; then ok; else bad "E7: rc=$RC want 3 :: $OUT"; fi

echo "--- E8: an interactive bare invocation still prints help ---"
# stdin a TTY -> help, exit 2, unchanged. script(1) provides the pty.
OUT="$(script -qec "bash $SCRIPT" /dev/null < /dev/null 2>&1 || true)"
if grep -q 'Usage:' <<< "$OUT"; then ok; else bad "E8: no help on a TTY bare invocation :: $(tail -3 <<< "$OUT")"; fi

echo "--- E9: messages say (stdin), never a temp path ---"
OUT="$(printf 'tz: Nowhere/Nope' | bash "$SCRIPT" 2>&1)"
if grep -q '(stdin)' <<< "$OUT"; then ok; else bad "E9: source not reported as (stdin) :: $OUT"; fi
if grep -qE '/tmp/ss-(stdin|file)\.' <<< "$OUT"; then bad "E9b: leaked a temp path :: $OUT"; else ok; fi

echo "--- no temp files left behind by any of the above ---"
LEFT="$(find /tmp -maxdepth 1 \( -name 'ss-stdin.*' -o -name 'ss-file.*' \) 2>/dev/null | wc -l)"
if [ "$LEFT" = 0 ]; then ok; else bad "E-cleanup: $LEFT temp file(s) left behind"; fi


echo
echo "=== F: --force for system-setup file ==="

# A loop device already formatted xfs; the document asks for ext4. Without
# --force that must be refused; with it, reformatted.
FIMG=/tmp/ss-f.img
FMNT=/tmp/ss-fmnt
sudo umount "$FMNT" 2>/dev/null || true
sudo rm -f "$FIMG"; sudo mkdir -p "$FMNT"
truncate -s 512M "$FIMG"
FLOOP="$(sudo losetup -f --show -P "$FIMG")"
printf 'label: gpt
start=2048, type=linux
' | sudo sfdisk "$FLOOP" >/dev/null 2>&1
sudo udevadm settle
sudo mkfs.xfs -f "${FLOOP}p1" >/dev/null 2>&1
sudo sed -i "\#$FMNT#d" /etc/fstab

fdoc() { j "$1" "{\"hdd\":{\"device\":\"$FLOOP\",\"mount\":\"$FMNT\",\"type\":\"ext4\"}}"; }

echo "--- F1: without --force the node is refused ---"
run F1 4 "hdd      failed \(4\)" file "$(fdoc f1)"
if [ "$(sudo blkid -s TYPE -o value "${FLOOP}p1")" = xfs ]; then ok; else bad "F1b: disk was modified without --force"; fi

echo "--- F5: --dry-run --force shows the flag and changes nothing ---"
run F5 0 "would run: system-setup hdd .*--force" file --dry-run --force "$(fdoc f5)"
if [ "$(sudo blkid -s TYPE -o value "${FLOOP}p1")" = xfs ]; then ok; else bad "F5b: dry run modified the disk"; fi

echo "--- F2/F3/F4: --force permits it, long and short, as a non-root user ---"
run F2 0 "hdd      ok" file --force "$(fdoc f2)"
if [ "$(sudo blkid -s TYPE -o value "${FLOOP}p1")" = ext4 ]; then ok; else bad "F2b: not reformatted"; fi
# F4: the flag has to survive the sudo re-exec. As root there is no re-exec,
# so this only proves anything when the suite runs unprivileged.
if [ "$EUID" -ne 0 ]; then ok; else bad "F4: suite is running as root, --force re-exec not exercised"; fi
sudo mkfs.xfs -f "${FLOOP}p1" >/dev/null 2>&1
sudo umount "$FMNT" 2>/dev/null || true
sudo sed -i "\#$FMNT#d" /etc/fstab
run F3 0 "hdd      ok" file -f "$(fdoc f3)"
if [ "$(sudo blkid -s TYPE -o value "${FLOOP}p1")" = ext4 ]; then ok; else bad "F3b: short -f did not force"; fi

echo "--- F6: --force through stdin ---"
sudo mkfs.xfs -f "${FLOOP}p1" >/dev/null 2>&1
sudo umount "$FMNT" 2>/dev/null || true
sudo sed -i "\#$FMNT#d" /etc/fstab
OUT="$(printf 'hdd:
  device: %s
  mount: %s
  type: ext4
' "$FLOOP" "$FMNT" | bash "$SCRIPT" --force 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'hdd      ok' <<< "$OUT"; then ok; else bad "F6: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
if [ "$(sudo blkid -s TYPE -o value "${FLOOP}p1")" = ext4 ]; then ok; else bad "F6b: stdin --force did not take effect"; fi

echo "--- F7: no confirmation prompts remain anywhere ---"
if grep -q 'confirm "' "$SCRIPT"; then bad "F7: a confirm call site still exists"; else ok; fi
if grep -q '^confirm() {' "$SCRIPT"; then ok; else bad "F7b: confirm() helper was removed; it should stay"; fi
# The real property: a forcing run completes with NO tty on stdin.
sudo mkfs.xfs -f "${FLOOP}p1" >/dev/null 2>&1
sudo umount "$FMNT" 2>/dev/null || true
sudo sed -i "\#$FMNT#d" /etc/fstab
OUT="$(bash "$SCRIPT" file --force "$(fdoc f7)" < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "F7c: forcing run needed a tty :: $(tail -3 <<< "$OUT")"; fi

# teardown
sudo umount "$FMNT" 2>/dev/null || true
sudo losetup -d "$FLOOP" 2>/dev/null || true
sudo rm -f "$FIMG"; sudo rmdir "$FMNT" 2>/dev/null || true
sudo sed -i "\#$FMNT#d" /etc/fstab
sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
