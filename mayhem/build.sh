#!/usr/bin/env bash
#
# neqo/mayhem/build.sh — build ALL of mozilla/neqo's cargo-fuzz targets as
# sanitized libFuzzer binaries, replicating OSS-Fuzz's projects/neqo/build.sh
# (`cargo fuzz build` from the repo root; neqo's `fuzz/` crate is a member of the
# root cargo workspace, not a standalone one, so binaries land in the WORKSPACE
# target dir — $SRC/target/..., not $SRC/fuzz/target/...).
#
# ASan is wired the Rust way, via RUSTFLAGS (`-Zsanitizer=address`), which needs
# the nightly toolchain the Dockerfile pins as default. neqo's crypto layer (the
# `nss` crate / nss-rs) needs a real built NSS+NSPR tree; the Dockerfile already
# built one from source and baked it at /opt/nss-build, and exports NSS_DIR +
# NSS_PREBUILT=1 so nss-rs's build.rs just LINKS against it — no hg clone, no
# rebuild, fully air-gapped (SPEC §6.5).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI/here, online) populates the cargo registry under
#     $CARGO_HOME (/opt/toolchains/rust/cargo, pinned by the Dockerfile ENV).
#   - The PATCH re-run resolves crates from that cache; the rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run, so we do NOT hard-code `--offline`
#     here (that would break THIS first, online build).
#   - NSS/NSPR need zero network at re-run time: NSS_PREBUILT=1 short-circuits
#     nss-rs's build.rs before it ever considers cloning/building anything.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# NOTE (parity with the C/C++ path): the base image exports $SANITIZER_FLAGS
# (ASan+UBSan, halting) as the default fuzz-instrumentation knob, but cargo-fuzz
# drives Rust instrumentation via RUSTFLAGS `-Zsanitizer=address` instead —
# $SANITIZER_FLAGS is a set of clang flags rustc doesn't understand, so it is
# intentionally NOT threaded into the Rust compile below.
#
# RUST_DEBUG_FLAGS threads DWARF < 4 symbols: debuginfo=2 (compact) + -Z
# dwarf-version=3 for neqo's OWN compilation units, and -Clinker=<cc-wrapper>
# prepends a DWARF3 anchor object as the FIRST object on every link so verify-repo's
# `readelf -m1` (which reads the FIRST .debug_info CU) sees DWARF v3 — even though
# the precompiled Rust ASan runtime archive (librustc-nightly_rt.asan.a) further
# into the binary remains DWARF v5. See the Dockerfile's DWARF<4 block.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

# Replicates OSS-Fuzz's FUZZING_LANGUAGE=rust RUSTFLAGS for a libFuzzer+ASan
# build. `--cfg fuzzing` gates neqo's fuzz_target! entry points (see any
# fuzz/fuzz_targets/*.rs: `#[cfg(all(fuzzing, not(windows)))]`); force-frame-pointers
# aids ASan backtraces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"
# FIXME (upstream, https://github.com/rust-fuzz/cargo-fuzz/issues/384): LTO breaks
# this build, same as OSS-Fuzz's own build.sh.
export CARGO_PROFILE_RELEASE_LTO=false

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "NSS_DIR=$NSS_DIR NSS_PREBUILT=${NSS_PREBUILT:-}"

cd "$SRC"

# fuzz/ is a member of the ROOT cargo workspace (see Cargo.toml `[workspace] members`),
# so cargo-fuzz writes every binary into $SRC/target/..., not $SRC/fuzz/target/...
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_TARGETS=()
for f in fuzz/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under fuzz/fuzz_targets/" >&2; exit 1; }
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (Dockerfile pins the required nightly); a
  # `+toolchain` override would make rustup try to install another channel into
  # the read-only shared /opt/toolchains/rust.
  cargo fuzz build -O --debug-assertions "$t"
  bin="$SRC/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "${FUZZ_TARGETS[@]/#//mayhem/}" 2>&1 || true
