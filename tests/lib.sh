#!/usr/bin/env bash
# Shared harness for the git-utils test suites.
#
# Each suite sources this, sets WORK to a disposable directory, and calls
# gu_init. HOME is pointed at a temp dir so the real ~/.ssh and
# ~/.repositories.json are never touched.
#
# Override the script under test with GU_SRC=/path/to/git-utils.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GU_SRC="${GU_SRC:-$HERE/../git-utils}"

PASS=0
FAIL=0

# gu_init <workdir> -- fresh disposable HOME + a copy of the script under test
gu_init() {
    WORK="$1"
    rm -rf "$WORK"
    mkdir -p "$WORK/home"
    cp "$GU_SRC" "$WORK/git-utils"
    chmod +x "$WORK/git-utils"
    export HOME="$WORK/home"
    GU="$WORK/git-utils"
}

# run <expected_code> <description> -- <args...>
run() {
    local expected="$1" desc="$2"; shift 2
    local out code
    out="$(cd "$WORK" && bash "$GU" "$@" </dev/null 2>"$WORK/err.log")"
    code=$?
    LAST_ERR="$(cat "$WORK/err.log")"
    LAST_OUT="$out"
    if [ "$code" -eq "$expected" ]; then
        PASS=$((PASS+1)); printf 'PASS [%3d] %s\n' "$code" "$desc"
    else
        FAIL=$((FAIL+1))
        printf 'FAIL [got %d want %d] %s\n       stdout: %s\n       stderr: %s\n' \
            "$code" "$expected" "$desc" "$out" "$LAST_ERR"
    fi
}

# check <description> <0|1>
check() {
    local desc="$1" cond="$2"
    if [ "$cond" = "1" ]; then PASS=$((PASS+1)); echo "PASS $desc"
    else FAIL=$((FAIL+1)); echo "FAIL $desc"; fi
}

gu_total() {
    echo
    echo "TOTAL: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

# gu_eval <snippet> -- run a snippet in a fresh bash with the script's
# functions loaded but main() never invoked.
#
# Sourcing the script directly would run main "$@"; sourcing it into the test
# shell would also install its `set -euo pipefail` and EXIT trap and take the
# harness down with it. So everything up to (not including) the final
# `main "$@"` line is sourced into a separate process.
gu_eval() {
    head -n -1 "$GU" > "$WORK/lib-under-test.sh"
    cat > "$WORK/snippet.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'
export HOME="$HOME"
. "$WORK/lib-under-test.sh"
$1
EOF
    bash "$WORK/snippet.sh"
}

# --- store accessors -------------------------------------------------------
# The harness reaches into the store's internal structure, so these follow the
# schema-1.1 layout (records live under .repositories).

store() { printf '%s' "$HOME/.repositories.json"; }
rec_field()      { jq -r --arg k "$1" --arg f "$2" '.repositories[$k][$f]' "$(store)"; }
rec_has()        { jq -c --arg k "$1" --arg f "$2" '.repositories[$k] | has($f)' "$(store)"; }
rec_exists()     { jq -e --arg k "$1" '.repositories | has($k)' "$(store)" >/dev/null 2>&1; }
images_of()      { jq -c --arg k "$1" '.repositories[$k].images' "$(store)"; }
has_images_key() { rec_has "$1" images; }
loc_count()      { jq -r --arg k "$1" '.repositories[$k].locations | length' "$(store)"; }
loc_path()       { jq -r --arg k "$1" --argjson i "${2:-0}" '.repositories[$k].locations[$i].path' "$(store)"; }
store_patch()    { local t; t="$(jq "$1" "$(store)")" && printf '%s' "$t" > "$(store)"; }

# --- git fixtures ----------------------------------------------------------

git_global_setup() {
    git config --global user.email t@t.com
    git config --global user.name t
    git config --global init.defaultBranch main
}

# make_repo <n> <key> [org] [name] -- bare repo + insteadOf redirect + seed dir
make_repo() {
    local n="$1" key="$2"
    local org="${3:-testorg$n}" name="${4:-testrepo$n}"
    git init --bare "$WORK/bare$n.git" -q
    git config --global "url.$WORK/bare$n.git.insteadOf" "git@${key}.repo:${org}/${name}.git"
    rm -rf "$WORK/seed$n"; mkdir -p "$WORK/seed$n"
    ( cd "$WORK/seed$n" && git init -q )
}

# push_seed <n>
push_seed() {
    local n="$1"
    ( cd "$WORK/seed$n" && git add -A && git commit -qm sync >/dev/null 2>&1
      git remote | grep -q origin || git remote add origin "$WORK/bare$n.git"
      git push -qf origin main )
}
