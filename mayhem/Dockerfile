# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# If mayhem/build.sh needs EXTRA apt packages, install them as root before the build
# (re-pin to SOURCE_DATE_EPOCH first for reproducibility — repro-sources-list.sh ships
# in the base):
#   USER root
#   RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
#       apt-get update && apt-get install -yq --no-install-recommends <pkgs> \
#    && rm -rf /var/lib/apt/lists/*
#   USER mayhem

# Seastar (redpanda's fork) and its system dependencies, plus the pinned third-party sources the
# harnesses link against. Upstream builds with Bazel + a hermetic LLVM/libc++; this layer instead builds
# the exact pinned deps (same versions/shas as MODULE.bazel and bazel/repositories.bzl) with the base's
# clang + libstdc++. The tarballs are baked in here so mayhem/build.sh runs air-gapped.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libboost-dev libboost-test-dev libboost-program-options-dev libboost-thread-dev \
      libboost-filesystem-dev libyaml-cpp-dev libc-ares-dev liblz4-dev libhwloc-dev libnuma-dev \
      libgnutls28-dev libsctp-dev libxml2-dev libprotobuf-dev protobuf-compiler ragel \
      libcrypto++-dev libzstd-dev libsnappy-dev libre2-dev liburing-dev liblttng-ust-dev \
      xfslibs-dev libunistring-dev libidn2-dev libp11-kit-dev libtasn1-6-dev nettle-dev libgmp-dev \
      libxxhash-dev libudev-dev rapidjson-dev python3-jinja2 libgtest-dev valgrind \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; d=/opt/toolchains/redpanda/src; mkdir -p "$d"; cd "$d"; \
    fetch() { curl -fsSL --retry 5 -o "$1.tar.gz" "$3"; echo "$2  $1.tar.gz" | sha256sum -c -; }; \
    fetch fmt ea7de4299689e12b6dddd392f9896f08fb0777ac7168897a244a6d6085043fea \
      https://github.com/fmtlib/fmt/archive/refs/tags/12.1.0.tar.gz; \
    fetch abseil 1692f77d1739bacf3f94337188b78583cf09bab7e420d2dc6c5605a4f86785a1 \
      https://github.com/abseil/abseil-cpp/archive/refs/tags/20250814.1.tar.gz; \
    fetch crc32c 49de137bf1c2eb6268d5122674f7dd1524b9148ba65c7b85c5ae4b9be104a25a \
      https://github.com/google/crc32c/archive/refs/tags/1.1.0.tar.gz; \
    fetch unordered_dense 8393d08b2a41949c70345926515036df55643e80118b608bcec6f4202d4a3026 \
      https://github.com/martinus/unordered_dense/archive/f30ed41b58af8c79788e8581fe57a6faf856258e.tar.gz; \
    fetch seastar 5918f72ec59c159a8d2fe36870e7d30c6e61426fde766d7dd6853fa7f9871f7f \
      https://github.com/redpanda-data/seastar/archive/a6ac2ff6190a4a9dce5059991355703e1073d11f.tar.gz; \
    chown -R mayhem:mayhem /opt/toolchains/redpanda
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
