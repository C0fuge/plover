#!/bin/bash
# Inside almalinux:8 with host network (see hdfs-sasl-test.yml): reads a multi-block file from the Kerberized HDFS
# with dfs.data.transfer.protection=privacy through the extension (libhdfs3 patches 0003/0004); short-circuit off.
# With CIPHER_SUITES (default AES/CTR/NoPadding, as start.sh) also with the AES/CTR cipher option (libhdfs3 0005), and,
# when the failover file exists (3 DataNodes), a throughput comparison 3des vs AES on full scans.
# DN_PROTECTION (default privacy, as start.sh): the DataNodes' dfs.data.transfer.protection. When it offers several QOPs
# (e.g. "authentication,privacy") the client is also run with "authentication,privacy", "privacy,authentication" and
# "authentication" and must negotiate what Hadoop's client does: the first QOP of the CLIENT's list the DataNode offers.
set -euo pipefail
dnf install -y -q libxml2 krb5-libs krb5-workstation libuuid openssl-libs >/dev/null
D=$PWD/duckdb; EXT=$PWD/ext/hadoopfs.duckdb_extension
(cd ext && sha256sum -c hadoopfs.duckdb_extension.sha256)
export KRB5_CONFIG=$PWD/tests/hdfs-sasl/krb5.conf
export KRB5CCNAME=FILE:/tmp/client.ccache
kinit -kt krb/client.keytab client@EXAMPLE.TEST && klist
CIPHER=${CIPHER_SUITES-AES/CTR/NoPadding}
conf() { # conf <file> <protection or ''> [cipher suites]
  { echo '<configuration>'
    echo '<property><name>hadoop.security.authentication</name><value>kerberos</value></property>'
    echo '<property><name>dfs.client.read.shortcircuit</name><value>false</value></property>'
    [ -n "$2" ] && echo "<property><name>dfs.data.transfer.protection</name><value>$2</value></property>"
    [ -n "${3:-}" ] && echo "<property><name>dfs.encrypt.data.transfer.cipher.suites</name><value>$3</value></property>"
    echo '</configuration>'; } > "$1"
}
debug() { sed 's|</configuration>|<property><name>dfs.client.log.severity</name><value>DEBUG1</value></property></configuration>|' "$1" > "$2"; }
conf /tmp/privacy.xml privacy
conf /tmp/plain.xml ''
debug /tmp/privacy.xml /tmp/debug.xml
CONFS=/tmp/privacy.xml
if [ -n "$CIPHER" ]; then
  conf /tmp/aes.xml privacy "$CIPHER"; debug /tmp/aes.xml /tmp/debug-aes.xml; CONFS="$CONFS /tmp/aes.xml"
fi
DNP=${DN_PROTECTION:-privacy}
echo "DataNodes: dfs.data.transfer.protection=$DNP"
# check_qop <conf> <want qop>: every DataNode connection of a scan negotiated <want qop> (debug log)
check_qop() {
  debug "$1" /tmp/dbg-q.xml
  if ! HDFS_ENABLE_LOGGING=true LIBHDFS3_CONF=/tmp/dbg-q.xml $D -unsigned -csv -noheader -c "LOAD '$EXT';
       SELECT count(*) FROM read_parquet('hdfs://localhost:8020/t/big.parquet');" > /tmp/dbg-q.out 2>&1; then
    tail -c 6000 /tmp/dbg-q.out; echo "FAIL: read with $(basename "$1" .xml)"; exit 1
  fi
  local n bad
  n=$(grep -c "DataTransferSasl: DataNode .*: qop " /tmp/dbg-q.out || true)
  bad=$(grep "DataTransferSasl: DataNode .*: qop " /tmp/dbg-q.out | grep -v ": qop $2," | head -3 || true)
  [ "$n" -gt 0 ] && [ -z "$bad" ] || { echo "$bad"; echo "FAIL: $(basename "$1" .xml): want qop $2 on all $n connections"; exit 1; }
  echo "$(basename "$1" .xml): $n connections, qop $2: $(grep -m1 "DataTransferSasl: DataNode .*: qop " /tmp/dbg-q.out | sed 's/.*DataTransferSasl: //')"
}
if [[ ",$DNP," == *",authentication,"* ]]; then
  conf /tmp/authpriv.xml "authentication,privacy"; check_qop /tmp/authpriv.xml auth
  conf /tmp/privauth.xml "privacy,authentication"; check_qop /tmp/privauth.xml auth-conf
  conf /tmp/auth.xml authentication; check_qop /tmp/auth.xml auth
  CONFS="$CONFS /tmp/authpriv.xml /tmp/privauth.xml /tmp/auth.xml"
  if [ -n "$CIPHER" ]; then  # cipher option offered, but auth negotiated: the DataNode sends no keys, stream stays plain
    conf /tmp/authpriv-aes.xml "authentication,privacy" "$CIPHER"; check_qop /tmp/authpriv-aes.xml auth
    conf /tmp/privauth-aes.xml "privacy,authentication" "$CIPHER"; check_qop /tmp/privauth-aes.xml auth-conf
    grep -q "cipher option AES/CTR/NoPadding" /tmp/dbg-q.out || { echo "FAIL: privacy,authentication + AES: AES not negotiated"; exit 1; }
    CONFS="$CONFS /tmp/authpriv-aes.xml /tmp/privauth-aes.xml"
  fi
else
  # the DataNodes do not offer auth: an authentication-only client must be refused
  conf /tmp/auth.xml authentication
  if LIBHDFS3_CONF=/tmp/auth.xml timeout 120 $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_read_timeout_ms = 5000;
       SELECT count(*) FROM read_parquet('hdfs://localhost:8020/t/big.parquet');" > /tmp/auth.out 2>&1; then
    cat /tmp/auth.out; echo "FAIL: authentication-only client read from $DNP DataNodes"; exit 1
  fi
  echo "authentication-only client refused: $(head -c 300 /tmp/auth.out)"
  rm -f /tmp/auth.xml
fi
Q="SELECT count(*), sum(id), sum(v), count(DISTINCT s) FROM read_parquet('hdfs://localhost:8020/t/big.parquet')"
want=$($D -csv -noheader -c "${Q/hdfs:\/\/localhost:8020\/t/data};")
echo "local:   $want"
# first contact with libhdfs3 debug log + Kerberos trace, shown on failure
if ! HDFS_ENABLE_LOGGING=true LIBHDFS3_CONF=/tmp/debug.xml KRB5_TRACE=/tmp/krb5.trace $D -unsigned -csv -noheader -c "LOAD '$EXT';
     SELECT count(*) FROM read_parquet('hdfs://localhost:8020/t/big.parquet');" > /tmp/debug.out 2>&1; then
  tail -c 6000 /tmp/debug.out; echo "--- krb5 trace"; tail -c 4000 /tmp/krb5.trace || true; exit 1
fi
grep -m1 "DataTransferSasl: DataNode" /tmp/debug.out || { tail -c 6000 /tmp/debug.out; echo "FAIL: no SASL handshake logged"; exit 1; }
grep -q "DataTransferSasl: DataNode .*: qop auth-conf, cipher 3des" /tmp/debug.out || { echo "FAIL: privacy without the cipher option is not 3des"; exit 1; }
if [ -n "$CIPHER" ]; then
  if ! HDFS_ENABLE_LOGGING=true LIBHDFS3_CONF=/tmp/debug-aes.xml $D -unsigned -csv -noheader -c "LOAD '$EXT';
       SELECT count(*) FROM read_parquet('hdfs://localhost:8020/t/big.parquet');" > /tmp/debug-aes.out 2>&1; then
    tail -c 6000 /tmp/debug-aes.out; exit 1
  fi
  grep -m1 "cipher option AES/CTR/NoPadding" /tmp/debug-aes.out || { grep "DataTransferSasl" /tmp/debug-aes.out | head; echo "FAIL: AES/CTR not negotiated"; exit 1; }
  if grep "DataTransferSasl: DataNode .*: qop .*, cipher " /tmp/debug-aes.out | grep -v "cipher option AES" | head -3 | grep .; then
    echo "FAIL: a connection without AES although offered"; exit 1
  fi
fi
for c in $CONFS; do
  for ttl in 0 600000; do
    got=$(LIBHDFS3_CONF=$c $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = $ttl; $Q;")
    echo "$(basename $c .xml) (ttl $ttl): $got"
    [ "$got" = "$want" ] || { echo "FAIL: result differs"; exit 1; }
  done
  # point reads across blocks (seek + short reads on the wrapped / encrypted stream)
  for k in 1 123457 299999; do
    got=$(LIBHDFS3_CONF=$c $D -unsigned -csv -noheader -c "LOAD '$EXT';
      SELECT id, v, s FROM read_parquet('hdfs://localhost:8020/t/big.parquet') WHERE id = $k;")
    [ "$got" = "$($D -csv -noheader -c "SELECT id, v, s FROM read_parquet('data/big.parquet') WHERE id = $k;")" ] || { echo "FAIL: id $k ($c)"; exit 1; }
  done
  echo "$(basename $c .xml): point reads OK"
done
# without the client setting the DataNode must refuse the plain read (proves SASL was in effect)
if LIBHDFS3_CONF=/tmp/plain.xml timeout 120 $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_read_timeout_ms = 5000; $Q;" > /tmp/plain.out 2>&1; then
  cat /tmp/plain.out; echo "FAIL: plain read succeeded against a privacy DataNode"; exit 1
fi
echo "plain read refused: $(head -c 300 /tmp/plain.out)"
# throughput 3des vs AES: full scans of the failover file (3 DataNodes), alternating, each a fresh process
if [ -n "$CIPHER" ] && [ -f data/fo.parquet ]; then
  F=hdfs://localhost:8020/t/fo.parquet; size=$(stat -c %s data/fo.parquet)
  QF="SELECT count(*), sum(id), sum(v), count(DISTINCT s) FROM read_parquet('$F')"
  wantf=$($D -csv -noheader -c "${QF/hdfs:\/\/localhost:8020\/t/data};")
  # local baseline: the same scan from the local file (decode cost without HDFS)
  t0=$(date +%s.%N); $D -csv -noheader -c "${QF/hdfs:\/\/localhost:8020\/t/data};" >/dev/null; t1=$(date +%s.%N)
  echo "throughput local file: $(awk -v s=$size -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f s, %.1f MB/s", b-a, s/(b-a)/1e6}')"
  for round in 1 2 3; do
    for c in /tmp/privacy.xml /tmp/aes.xml $( [ -f /tmp/auth.xml ] && echo /tmp/auth.xml ); do
      t0=$(date +%s.%N)
      got=$(LIBHDFS3_CONF=$c $D -unsigned -csv -noheader -c "LOAD '$EXT'; $QF;")
      t1=$(date +%s.%N)
      [ "$got" = "$wantf" ] || { echo "FAIL: fo.parquet result differs ($c)"; exit 1; }
      echo "throughput round $round $(case $c in /tmp/aes.xml) echo AES;; /tmp/auth.xml) echo "auth (no wrap)";; *) echo 3des;; esac): $(awk -v s=$size -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f s, %.1f MB/s", b-a, s/(b-a)/1e6}') ($size bytes)"
    done
  done
fi
echo "hdfs sasl test OK"
