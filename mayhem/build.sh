#!/usr/bin/env bash
#
# mayhem/build.sh — build Redpanda's libFuzzer harnesses (radix_tree, iobuf, serde) and the
# reactor-free gtest unit tests that mayhem/test.sh runs.
#
# Upstream builds with Bazel and a hermetic LLVM + libc++ toolchain. This script instead compiles the
# few source files each harness needs straight with the base's clang (libstdc++), against the same pinned
# third-party versions (fmt, abseil, crc32c, unordered_dense, Redpanda's Seastar fork). The dependency
# sources are baked into the image by mayhem/Dockerfile (/opt/toolchains/redpanda/src), so this runs
# offline. Dependencies are built into /opt/toolchains/redpanda (outside the git tree, so a
# `git clean -ffdX` does not remove them) and stamped, which makes a re-run an incremental no-op for them.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

TC=/opt/toolchains/redpanda
V="$SRC/src/v"
KEY="$(printf '%s|%s|%s' "$SANITIZER_FLAGS" "$DEBUG_FLAGS" "deps-v1" | sha1sum | cut -c1-10)"
SAN_PREFIX="$TC/deps-san-$KEY"
PLAIN_PREFIX="$TC/deps-plain"

# build_deps <prefix> <cmake build type> <c/c++ flags>
build_deps() {
  local P="$1" BT="$2" FL="$3" W="$TC/work"
  [ -f "$P/.complete" ] && return 0
  rm -rf "$P" "$W"; mkdir -p "$P" "$W"
  local n
  for n in fmt abseil crc32c unordered_dense seastar; do
    mkdir -p "$W/$n" && tar -xzf "$TC/src/$n.tar.gz" -C "$W/$n" --strip-components=1
  done
  local cm=(cmake -GNinja -DCMAKE_BUILD_TYPE="$BT" -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_PREFIX_PATH="$P"
            -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON
            -DCMAKE_CXX_STANDARD=23)
  "${cm[@]}" -S "$W/unordered_dense" -B "$W/b-ud" >/dev/null
  cmake --build "$W/b-ud" -j"$MAYHEM_JOBS" >/dev/null && cmake --install "$W/b-ud" >/dev/null
  "${cm[@]}" -S "$W/crc32c" -B "$W/b-crc" -DCRC32C_BUILD_TESTS=OFF -DCRC32C_BUILD_BENCHMARKS=OFF \
    -DCRC32C_USE_GLOG=OFF -DCRC32C_INSTALL=ON -DCMAKE_CXX_FLAGS="$FL" -DCMAKE_C_FLAGS="$FL" >/dev/null
  cmake --build "$W/b-crc" -j"$MAYHEM_JOBS" >/dev/null && cmake --install "$W/b-crc" >/dev/null
  "${cm[@]}" -S "$W/fmt" -B "$W/b-fmt" -DFMT_TEST=OFF -DFMT_DOC=OFF -DCMAKE_CXX_FLAGS="$FL" >/dev/null
  cmake --build "$W/b-fmt" -j"$MAYHEM_JOBS" >/dev/null && cmake --install "$W/b-fmt" >/dev/null
  "${cm[@]}" -S "$W/abseil" -B "$W/b-absl" -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF \
    -DCMAKE_CXX_FLAGS="$FL" >/dev/null
  cmake --build "$W/b-absl" -j"$MAYHEM_JOBS" >/dev/null && cmake --install "$W/b-absl" >/dev/null
  "${cm[@]}" -S "$W/seastar" -B "$W/b-seastar" -DCMAKE_CXX_FLAGS="$FL" -DCMAKE_C_FLAGS="$FL" \
    -DSeastar_APPS=OFF -DSeastar_DEMOS=OFF -DSeastar_DOCS=OFF -DSeastar_TESTING=OFF -DSeastar_INSTALL=ON \
    -DSeastar_API_LEVEL=10 -DSeastar_SCHEDULING_GROUPS_COUNT=22 -DSeastar_STACK_GUARDS=ON \
    -DSeastar_CXX_DIALECT=23 -DSeastar_DPDK=OFF -DSeastar_HWLOC=ON -DSeastar_IO_URING=ON \
    -DSeastar_UNUSED_RESULT_ERROR=OFF >/dev/null
  cmake --build "$W/b-seastar" -j"$MAYHEM_JOBS" >/dev/null && cmake --install "$W/b-seastar" >/dev/null
  rm -rf "$W"
  touch "$P/.complete"
}

# --- 1) dependencies: sanitized (fuzz targets) and plain (unit tests) -----------------------------
build_deps "$SAN_PREFIX" Debug "$SANITIZER_FLAGS $DEBUG_FLAGS"
build_deps "$PLAIN_PREFIX" Release "-O2"

# gather <prefix> -> sets CF (compile flags) and LF (link flags) for sources under src/v
gather() {
  local P="$1"
  export PKG_CONFIG_PATH="$P/lib/pkgconfig"
  CF="$(pkg-config --cflags seastar) -I$V -I$SRC/src -I$P/include"
  LF="-Wl,--start-group $(ls "$P"/lib/libabsl_*.a | tr '\n' ' ') $P/lib/libcrc32c.a \
$(pkg-config --libs --static seastar-testing seastar) -Wl,--end-group"
}

OBJ="$SRC/mayhem/build/obj"
GEN="$TC/gen"
mkdir -p "$OBJ" "$OBJ-plain" "$GEN/serde/test"
python3 "$V/serde/test/struct_gen.py" "$GEN/serde/test/generated_structs.h"

# --- 2) fuzz harnesses: sanitized project sources + libFuzzer, and a standalone reproducer each ----
gather "$SAN_PREFIX"
SAN="$SANITIZER_FLAGS $DEBUG_FLAGS"
for f in base/vassert bytes/iobuf; do
  $CXX $SAN -fsanitize=fuzzer-no-link $CF -c "$V/$f.cc" -o "$OBJ/$(basename "$f").o"
done
$CXX $SAN -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SAN -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

# fuzz_target <name> <harness source> <extra objects...>
fuzz_target() {
  local name="$1" srcf="$2"; shift 2
  local objs=("$@" "$OBJ/vassert.o" "$OBJ/iobuf.o" "$OBJ/lsan_off.o")
  $CXX $SAN $CF -I"$GEN" "$srcf" "${objs[@]}" $LIB_FUZZING_ENGINE $LF -o "$SRC/$name"
  $CXX $SAN $CF -I"$GEN" "$srcf" "${objs[@]}" "$OBJ/standalone_main.o" $LF -o "$SRC/$name-standalone"
}
fuzz_target radix_tree_fuzz "$V/container/tests/radix_tree_fuzz.cc"
fuzz_target iobuf_fuzz "$V/bytes/tests/iobuf_fuzz.cc"
fuzz_target serde_fuzz "$V/serde/test/fuzz.cc"

# --- 3) unit tests: plain flags, plain dependencies ------------------------------------------------
gather "$PLAIN_PREFIX"
PO="$OBJ-plain"
for f in base/vassert bytes/iobuf random/generators security/acl; do
  $CXX -O1 $COVERAGE_FLAGS $CF -c "$V/$f.cc" -o "$PO/$(basename "$f").o"
done
mkdir -p "$SRC/rp_tests"
for t in container/tests/radix_tree_test container/tests/interval_set_test \
         container/tests/contiguous_range_map_test bytes/tests/iobuf_fragment_list_test \
         security/tests/acl_serde_test utils/tests/variant_test; do
  $CXX -O1 $COVERAGE_FLAGS $CF "$V/$t.cc" "$PO"/*.o $COVERAGE_FLAGS $LF -lgtest -lgtest_main -o "$SRC/rp_tests/$(basename "$t")"
done
