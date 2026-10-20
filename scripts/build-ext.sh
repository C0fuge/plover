#!/bin/bash
# Builds hadoopfs.duckdb_extension for DuckDB $DUCKDB_VERSION (default v1.4.5) against the static deps in $PREFIX.
# DuckDB is linked statically into the extension (EXTENSION_STATIC_BUILD=1, like official Linux extensions); all
# static deps' symbols are kept private (-Wl,--exclude-libs,ALL). Output: $OUT_DIR/hadoopfs.duckdb_extension (+ .sha256)
source "$(dirname "$0")/common.sh"
DUCKDB_VERSION=${DUCKDB_VERSION:-v1.4.5}
OUT=${OUT_DIR:-$WORK/out}
case "$(uname -m)" in x86_64) PLATFORM=linux_amd64 ;; aarch64) PLATFORM=linux_arm64 ;; *) echo "unknown arch"; exit 1 ;; esac
mkdir -p "$WORK" "$OUT" && cd "$WORK"

log "duckdb $DUCKDB_VERSION"
git_at "$DUCKDB_REPO" "refs/tags/$DUCKDB_VERSION" duckdb-src
log "hadoopfs @ $HADOOPFS_COMMIT"
git_at "$HADOOPFS_REPO" "$HADOOPFS_COMMIT" ext-src
for p in "$HERE"/patches/hadoopfs/*.patch; do log "apply $(basename "$p")"; patch -d ext-src -p1 < "$p"; done
cat >> ext-src/CMakeLists.txt <<'CM'
# libhdfs3 is static, so its own static deps and the system libs are linked here too; their symbols stay private.
target_link_libraries(${LOADABLE_EXTENSION_NAME} ${HADOOPFS_EXTRA_LIBS})
target_link_options(${LOADABLE_EXTENSION_NAME} PRIVATE -Wl,--exclude-libs,ALL)
CM
echo "duckdb_extension_load(hadoopfs DONT_LINK EXTENSION_VERSION $HADOOPFS_EXT_VERSION INCLUDE_DIR $WORK/ext-src/src/include SOURCE_DIR $WORK/ext-src)" > ext_config.cmake

LAUNCHER=()
if command -v ccache >/dev/null; then
  LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache); ccache -z >/dev/null
fi
log "configure ($PLATFORM)"
cmake -G Ninja -S duckdb-src -B ext -DCMAKE_BUILD_TYPE=Release -DEXTENSION_STATIC_BUILD=1 "${LAUNCHER[@]}" \
  -DDUCKDB_EXTENSION_CONFIGS=$WORK/ext_config.cmake -DDUCKDB_EXPLICIT_PLATFORM=$PLATFORM -DOVERRIDE_GIT_DESCRIBE=$DUCKDB_VERSION \
  -DBUILD_SHELL=FALSE -DBUILD_UNITTESTS=FALSE -DENABLE_UNITTEST_CPP_TESTS=FALSE -DCMAKE_MODULE_PATH=$WORK/ext-src/CMake \
  -DLIBHDFS3_INCLUDE_DIR=$PREFIX/include -DLIBHDFS3_LIBRARIES=$PREFIX/lib/libhdfs3.a \
  "-DHADOOPFS_EXTRA_LIBS=$PREFIX/lib/libprotobuf.a;$PREFIX/lib/libgsasl.a;xml2;gssapi_krb5;krb5;k5crypto;com_err;uuid;ssl;crypto;pthread" $POL >/dev/null
log "build"
ninja -C ext -j$J hadoopfs_loadable_extension
command -v ccache >/dev/null && ccache -s | head -20 || true
f=$(find ext -name 'hadoopfs.duckdb_extension' | head -1)
cp "$f" "$OUT/"
(cd "$OUT" && sha256sum hadoopfs.duckdb_extension > hadoopfs.duckdb_extension.sha256)
# footer: last 512 bytes carry duckdb version / platform / extension version
log "result"; ls -la "$OUT"; cat "$OUT/hadoopfs.duckdb_extension.sha256"
tail -c 512 "$OUT/hadoopfs.duckdb_extension" | strings | head -8
ldd "$OUT/hadoopfs.duckdb_extension" || true
