#!/bin/bash
# Unit/interop test of libhdfs3 patch 0003 (DigestMd5Client, SASL DIGEST-MD5 with auth-conf): RFC 2831 known
# answer, then handshake + wrap/unwrap both ways against the JDK's DIGEST-MD5 server (the code an HDFS DataNode
# runs for dfs.data.transfer.protection) for every QOP and cipher. Needs g++, OpenSSL headers, java >= 11.
source "$(dirname "$0")/common.sh"
T=$WORK/sasl-test; mkdir -p "$T" && cd "$T"
git_at "$LIBHDFS3_REPO" "$LIBHDFS3_COMMIT" src
for p in "$HERE"/patches/libhdfs3/*.patch; do [ -f "$p" ] && patch -s -d src -p1 < "$p"; done
CXX=${CXX:-g++}
log "build digestmd5_test"
$CXX -std=c++11 -O1 -g -Wall -Wextra -fsanitize=address,undefined -I src/src/rpc "$HERE/tests/libhdfs3/digestmd5_test.cpp" \
  src/src/rpc/DigestMd5Client.cpp -lcrypto -o digestmd5_test
./digestmd5_test kat
java -version 2>&1 | head -1
U='AAEAAAGQbG9ja3Rva2VuLWlk/w=='; P='c2VjcmV0LWJsb2NrLXRva2VuLXBhc3N3b3Jk'   # base64 like a block token
# run_case <server qops> <client qops> <client ciphers> <want qop> <want cipher> [password the client uses]
run_case() {
  rm -f port; java "$HERE/tests/libhdfs3/DigestServer.java" port "$1" "$U" "$P" > server.log 2>&1 & local spid=$!
  for i in $(seq 100); do [ -s port ] && break; sleep 0.2; done
  [ -s port ] || { cat server.log; echo "server did not start"; return 1; }
  local crc=0; ./digestmd5_test peer "$(cat port)" "$2" "$3" "$U" "${6:-$P}" "$4" "$5" > client.log 2>&1 || crc=$?
  local src=0; wait $spid || src=$?
  echo "--- server [$1] client [$2 / $3]: client rc $crc, server rc $src"; cat client.log server.log | sed 's/^/    /'
  [ $crc = 0 ] && [ $src = 0 ]
}
fail=0
run_case auth-conf auth-conf,auth-int,auth 3des,rc4,des,rc4-56,rc4-40 auth-conf 3des || fail=1
for c in rc4 des rc4-56 rc4-40; do run_case auth-conf auth-conf $c auth-conf $c || fail=1; done
run_case auth-conf,auth-int,auth auth-int,auth auth auth-int - || fail=1
run_case auth-conf,auth-int,auth auth auth auth - || fail=1
run_case auth-int,auth auth-conf,auth-int auth auth-int - || fail=1
# wrong password: both sides must fail
if run_case auth-conf auth-conf 3des auth-conf 3des d3JvbmctcGFzc3dvcmQ= >/dev/null 2>&1; then echo "wrong password accepted"; fail=1
else echo "--- wrong password rejected: OK"; fi
[ $fail = 0 ] && echo "sasl test OK" || { echo "sasl test FAILED"; exit 1; }
