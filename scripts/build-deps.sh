#!/bin/bash
# Static, PIC builds of protobuf 3.21.12, libgsasl 1.10.0 (MIT GSSAPI) and libhdfs3 (ClickHouse fork, Kerberos)
# into $PREFIX (/opt/deps). CI caches $PREFIX keyed on sources.env + this script + patches/libhdfs3.
source "$(dirname "$0")/common.sh"
mkdir -p "$WORK" && cd "$WORK"

log "protobuf"
fetch "$PROTOBUF_URL" "$PROTOBUF_SHA256" protobuf.tar.gz
rm -rf protobuf-src && mkdir protobuf-src && tar --no-same-owner -xzf protobuf.tar.gz -C protobuf-src --strip-components=1
cmake -G Ninja -S protobuf-src -B pb -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib $POL >/dev/null
ninja -C pb -j$J install >/dev/null

log "libgsasl"
fetch "$GSASL_URL" "$GSASL_SHA256" gsasl.tar.gz
rm -rf gsasl-src && mkdir gsasl-src && tar --no-same-owner -xzf gsasl.tar.gz -C gsasl-src --strip-components=1
(cd gsasl-src && ./configure -q --prefix=$PREFIX --enable-static --disable-shared --with-pic \
   --with-gssapi-impl=mit --without-stringprep --disable-nls >/dev/null && make -s -j$J install >/dev/null)

log "libhdfs3 @ $LIBHDFS3_COMMIT"
git_at "$LIBHDFS3_REPO" "$LIBHDFS3_COMMIT" libhdfs3-src
for p in "$HERE"/patches/libhdfs3/*.patch; do [ -f "$p" ] && { log "apply $(basename "$p")"; patch -d libhdfs3-src -p1 < "$p"; }; done
cmake -G Ninja -S libhdfs3-src -B hdfs3 -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DWITH_KERBEROS=ON -DProtobuf_INCLUDE_DIR=$PREFIX/include -DProtobuf_LIBRARY=$PREFIX/lib/libprotobuf.a \
  -DProtobuf_PROTOC_EXECUTABLE=$PREFIX/bin/protoc -DGSASL_INCLUDE_DIR=$PREFIX/include -DGSASL_LIBRARIES=$PREFIX/lib/libgsasl.a $POL >/dev/null
ninja -C hdfs3 -j$J libhdfs3-static
mkdir -p $PREFIX/include/hdfs && cp libhdfs3-src/src/client/hdfs.h $PREFIX/include/hdfs/
cp "$(find hdfs3 -name 'libhdfs3.a' | head -1)" $PREFIX/lib/libhdfs3.a
echo "libhdfs3 $LIBHDFS3_COMMIT" > $PREFIX/DEPS-VERSION
log "deps done"; ls -la $PREFIX/lib
