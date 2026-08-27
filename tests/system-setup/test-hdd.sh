#!/usr/bin/env bash
# Host tests for `system-setup hdd` (plan phase 8, test cases 43-57).
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
run 43 0 "hdd configured" hdd --device "$LOOP" --mount "$MNT" --type ext4
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1" 2>/dev/null || sudo blkid -s UUID -o value "${LOOP}1" 2>/dev/null)"
assert 43b "[ -n '$UUID' ]"
assert 43c "sudo grep -q 'UUID=$UUID' /etc/fstab"
assert 43d "sudo grep -q 'nofail' /etc/fstab"
assert 43e "findmnt -n '$MNT' >/dev/null"
assert 43f "! sudo grep -qE '^${LOOP}[p]?1[[:space:]]' /etc/fstab"

echo
echo "=== 44: identical re-run is idempotent ==="
run 44 0 "already configured" hdd --device "$LOOP" --mount "$MNT" --type ext4
assert 44b "[ \"\$(fstab_lines 'UUID=$UUID')\" = 1 ]"

echo
echo "=== 47/48: different filesystem without --force is refused ==="
run 47 4 "not 'xfs'" hdd --device "$LOOP" --mount "$MNT" --type xfs
assert 47b "[ \"\$(sudo blkid -s TYPE -o value ${LOOP}p1)\" = ext4 ]"
echo "--- with --force it reformats ---"
run 48 0 "hdd configured" hdd --device "$LOOP" --mount "$MNT" --type xfs --force
assert 48b "[ \"\$(sudo blkid -s TYPE -o value ${LOOP}p1)\" = xfs ]"
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
assert 48c "sudo grep -q 'UUID=$UUID' /etc/fstab"

echo
echo "=== 45/46: correct fs mounted at the wrong place ==="
sudo umount "$MNT" 2>/dev/null || true
sudo mount "${LOOP}p1" "$ALT"
run 45 4 "mounted at $ALT" hdd --device "$LOOP" --mount "$MNT" --type xfs
assert 45b "[ \"\$(findmnt -nro TARGET -S ${LOOP}p1)\" = '$ALT' ]"
echo "--- with --force it moves ---"
run 46 0 "hdd configured" hdd --device "$LOOP" --mount "$MNT" --type xfs --force
assert 46b "[ \"\$(findmnt -nro TARGET -S ${LOOP}p1)\" = '$MNT' ]"

echo
echo "=== 49: more than one partition is unsafe; --force overrides ==="
fresh_loop
printf 'label: gpt\nstart=2048, size=200M, type=linux\nstart=,  type=linux\n' | sudo sfdisk "$LOOP" >/dev/null 2>&1
sudo udevadm settle
run 49 4 "refusing to touch" hdd --device "$LOOP" --mount "$MNT"
echo "--- --force proceeds without prompting: it means \"I mean it\" ---"
# --force both permits the destructive action and skips the confirmation, per
# git-utils confirm(). There is no second gate by design: the flag is explicit
# and is not expressible from the JSON file, so it can only come from a human.
run 49b 0 "hdd configured" hdd --device "$LOOP" --mount "$MNT" --force

echo
echo "=== 50: a raw filesystem signature with no partition table is unsafe ==="
fresh_loop
sudo mkfs.ext4 -F "$LOOP" >/dev/null 2>&1
run 50 4 "refusing to touch" hdd --device "$LOOP" --mount "$MNT"

echo
echo "=== 52: missing device ==="
run 52 5 "not found" hdd --device /dev/definitely-not-here --mount "$MNT"

echo
echo "=== 53: a legacy device-path fstab line is replaced, not duplicated ==="
fresh_loop
sudo sh -c "printf '%s %s ext4 defaults 0 0\n' '${LOOP}p1' '$MNT' >> /etc/fstab"
run 53 0 "hdd configured" hdd --device "$LOOP" --mount "$MNT" --type ext4
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
run 54 3 "restored" hdd --device "$LOOP" --mount "$MNT" --type ext4
AFTER="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
if [ "$AFTER" = "$BROKEN" ]; then ok; else bad "54b: fstab is neither the pre-run state nor unchanged ($AFTER)"; fi
sudo sed -i '/ss-nope/d' /etc/fstab
assert 54c "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$BEFORE' ]"

echo
echo "=== 55: a bare mount name is normalised to an absolute path ==="
fresh_loop
run 55 0 "mount:  /ss-bare" hdd --device "$LOOP" --mount ss-bare --type ext4
assert 55b "findmnt -n /ss-bare >/dev/null"
sudo umount /ss-bare 2>/dev/null || true
sudo sed -i '\#/ss-bare#d' /etc/fstab
sudo sed -i '/# >>> system-setup \/dev\/loop/,/# <<< system-setup \/dev\/loop/d' /etc/fstab
sudo rmdir /ss-bare 2>/dev/null || true

echo
echo "=== 56/57: argument and dependency errors ==="
run 56 2 "invalid --type" hdd --device "$LOOP" --type btrfs
run 57 2 "refusing to use /" hdd --device "$LOOP" --mount /

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
