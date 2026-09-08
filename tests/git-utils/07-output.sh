#!/usr/bin/env bash
# Fix 50-02 Phase 2: status objects, folding, --output-format rendering.
# Spec cases 62-67. Case 68 (yq absent) needs a command that calls
# precheck_output and lands with `folder status` in phase 3.
#
# No command consumes this layer yet, so the functions are driven directly.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gu_init /tmp/gu-output

# render <format> <json> -- run render_output in the script's own environment
render() {
    printf '%s' "$2" > "$WORK/render-in.json"
    gu_eval "OUTPUT_FORMAT='$1'; render_output \"\$(cat '$WORK/render-in.json')\""
}

SIMPLE='{"database":{"code":0,"status":"Ok","description":""},"schema":{"code":1,"status":"Failed","description":"Database schema is invalid or missing"}}'

echo "=== status_obj shape ==="
OUT="$(gu_eval 'status_obj 0 Ok')"
check "status_obj 0 Ok" "$( [ "$OUT" = '{"code":0,"status":"Ok","description":""}' ] && echo 1 || echo 0 )"
OUT="$(gu_eval 'status_obj 90 Failed "Missing fields"')"
check "status_obj with description" \
    "$( [ "$OUT" = '{"code":90,"status":"Failed","description":"Missing fields"}' ] && echo 1 || echo 0 )"

echo "=== status_failed keys off .status, not .code ==="
for s in Ok Fixed Warning Skipped; do
    gu_eval "status_failed \"\$(status_obj 0 $s)\"" >/dev/null 2>&1
    check "$s does not count as failure" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"
done
gu_eval 'status_failed "$(status_obj 1 Failed)"' >/dev/null 2>&1
check "Failed counts as failure" "$( [ $? -eq 0 ] && echo 1 || echo 0 )"
# the case the .code predicate would get wrong in both directions
gu_eval 'status_failed "$(status_obj 90 Failed "Missing fields")"' >/dev/null 2>&1
check "code 90 + Failed -> failure" "$( [ $? -eq 0 ] && echo 1 || echo 0 )"
gu_eval 'status_failed "$(status_obj 0 Warning "Repository has no locations")"' >/dev/null 2>&1
check "code 0 + Warning -> not a failure" "$( [ $? -ne 0 ] && echo 1 || echo 0 )"

echo "=== 62: default vs yaml vs text are identical ==="
DEF="$(render text "$SIMPLE")"
YML="$(render yaml "$SIMPLE")"
check "text == yaml" "$( [ "$DEF" = "$YML" ] && echo 1 || echo 0 )"
OUT="$(gu_eval "render_output \"\$(cat '$WORK/render-in.json')\"")"
check "unset format defaults to text" "$( [ "$OUT" = "$DEF" ] && echo 1 || echo 0 )"

echo "=== 63/64: folding keeps the reason, drops the empty description ==="
check "passing check folds to bare Ok" "$( echo "$DEF" | grep -qx 'database: Ok' && echo 1 || echo 0 )"
check "failing check keeps its reason" \
    "$( echo "$DEF" | grep -q 'schema: Failed — Database schema is invalid or missing' && echo 1 || echo 0 )"
check "no trailing separator on a passing check" "$( echo "$DEF" | grep -q 'Ok —' && echo 0 || echo 1 )"

echo "=== json format is unfolded ==="
JS="$(render json "$SIMPLE")"
check "json keeps the status object" "$( echo "$JS" | jq -e '.schema.code == 1' >/dev/null && echo 1 || echo 0 )"
check "json keeps the description field" \
    "$( echo "$JS" | jq -e '.schema.description == "Database schema is invalid or missing"' >/dev/null && echo 1 || echo 0 )"
check "json is pretty-printed" "$( [ "$(echo "$JS" | wc -l)" -gt 1 ] && echo 1 || echo 0 )"

echo "=== 65: nested folding (checks.locations and the repositories array) ==="
NESTED='{"database":{"code":0,"status":"Ok","description":""},"repositories":[{"id":"my-repo","name":"my.repo.name","checks":{"fields":{"code":0,"status":"Ok","description":""},"locations":{"/home/user/my.repo":{"location":{"code":0,"status":"Ok","description":""},"origin":{"code":8,"status":"Failed","description":"Origin does not match"}}},"health":{"code":1,"status":"Failed","description":""}}}]}'
NOUT="$(render text "$NESTED")"
check "status inside checks.locations folded" "$( echo "$NOUT" | grep -q 'origin: Failed — Origin does not match' && echo 1 || echo 0 )"
check "status inside repositories[] folded" "$( echo "$NOUT" | grep -q 'health: Failed$' && echo 1 || echo 0 )"
check "path-shaped map key survives" "$( echo "$NOUT" | grep -q '/home/user/my.repo:' && echo 1 || echo 0 )"
check "no raw 'code:' left anywhere" "$( echo "$NOUT" | grep -q 'code:' && echo 0 || echo 1 )"

echo "=== 66: non-status objects pass through unchanged ==="
PASSTHRU='{"id":"r","name":"my.repo.name","images":["nginx:1.27-alpine","registry.example.com/team/api:v2"],"locations":[{"path":"/home/user/x"}],"foreign":false,"checks":{"health":{"code":0,"status":"Ok","description":""}}}'
POUT="$(render text "$PASSTHRU")"
check "images array intact" "$( echo "$POUT" | grep -q -- '- nginx:1.27-alpine' && echo 1 || echo 0 )"
check "colon-bearing image ref intact" "$( echo "$POUT" | grep -q -- '- registry.example.com/team/api:v2' && echo 1 || echo 0 )"
check "locations array of objects intact" "$( echo "$POUT" | grep -q -- '- path: /home/user/x' && echo 1 || echo 0 )"
check "boolean false passes through" "$( echo "$POUT" | grep -qx 'foreign: false' && echo 1 || echo 0 )"
check "plain scalar passes through" "$( echo "$POUT" | grep -qx 'name: my.repo.name' && echo 1 || echo 0 )"
check "status object still folded alongside" "$( echo "$POUT" | grep -qx '  health: Ok' && echo 1 || echo 0 )"

echo "=== key order is preserved through the render ==="
check "id renders first" "$( [ "$(echo "$POUT" | head -1)" = "id: r" ] && echo 1 || echo 0 )"
JORD="$(render json "$PASSTHRU")"
check "id is first in json too" "$( [ "$(echo "$JORD" | jq -r 'keys_unsorted[0]')" = "id" ] && echo 1 || echo 0 )"

echo "=== YAML-ambiguous scalars are quoted by the renderer ==="
AMBIG='{"branch":"no","other":"yes","ver":"1.0","desc":"Failed: it broke"}'
AOUT="$(render text "$AMBIG")"
check "a branch named 'no' is quoted" "$( echo "$AOUT" | grep -qx "branch: 'no'" && echo 1 || echo 0 )"
check "colon-space value is quoted" "$( echo "$AOUT" | grep -q "desc: 'Failed: it broke'" && echo 1 || echo 0 )"
check "ambiguous output round-trips" \
    "$( [ "$(printf '%s' "$AOUT" | yq -c . 2>/dev/null)" = "$AMBIG" ] && echo 1 || echo 0 )"

echo "=== 67: invalid --output-format value -> 2 ==="
for bad in xml "" JSON yamll; do
    gu_eval "output_format_set '$bad'" >/dev/null 2>&1
    check "output_format_set '$bad' -> 2" "$( [ $? -eq 2 ] && echo 1 || echo 0 )"
done
for good in json text yaml; do
    gu_eval "output_format_set '$good'; [ \"\$OUTPUT_FORMAT\" = '$good' ]" >/dev/null 2>&1
    check "output_format_set '$good' accepted" "$( [ $? -eq 0 ] && echo 1 || echo 0 )"
done

echo "=== empty structures render cleanly ==="
EOUT="$(render text '{"repositories":[],"description":""}')"
check "empty array renders as []" "$( echo "$EOUT" | grep -qx 'repositories: \[\]' && echo 1 || echo 0 )"

gu_total
