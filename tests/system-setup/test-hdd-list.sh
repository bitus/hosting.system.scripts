#!/usr/bin/env bash
# Tests for the hdd command group and `hdd list`
# (fixes 2026-08-30, phase B, B1-B9).
#
#   bash tests/test-hdd-list.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"

# Root for the same reason the inspection suite needs it: the block devices are
# root:disk and blkid lives in /usr/sbin.
if [ "$EUID" -ne 0 ]; then
    echo "### re-running under sudo (disk inspection requires root)"
    exec sudo SCRIPT="$SCRIPT" bash "$0" "$@"
fi

PASS=0; FAIL=0
declare -a FAILURES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

IMG=/tmp/ss-list.img
LOOP=""
FSTAB_SAVE=/tmp/ss-list-fstab.save

cleanup() {
    [ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null
    rm -f "$IMG"
    if [ -f "$FSTAB_SAVE" ]; then cp "$FSTAB_SAVE" /etc/fstab; rm -f "$FSTAB_SAVE"; fi
    return 0
}
trap cleanup EXIT
cp /etc/fstab "$FSTAB_SAVE"

run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$*] rc=$rc want=$want :: $(tail -3 <<< "$out")"; return; fi
    if [ -n "$pat" ] && ! grep -qE "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $(tail -3 <<< "$out")"; return; fi
    ok
}

echo "=== B1/B2: the group router ==="
run B1  2 "init"        hdd
run B1b 2 "list"        hdd
run B2  2 "unknown hdd subcommand: nonsense" hdd nonsense
run B2b 2 "expand"      hdd nonsense

echo
echo "=== B3: help for the group and each subcommand ==="
run B3a 0 "system-setup hdd <subcommand>" hdd -h
run B3b 0 "hdd init"  hdd init -h
run B3c 0 "hdd list"  hdd list -h
run B3d 2 "unexpected argument" hdd list extra

echo
echo "=== list runs and prints a header ==="
run L1 0 "DEVICE +PARTITION +FS +MOUNT +SIZE +GROWABLE +FREE +FSTAB" hdd list
run L2 0 "/dev/sd"  hdd list

echo
echo "=== B8: loop devices are excluded ==="
rm -f "$IMG"; truncate -s 256M "$IMG"
LOOP="$(losetup -f --show -P "$IMG")"
printf 'label: gpt\nstart=2048, size=100M, type=linux\n' | sfdisk "$LOOP" >/dev/null 2>&1
udevadm settle
LPART="$(bash -c "source '$SCRIPT'; part_name '$LOOP' 1")"
mkfs.ext4 -F "$LPART" >/dev/null 2>&1
OUT="$(bash "$SCRIPT" hdd list 2>&1)"
if grep -q "$LOOP" <<< "$OUT"; then bad "B8: loop device appeared in the table"; else ok; fi

echo
echo "=== B4-B7: column logic, driven through an overridden dev_disks ==="
# `list` deliberately omits loop devices, so its per-partition columns cannot be
# exercised with one through the CLI. Sourcing the script and replacing
# dev_disks lets the real row-building code run against a device we control -
# without adding a test hook to the shipped script.
col() {   # col <partition> <column-number>
    awk -v p="$2" 'NR > 1 && $2 == "'"$1"'" { print $p }' <<< "$TABLE"
}
render() {
    TABLE="$(
        # shellcheck source=/dev/null
        source "$SCRIPT"
        # shellcheck disable=SC2317  # called indirectly, by cmd_hdd_list
        dev_disks() { printf '%s\n' "$LOOP"; }
        cmd_hdd_list
    )"
}

echo "--- B4: an entry in the managed block reports managed ---"
UUID="$(blkid -s UUID -o value "$LPART")"
sed -i "\\#$LPART#d" /etc/fstab
# clear any existing block first - a second one would shadow this
sed -i '/# >>> system-setup /,/# <<< system-setup /d' /etc/fstab
cat >> /etc/fstab <<EOF
# >>> system-setup >>>
UUID=$UUID  /tmp/ss-list-mnt  ext4  defaults,nofail  0  2
# <<< system-setup <<<
EOF
render
if [ "$(col "$LPART" 8)" = "managed" ]; then ok; else bad "B4: FSTAB was '$(col "$LPART" 8)', want managed"; fi

echo "--- B5: a hand-written entry reports yes ---"
sed -i '/# >>> system-setup /,/# <<< system-setup /d' /etc/fstab
printf 'UUID=%s /tmp/ss-list-mnt ext4 defaults 0 2\n' "$UUID" >> /etc/fstab
render
if [ "$(col "$LPART" 8)" = "yes" ]; then ok; else bad "B5: FSTAB was '$(col "$LPART" 8)', want yes"; fi

echo "--- B6: an absent entry reports no ---"
sed -i '\#/tmp/ss-list-mnt#d' /etc/fstab
render
if [ "$(col "$LPART" 8)" = "no" ]; then ok; else bad "B6: FSTAB was '$(col "$LPART" 8)', want no"; fi

echo "--- columns: fs, size, growable ---"
if [ "$(col "$LPART" 3)" = "ext4" ]; then ok; else bad "c1: FS was '$(col "$LPART" 3)'"; fi
if [ "$(col "$LPART" 4)" = "-" ]; then ok; else bad "c2: MOUNT should be blank when unmounted, was '$(col "$LPART" 4)'"; fi
if [ "$(col "$LPART" 5)" != "-" ]; then ok; else bad "c3: SIZE should never be blank"; fi
if [ "$(col "$LPART" 6)" != "-" ]; then ok; else bad "c4: GROWABLE should be set - 100M partition on a 256M disk"; fi
if [ "$(col "$LPART" 7)" = "-" ]; then ok; else bad "c5: FREE should be blank when unmounted, was '$(col "$LPART" 7)'"; fi

echo "--- FREE is populated once mounted ---"
mkdir -p /tmp/ss-list-mnt && mount "$LPART" /tmp/ss-list-mnt
render
if [ "$(col "$LPART" 7)" != "-" ]; then ok; else bad "c6: FREE still blank while mounted"; fi
if [ "$(col "$LPART" 4)" = "/tmp/ss-list-mnt" ]; then ok; else bad "c7: MOUNT was '$(col "$LPART" 4)'"; fi
umount /tmp/ss-list-mnt; rmdir /tmp/ss-list-mnt

echo "--- B7: a disk with no partitions gets one row of blanks ---"
sfdisk --delete "$LOOP" >/dev/null 2>&1
udevadm settle
render
ROW="$(awk 'NR > 1' <<< "$TABLE" | head -1)"
if grep -qE "^$LOOP +- +- +- +[0-9]" <<< "$ROW"; then ok; else bad "B7: partitionless row was '$ROW'"; fi
if [ "$(awk 'NR > 1' <<< "$TABLE" | wc -l)" = 1 ]; then ok; else bad "B7b: expected exactly one row"; fi

echo
echo "=== B9: growpart absent - the table still prints ==="
GP="$(command -v growpart || true)"
if [ -n "$GP" ]; then
    mv "$GP" "$GP.hidden"
    OUT="$(bash "$SCRIPT" hdd list 2>&1)"; RC=$?
    mv "$GP.hidden" "$GP"
    if [ "$RC" = 0 ]; then ok; else bad "B9: list failed without growpart (rc=$RC)"; fi
    if grep -q "DEVICE" <<< "$OUT"; then ok; else bad "B9b: no table printed"; fi
    if grep -q "growpart is not installed" <<< "$OUT"; then ok; else bad "B9c: no explanatory note"; fi
else
    echo "  (growpart not installed, skipping)"
fi

echo
echo "=== the unbuilt subcommands announce themselves ==="
run S1 1 "not implemented" hdd add
run S2 1 "not implemented" hdd expand
run S3 1 "not implemented" hdd remove

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
