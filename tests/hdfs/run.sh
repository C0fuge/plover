#!/bin/bash
# Inside almalinux:8 with host network (see hdfs-test.yml). Needs ext/hadoopfs.duckdb_extension and HDFS on localhost.
set -euo pipefail
dnf install -y -q libxml2 krb5-libs libuuid openssl-libs python3 >/dev/null
D=$PWD/duckdb  # CLI downloaded by the workflow
EXT=$PWD/ext/hadoopfs.duckdb_extension
(cd ext && sha256sum -c hadoopfs.duckdb_extension.sha256)
URL=hdfs://localhost:8020/t
JMX='http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=NameNodeActivity'
N=${N:-20}
n_files=$(ls data/*.parquet | wc -l)

rpcs() { curl -sSf "$JMX" | python3 -c 'import json,sys; b=json.load(sys.stdin)["beans"][0]; print(b["FileInfoOps"], b["GetBlockLocations"], b["GetListingOps"])'; }
# phase <ttl_ms>: one DuckDB process, N point queries; prints the RPC deltas
phase() {
  local ttl=$1 sql=/tmp/q_$1.sql
  { echo "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = $ttl;"
    for k in $(seq 1 "$N"); do echo "SELECT id, v, s FROM read_parquet('$URL/*.parquet') WHERE id = $((k * 37813 % 800000));"; done
  } > $sql
  read -r fi0 bl0 li0 < <(rpcs)
  $D -unsigned -csv -noheader < $sql > /tmp/out_$ttl.csv
  read -r fi1 bl1 li1 < <(rpcs)
  echo "ttl=$ttl: $N point queries over $n_files files: getfileinfo $((fi1 - fi0)), getBlockLocations $((bl1 - bl0)), listing $((li1 - li0))"
  echo "$((fi1 - fi0 + bl1 - bl0))" > /tmp/total_$ttl
}
phase 0
phase 600000
diff /tmp/out_0.csv /tmp/out_600000.csv && echo "results identical ($(wc -l < /tmp/out_0.csv) rows)"
[ "$(wc -l < /tmp/out_0.csv)" = "$N" ]
off=$(cat /tmp/total_0); on=$(cat /tmp/total_600000)
echo "NameNode getfileinfo+getBlockLocations per query: off $((off / N)), on $((on / N)) (total $off -> $on)"
[ "$on" -le $(( n_files * 2 + 2 )) ] || { echo "FAIL: cache on still costs $on calls"; exit 1; }

# full scan identical, cache on and off
for ttl in 0 600000; do
  $D -unsigned -csv -noheader -c "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = $ttl;
    SELECT count(*), sum(id), sum(v), count(DISTINCT s) FROM read_parquet('$URL/*.parquet');"
done | tee /tmp/full.csv
[ "$(sort -u /tmp/full.csv | wc -l)" = 1 ] && grep -q '^800000,319999600000,' /tmp/full.csv

# mtime: a file written minutes ago, not January 1970
$D -unsigned -csv -noheader -c "LOAD '$EXT';
  SELECT last_modified, last_modified > now() - INTERVAL 1 DAY AND last_modified < now() + INTERVAL 1 HOUR
  FROM read_blob('$URL/f0.parquet');" | tee /tmp/mtime.csv
grep -q ',true$' /tmp/mtime.csv
echo "hdfs test OK"
