#!/bin/bash
# Inside almalinux:8 with host network (see hdfs-test.yml). Needs ext/hadoopfs.duckdb_extension and HDFS on localhost.
set -euo pipefail
dnf install -y -q libxml2 krb5-libs libuuid openssl-libs python3 diffutils >/dev/null
D=$PWD/duckdb  # CLI downloaded by the workflow
EXT=$PWD/ext/hadoopfs.duckdb_extension
(cd ext && sha256sum -c hadoopfs.duckdb_extension.sha256)
URL=hdfs://localhost:8020/t
JMX='http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=NameNodeActivity'
N=${N:-20}
n_files=$(ls data/*.parquet | wc -l)

# JMX values are cached for one metrics period (10 s): wait it out, or two reads 1 s apart show the same counters
rpcs() { sleep 11; curl -sSf "$JMX" | python3 -c 'import json,sys; b=json.load(sys.stdin)["beans"][0]; print(b["FileInfoOps"], b["GetBlockLocations"], b["GetListingOps"])'; }
# phase <ttl_ms> [n]: one DuckDB process, n (default N) point queries; prints the RPC deltas
phase() {
  local ttl=$1 n=${2:-$N} tag=$1_${2:-$N} sql=/tmp/q_$1_${2:-$N}.sql
  { echo "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = $ttl;"
    for k in $(seq 1 "$n"); do echo "SELECT id, v, s FROM read_parquet('$URL/*.parquet') WHERE id = $((k * 37813 % 800000));"; done
  } > $sql
  read -r fi0 bl0 li0 < <(rpcs)
  $D -unsigned -csv -noheader < $sql > /tmp/out_$tag.csv
  read -r fi1 bl1 li1 < <(rpcs)
  echo "ttl=$ttl: $n point queries over $n_files files: getfileinfo $((fi1 - fi0)), getBlockLocations $((bl1 - bl0)), listing $((li1 - li0))"
  echo "$((fi1 - fi0 + bl1 - bl0))" > /tmp/total_$tag
  echo "$((li1 - li0))" > /tmp/listing_$tag
}
phase 0
phase 600000
phase 600000 1  # the first query alone (fresh process = empty cache)
diff /tmp/out_0_$N.csv /tmp/out_600000_$N.csv && echo "results identical ($(wc -l < /tmp/out_0_$N.csv) rows)"
[ "$(wc -l < /tmp/out_0_$N.csv)" = "$N" ]
off=$(cat /tmp/total_0_$N); on=$(cat /tmp/total_600000_$N); first=$(cat /tmp/total_600000_1)
li_off=$(cat /tmp/listing_0_$N); li_on=$(cat /tmp/listing_600000_$N); li_first=$(cat /tmp/listing_600000_1)
echo "NameNode getfileinfo+getBlockLocations per query: off $((off / N)), on $((on / N)) (total $off -> $on; first query $first)"
echo "getListing: off $li_off, on $li_on (first query $li_first)"
[ "$off" -ge "$N" ] || { echo "FAIL: cache off counted only $off calls (metrics not read?)"; exit 1; }
[ "$li_off" -ge "$N" ] || { echo "FAIL: cache off counted only $li_off listings"; exit 1; }
[ "$on" -lt "$off" ] && [ "$on" -le $(( n_files * 2 + 2 )) ] || { echo "FAIL: cache on still costs $on calls"; exit 1; }
# listing cache (patch 0007): the queries after the first make no NameNode call at all
[ "$li_first" -ge 1 ] && [ "$((on + li_on))" = "$((first + li_first))" ] ||
  { echo "FAIL: cache on: $N queries cost $((on + li_on)) calls, the first alone $((first + li_first))"; exit 1; }
echo "cache on: 0 NameNode calls after the first query"

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
# hdfs_transfer_info() without SASL: every DataNode connection is plain (qop none), no INFO negotiation line
$D -unsigned -csv -noheader -c "LOAD '$EXT'; SELECT count(*) FROM read_parquet('$URL/f0.parquet');
  SELECT qop, coalesce(cipher, 'NULL'), encrypted, connections > 0, failures FROM hdfs_transfer_info();" 2>/tmp/info.err | tee /tmp/info.csv
[ "$(tail -n +2 /tmp/info.csv | sort -u)" = "none,NULL,false,true,0" ] || { echo "FAIL: hdfs_transfer_info() without SASL"; exit 1; }
! grep -q DataTransferSasl /tmp/info.err || { echo "FAIL: negotiation logged without SASL"; exit 1; }
echo "hdfs test OK"
