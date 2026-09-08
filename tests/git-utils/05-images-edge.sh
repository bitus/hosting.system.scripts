#!/usr/bin/env bash
# Fix 50-01 edge cases: update-failure fallback, best-effort write failures
# (read-only store, lock contention), and the vanished-record race.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-images-edge
git_global_setup

echo "=== 22: git update fails for first location -> falls through ==="
make_repo 1 imz1
echo 'ok:v1' > "$WORK/seed1/.images"
push_seed 1
run 0 "add imz1 -> 0" repo add testorg1/testrepo1/main -n imz1
run 0 "clone1 imz1 -> 0" repo clone imz1 "$WORK/f1a"
run 0 "clone2 imz1 -> 0" repo clone imz1 "$WORK/f1b"
# corrupt the first location so `git fetch origin` fails there
rm -rf "$WORK/f1a/.git/refs" "$WORK/f1a/.git/objects"
run 3 "update imz1 by key -> 3 (first location's fetch fails)" repo update imz1
check "images collected from f1b despite f1a failing" "$( [ "$(images_of imz1)" = '["ok:v1"]' ] && echo 1 || echo 0 )"

echo "=== 24: read-only store -> warning only, exit code unaffected ==="
make_repo 2 imz2
echo 'ro:v1' > "$WORK/seed2/.images"
push_seed 2
run 0 "add imz2 -> 0" repo add testorg2/testrepo2/main -n imz2
run 0 "clone imz2 -> 0" repo clone imz2 "$WORK/f2"
# change the source upstream so a real recompute happens (a local uncommitted
# edit would just be wiped by `git clean -fd` before collection)
echo 'ro2:v2' >> "$WORK/seed2/.images"
push_seed 2
chmod 555 "$HOME"
run 0 "update imz2 with HOME read-only -> still 0" repo update imz2
check "warned about failing to write images" \
    "$( echo "$LAST_ERR" | grep -qi 'failed to write images\|could not acquire lock' && echo 1 || echo 0 )"
chmod 755 "$HOME"
check "images unchanged (write was blocked)" "$( [ "$(images_of imz2)" = '["ro:v1"]' ] && echo 1 || echo 0 )"

echo "=== 25: lock held elsewhere > LOCK_WAIT -> warning only, not exit 3 ==="
make_repo 3 imz3
echo 'lock:v1' > "$WORK/seed3/.images"
push_seed 3
run 0 "add imz3 -> 0" repo add testorg3/testrepo3/main -n imz3
run 0 "clone imz3 -> 0" repo clone imz3 "$WORK/f3"
echo 'lock2:v2' >> "$WORK/seed3/.images"
push_seed 3
( exec 9>"$HOME/.repositories.json.lock"; flock 9; sleep 12 ) &
LOCKPID=$!
sleep 1
START=$(date +%s)
run 0 "update imz3 while lock held elsewhere -> still 0" repo update imz3
ELAPSED=$(( $(date +%s) - START ))
check "waited roughly LOCK_WAIT (~10s), got ${ELAPSED}s" "$( [ "$ELAPSED" -ge 9 ] && echo 1 || echo 0 )"
check "warned about lock" "$( echo "$LAST_ERR" | grep -qi 'could not acquire lock to update images' && echo 1 || echo 0 )"
wait "$LOCKPID" 2>/dev/null || true

echo "=== 28: record deleted between clone's location-add and the images write ==="
make_repo 4 imz4
echo 'gone:v1' > "$WORK/seed4/.images"
push_seed 4
run 0 "add imz4 -> 0" repo add testorg4/testrepo4/main -n imz4
# Drive images_write directly against a vanished record. Sourcing the whole
# script would invoke main(), so the harness sources everything up to (not
# including) the final `main "$@"` line.
cat > "$WORK/harness.sh" << HARNESS
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'
export HOME="$HOME"
head -n -1 "$GU" > "$WORK/lib-under-test.sh"
. "$WORK/lib-under-test.sh"
repos_delete imz4
images_write imz4 '["gone:v1"]'
HARNESS
out="$(cd "$WORK" && bash "$WORK/harness.sh" 2>"$WORK/err.log")"; code=$?
LAST_ERR="$(cat "$WORK/err.log")"
check "images_write against vanished record exits 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "warned about vanished record" "$( echo "$LAST_ERR" | grep -qi 'no longer exists' && echo 1 || echo 0 )"
check "record not resurrected" "$( rec_exists imz4 && echo 0 || echo 1 )"

gu_total
