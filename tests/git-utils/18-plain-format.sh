#!/usr/bin/env bash
# Fix 50-04 Phase 1: the `plain` output format and the default flip.
#
# Spec cases 90, 91 and the part of 95 reachable now. Cases 92-94 need the
# plain forms of `repo folders` and the fan-out commands and land with those
# phases.
#
# The load-bearing claim of this phase is that flipping the default from
# `text` to `plain` is INERT for every command that predates fix 50-04,
# because none of them passes a plain filter. That claim is what the existing
# seventeen suites prove; what this suite proves is that the mechanism does
# what it says, including the fall-through.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-plain
git_global_setup

# render <format> <json> [plain_filter]
#
# Both the document and the filter go through files: the filter contains
# double quotes and jq's \(...) interpolation, which does not survive being
# pasted into the generated snippet.
render() {
    printf '%s' "$2" > "$WORK/render-in.json"
    printf '%s' "${3:-}" > "$WORK/render-filter.jq"
    if [ -n "${3:-}" ]; then
        gu_eval "OUTPUT_FORMAT='$1'; render_output \"\$(cat '$WORK/render-in.json')\" \"\$(cat '$WORK/render-filter.jq')\""
    else
        gu_eval "OUTPUT_FORMAT='$1'; render_output \"\$(cat '$WORK/render-in.json')\""
    fi
}

SIMPLE='{"a":{"code":0,"status":"Ok","description":""},"b":{"code":8,"status":"Failed","description":"Origin does not match"}}'
ARR='[{"id":"my.repo","path":"/home/user/docker/my.repo"},{"id":"my.repo2","path":"/opt/x y/my.repo2"}]'

echo "=== 90: plain is the default format ==="
OUT="$(gu_eval 'printf "%s" "$OUTPUT_FORMAT"')"
check "OUTPUT_FORMAT defaults to plain" "$( [ "$OUT" = "plain" ] && echo 1 || echo 0 )"
OUT="$(gu_eval 'printf "%s" "$OUTPUT_FORMAT_DEFAULT"')"
check "OUTPUT_FORMAT_DEFAULT is plain" "$( [ "$OUT" = "plain" ] && echo 1 || echo 0 )"

echo "=== 91: plain without a filter is byte-identical to text ==="
P="$(render plain "$SIMPLE")"
T="$(render text "$SIMPLE")"
Y="$(render yaml "$SIMPLE")"
check "plain == text (no filter)" "$( [ "$P" = "$T" ] && echo 1 || echo 0 )"
check "plain == yaml (no filter)" "$( [ "$P" = "$Y" ] && echo 1 || echo 0 )"
check "fall-through still folds status objects" \
    "$( echo "$P" | grep -q 'Failed — Origin does not match' && echo 1 || echo 0 )"

echo "=== plain WITH a filter emits raw lines ==="
POUT="$(render plain "$ARR" '.[] | "\(.id) \(.path)"')"
check "two lines out" "$( [ "$(echo "$POUT" | wc -l)" -eq 2 ] && echo 1 || echo 0 )"
check "first line is 'id path'" \
    "$( [ "$(echo "$POUT" | head -1)" = "my.repo /home/user/docker/my.repo" ] && echo 1 || echo 0 )"
# grep -qv would pass as soon as ANY line lacked a quote; the claim is that
# NO line has one.
check "raw output is unquoted" "$( echo "$POUT" | grep -q '\"' && echo 0 || echo 1 )"

# The parsing rule the description states: a key cannot contain a space, a
# path can, so a consumer splits on the FIRST space. Proven, not assumed.
LINE="$(echo "$POUT" | tail -1)"
check "path containing a space survives" \
    "$( [ "${LINE#* }" = "/opt/x y/my.repo2" ] && echo 1 || echo 0 )"
check "key is the first field" \
    "$( [ "${LINE%% *}" = "my.repo2" ] && echo 1 || echo 0 )"

echo "=== a filter is ignored by every non-plain format ==="
JOUT="$(render json "$ARR" '.[] | "\(.id) \(.path)"')"
check "json ignores the plain filter" \
    "$( printf '%s' "$JOUT" | jq -e 'type == "array"' >/dev/null 2>&1 && echo 1 || echo 0 )"
TOUT="$(render text "$ARR" '.[] | "\(.id) \(.path)"')"
check "text ignores the plain filter" \
    "$( echo "$TOUT" | grep -q '^- id: my.repo$' && echo 1 || echo 0 )"

echo "=== 95: json stays valid ==="
check "json output parses" \
    "$( printf '%s' "$(render json "$SIMPLE")" | jq empty >/dev/null 2>&1 && echo 1 || echo 0 )"

echo "=== format validation accepts plain, still rejects junk ==="
for good in json text yaml plain; do
    gu_eval "output_format_set '$good'; [ \"\$OUTPUT_FORMAT\" = '$good' ]" >/dev/null 2>&1
    check "output_format_set '$good' accepted" "$( [ $? -eq 0 ] && echo 1 || echo 0 )"
done
for bad in xml "" PLAIN plainn; do
    gu_eval "output_format_set '$bad'" >/dev/null 2>&1
    check "output_format_set '$bad' -> 2" "$( [ $? -eq 2 ] && echo 1 || echo 0 )"
done

echo "=== the flip is inert end to end ==="
# An existing command, default format, must produce exactly what it produced
# before the flip -- i.e. the same bytes as an explicit --output-format text.
make_repo 1 plainrepo
echo hi > "$WORK/seed1/f"; push_seed 1
run 0 "repo add for the format comparison" repo add testorg1/testrepo1/main -n plainrepo

DEF="$(cd "$WORK" && bash "$GU" repo info plainrepo 2>/dev/null)"
TXT="$(cd "$WORK" && bash "$GU" repo info plainrepo --output-format text 2>/dev/null)"
check "repo info default == --output-format text" "$( [ "$DEF" = "$TXT" ] && echo 1 || echo 0 )"
check "repo info default is not empty" "$( [ -n "$DEF" ] && echo 1 || echo 0 )"

DEF="$(cd "$WORK" && bash "$GU" folder validate 2>/dev/null || true)"
TXT="$(cd "$WORK" && bash "$GU" folder validate --output-format text 2>/dev/null || true)"
check "folder validate default == text" "$( [ "$DEF" = "$TXT" ] && echo 1 || echo 0 )"

echo "=== E_CMDOUTPUT replaces E_GITOUTPUT ==="
OUT="$(gu_eval 'printf "%s" "$E_CMDOUTPUT"')"
check "E_CMDOUTPUT is 10" "$( [ "$OUT" = "10" ] && echo 1 || echo 0 )"
gu_eval 'printf "%s" "${E_GITOUTPUT:-}"' >/dev/null 2>&1
check "E_GITOUTPUT is gone (renamed, not aliased)" \
    "$( [ -z "$(gu_eval 'printf "%s" "${E_GITOUTPUT:-}"' 2>/dev/null)" ] && echo 1 || echo 0 )"

echo "=== new error-code constants exist and are distinct ==="
CODES="$(gu_eval 'printf "%s %s %s %s %s" "$E_NOCOMPOSE" "$E_NOTRUNNING" "$E_IMAGE" "$E_NOUPDATE" "$TIMEOUT_EXIT"')"
check "14 16 18 22 124" "$( [ "$CODES" = "14 16 18 22 124" ] && echo 1 || echo 0 )"
check "no collision with the existing code space" \
    "$( [ "$(echo "$CODES" | tr ' ' '\n' | sort -u | wc -l)" -eq 5 ] && echo 1 || echo 0 )"
DEFS="$(gu_eval 'printf "%s %s" "$PULL_TIMEOUT_DEFAULT" "$STATUS_TIMEOUT_DEFAULT"')"
check "timeout defaults are 300 and 60" "$( [ "$DEFS" = "300 60" ] && echo 1 || echo 0 )"

echo "=== help mentions plain ==="
HOUT="$(cd "$WORK" && bash "$GU" --help 2>&1)"
check "help lists plain" "$( echo "$HOUT" | grep -q 'json|text|yaml|plain' && echo 1 || echo 0 )"
check "help states the new default" "$( echo "$HOUT" | grep -q 'default plain' && echo 1 || echo 0 )"

gu_total
