#!/bin/bash
# Unit tests of our libhdfs3 patches (no HDFS needed): fetches libhdfs3 at the pinned commit, applies
# patches/libhdfs3, builds tests/libhdfs3/*_test.cpp against the patched sources and runs them.
# Cheap (shallow clone + a few small files), so CI runs it on every build, also on a deps cache hit.
source "$(dirname "$0")/common.sh"
T=$WORK/libhdfs3-test; mkdir -p "$T" && cd "$T"
git_at "$LIBHDFS3_REPO" "$LIBHDFS3_COMMIT" src
for p in "$HERE"/patches/libhdfs3/*.patch; do [ -f "$p" ] && patch -s -d src -p1 < "$p"; done
CXX=${CXX:-g++}
log "deadnodes_test"
$CXX -std=c++20 -O1 -g -Wall -pthread -I src/src/client "$HERE/tests/libhdfs3/deadnodes_test.cpp" src/src/client/DeadNodes.cpp -o deadnodes_test
./deadnodes_test
