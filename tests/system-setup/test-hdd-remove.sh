#!/usr/bin/env bash
# Host tests for `system-setup hdd remove` (fixes 2026-08-30, phase E, E1-E9).
#
# Loop devices only. The suite's central claim is E8: `remove` takes away a
# MOUNT CONFIGURATION and nothing else - the partition, its filesystem and its
# contents survive untouched.
#
#   bash tests/test-hdd-remove.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"

IMG=/tmp/ss-rm.img
MNT=/tmp/ss-rm-mnt
ALT=/tmp/ss-rm-alt
LOOP=""
# Restored wholesale on exit, as the net under the targeted cleanup below.
FSTAB_SAVE=/tmp/ss-rm-fstab.save
PASS=0; FAIL=0
declare -a FAILURES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

run() {
    local id="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$id: [$*] rc=$rc want=$want :: $(tail -3 <<< "$out")"; return; fi
    if [ -n "$pat" ] && ! grep -qE -- "$pat" <<< "$out"; then bad "$id: [$*] missing /$pat/ :: $(tail -3 <<< "$out")"; return; fi
    ok
}
assert() { if eval "$2"; then ok; else bad "$1: assertion failed: $2"; fi; }

block_body() { sudo sed -n '/# >>> system-setup >>>/,/# <<< system-setup <<</p' /etc/fstab | sed '1d;$d'; }

# By mount point, never a block-wide delete: the managed block also holds this
# host's own entries. Then drop the block if that emptied it.
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

fresh_loop() {
    teardown
    scrub_fstab
    sudo rm -f "$IMG"
    truncate -s 1G "$IMG"
    LOOP="$(sudo losetup -f --show -P "$IMG")"
    printf 'label: gpt\nstart=2048, size=400M, type=linux\nstart=,  type=linux\n' \
        | sudo sfdisk "$LOOP" >/dev/null 2>&1
    sudo udevadm settle
    sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1
    sudo mkfs.ext4 -F "${LOOP}p2" >/dev/null 2>&1
}

# adopt <partition> <mount> -- get a managed entry in place to remove
adopt() { sudo bash "$SCRIPT" hdd add -p "$1" -m "$2" >/dev/null 2>&1; }

echo "### preparing"
sudo cp /etc/fstab "$FSTAB_SAVE"
sudo mkdir -p "$MNT" "$ALT"
scrub_fstab

echo
echo "=== argument handling ==="
run A1 0 "system-setup hdd remove" hdd remove -h
run A2 2 "one of --partition or --mount is required" hdd remove
run A3 2 "alternatives; give exactly one" hdd remove -p /dev/loop0p1 -m "$MNT"
run A4 2 "unknown flag" hdd remove -p /dev/loop0p1 --nope
run A5 2 "refusing to use /" hdd remove -m /

echo
echo "=== E1: managed and mounted, removed with --force ==="
fresh_loop
adopt "${LOOP}p1" "$MNT"
UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
CONTENT_MARK=/tmp/ss-rm-mnt/keepme
sudo touch "$CONTENT_MARK"
assert E1a "findmnt -n '$MNT' >/dev/null"
run E1 0 "hdd removed" hdd remove -p "${LOOP}p1" --force
assert E1b "! findmnt -n '$MNT' >/dev/null"
assert E1c "! sudo grep -q 'UUID=$UUID' /etc/fstab"
# the mount point directory stays: something else may be using it
assert E1d "[ -d '$MNT' ]"

echo
echo "=== E8: the partition, its filesystem and its data are untouched ==="
assert E8a "[ \"\$(sudo blkid -s UUID -o value ${LOOP}p1)\" = '$UUID' ]"
assert E8b "[ \"\$(sudo blkid -s TYPE -o value ${LOOP}p1)\" = ext4 ]"
sudo mount "${LOOP}p1" "$MNT"
assert E8c "[ -f '$CONTENT_MARK' ]"
sudo umount "$MNT"

echo
echo "=== E9: remove then add again - the cycle is reversible ==="
run E9 0 "hdd added" hdd add -p "${LOOP}p1" -m "$MNT"
assert E9b "findmnt -n '$MNT' >/dev/null"

echo
echo "=== E2: managed but NOT mounted ==="
sudo umount "$MNT"
run E2 0 "hdd removed" hdd remove -p "${LOOP}p1" --force
assert E2b "! sudo grep -q 'UUID=$UUID' /etc/fstab"

echo
echo "=== E3: a hand-written entry is never removed ==="
sudo sh -c "printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' '$UUID' '$MNT' >> /etc/fstab"
run E3  4 "did not write" hdd remove -p "${LOOP}p1" --force
run E3b 4 "did not write" hdd remove -m "$MNT" --force
assert E3c "sudo grep -q 'UUID=$UUID' /etc/fstab"
sudo sed -i "/UUID=$UUID/d" /etc/fstab

echo
echo "=== E4: not in fstab at all ==="
run E4  5 "no entry in /etc/fstab"     hdd remove -p "${LOOP}p1" --force
run E4b 5 "no entry in /etc/fstab written by system-setup mounts" hdd remove -m "$MNT" --force
run E4c 5 "not found"                  hdd remove -p /dev/definitely-not-here1 --force

echo
echo "=== E5: no --force and no TTY ==="
adopt "${LOOP}p1" "$MNT"
OUT="$(bash "$SCRIPT" hdd remove -p "${LOOP}p1" < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok; else bad "E5: rc=$RC want=2 :: $(tail -3 <<< "$OUT")"; fi
if grep -q -- "--force" <<< "$OUT"; then ok; else bad "E5b: the refusal does not name --force :: $OUT"; fi
assert E5c "findmnt -n '$MNT' >/dev/null"
assert E5d "sudo grep -q 'UUID=$UUID' /etc/fstab"

echo
echo "=== E6: --dry-run reports, does not prompt, changes nothing ==="
BEFORE="$(sudo md5sum /etc/fstab | cut -d' ' -f1)"
# no --force AND no tty: a dry run must still succeed, because it never asks
OUT="$(bash "$SCRIPT" hdd remove -p "${LOOP}p1" --dry-run < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "E6: rc=$RC want=0 :: $(tail -3 <<< "$OUT")"; fi
if grep -q "would remove the entry for $MNT" <<< "$OUT"; then ok; else bad "E6b: no report :: $OUT"; fi
assert E6c "[ \"\$(sudo md5sum /etc/fstab | cut -d' ' -f1)\" = '$BEFORE' ]"
assert E6d "findmnt -n '$MNT' >/dev/null"

echo
echo "=== E7: --dry-run on a hand-written entry refuses, without prompting ==="
adopt "${LOOP}p2" "$ALT"
sudo bash "$SCRIPT" hdd remove -p "${LOOP}p2" --force >/dev/null 2>&1
U2="$(sudo blkid -s UUID -o value "${LOOP}p2")"
sudo sh -c "printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' '$U2' '$ALT' >> /etc/fstab"
OUT="$(bash "$SCRIPT" hdd remove -p "${LOOP}p2" --dry-run < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 4 ]; then ok; else bad "E7: rc=$RC want=4 :: $(tail -3 <<< "$OUT")"; fi
if grep -q "TTY" <<< "$OUT"; then bad "E7b: a dry run reached the prompt"; else ok; fi
sudo sed -i "/UUID=$U2/d" /etc/fstab

echo
echo "=== --mount selects the same entry as --partition ==="
# The reason --mount exists: a UUID cannot be read off a disk that is gone.
run M1 0 "would remove the entry for $MNT" hdd remove -m "$MNT" --dry-run
run M2 0 "would remove the entry for $MNT" hdd remove -m "$MNT/" --dry-run
run M3 0 "hdd removed" hdd remove -m "$MNT" --force
assert M4 "! sudo grep -q 'UUID=$UUID' /etc/fstab"
assert M5 "! findmnt -n '$MNT' >/dev/null"

echo
echo "=== removing the last entry removes the block ==="
# Only meaningful when the block held nothing else; on a host with its own
# managed entries it must NOT be emptied, which is the other half of the check.
OTHERS="$(block_body | grep -vcE "[[:space:]]($MNT|$ALT)[[:space:]]" || true)"
adopt "${LOOP}p1" "$MNT"
sudo bash "$SCRIPT" hdd remove -p "${LOOP}p1" --force >/dev/null 2>&1
if [ "$OTHERS" = 0 ]; then
    if sudo grep -q '^# >>> system-setup >>>$' /etc/fstab; then
        bad "B1: an empty block was left behind"
    else ok; fi
else
    if [ "$(block_body | wc -l)" = "$OTHERS" ]; then ok; else bad "B1: the host's own entries were disturbed"; fi
fi

echo
echo "=== a partition removed while another on the same disk stays ==="
fresh_loop
adopt "${LOOP}p1" "$MNT"
adopt "${LOOP}p2" "$ALT"
U1="$(sudo blkid -s UUID -o value "${LOOP}p1")"
U2="$(sudo blkid -s UUID -o value "${LOOP}p2")"
run S1 0 "hdd removed" hdd remove -p "${LOOP}p1" --force
assert S2 "! sudo grep -q 'UUID=$U1' /etc/fstab"
assert S3 "sudo grep -q 'UUID=$U2' /etc/fstab"
assert S4 "findmnt -n '$ALT' >/dev/null"

echo
echo "=== the prompt is unreachable from a document ==="
if grep -qE 'confirm "' "$SCRIPT"; then ok; else bad "P1: no confirm call site exists any more"; fi
# `file` runs tz/hdd/docker/ntp/network, and the hdd node is `hdd init`, which
# has no prompt. Nothing a document can name reaches confirm().
if grep -qE 'cmd=cmd_hdd_init' "$SCRIPT"; then ok; else bad "P2: the file hdd node no longer routes to init"; fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
