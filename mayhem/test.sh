#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Redpanda's own gtest unit tests (built by mayhem/build.sh with plain flags).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Each binary is an upstream gtest suite (radix tree, interval set, contiguous range map, iobuf fragment
# list, ACL serde round-trips, variant visitor). They assert known inputs -> known outputs; a binary that
# produces no gtest report (missing, crashed, or neutered to exit(0)) counts as one failure.
TESTS=(radix_tree_test interval_set_test contiguous_range_map_test iobuf_fragment_list_test \
       acl_serde_test variant_test)
passed=0; failed=0; skipped=0
tmp="$(mktemp -d)"
for t in "${TESTS[@]}"; do
  bin="$SRC/rp_tests/$t"
  if [ ! -x "$bin" ]; then echo "missing test binary $bin (mayhem/build.sh should have built it)" >&2; failed=$((failed+1)); continue; fi
  "$bin" --gtest_output="json:$tmp/$t.json" >"$tmp/$t.log" 2>&1 || true
  tail -n 3 "$tmp/$t.log"
  if [ ! -s "$tmp/$t.json" ]; then echo "no gtest report from $t" >&2; failed=$((failed+1)); continue; fi
  read -r p f s <<<"$(python3 - "$tmp/$t.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
n = r.get("tests", 0)
f = r.get("failures", 0) + r.get("errors", 0)
s = r.get("disabled", 0)
print(max(n - f - s, 0), f, s)
PY
)"
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
done
rm -rf "$tmp"
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
