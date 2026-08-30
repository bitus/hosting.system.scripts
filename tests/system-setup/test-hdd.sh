#!/usr/bin/env bash
# Host tests for `system-setup hdd init` (cases 43-57, plus C1-C11 and the
# device-keyed block migration from the 2026-08-30 fix).
#
# Runs entirely against LOOP DEVICES backed by files in /tmp - no real disk is
# touched, and the whole classification matrix (blank / single / multi-partition
# / bare signature / mounted-in-use) is exercised non-destructively.
# Test 58 (real disk + reboot + detach) is phase 9 and is not covered here.
#
#   bash tests/test-hdd.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
IMG=/tmp/ss-hdd-test.img
MNT=/tmp/ss-mnt
ALT=/tmp/ss-alt
PASS=0; FAIL=0
declare -a FAILURES=()
LOOP=""

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
assert() { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }

fstab_lines() { sudo grep -c "$1" /etc/fstab 2>/dev/null || true; }

# --- loop device lifecycle -------------------------------------------------
teardown() {
    sudo umount "$MNT" 2>/dev/null || true
    sudo umount "$ALT" 2>/dev/null || true
    [ -z "$LOOP" ] || sudo losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
}
fresh_loop() {
    teardown
    # Sentinel keys are device PATHS, and loop paths are recycled: without
    # this, a block left by an earlier case makes the next case's brand new
    # partition at the same path look like one we manage.
    sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab
    sudo rm -f "$IMG"
    truncate -s 2G "$IMG"
    LOOP="$(sudo losetup -f --show -P "$IMG")"
    debug_loop
}
debug_loop() { echo "  [loop: $LOOP]"; }

cleanup_all() {
    teardown
    sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab
    sudo sed -i "\#$MNT#d;\#$ALT#d" /etc/fstab
    sudo rm -f "$IMG"
    sudo rmdir "$MNT" "$ALT" 2>/dev/null || true
}
trap cleanup_all EXIT

echo "### preparing"
sudo mkdir -p "$MNT" "$ALT"
# start from a clean fstab with respect to our test paths
sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab
sudo sed -i "\#$MNT#d;\#$ALT#d" /etc/fstab

echo
echo "=== 43: blank device -> partition, format, mount, UUID in fstab ==="
fresh_loop
run 43 0 "hdd configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1" 2>/dev/null || sudo blkid -s UUID -o value "${LOOP}1" 2>/dev/null)"
assert 43b "[ -n '$UUID' ]"
assert 43c "sudo grep -q 'UUID=$UUID' /etc/fstab"
assert 43d "sudo grep -q 'nofail' /etc/fstab"
assert 43e "findmnt -n '$MNT' >/dev/null"
assert 43f "! sudo grep -qE '^${LOOP}[p]?1[[:space:]]' /etc/fstab"

assert C2 "sudo grep -qF '# >>> system-setup ${LOOP}p1 >>>' /etc/fstab"
assert C2b "! sudo grep -qF '# >>> system-setup ${LOOP} >>>' /etc/fstab"

echo
echo "=== 44/C3: identical re-run is idempotent ==="
run 44 0 "already configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4
assert 44b "[ \"\$(fstab_lines 'UUID=$UUID')\" = 1 ]"

echo
echo "=== C11: a managed but unmounted disk stays unmounted ==="
# `init` reports success and does nothing. It is not a mount command, and
# an operator who unmounted a managed disk did so on purpose.
sudo umount "$MNT"
run C11 0 "already configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4
assert C11b "! findmnt -n '$MNT' >/dev/null"
sudo mount "$MNT"

echo
echo "=== C4: a partition this command did not create is refused ==="
# The disk is not blank and holds nothing of ours: no override exists.
fresh_loop
printf 'label: gpt
start=2048, type=linux
' | sudo sfdisk "$LOOP" >/dev/null 2>&1
sudo udevadm settle
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
run C4  4 "refusing to touch" hdd init --device "$LOOP" --mount "$MNT" --type ext4
run C4b 4 "did not create"    hdd init --device "$LOOP" --mount "$MNT" --type ext4
# hdd_describe explains the refusal - the operator has to be told what is there
run C4c 4 "$(basename "$LOOP")" hdd init --device "$LOOP" --mount "$MNT" --type ext4

echo
echo "=== C5: someone else's fstab entry does not make it ours ==="
FUUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
sudo sh -c "printf 'UUID=%s %s ext4 defaults,nofail 0 2
' '$FUUID' '$ALT' >> /etc/fstab"
run C5 4 "refusing to touch" hdd init --device "$LOOP" --mount "$MNT" --type ext4
assert C5b "sudo grep -q 'UUID=$FUUID' /etc/fstab"
sudo sed -i "/UUID=$FUUID/d" /etc/fstab

echo
echo "=== C6/C7: all partitions managed vs only some ==="
fresh_loop
printf 'label: gpt
start=2048, size=200M, type=linux
start=,  type=linux
' | sudo sfdisk "$LOOP" >/dev/null 2>&1
sudo udevadm settle
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
sudo mkfs.ext4 -F "${LOOP}p2" >/dev/null 2>&1
U1="$(sudo blkid -s UUID -o value "${LOOP}p1")"
U2="$(sudo blkid -s UUID -o value "${LOOP}p2")"

block() {   # block <partition> <uuid> <mount>
    sudo tee -a /etc/fstab >/dev/null <<EOF
# >>> system-setup $1 >>>
UUID=$2  $3  ext4  defaults,nofail  0  2
# <<< system-setup $1 <<<
EOF
}

echo "--- C7: one managed, one not -> still refused ---"
# The case a looser check gets wrong: "any partition managed" is not
# "all partitions managed", and treating them alike would reformat p2.
block "${LOOP}p1" "$U1" "$MNT"
run C7 4 "refusing to touch" hdd init --device "$LOOP" --mount "$MNT" --type ext4

echo "--- C6: both managed -> success, nothing changed ---"
block "${LOOP}p2" "$U2" "$ALT"
FB="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
run C6 0 "every partition on $LOOP is managed" hdd init --device "$LOOP" --mount "$MNT" --type ext4
assert C6b "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$FB' ]"
sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab

echo
echo "=== C8: --force is gone ==="
run C8  2 "unknown flag" hdd init --device "$LOOP" --mount "$MNT" --force
run C8b 2 "unknown flag" hdd init --device "$LOOP" --mount "$MNT" -f

echo
echo "=== M: a pre-2026-08-30 device-keyed block is re-keyed, not refused ==="
fresh_loop
run M1 0 "hdd configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4
# rewrite our own block back into the old device-keyed spelling
sudo sed -i "s|# >>> system-setup ${LOOP}p1 >>>|# >>> system-setup ${LOOP} >>>|" /etc/fstab
sudo sed -i "s|# <<< system-setup ${LOOP}p1 <<<|# <<< system-setup ${LOOP} <<<|" /etc/fstab
BODY="$(sudo sed -n "\|# >>> system-setup ${LOOP} >>>|,\|# <<< system-setup ${LOOP} <<<|p" /etc/fstab | sed '1d;$d')"

# ...and ask for a DIFFERENT mount point. Migration is a re-keying, not a
# reconfiguration: it must not silently move a live filesystem.
run M2 0 "earlier release" hdd init --device "$LOOP" --mount "$ALT" --type ext4
assert M2b "sudo grep -qF '# >>> system-setup ${LOOP}p1 >>>' /etc/fstab"
assert M2c "! sudo grep -qF '# >>> system-setup ${LOOP} >>>' /etc/fstab"
NEWBODY="$(sudo sed -n "\|# >>> system-setup ${LOOP}p1 >>>|,\|# <<< system-setup ${LOOP}p1 <<<|p" /etc/fstab | sed '1d;$d')"
if [ "$NEWBODY" = "$BODY" ]; then ok; else bad "M2d: block body changed: '$NEWBODY' != '$BODY'"; fi
assert M2e "! findmnt -n '$ALT' >/dev/null"
run M3 0 "already configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4

echo
echo "=== 50/C9: a raw filesystem signature with no partition table is unsafe ==="
fresh_loop
sudo mkfs.ext4 -F "$LOOP" >/dev/null 2>&1
run 50 4 "refusing to touch" hdd init --device "$LOOP" --mount "$MNT"

echo
echo "=== 52: missing device ==="
run 52 5 "not found" hdd init --device /dev/definitely-not-here --mount "$MNT"

echo
echo "=== 53: a legacy device-path fstab line is replaced, not duplicated ==="
fresh_loop
sudo sh -c "printf '%s %s ext4 defaults 0 0\n' '${LOOP}p1' '$MNT' >> /etc/fstab"
run 53 0 "hdd configured" hdd init --device "$LOOP" --mount "$MNT" --type ext4
assert 53b "! sudo grep -qE '^${LOOP}p1[[:space:]]' /etc/fstab"
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
assert 53c "[ \"\$(fstab_lines '$MNT')\" = 1 ]"
assert 53d "sudo grep -q 'UUID=$UUID' /etc/fstab"

echo
echo "=== 54: a broken fstab is rolled back, not left behind ==="
# Must start from a device that is NOT already configured, or the idempotency
# short-circuit returns before fstab is ever written and nothing is exercised.
fresh_loop
BEFORE="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
# a bogus entry that mount -a will reject
sudo sh -c "printf 'UUID=00000000-dead-dead-dead-000000000000 /tmp/ss-nope ext4 defaults 0 2\n' >> /etc/fstab"
BROKEN="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
run 54 3 "restored" hdd init --device "$LOOP" --mount "$MNT" --type ext4
AFTER="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
if [ "$AFTER" = "$BROKEN" ]; then ok; else bad "54b: fstab is neither the pre-run state nor unchanged ($AFTER)"; fi
sudo sed -i '/ss-nope/d' /etc/fstab
assert 54c "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$BEFORE' ]"

echo
echo "=== 55: a bare mount name is normalised to an absolute path ==="
fresh_loop
run 55 0 "mount:  /ss-bare" hdd init --device "$LOOP" --mount ss-bare --type ext4
assert 55b "findmnt -n /ss-bare >/dev/null"
sudo umount /ss-bare 2>/dev/null || true
sudo sed -i '\#/ss-bare#d' /etc/fstab
sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab
sudo rmdir /ss-bare 2>/dev/null || true

echo
echo "=== 56/57: argument and dependency errors ==="
run 56 2 "invalid --type" hdd init --device "$LOOP" --type btrfs
run 57 2 "refusing to use /" hdd init --device "$LOOP" --mount /

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
