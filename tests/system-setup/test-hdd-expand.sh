#!/usr/bin/env bash
# Host tests for `system-setup hdd expand` (fixes 2026-08-30, phase F, F1-F14).
#
# Loop devices only. The image is made larger than the partition, so growpart
# has somewhere to grow into; `losetup -c` is never needed because the backing
# file is sized up front.
#
# F14 is the one that matters: every other case checks a size changed, and only
# F14 checks that growing a filesystem did not lose what was on it.
#
#   bash tests/test-hdd-expand.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/system-setup}"
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

IMG=/tmp/ss-ex.img
MNT=/tmp/ss-ex-mnt
LOOP=""
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

psize() { sudo lsblk -bdnro SIZE "$1" 2>/dev/null | head -1; }
fsavail() { sudo df -B1 --output=size "$1" 2>/dev/null | tail -1 | tr -d ' '; }

teardown() {
    sudo umount "$MNT" 2>/dev/null || true
    [ -z "$LOOP" ] || sudo losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
}
cleanup_all() {
    teardown
    sudo rm -f "$IMG"
    sudo rmdir "$MNT" 2>/dev/null || true
    # any temp mount `expand` might have leaked
    sudo find /tmp -maxdepth 1 -name 'tmp.*' -type d -empty -delete 2>/dev/null || true
}
trap cleanup_all EXIT

# lay_out <fs> [second-partition] -- a 1G image with a 400M first partition,
# formatted <fs>, leaving ~600M free after it. With a second argument, a second
# partition follows immediately and the first cannot grow at all.
lay_out() {
    local fs="$1" second="${2:-}"
    teardown
    sudo rm -f "$IMG"
    truncate -s 1G "$IMG"
    LOOP="$(sudo losetup -f --show -P "$IMG")"
    if [ -n "$second" ]; then
        printf 'label: gpt\nstart=2048, size=400M, type=linux\nstart=, size=200M, type=linux\n' \
            | sudo sfdisk "$LOOP" >/dev/null 2>&1
    else
        printf 'label: gpt\nstart=2048, size=400M, type=linux\n' \
            | sudo sfdisk "$LOOP" >/dev/null 2>&1
    fi
    sudo udevadm settle
    case "$fs" in
        ext4) sudo mkfs.ext4 -F "${LOOP}p1" >/dev/null 2>&1 ;;
        xfs)  sudo mkfs.xfs  -f "${LOOP}p1" >/dev/null 2>&1 ;;
        vfat) sudo mkfs.vfat    "${LOOP}p1" >/dev/null 2>&1 ;;
        ntfs) sudo mkfs.ntfs -F -f "${LOOP}p1" >/dev/null 2>&1 ;;
    esac
    sudo udevadm settle
}

have() { command -v "$1" >/dev/null 2>&1; }

echo "### preparing"
sudo mkdir -p "$MNT"

echo
echo "=== argument handling ==="
run A1 0 "system-setup hdd expand" hdd expand -h
run A2 2 "--partition is required" hdd expand
run A3 2 "unknown flag"            hdd expand -p /dev/loop0p1 --nope
run A4 5 "not found"               hdd expand -p /dev/definitely-not-here1

echo
echo "=== F1: ext4, mounted - grown in place, no prompt, still mounted ==="
lay_out ext4
sudo mount "${LOOP}p1" "$MNT"
BEFORE_P="$(psize "${LOOP}p1")"; BEFORE_F="$(fsavail "$MNT")"
# F14: something to lose
sudo sh -c "head -c 3000000 /dev/urandom > $MNT/payload"
SUM="$(sudo md5sum "$MNT/payload" | cut -d' ' -f1)"
# no --force AND no tty: the mount state does not change, so it must not ask
OUT="$(bash "$SCRIPT" hdd expand -p "${LOOP}p1" < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "F1: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
if grep -q "TTY" <<< "$OUT"; then bad "F1b: it prompted when no mount change was needed"; else ok; fi
assert F1c "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
assert F1d "[ \"\$(fsavail $MNT)\" -gt $BEFORE_F ]"
assert F1e "findmnt -n '$MNT' >/dev/null"

echo "--- F14: the data is still there ---"
assert F14  "[ -f '$MNT/payload' ]"
assert F14b "[ \"\$(sudo md5sum $MNT/payload | cut -d' ' -f1)\" = '$SUM' ]"
sudo umount "$MNT"

echo
echo "=== F9: a fully-grown partition - NOCHANGE is not a crash ==="
run F9 2 "no free space immediately after" hdd expand -p "${LOOP}p1"

echo
echo "=== F10: a partition with another one after it cannot grow ==="
lay_out ext4 second
run F10 2 "no free space immediately after" hdd expand -p "${LOOP}p1"

echo
echo "=== F2/F3: ext4, unmounted - needs --force, and is left unmounted ==="
lay_out ext4
BEFORE_P="$(psize "${LOOP}p1")"
run F2 4 "re-run with --force" hdd expand -p "${LOOP}p1"
assert F2b "[ \"\$(psize ${LOOP}p1)\" = $BEFORE_P ]"
run F3 0 "hdd expanded" hdd expand -p "${LOOP}p1" --force
assert F3b "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
assert F3c "! findmnt -nro SOURCE -S ${LOOP}p1 >/dev/null 2>&1"
# the temporary mount is gone, directory and all
LEFT="$(sudo find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
if [ "$LEFT" = 0 ]; then ok; else bad "F3d: $LEFT temporary mount dir(s) left behind"; fi
# and the filesystem really did grow, not just the partition
sudo mount "${LOOP}p1" "$MNT"
assert F3e "[ \"\$(fsavail $MNT)\" -gt 400000000 ]"
sudo umount "$MNT"

echo
echo "=== F4: xfs, mounted - grown in place ==="
lay_out xfs
sudo mount "${LOOP}p1" "$MNT"
BEFORE_F="$(fsavail "$MNT")"
run F4 0 "hdd expanded" hdd expand -p "${LOOP}p1"
assert F4b "[ \"\$(fsavail $MNT)\" -gt $BEFORE_F ]"
assert F4c "findmnt -n '$MNT' >/dev/null"
sudo umount "$MNT"

echo
echo "=== F5: xfs, unmounted, --force - grown and left unmounted ==="
lay_out xfs
BEFORE_P="$(psize "${LOOP}p1")"
run F5 0 "hdd expanded" hdd expand -p "${LOOP}p1" --force
assert F5b "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
assert F5c "! findmnt -nro SOURCE -S ${LOOP}p1 >/dev/null 2>&1"

echo
echo "=== F6: vfat, unmounted - grown with no prompt ==="
if have fatresize && have mkfs.vfat; then
    lay_out vfat
    BEFORE_P="$(psize "${LOOP}p1")"
    OUT="$(bash "$SCRIPT" hdd expand -p "${LOOP}p1" < /dev/null 2>&1)"; RC=$?
    if [ "$RC" = 0 ]; then ok; else bad "F6: rc=$RC :: $(tail -3 <<< "$OUT")"; fi
    if grep -q "TTY" <<< "$OUT"; then bad "F6b: it prompted when no mount change was needed"; else ok; fi
    assert F6c "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
    sudo mount "${LOOP}p1" "$MNT"
    assert F6d "[ \"\$(fsavail $MNT)\" -gt 400000000 ]"
    sudo umount "$MNT"

    echo "--- F7: vfat, mounted, --force - remounted at the same place ---"
    lay_out vfat
    sudo mount "${LOOP}p1" "$MNT"
    sudo sh -c "head -c 2000000 /dev/urandom > $MNT/payload"
    SUM="$(sudo md5sum "$MNT/payload" | cut -d' ' -f1)"
    BEFORE_P="$(psize "${LOOP}p1")"
    run F7 0 "hdd expanded" hdd expand -p "${LOOP}p1" --force
    assert F7b "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
    assert F7c "[ \"\$(findmnt -nro TARGET -S ${LOOP}p1)\" = '$MNT' ]"
    assert F7d "[ \"\$(sudo md5sum $MNT/payload | cut -d' ' -f1)\" = '$SUM' ]"
    sudo umount "$MNT"
else
    echo "  (fatresize/dosfstools not installed, skipping F6/F7)"
fi

echo
echo "=== F8: ntfs, mounted, no --force, no TTY ==="
if have ntfsresize && have mkfs.ntfs; then
    lay_out ntfs
    sudo mount "${LOOP}p1" "$MNT" 2>/dev/null || sudo mount -t ntfs3 "${LOOP}p1" "$MNT"
    BEFORE_P="$(psize "${LOOP}p1")"
    OUT="$(bash "$SCRIPT" hdd expand -p "${LOOP}p1" < /dev/null 2>&1)"; RC=$?
    if [ "$RC" = 2 ]; then ok; else bad "F8: rc=$RC want=2 :: $(tail -3 <<< "$OUT")"; fi
    if grep -q -- "--force" <<< "$OUT"; then ok; else bad "F8b: the refusal does not name --force"; fi
    assert F8c "[ \"\$(psize ${LOOP}p1)\" = $BEFORE_P ]"

    echo "--- and with --force it unmounts, grows and remounts ---"
    run F8d 0 "hdd expanded" hdd expand -p "${LOOP}p1" --force
    assert F8e "[ \"\$(psize ${LOOP}p1)\" -gt $BEFORE_P ]"
    assert F8f "[ \"\$(findmnt -nro TARGET -S ${LOOP}p1)\" = '$MNT' ]"
    sudo umount "$MNT"
else
    echo "  (ntfs-3g not installed, skipping F8)"
fi

echo
echo "=== F11/F12: --dry-run ==="
lay_out ext4
sudo mount "${LOOP}p1" "$MNT"
BEFORE_P="$(psize "${LOOP}p1")"
run F11  0 "dry run: .* can be expanded" hdd expand -p "${LOOP}p1" --dry-run
run F11b 0 "growable:"                   hdd expand -p "${LOOP}p1" --dry-run
run F11c 0 "no change of mount state"    hdd expand -p "${LOOP}p1" --dry-run
assert F11d "[ \"\$(psize ${LOOP}p1)\" = $BEFORE_P ]"
sudo umount "$MNT"

echo "--- a dry run of a case that WOULD prompt still does not prompt ---"
OUT="$(bash "$SCRIPT" hdd expand -p "${LOOP}p1" --dry-run < /dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "F11e: rc=$RC on an unmounted ext4 dry run :: $(tail -3 <<< "$OUT")"; fi
if grep -q "must be mounted temporarily" <<< "$OUT"; then ok; else bad "F11f: the mount change is not reported"; fi
assert F11g "[ \"\$(psize ${LOOP}p1)\" = $BEFORE_P ]"

echo "--- F12: --dry-run on a partition that cannot grow ---"
# actually grow it first, or there is still space and the case proves nothing
bash "$SCRIPT" hdd expand -p "${LOOP}p1" --force >/dev/null 2>&1
run F12 2 "no free space immediately after" hdd expand -p "${LOOP}p1" --dry-run

echo
echo "=== F13: growpart absent ==="
GP="$(command -v growpart || true)"
if [ -n "$GP" ]; then
    lay_out ext4
    sudo mv "$GP" "$GP.hidden"
    OUT="$(bash "$SCRIPT" hdd expand -p "${LOOP}p1" --force 2>&1)"; RC=$?
    sudo mv "$GP.hidden" "$GP"
    if [ "$RC" = 1 ]; then ok; else bad "F13: rc=$RC want=1 :: $(tail -3 <<< "$OUT")"; fi
    if grep -q "cloud-guest-utils" <<< "$OUT"; then ok; else bad "F13b: the message does not name the package :: $OUT"; fi
else
    echo "  (growpart not installed, skipping F13)"
fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '\n'
    for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
    exit 1
fi
