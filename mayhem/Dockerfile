# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — neqo (Mozilla's QUIC/HTTP-3 implementation, Rust,
# cargo-fuzz). Builds ON TOP of the org C/C++ base (ghcr.io/mayhemheroes/base),
# adding:
#   1. a pinned Rust nightly + cargo-fuzz under /opt/toolchains/rust (needed for
#      `-Zsanitizer=address`, the OSS-Fuzz Rust ASan path);
#   2. a from-source NSS + NSPR build under /opt/nss-build — neqo's crypto layer
#      is the `nss` crate (nss-rs, a bindgen wrapper), which itself needs a real
#      built NSS/NSPR tree (Debian's libnss3-dev in this base is 3.110; nss-rs
#      requires >=3.121, so the system package can't satisfy it). We build NSS
#      ONCE here (online, at image-build time) and bake it in; mayhem/build.sh
#      then points nss-rs at the PREBUILT tree via NSS_DIR+NSS_PREBUILT=1 so the
#      air-gapped re-run (SPEC §6.5) never needs to touch the network or rebuild
#      NSS — nss-rs's build.rs only links against what's already on disk.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t neqo-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix (SPEC §6.2/6.5) ──
# nightly is required for `-Zsanitizer=address`/`-Zdwarf-version`. Pin by date; pin cargo-fuzz.
ARG RUST_TOOLCHAIN=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"; \
    rustup component add rust-src --toolchain "${RUST_TOOLCHAIN}"; \
    cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked; \
    rm -f /tmp/rustup-init.sh; \
    # `mayhem` (2000) runs both this build AND the air-gapped PATCH re-run; it must
    # read the toolchain and read/refresh the cargo registry cache under CARGO_HOME.
    chown -R 2000:2000 /opt/toolchains/rust; \
    chmod -R a+rX /opt/toolchains/rust; \
    chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git" 2>/dev/null || true; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    rustc --version; cargo --version; cargo fuzz --version

# DWARF<4 gate workaround for Rust/cargo-fuzz (§6.2 item 10). cargo-fuzz links the
# Rust nightly ASan runtime archive (librustc-nightly_rt.asan.a) via --whole-archive,
# and that archive's DWARF5 CUs land FIRST in .debug_info. `-Zdwarf-version=3` only
# controls rustc's own CUs, not the precompiled runtime. Fix: compile a tiny DWARF3
# anchor object and inject it as the FIRST object on every link via a cc-wrapper
# (-Clinker=...), so its DWARF3 CU sits at .debug_info offset 0 — what verify-repo's
# `readelf -m1` reads.
RUN set -eux; \
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/mayhem-dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c \
      -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/mayhem-dwarf3-anchor /opt/mayhem-dwarf3-anchor/anchor.o \
               /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/mayhem-dwarf3-anchor/anchor.o | grep -m1 Version:)"

# ── NSS + NSPR, built from source, baked in (online, THIS docker build only) ────
# neqo's `nss` (nss-rs) crate needs a real built NSS tree; the base's Debian NSS is
# too old (3.110 < nss-rs's required 3.121) so we build our own, pinned by commit,
# replicating OSS-Fuzz's projects/neqo Dockerfile (which uses `hg clone`) but via
# the GitHub git mirrors (pinnable by SHA, no mercurial network dependency needed
# for the clone itself — mercurial is still installed because NSS's own build
# tooling probes for `hg` at configure time).
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
        gyp ninja-build python-is-python3 zlib1g-dev mercurial \
        libclang-dev libc++-dev libc++abi-dev pkg-config; \
    apt-get autoremove -y; apt-get clean -y; rm -rf /var/lib/apt/lists/*

ARG NSS_COMMIT=7c0c73d30e9c140bc24e8faf545b6a77a1dd9d39
ARG NSPR_COMMIT=18ce36a4e1bd3db721b60dd7a2dea3d5e5c469b6
RUN set -eux; \
    install -d /opt/nss-build; \
    git clone https://github.com/nss-dev/nss.git /opt/nss-build/nss; \
    git -C /opt/nss-build/nss checkout --detach "${NSS_COMMIT}"; \
    git clone https://github.com/mozilla/nspr.git /opt/nss-build/nspr; \
    git -C /opt/nss-build/nspr checkout --detach "${NSPR_COMMIT}"; \
    cd /opt/nss-build/nss; \
    CC=clang CXX="clang++ -stdlib=libc++" bash build.sh --static \
        -Ddisable_tests=1 -Ddisable_dbm=1 -Ddisable_libpkix=1 -Ddisable_ckbi=1 -Ddisable_fips=1; \
    # neqo (nss-rs) hardcodes a "Release" dist dir; the un-optimized build above
    # (no --opt — an optimized build fails with assembler errors on this archive/
    # toolchain combo, same FIXME as upstream OSS-Fuzz's Dockerfile) lands in
    # dist/Debug, so alias it.
    ln -sfn Debug /opt/nss-build/dist/Release; \
    chown -R 2000:2000 /opt/nss-build; \
    chmod -R a+rX /opt/nss-build

# Baked, prebuilt NSS — build.sh sets NSS_PREBUILT so nss-rs's build.rs skips both
# the network `hg clone` fallback AND rebuilding NSS; it only links the tree above.
ENV NSS_DIR=/opt/nss-build/nss \
    NSS_PREBUILT=1

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds every sanitized fuzz target.
RUN bash mayhem/build.sh

# Run neqo's own assertion-based test suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
