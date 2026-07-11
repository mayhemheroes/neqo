#!/usr/bin/env bash
#
# neqo/mayhem/test.sh — RUN neqo's own assertion-based test suite and emit a CTRF
# summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: this is a REAL behavioral known-answer test (KAT) suite, not
# an "exit code only" check. The exact code paths the fuzz targets exercise ship
# their own assertion tests, e.g.:
#   - neqo-common/src/codec.rs `Decoder::decode`/`decode_varint`/... — byte-exact
#     KATs (`assert_eq!(dec.decode(2).unwrap(), &[0x01, 0x23])`, varint round trips)
#     for exactly the decoder the `tparams`/`frame`/`packet`/`hframe`/`qpack`/
#     `hsettings`/`wtframe` fuzz targets all funnel through.
#   - neqo-transport/src/tparams.rs `mod tests` — encode/decode round-trip KATs for
#     TransportParameters (what fuzz/fuzz_targets/tparams.rs directly fuzzes).
#   - neqo-qpack, neqo-http3 ship their own KATs for QPACK/HTTP-3 frame codecs
#     (what fuzz/fuzz_targets/{qpack,hframe,hsettings,priority}.rs fuzz).
# A no-op / "exit(0)" / output-altering patch to any of these decoders breaks a
# concrete `assert_eq!` and CANNOT pass. We only RUN the suite here (`cargo test`);
# fuzz targets are built by mayhem/build.sh, never here.
#
# Excluded workspace members:
#   fuzz      — needs `-Zsanitizer=address`/`--cfg fuzzing`, not a normal test build.
#   mtu       — its `--test netns` suite needs root + network namespaces (CI runs it
#               under sudo); not appropriate for an image build step.
#   neqo-bin  — its tests spin real client/server processes over UDP ports; slow and
#               environment-sensitive, and adds nothing the library-level KATs above
#               don't already cover for the fuzzed decode paths.
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (neqo workspace, default features, no sanitizer) ==="
# NSS_DIR/NSS_PREBUILT (Dockerfile ENV) make nss-rs link the already-built NSS tree;
# no rebuild, no network. RUSTFLAGS cleared so it inherits nothing from the ASan
# fuzz build. --no-fail-fast so we count every test, not just the first failure.
out="$(RUSTFLAGS="" cargo test --locked --workspace \
  --exclude fuzz --exclude mtu --exclude neqo-bin \
  --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
