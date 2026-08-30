#!/usr/bin/env bash
# Unit tests for the hdd inspection layer (fixes 2026-08-30, phase A, A1-A10).
#
# Sources the script and calls its predicates directly - the same approach the
# validation suite uses, and the reason `system-setup` guards its `main` call
# with a BASH_SOURCE check.
#
# Uses loop devices only; no real disk is touched.
#
#   bash tests/test-inspect.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
[ -n "$SCRIPT" ] || SCRIPT="$REPO/system-setup"
# Disk inspection needs root: the block devices are root:disk, and blkid and
# sfdisk live in /usr/sbin. Re-exec rather than sprinkling sudo through every
# assertion - the functions under test are the thing being called, and they
# have to be called the way the script calls them.
if [ "$EUID" -ne 0 ]; then
    echo "### re-running under sudo (disk inspection requires root)"
    exec sudo SCRIPT="${SCRIPT:-}" bash "$0" "$@"
fi

PASS=0; FAIL=0
declare -a FAILURES=()

# shellcheck source=/dev/null
source "$SCRIPT"
set +e                  # the script enables -e; this harness must not inherit it
IFS=$' \t\n'            # and needs an ordinary IFS for its own word splitting

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

IMG=/tmp/ss-inspect.img
MNT=/tmp/ss-inspect-mnt
LOOP=""
FSTAB_SAVE=/tmp/ss-inspect-fstab.save

cleanup() {
    sudo umount "$MNT" 2>/dev/null
    [ -z "$LOOP" ] || sudo losetup -d "$LOOP" 2>/dev/null
    sudo rm -f "$IMG"
    sudo rmdir "$MNT" 2>/dev/null
    [ -f "$FSTAB_SAVE" ] && sudo cp "$FSTAB_SAVE" /etc/fstab && sudo rm -f "$FSTAB_SAVE"
    return 0
}
trap cleanup EXIT

echo "### preparing a loop device with room to grow"
sudo cp /etc/fstab "$FSTAB_SAVE"
sudo mkdir -p "$MNT"
sudo rm -f "$IMG"
truncate -s 512M "$IMG"
LOOP="$(sudo losetup -f --show -P "$IMG")"
# one 200M partition, leaving ~300M free after it
printf 'label: gpt\nstart=2048, size=200M, type=linux\n' | sudo sfdisk "$LOOP" >/dev/null 2>&1
sudo udevadm settle
PART="$(part_name "$LOOP" 1)"
sudo mkfs.ext4 -F "$PART" >/dev/null 2>&1
echo "  loop=$LOOP  part=$PART"

echo
echo "=== A1-A3: partition_managed ==="
sudo sed -i "\\#$PART#d" /etc/fstab
UUID="$(part_uuid "$PART")"
# the single managed block, membership decided by UUID. Clear any existing one
# first: appending a second block would shadow it, since block_extract stops at
# the first close marker it meets.
sudo sed -i "/# >>> system-setup /,/# <<< system-setup /d" /etc/fstab
sudo tee -a /etc/fstab >/dev/null <<EOF
# >>> system-setup >>>
UUID=$UUID  $MNT  ext4  defaults,nofail  0  2
# <<< system-setup <<<
EOF
if partition_managed "$PART"; then ok; else bad "A1: managed block not detected"; fi

echo "--- the match is field-exact, not a substring search ---"
# The same UUID as a LABEL= value, and in a comment. Either would fool a
# grep -F over the block, and neither means the partition is managed.
sudo sed -i "/# >>> system-setup /,/# <<< system-setup /d" /etc/fstab
sudo tee -a /etc/fstab >/dev/null <<EOF
# >>> system-setup >>>
# UUID=$UUID was here once
LABEL=UUID=$UUID  /tmp/ss-decoy  ext4  defaults  0  2
# <<< system-setup <<<
EOF
if partition_managed "$PART"; then bad "A1b: a non-field UUID match counted as managed"; else ok; fi

# same partition, in fstab but NOT in the block
sudo sed -i "/# >>> system-setup /,/# <<< system-setup /d" /etc/fstab
printf 'UUID=%s %s ext4 defaults 0 2\n' "$UUID" "$MNT" | sudo tee -a /etc/fstab >/dev/null
if partition_managed "$PART"; then bad "A2: a hand-written entry was reported as managed"; else ok; fi

sudo sed -i "\\#$MNT#d" /etc/fstab
if partition_managed "$PART"; then bad "A3: absent partition reported as managed"; else ok; fi

echo
echo "=== A4-A6: partition_in_fstab ==="
printf '%s %s ext4 defaults 0 2\n' "$PART" "$MNT" | sudo tee -a /etc/fstab >/dev/null
if partition_in_fstab "$PART"; then ok; else bad "A4: device-path entry not found"; fi
sudo sed -i "\\#$MNT#d" /etc/fstab

# A5 is the one that matters: an operator's own entry is almost always UUID=
printf 'UUID=%s %s ext4 defaults 0 2\n' "$UUID" "$MNT" | sudo tee -a /etc/fstab >/dev/null
if partition_in_fstab "$PART"; then ok; else bad "A5: UUID= entry not found - remove/list would mistake it for absent"; fi
sudo sed -i "\\#$MNT#d" /etc/fstab

if partition_in_fstab "$PART"; then bad "A6: absent partition reported as present"; else ok; fi

echo "--- PARTUUID= is matched too ---"
PUUID="$(sudo blkid -s PARTUUID -o value "$PART" 2>/dev/null)"
if [ -n "$PUUID" ]; then
    printf 'PARTUUID=%s %s ext4 defaults 0 2\n' "$PUUID" "$MNT" | sudo tee -a /etc/fstab >/dev/null
    if partition_in_fstab "$PART"; then ok; else bad "A6b: PARTUUID= entry not found"; fi
    sudo sed -i "\\#$MNT#d" /etc/fstab
else
    echo "  (no PARTUUID, skipping)"
fi

echo "--- a commented-out entry must NOT count ---"
printf '# UUID=%s %s ext4 defaults 0 2\n' "$UUID" "$MNT" | sudo tee -a /etc/fstab >/dev/null
if partition_in_fstab "$PART"; then bad "A6c: a commented line counted as an entry"; else ok; fi
sudo sed -i "\\#$MNT#d" /etc/fstab

echo
echo "=== A7-A9: growable_of ==="
if command -v growpart >/dev/null 2>&1; then
    G="$(growable_of "$PART")"
    if [ -n "$G" ] && [ "$G" -gt 0 ]; then ok; else bad "A7: no growable space reported on a 200M/512M disk"; fi
    # ~300M of slack; allow a wide band, this is a sanity check not a measurement
    if [ -n "$G" ] && [ "$G" -gt $((250 * 1024 * 1024)) ] && [ "$G" -lt $((320 * 1024 * 1024)) ]; then
        ok
    else
        bad "A7b: growable was $G bytes, expected roughly 300M"
    fi

    echo "--- A8: after growing, there is nothing left to grow ---"
    sudo growpart "$LOOP" 1 >/dev/null 2>&1
    sudo udevadm settle
    G2="$(growable_of "$PART")"; RC=$?
    if [ -z "$G2" ] && [ "$RC" -ne 0 ]; then ok; else bad "A8: expected empty+non-zero, got '$G2' rc=$RC"; fi
    # the point of A8: NOCHANGE exits 1, and must not look like a crash
    OUT="$(sudo growpart --dry-run "$LOOP" 1 2>&1)"
    if grep -q "^NOCHANGE:" <<< "$OUT"; then ok; else bad "A8b: growpart no longer prints NOCHANGE; the parser assumption is stale"; fi
else
    echo "  (growpart not installed, skipping A7/A8)"
fi

echo "--- A9: growpart absent must be quiet, not an error ---"
GP="$(command -v growpart || true)"
if [ -n "$GP" ]; then
    sudo mv "$GP" "$GP.hidden"
    G3="$(growable_of "$PART" 2>&1)"; RC=$?
    sudo mv "$GP.hidden" "$GP"
    if [ -z "$G3" ] && [ "$RC" -ne 0 ]; then ok; else bad "A9: expected empty+non-zero with growpart absent, got '$G3' rc=$RC"; fi
else
    echo "  (growpart not installed, skipping)"
fi

echo
echo "=== part_free_space ==="
if part_free_space "$PART" >/dev/null 2>&1; then bad "fs1: reported free space for an unmounted partition"; else ok; fi
sudo mount "$PART" "$MNT"
F="$(part_free_space "$PART")"
if [ -n "$F" ] && [ "$F" -gt 0 ]; then ok; else bad "fs2: no free space reported while mounted"; fi
sudo umount "$MNT"

echo
echo "=== A10: dev_disks ==="
DISKS="$(dev_disks)"
if grep -q "^$LOOP$" <<< "$DISKS"; then bad "A10: loop device present in dev_disks"; else ok; fi
if [ -n "$DISKS" ]; then ok; else bad "A10b: no disks listed at all"; fi
# every entry must be a real block device of type disk
BADDISK=""
while read -r d; do
    [ -n "$d" ] || continue
    [ "$(lsblk -dnro TYPE "$d" 2>/dev/null | head -1)" = "disk" ] || BADDISK="$d"
done <<< "$DISKS"
if [ -z "$BADDISK" ]; then ok; else bad "A10c: '$BADDISK' is not a disk"; fi

echo
echo "=== part_device / part_number / part_is_partition ==="
if [ "$(part_device "$PART")" = "$LOOP" ]; then ok; else bad "pd1: part_device gave '$(part_device "$PART")', want $LOOP"; fi
if [ "$(part_number "$PART")" = "1" ]; then ok; else bad "pd2: part_number gave '$(part_number "$PART")'"; fi
if part_is_partition "$PART"; then ok; else bad "pd3: partition not recognised as one"; fi
if part_is_partition "$LOOP"; then bad "pd4: a whole disk was reported as a partition"; else ok; fi
if part_device "$LOOP" >/dev/null 2>&1; then bad "pd5: part_device succeeded on a whole disk"; else ok; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
