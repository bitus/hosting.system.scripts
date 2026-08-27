#!/usr/bin/env bash
# Writability-preflight edge cases and trailing-newline normalisation.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-preflight

echo "=== repo add with HOME read-only (no store yet) -> 3, no key generated ==="
chmod 555 "$HOME"
run 3 "repo add with HOME readonly -> 3" repo add someorg/somename/main
chmod 755 "$HOME"
check "no key generated (preflight blocked before keygen)" \
    "$( [ -e "$HOME/.ssh/somename.key" ] && echo 0 || echo 1 )"

echo "=== trailing-newline normalisation on ~/.ssh/config ==="
mkdir -p "$HOME/.ssh"
printf 'Host somewhere\n    HostName example.com' > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"
run 0 "repo add appends after normalising newline -> 0" repo add fooorg/foorepo/main -n foorepo
check "original block preserved, not glued" \
    "$( grep -q '^Host somewhere$' "$HOME/.ssh/config" && grep -q '^    HostName example.com$' "$HOME/.ssh/config" && echo 1 || echo 0 )"
check "new block appended" "$( grep -q 'Host foorepo.repo' "$HOME/.ssh/config" && echo 1 || echo 0 )"

echo "=== repo delete with ~/.ssh read-only -> 3, record still present ==="
chmod 555 "$HOME/.ssh"
run 3 "delete foorepo with ~/.ssh readonly -> 3" repo delete foorepo
chmod 755 "$HOME/.ssh"
check "record still present after blocked delete" "$( rec_exists foorepo && echo 1 || echo 0 )"

gu_total
