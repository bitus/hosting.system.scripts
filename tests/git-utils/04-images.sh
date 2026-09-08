#!/usr/bin/env bash
# Fix 50-01: Docker Compose / .images collection.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-images
mkdir -p "$WORK/fakebin"
git_global_setup

# a "docker is not installed" stub, placed first on PATH
cat > "$WORK/fakebin/docker" << 'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/fakebin/docker"

echo "=== 1: .images only, no compose ==="
make_repo 1 img1
printf 'zeta:1\nalpha:1\n' > "$WORK/seed1/.images"
push_seed 1
run 0 "add img1 -> 0" repo add testorg1/testrepo1/main -n img1
run 0 "clone img1 -> 0" repo clone img1 "$WORK/d1"
check "images = [alpha:1, zeta:1]" "$( [ "$(images_of img1)" = '["alpha:1","zeta:1"]' ] && echo 1 || echo 0 )"
check "no warning" "$( echo "$LAST_ERR" | grep -q '^warning:' && echo 0 || echo 1 )"

echo "=== 2/3/4: comments, CRLF, no trailing newline ==="
make_repo 2 img2
printf '# top comment\n  nginx:1.27-alpine   # trailing comment  \r\n\r\n   \r\nimage_custom_mailer\r\n' > "$WORK/seed2/.images"
printf 'lastline:1' >> "$WORK/seed2/.images"
push_seed 2
run 0 "add img2 -> 0" repo add testorg2/testrepo2/main -n img2
run 0 "clone img2 -> 0" repo clone img2 "$WORK/d2"
check "images2 parsed correctly" \
    "$( [ "$(images_of img2)" = '["image_custom_mailer","lastline:1","nginx:1.27-alpine"]' ] && echo 1 || echo 0 )"

echo "=== 5: empty / comments-only .images -> [] ==="
make_repo 3 img3
printf '# just a comment\n\n   \n' > "$WORK/seed3/.images"
push_seed 3
run 0 "add img3 -> 0" repo add testorg3/testrepo3/main -n img3
run 0 "clone img3 -> 0" repo clone img3 "$WORK/d3"
check "images3 = []" "$( [ "$(images_of img3)" = '[]' ] && echo 1 || echo 0 )"

echo "=== 6: .images is a directory -> warning, treated as absent ==="
make_repo 4 img4
mkdir -p "$WORK/seed4/.images"; touch "$WORK/seed4/.images/.gitkeep"
push_seed 4
run 0 "add img4 -> 0" repo add testorg4/testrepo4/main -n img4
run 0 "clone img4 -> 0" repo clone img4 "$WORK/d4"
check "images4 = []" "$( [ "$(images_of img4)" = '[]' ] && echo 1 || echo 0 )"
check "warned about directory" "$( echo "$LAST_ERR" | grep -qi 'directory' && echo 1 || echo 0 )"

echo "=== 9: neither .images nor compose -> [], no warning ==="
make_repo 5 img5
echo hi > "$WORK/seed5/readme.txt"
push_seed 5
run 0 "add img5 -> 0" repo add testorg5/testrepo5/main -n img5
run 0 "clone img5 -> 0" repo clone img5 "$WORK/d5"
check "images5 = []" "$( [ "$(images_of img5)" = '[]' ] && echo 1 || echo 0 )"
check "no warning" "$( echo "$LAST_ERR" | grep -q '^warning:' && echo 0 || echo 1 )"

echo "=== 10-14: compose extraction ==="
make_repo 6 img6
cat > "$WORK/seed6/compose.yml" << 'EOF'
services:
  web:
    image: nginx:1.27-alpine
  worker:
    image: registry.example.com/team/api:v2
  web2:
    image: nginx:1.27-alpine
  debugger:
    image: busybox:latest
    profiles: ["debug"]
  builder:
    build:
      context: .
    image: image_custom_mailer
  fromenv:
    image: ${OBSERVE_IMAGE}
EOF
echo 'OBSERVE_IMAGE=public.ecr.aws/zinclabs/openobserve:latest' > "$WORK/seed6/.env"
push_seed 6
run 0 "add img6 -> 0" repo add testorg6/testrepo6/main -n img6
run 0 "clone img6 -> 0" repo clone img6 "$WORK/d6"
EXPECT6='["busybox:latest","nginx:1.27-alpine","public.ecr.aws/zinclabs/openobserve:latest","registry.example.com/team/api:v2"]'
check "build skipped, profile included, dedup, env interpolated" \
    "$( [ "$(images_of img6)" = "$EXPECT6" ] && echo 1 || echo 0 )"

echo "=== 15: .images + compose union ==="
make_repo 7 img7
printf 'services:\n  web:\n    image: nginx:stable\n' > "$WORK/seed7/compose.yml"
printf 'image_custom_mailer\nnginx:stable\n' > "$WORK/seed7/.images"
push_seed 7
run 0 "add img7 -> 0" repo add testorg7/testrepo7/main -n img7
run 0 "clone img7 -> 0" repo clone img7 "$WORK/d7"
check "union + dedup" "$( [ "$(images_of img7)" = '["image_custom_mailer","nginx:stable"]' ] && echo 1 || echo 0 )"

echo "=== 16/17: compose repo, docker unavailable -> images untouched ==="
make_repo 8 img8
printf 'services:\n  web:\n    image: nginx:stable\n' > "$WORK/seed8/compose.yml"
push_seed 8
run 0 "add img8 -> 0" repo add testorg8/testrepo8/main -n img8
store_patch '.repositories.img8.images = ["preexisting:v9"]'
out="$(cd "$WORK" && PATH="$WORK/fakebin:$PATH" bash "$GU" repo clone img8 "$WORK/d8" </dev/null 2>"$WORK/err.log")"; code=$?
LAST_ERR="$(cat "$WORK/err.log")"
check "clone img8 (docker unavailable) exit 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "images8 untouched (still preexisting:v9)" "$( [ "$(images_of img8)" = '["preexisting:v9"]' ] && echo 1 || echo 0 )"
check "warned about docker unavailable" "$( echo "$LAST_ERR" | grep -qi 'docker compose not available' && echo 1 || echo 0 )"

make_repo 9 img9
printf 'services:\n  web:\n    image: nginx:stable\n' > "$WORK/seed9/compose.yml"
echo 'image_custom_mailer' > "$WORK/seed9/.images"
push_seed 9
run 0 "add img9 -> 0" repo add testorg9/testrepo9/main -n img9
store_patch '.repositories.img9.images = ["preexisting:v9"]'
out="$(cd "$WORK" && PATH="$WORK/fakebin:$PATH" bash "$GU" repo clone img9 "$WORK/d9" </dev/null 2>"$WORK/err.log")"; code=$?
check "clone img9 exit 0" "$( [ "$code" -eq 0 ] && echo 1 || echo 0 )"
check "images9 untouched (.images discarded per row 4)" "$( [ "$(images_of img9)" = '["preexisting:v9"]' ] && echo 1 || echo 0 )"

echo "=== 18/19: malformed compose file ==="
make_repo 10 im10
echo 'this: is: not: valid: yaml: [' > "$WORK/seed10/compose.yml"
push_seed 10
run 0 "add im10 -> 0" repo add testorg10/testrepo10/main -n im10
run 0 "clone im10 -> 0 (malformed compose, no .images)" repo clone im10 "$WORK/d10"
check "images10 = []" "$( [ "$(images_of im10)" = '[]' ] && echo 1 || echo 0 )"
check "warned about config failure" "$( echo "$LAST_ERR" | grep -qi 'config failed' && echo 1 || echo 0 )"

make_repo 11 im11
echo 'this: is: not: valid: yaml: [' > "$WORK/seed11/compose.yml"
echo 'onlyme:latest' > "$WORK/seed11/.images"
push_seed 11
run 0 "add im11 -> 0" repo add testorg11/testrepo11/main -n im11
run 0 "clone im11 -> 0 (malformed compose, with .images)" repo clone im11 "$WORK/d11"
check "images11 = [onlyme:latest]" "$( [ "$(images_of im11)" = '["onlyme:latest"]' ] && echo 1 || echo 0 )"

echo "=== 20: compose deleted upstream, then update recomputes ==="
make_repo 12 im12
printf 'services:\n  web:\n    image: nginx:stable\n' > "$WORK/seed12/compose.yml"
push_seed 12
run 0 "add im12 -> 0" repo add testorg12/testrepo12/main -n im12
run 0 "clone im12 -> 0" repo clone im12 "$WORK/d12"
check "images12 initially [nginx:stable]" "$( [ "$(images_of im12)" = '["nginx:stable"]' ] && echo 1 || echo 0 )"
rm "$WORK/seed12/compose.yml"; push_seed 12
run 0 "update im12 -> 0" repo update im12
check "images12 recomputed to []" "$( [ "$(images_of im12)" = '[]' ] && echo 1 || echo 0 )"

echo "=== 21/23: location selection ==="
make_repo 13 im13
echo 'entry:v1' > "$WORK/seed13/.images"
push_seed 13
run 0 "add im13 -> 0" repo add testorg13/testrepo13/main -n im13
run 0 "clone1 im13 -> 0" repo clone im13 "$WORK/e13a"
run 0 "clone2 im13 -> 0" repo clone im13 "$WORK/e13b"
rm -rf "$WORK/e13a"
run 0 "update im13 by key (first missing, falls to second)" repo update im13
check "collected from e13b despite e13a missing" "$( [ "$(images_of im13)" = '["entry:v1"]' ] && echo 1 || echo 0 )"

make_repo 14 im14
echo 'entry:v1' > "$WORK/seed14/.images"
push_seed 14
run 0 "add im14 -> 0" repo add testorg14/testrepo14/main -n im14
run 0 "update im14, zero locations -> 0, no-op" repo update im14
run 0 "update im14 again -> 0, still no-op" repo update im14
check "images14 stays [] from repo add" "$( [ "$(images_of im14)" = '[]' ] && echo 1 || echo 0 )"

echo "=== 26: unchanged second update performs no store write ==="
make_repo 15 im15
echo 'stable:v1' > "$WORK/seed15/.images"
push_seed 15
run 0 "add im15 -> 0" repo add testorg15/testrepo15/main -n im15
run 0 "clone im15 -> 0" repo clone im15 "$WORK/d15"
run 0 "update im15 (1st) -> 0" repo update im15
MTIME1="$(stat -c '%Y' "$(store)")"
sleep 1
run 0 "update im15 (2nd, no source changes) -> 0" repo update im15
MTIME2="$(stat -c '%Y' "$(store)")"
check "store untouched on unchanged update ($MTIME1 == $MTIME2)" "$( [ "$MTIME1" = "$MTIME2" ] && echo 1 || echo 0 )"

echo "=== 27: legacy record (no images key) populated on next update ==="
make_repo 16 im16
echo 'legacy:v1' > "$WORK/seed16/.images"
push_seed 16
run 0 "add im16 -> 0" repo add testorg16/testrepo16/main -n im16
run 0 "clone im16 -> 0" repo clone im16 "$WORK/d16"
store_patch 'del(.repositories.im16.images)'
check "images key removed (simulating legacy record)" "$( [ "$(has_images_key im16)" = "false" ] && echo 1 || echo 0 )"
run 0 "update im16 -> 0, no error" repo update im16
check "images16 populated" "$( [ "$(has_images_key im16)" = "true" ] && echo 1 || echo 0 )"
check "images16 = [legacy:v1]" "$( [ "$(images_of im16)" = '["legacy:v1"]' ] && echo 1 || echo 0 )"

gu_total
