#!/bin/bash
# Inside almalinux:8 with host network (see hdfs-sasl-test.yml): reads a multi-block file from the Kerberized HDFS
# with dfs.data.transfer.protection=privacy through the extension (libhdfs3 patches 0003/0004); short-circuit off.
set -euo pipefail
dnf install -y -q libxml2 krb5-libs krb5-workstation libuuid openssl-libs >/dev/null
D=$PWD/duckdb; EXT=$PWD/ext/hadoopfs.duckdb_extension
(cd ext && sha256sum -c hadoopfs.duckdb_extension.sha256)
export KRB5_CONFIG=$PWD/tests/hdfs-sasl/krb5.conf
export KRB5CCNAME=FILE:/tmp/client.ccache
kinit -kt krb/client.keytab client@EXAMPLE.TEST && klist
conf() { # conf <file> <protection or ''>
  { echo '<configuration>'
    echo '<property><name>hadoop.security.authentication</name><value>kerberos</value></property>'
    echo '<property><name>dfs.client.read.shortcircuit</name><value>false</value></property>'
    [ -n "$2" ] && echo "<property><name>dfs.data.transfer.protection</name><value>$2</value></property>"
    echo '</configuration>'; } > "$1"
}
conf /tmp/privacy.xml privacy
conf /tmp/plain.xml ''
Q="SELECT count(*), sum(id), sum(v), count(DISTINCT s) FROM read_parquet('hdfs://localhost:8020/t/big.parquet')"
want=$($D -csv -noheader -c "${Q/hdfs:\/\/localhost:8020\/t/data};")
echo "local:   $want"
for ttl in 0 600000; do
  got=$(LIBHDFS3_CONF=/tmp/privacy.xml $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = $ttl; $Q;")
  echo "privacy (ttl $ttl): $got"
  [ "$got" = "$want" ] || { echo "FAIL: result differs"; exit 1; }
done
# point reads across blocks (seek + short reads on the wrapped stream)
for k in 1 123457 299999; do
  got=$(LIBHDFS3_CONF=/tmp/privacy.xml $D -unsigned -csv -noheader -c "LOAD '$EXT';
    SELECT id, v, s FROM read_parquet('hdfs://localhost:8020/t/big.parquet') WHERE id = $k;")
  [ "$got" = "$($D -csv -noheader -c "SELECT id, v, s FROM read_parquet('data/big.parquet') WHERE id = $k;")" ] || { echo "FAIL: id $k"; exit 1; }
done
echo "point reads OK"
# without the client setting the DataNode must refuse the plain read (proves SASL was in effect)
if LIBHDFS3_CONF=/tmp/plain.xml timeout 120 $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_read_timeout_ms = 5000; $Q;" > /tmp/plain.out 2>&1; then
  cat /tmp/plain.out; echo "FAIL: plain read succeeded against a privacy DataNode"; exit 1
fi
echo "plain read refused: $(head -c 300 /tmp/plain.out)"
echo "hdfs sasl test OK"
