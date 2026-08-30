#!/usr/bin/env bash
# Host tests for `system-setup hdd add` (fixes 2026-08-30, phase D, D1-D11).
#
# Loop devices only; no real disk is touched. `add` never formats, so every
# case here starts from a filesystem this suite made itself.
#
#   bash tests/test-hdd-add.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"

IMG=/tmp/ss-add.img
MNT=/tmp/ss-add-mnt
ALT=/tmp/ss-add-alt
LOOP=""
# Restored wholesale on exit, as the net under the targeted cleanup below.
FSTAB_SAVE=/tmp/ss-add-fstab.save
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$*] rc=$rc want=$want :: $(tail -3 <<< "$out")"; return; fi
    # -- because half the patterns here start with a dash, and grep would
    # read those as options
    if [ -n "$pat" ] && ! grep -qE -- "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $(tail -3 <<< "$out")"; return; fi
    ok
}
assert() { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }

# Clear our test entries by MOUNT POINT, never by deleting the managed block:
# on a real host it also holds entries this suite must not remove. Then drop
# the block if that emptied it - an empty block shadows a later one, since
# block_extract stops at the first close marker it meets.
scrub_fstab() {
    sudo sed -i "\\#$MNT#d;\\#$ALT#d" /etc/fstab
    sudo sed -i '/^# >>> system-setup >>>$/{N;/\n# <<< system-setup <<<$/d}' /etc/fstab
}

teardown() {
    sudo umount "$MNT" 2>/dev/null || true
    sudo umount "$ALT" 2>/dev/null || true
    [ -z "$LOOP" ] || sudo losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
}
cleanup_all() {
    teardown
    scrub_fstab
    if [ -f "$FSTAB_SAVE" ]; then sudo cp "$FSTAB_SAVE" /etc/fstab; sudo rm -f "$FSTAB_SAVE"; fi
    sudo rm -f "$IMG"
    sudo rmdir "$MNT" "$ALT" 2>/dev/null || true
}
trap cleanup_all EXIT

# fresh_loop <partition-spec...> -- a new loop device with the given sfdisk
# layout and nothing in fstab pointing at our mount points.
fresh_loop() {
    teardown
    scrub_fstab
    sudo rm -f "$IMG"
    truncate -s 1G "$IMG"
    LOOP="$(sudo losetup -f --show -P "$IMG")"
    # 400M each: mkfs.xfs refuses anything under ~300M on xfsprogs 6.x, and D9
    # needs a real xfs filesystem to prove the blkid-type mapping
    printf 'label: gpt\nstart=2048, size=400M, type=linux\nstart=,  type=linux\n' \
        | sudo sfdisk "$LOOP" >/dev/null 2>&1
    sudo udevadm settle
}

echo "### preparing"
sudo cp /etc/fstab "$FSTAB_SAVE"
sudo mkdir -p "$MNT" "$ALT"
scrub_fstab

echo
echo "=== argument handling ==="
run A1 0 "system-setup hdd add" hdd add -h
run A2 2 "--partition is required" hdd add -m "$MNT"
run A3 2 "--mount is required"     hdd add -p /dev/loop0p1
run A4 2 "unknown flag"            hdd add -p /dev/loop0p1 -m "$MNT" --nope
run A5 2 "unexpected argument"     hdd add -p /dev/loop0p1 -m "$MNT" extra
run A6 2 "refusing to use /"       hdd add -p /dev/loop0p1 -m /

echo
echo "=== D1: an existing ext4 partition is adopted ==="
fresh_loop
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
run D1 0 "hdd added" hdd add -p "${LOOP}p1" -m "$MNT"
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
assert D1b "findmnt -n '$MNT' >/dev/null"
assert D1c "sudo sed -n '/# >>> system-setup >>>/,/# <<< system-setup <<</p' /etc/fstab | grep -qE '^UUID=${UUID}[[:space:]]'"
assert D1d "sudo grep -q 'nofail' /etc/fstab"
# the filesystem was adopted, not recreated
assert D1e "[ \"\$(sudo blkid -s UUID -o value ${LOOP}p1)\" = '$UUID' ]"
# `list` omits loop devices by design, so its view of this row is not
# testable here - test-hdd-list.sh covers the managed column against one.

echo
echo "=== D3: adding it again is refused ==="
run D3 4 "already recorded in /etc/fstab by system-setup" hdd add -p "${LOOP}p1" -m "$ALT"

echo
echo "=== D5: a mounted partition is refused ==="
# p2 is not in fstab at all, but it is mounted - a different refusal from D3.
sudo mkfs.ext4 -F "${LOOP}p2" >/dev/null 2>&1
sudo mount "${LOOP}p2" "$ALT"
run D5 4 "already mounted at $ALT" hdd add -p "${LOOP}p2" -m /tmp/ss-add-other
sudo umount "$ALT"

echo
echo "=== D4: someone else's fstab entry is refused ==="
U2="$(sudo blkid -s UUID -o value "${LOOP}p2")"
sudo sh -c "printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' '$U2' '/tmp/ss-add-other' >> /etc/fstab"
run D4 4 "system-setup did not write" hdd add -p "${LOOP}p2" -m "$ALT"
assert D4b "sudo grep -q 'UUID=$U2' /etc/fstab"
sudo sed -i "/UUID=$U2/d" /etc/fstab

echo
echo "=== D10: a mount point already claimed in fstab is refused ==="
# hdd_fstab_write drops any entry claiming the mount point - correct for `init`
# re-running on one disk, and a silent eviction here.
sudo sh -c "printf 'UUID=00000000-0000-0000-0000-0000000000ff %s ext4 defaults,nofail 0 2\n' '$ALT' >> /etc/fstab"
run D10 4 "$ALT is already claimed" hdd add -p "${LOOP}p2" -m "$ALT"
assert D10b "sudo grep -q '00000000-0000-0000-0000-0000000000ff' /etc/fstab"
sudo sed -i '/00000000-0000-0000-0000-0000000000ff/d' /etc/fstab

echo
echo "=== D11: a mount point already in use is refused ==="
# p2 occupies $ALT; p1 is the one being added, and is not itself mounted - the
# refusal has to be about the MOUNT POINT, not about the partition.
fresh_loop
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
sudo mkfs.ext4 -F "${LOOP}p2" >/dev/null 2>&1
sudo mount "${LOOP}p2" "$ALT"
run D11 4 "$ALT is already a mount point" hdd add -p "${LOOP}p1" -m "$ALT"
sudo umount "$ALT"

echo
echo "=== D2: a whole disk is refused ==="
run D2 2 "whole disk" hdd add -p "$LOOP" -m "$ALT"

echo
echo "=== D6: a partition with no filesystem is refused ==="
fresh_loop
run D6 2 "has no filesystem" hdd add -p "${LOOP}p1" -m "$MNT"

echo
echo "=== D7: an unsupported filesystem is refused ==="
if command -v mkfs.btrfs >/dev/null 2>&1; then
    sudo mkfs.btrfs -f "${LOOP}p1" >/dev/null 2>&1
    run D7 2 "formatted as 'btrfs'" hdd add -p "${LOOP}p1" -m "$MNT"
else
    # No mkfs.btrfs on the host; a swap signature is just as unsupported and
    # mkswap is part of util-linux, so it is always present.
    sudo mkswap "${LOOP}p1" >/dev/null 2>&1
    run D7 2 "formatted as 'swap'" hdd add -p "${LOOP}p1" -m "$MNT"
fi

echo
echo "=== D8: a partition that does not exist ==="
run D8 5 "not found" hdd add -p /dev/definitely-not-here1 -m "$MNT"

echo
echo "=== D9: --dry-run changes nothing ==="
fresh_loop
sudo mkfs.xfs -f "${LOOP}p1" >/dev/null 2>&1
BEFORE="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
run D9 0 "would be added at $MNT as xfs" hdd add -p "${LOOP}p1" -m "$MNT" --dry-run
assert D9b "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$BEFORE' ]"
assert D9c "! findmnt -n '$MNT' >/dev/null"

echo "--- and a dry run that would fail reports the same refusal ---"
# The point of splitting checks from apply: --dry-run cannot disagree with a
# real run about whether the operation was possible.
run D9d 2 "whole disk" hdd add -p "$LOOP" -m "$MNT" --dry-run
assert D9e "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$BEFORE' ]"

echo "--- then the real run succeeds, as the dry run said it would ---"
run D9f 0 "hdd added" hdd add -p "${LOOP}p1" -m "$MNT"
assert D9g "[ \"\$(findmnt -nro FSTYPE '$MNT')\" = xfs ]"

echo
echo "=== a bare mount name is normalised, exactly as init does it ==="
fresh_loop
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
run N1 0 "mount:  /ss-add-bare" hdd add -p "${LOOP}p1" -m ss-add-bare
assert N1b "findmnt -n /ss-add-bare >/dev/null"
sudo umount /ss-add-bare 2>/dev/null || true
sudo sed -i '\#/ss-add-bare#d' /etc/fstab
sudo sed -i '/^# >>> system-setup >>>$/{N;/\n# <<< system-setup <<<$/d}' /etc/fstab
sudo rmdir /ss-add-bare 2>/dev/null || true

echo
echo "=== two partitions on one disk, managed independently ==="
# The whole reason the fstab block holds entries rather than wrapping one.
fresh_loop
sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
sudo mkfs.ext4 -F "${LOOP}p2" >/dev/null 2>&1
run T1 0 "hdd added" hdd add -p "${LOOP}p1" -m "$MNT"
run T2 0 "hdd added" hdd add -p "${LOOP}p2" -m "$ALT"
assert T3 "findmnt -n '$MNT' >/dev/null"
assert T4 "findmnt -n '$ALT' >/dev/null"
# Count OUR entries: on a real host the block also holds its own, which is
# the point - `add` appends to the block without disturbing what is there.
BODY="$(sudo sed -n '/# >>> system-setup >>>/,/# <<< system-setup <<</p' /etc/fstab | sed '1d;$d')"
MINE="$(grep -cE "[[:space:]]($MNT|$ALT)[[:space:]]" <<< "$BODY")"
if [ "$MINE" = 2 ]; then ok; else bad "T5: expected 2 entries of ours in the block, got $MINE :: $BODY"; fi
if [ "$(sudo grep -c '^# >>> system-setup >>>$' /etc/fstab)" = 1 ]; then ok; else bad "T6: more than one managed block"; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
