#!/usr/bin/env bash
#
# mayhem/test.sh — RUN full-moon's own functional test suite (compiled by
# mayhem/build.sh via `cargo test --no-run`). These are the crate's real assertion
# tests in full-moon/tests/ (pass_cases/fail_cases/visitors/node/etc., driven by
# insta snapshot + pretty_assertions known-answer tests over the Lua parser) — they
# assert parsed AST values and printed output, NOT just exit status, so a PATCH that
# neuters full_moon to a no-op / exit(0) fails them (anti-reward-hacking, SPEC §6.3).
#
# Emits a CTRF summary. Exit 0 iff failed==0. Does NOT compile (build.sh did).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

# RUN the prebuilt tests. build.sh already compiled them with `cargo test --no-run`,
# so this resolves from the build cache and does not recompile the world. Capture
# libtest's summary lines: "test result: ok. N passed; M failed; K ignored; ...".
LOG="$(mktemp)"
env -u RUSTFLAGS cargo test --no-fail-fast 2>&1 | tee "$LOG"

PASSED=$(grep -hoE '[0-9]+ passed'  "$LOG" | awk '{s+=$1} END{print s+0}')
FAILED=$(grep -hoE '[0-9]+ failed'  "$LOG" | awk '{s+=$1} END{print s+0}')
SKIPPED=$(grep -hoE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
rm -f "$LOG"

# If we somehow parsed nothing, treat as a hard failure (the runner must have run).
if [ "$((PASSED + FAILED + SKIPPED))" -eq 0 ]; then
  echo "ERROR: no libtest results parsed — test runner did not execute" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$SKIPPED"
