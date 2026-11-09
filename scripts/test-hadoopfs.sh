#!/bin/bash
# Unit tests of our hadoopfs patches (no HDFS, no DuckDB build): fetches the extension at the pinned commit, applies
# patches/hadoopfs and builds tests/hadoopfs/*_test.cpp (header-only parts) with ThreadSanitizer. CI runs it every build.
source "$(dirname "$0")/common.sh"
T=$WORK/hadoopfs-test; mkdir -p "$T" && cd "$T"
git_at "$HADOOPFS_REPO" "$HADOOPFS_COMMIT" src
for p in "$HERE"/patches/hadoopfs/*.patch; do patch -s -d src -p1 < "$p"; done
CXX=${CXX:-g++}
log "metadata_cache_test"
build() { $CXX -std=c++11 -O1 -g -Wall -pthread "$@" -I src/src/include "$HERE/tests/hadoopfs/metadata_cache_test.cpp" -o metadata_cache_test; }
build -fsanitize=thread 2>/dev/null || { log "no libtsan, plain build"; build; }
./metadata_cache_test
