#!/usr/bin/env bash
# Fix: "Permission denied" after updating the repo on a production host.
#
# `git reset --hard` restores a file with the mode git recorded for it. The
# scripts were committed 100644, so an update stripped the executable bit that
# `setup` had applied, and every later run through the /usr/local/sbin symlink
# failed. Two halves to the fix: the bit is recorded in git, and re-running
# `setup` repairs it without having to delete the symlink first.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-execbit
git_global_setup
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== the shipped repo records the executable bit ==="
for f in git-utils setup system-setup; do
    mode="$(cd "$REPO_ROOT" && git ls-files -s "$f" | awk '{print $1}')"
    check "$f is 100755 in git" "$( [ "$mode" = "100755" ] && echo 1 || echo 0 )"
done
mode="$(cd "$REPO_ROOT" && git ls-files -s command-shortcuts | awk '{print $1}')"
check "command-shortcuts stays 100644 (sourced, no shebang)" \
    "$( [ "$mode" = "100644" ] && echo 1 || echo 0 )"

echo "=== a recorded 100755 survives fetch/reset/clean ==="
# stand up a tiny repo the way the production host has one
git init -q --bare "$WORK/origin.git"
mkdir -p "$WORK/checkout"
( cd "$WORK/checkout" && git init -q \
    && printf '#!/usr/bin/env bash\necho ran\n' > tool \
    && git add tool && git update-index --chmod=+x tool \
    && git commit -qm one && git remote add origin "$WORK/origin.git" \
    && git push -q origin main )
check "committed as 100755" \
    "$( [ "$(cd "$WORK/checkout" && git ls-files -s tool | awk '{print $1}')" = "100755" ] && echo 1 || echo 0 )"
chmod -x "$WORK/checkout/tool"
( cd "$WORK/checkout" && git fetch -q origin && git reset -q --hard origin/main && git clean -qfd )
check "reset --hard restored the executable bit" "$( [ -x "$WORK/checkout/tool" ] && echo 1 || echo 0 )"

echo "--- and a 100644 file does NOT survive it (the original bug) ---"
( cd "$WORK/checkout" && printf '#!/usr/bin/env bash\necho ran\n' > plain \
    && git add plain && git update-index --chmod=-x plain \
    && git commit -qm two && git push -q origin main )
chmod +x "$WORK/checkout/plain"
( cd "$WORK/checkout" && git fetch -q origin && git reset -q --hard origin/main && git clean -qfd )
check "a 100644 file loses the bit on reset --hard" \
    "$( [ -x "$WORK/checkout/plain" ] && echo 0 || echo 1 )"

echo "=== setup repairs a stripped bit without deleting the symlink ==="
SBIN=/usr/local/sbin
if [ ! -w "$SBIN" ]; then
    echo "SKIP $SBIN not writable in this environment"
else
    rm -f "$SBIN/git-utils"
    run 0 "first setup installs the symlink -> 0" setup
    check "symlink created" "$( [ -L "$SBIN/git-utils" ] && echo 1 || echo 0 )"
    check "target is executable" "$( [ -x "$GU" ] && echo 1 || echo 0 )"
    check "runs through the symlink" \
        "$( "$SBIN/git-utils" -h >/dev/null 2>&1 && echo 1 || echo 0 )"

    # exactly what an update does to the checkout
    chmod -x "$GU"
    check "running through the symlink now fails" \
        "$( "$SBIN/git-utils" -h >/dev/null 2>&1 && echo 0 || echo 1 )"

    run 0 "re-running setup -> 0" setup
    check "setup said it restored the bit" \
        "$( echo "$LAST_OUT" | grep -q 'restored the executable bit' && echo 1 || echo 0 )"
    check "symlink was left alone" "$( [ -L "$SBIN/git-utils" ] && echo 1 || echo 0 )"
    check "target executable again" "$( [ -x "$GU" ] && echo 1 || echo 0 )"
    check "runs through the symlink again" \
        "$( "$SBIN/git-utils" -h >/dev/null 2>&1 && echo 1 || echo 0 )"

    echo "--- a setup with nothing to repair is quiet about it ---"
    run 0 "third setup -> 0" setup
    check "no spurious 'restored' message" \
        "$( echo "$LAST_OUT" | grep -q 'restored the executable bit' && echo 0 || echo 1 )"
    check "warns that the symlink already points here" \
        "$( echo "$LAST_ERR" | grep -q 'already points here' && echo 1 || echo 0 )"

    echo "--- a symlink pointing somewhere else is reported, not silently kept ---"
    rm -f "$SBIN/git-utils"
    ln -s /nonexistent/elsewhere/git-utils "$SBIN/git-utils"
    run 0 "setup with a foreign symlink -> 0" setup
    check "names the path it actually points at" \
        "$( echo "$LAST_ERR" | grep -q 'points at' && echo 1 || echo 0 )"
    rm -f "$SBIN/git-utils"
fi

gu_total
