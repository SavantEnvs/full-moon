#!/usr/bin/env bash
#
# mayhem/build.sh — build full-moon's libFuzzer fuzz target as a sanitized binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then build the project's
# test suite for mayhem/test.sh to RUN.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache (CARGO_NET_OFFLINE=true is
#     exported by the runtime), so we do NOT hard-code `--offline` here.
#
# full-moon ships its own in-workspace fuzz/ crate (full-moon/fuzz/, target
# "roundtrip"). Rather than reuse that in-workspace crate (which would pull it into
# the root workspace resolution and risk touching upstream), we ship an ADDITIVE
# mayhem/fuzz/ crate exposing the SAME "roundtrip" target against the unmodified
# full_moon library. Upstream files are untouched; this crate only CALLS full_moon.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS
# is non-empty we instrument the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build. We
# referenced $SANITIZER_FLAGS so the fuzzed code is sanitized by default.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so we pin -Zdwarf-version=3
# for Rust code. The libfuzzer-sys cc shim is compiled by clang (DWARF-5 default), so we
# pin its DWARF too via CFLAGS/CXXFLAGS. $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land
# DWARF-5 compile units in the final binary (its first CU) and fail the DWARF < 4
# gate. Strip the debug info from that runtime archive (a toolchain artifact, NOT
# project code). Idempotent: re-running --strip-debug on an already-stripped archive
# is a no-op, so the offline PATCH re-run stays clean.
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

# Our additive fuzz crate (upstream fuzz/ left untouched).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# Dep-resolution pin for the FUZZ crate (build artifact only — NEVER touches upstream source).
# full_moon depends on smol_str ^0.3.1; cargo resolves the newest compatible (0.3.6), but smol_str
# >= 0.3.4 uses `from_buf_and_chars([0; _], …)` — the `[0; _]` array-length inference
# (generic_arg_infer). That feature is STILL UNSTABLE on the image's pinned nightly-2025-05-14
# (rustc 1.89.0-nightly built 2025-05-13, which predates the stabilization merge), so smol_str >= 0.3.4
# FAILS with E0658 "using `_` for array lengths is unstable". 0.3.2 is the newest non-yanked release
# that does NOT use it. cargo-fuzz resolves mayhem/fuzz/ as its OWN standalone workspace with its OWN
# lockfile, so pin smol_str back to 0.3.2 THERE (half is not pulled here — it comes only from
# full_moon's DEV-deps, which a normal `full_moon` dependency does not build).
#
# Idempotent + air-gapped (same contract as the root pin below): the FIRST (online) build resolves +
# writes mayhem/fuzz/Cargo.lock with smol_str pinned, populating the registry index + crate cache under
# $CARGO_HOME; the offline PATCH re-run finds the lock ALREADY pinning 0.3.2 and SKIPS the resolve
# (generate-lockfile / cargo update hit the network index, absent under --network none).
FUZZ_MANIFEST="$FUZZ_DIR/Cargo.toml"
FUZZ_LOCK="$FUZZ_DIR/Cargo.lock"
smol_pinned() { [ -f "$1" ] && awk '/^name = "smol_str"$/{h=1;next} h&&/^version = /{print;exit}' "$1" | grep -q '"0\.3\.2"'; }
if smol_pinned "$FUZZ_LOCK"; then
  echo "=== smol_str already pinned to 0.3.2 in the fuzz lockfile — skipping resolve (offline-safe) ==="
else
  echo "=== pinning smol_str to 0.3.2 in the fuzz lockfile (compat with pinned nightly) ==="
  env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo generate-lockfile --manifest-path "$FUZZ_MANIFEST"
  grep -q 'name = "smol_str"' "$FUZZ_LOCK" && env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update --manifest-path "$FUZZ_MANIFEST" -p smol_str --precise 0.3.2
fi

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the project test suite with NORMAL flags (clean, non-sanitized) so
# mayhem/test.sh only RUNS it. RUSTFLAGS/CFLAGS are cleared for this build.
#
# Dep-resolution pins (build artifacts only — NEVER touch upstream source): the repo ships no root
# Cargo.lock at this pinned commit, so cargo resolves the newest compatible deps. Two of those break on
# the image's pinned nightly-2025-05-14 and must be pinned back in the GENERATED lockfile:
#   - smol_str: full_moon (the LIBRARY, built by the test suite) depends on ^0.3.1; smol_str >= 0.3.4
#     uses the `[0; _]` array-length inference (generic_arg_infer), still unstable on this nightly
#     snapshot => E0658. Pin to 0.3.2, the newest non-yanked release without it (same reason as the
#     fuzz-crate pin above; the root workspace resolves its own separate lockfile).
#   - half: dev-dep criterion -> ciborium -> ciborium-ll -> half >= 2.5, which in turn pulls
#     zerocopy >= 0.8.26 for its SIMD path; that zerocopy uses the still-unstable `stdarch_x86_avx512`
#     feature and FAILS to compile on this nightly. Older `half` (< 2.5) has NO zerocopy dependency, so
#     pinning `half` back to 2.4.1 removes zerocopy entirely and the suite builds.
#
# Idempotent + air-gapped: the FIRST (online) build resolves + writes Cargo.lock with both pins,
# populating the registry INDEX + crate cache under $CARGO_HOME. The offline PATCH re-run then finds
# Cargo.lock ALREADY pinning both and SKIPS the resolve step entirely (generate-lockfile / cargo update
# hit the network index, which is absent under --network none) — so the re-run never needs the net.
pins_ok() {
  [ -f Cargo.lock ] \
    && awk '/^name = "half"$/{h=1;next}     h&&/^version = /{print;exit}' Cargo.lock | grep -q '"2\.4\.1"' \
    && awk '/^name = "smol_str"$/{h=1;next} h&&/^version = /{print;exit}' Cargo.lock | grep -q '"0\.3\.2"'
}
if pins_ok; then
  echo "=== half 2.4.1 + smol_str 0.3.2 already pinned in Cargo.lock — skipping resolve (offline-safe) ==="
else
  echo "=== pinning half=2.4.1 + smol_str=0.3.2 in the generated lockfile (compat with pinned nightly) ==="
  env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo generate-lockfile
  grep -q 'name = "half"'     Cargo.lock && env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update -p half     --precise 2.4.1
  grep -q 'name = "smol_str"' Cargo.lock && env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update -p smol_str --precise 0.3.2
fi

echo "=== building full-moon test suite (cargo test --no-run) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo test --no-run
echo "build.sh complete"
