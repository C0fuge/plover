#!/bin/bash
# Inside almalinux:8 with host network, after run.sh (see hdfs-sasl-test.yml, DATANODES >= 3): DataNode failover under
# dfs.data.transfer.protection=privacy with the metadata cache on, all in ONE DuckDB process (cached block locations,
# pooled SaslSocket connections):
#   1. full scan of /t/fo.parquet (primes the cache and the connection pool), checks that >= 2 DataNodes served blocks
#   2. kill the DataNode that served the most blocks, scan again (cached locations still list it) -> same result
#   3. restart it, wait until it is live, start a scan and kill another DataNode in the middle of it -> same result
# DataNodes are killed/started by the host (the workflow's watcher): we write "kill dnI" / "start dnI" to ctl/req and
# wait for ctl/ack.
set -euo pipefail
D=$PWD/duckdb; EXT=$PWD/ext/hadoopfs.duckdb_extension
N=${DATANODES:-3}
export KRB5_CONFIG=$PWD/tests/hdfs-sasl/krb5.conf
export KRB5CCNAME=FILE:/tmp/client.ccache
kinit -kt krb/client.keytab client@EXAMPLE.TEST
F=hdfs://localhost:8020/t/fo.parquet
Q="SELECT count(*), sum(id), sum(v), count(DISTINCT s) FROM read_parquet('$F')"
want=$($D -csv -noheader -c "${Q/hdfs:\/\/localhost:8020\/t/data};")
size=$(stat -c %s data/fo.parquet)
echo "local: $want ($size bytes)"

host() { # host <kill|start> <dnI>: ask the workflow's watcher, wait for the ack
  rm -f ctl/ack; echo "$1 $2" > ctl/req.tmp; mv ctl/req.tmp ctl/req
  for _ in $(seq 1 300); do [ -f ctl/ack ] && { rm -f ctl/ack; return 0; }; sleep 0.1; done
  echo "FAIL: no ack for $1 $2"; exit 1
}
blocks_read() { # blocks_read <i>: DataNodeActivity BlocksRead of DataNode i (0 when down)
  curl -sf "http://localhost:$((9864 + 10 * ($1 - 1)))/jmx?qry=Hadoop:service=DataNode,name=DataNodeActivity*" |
    /usr/libexec/platform-python -c 'import json,sys; print(sum(b.get("BlocksRead", 0) for b in json.load(sys.stdin)["beans"]))' 2>/dev/null || echo 0
}
live() {
  curl -sf "http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState" |
    grep -o '"NumLiveDataNodes" : [0-9]*' | grep -o '[0-9]*$'
}

# one DuckDB process fed through a FIFO; each step COPYs its result to /tmp/r<k>.csv, then writes a sentinel
rm -f /tmp/r*.csv /tmp/done* /tmp/fo.in; mkfifo /tmp/fo.in
LIBHDFS3_CONF=/tmp/privacy.xml $D -unsigned < /tmp/fo.in > /tmp/fo.out 2> /tmp/fo.err &
DPID=$!
exec 3> /tmp/fo.in
echo "LOAD '$EXT'; SET hdfs_metadata_cache_ttl_ms = 600000; SET hdfs_read_timeout_ms = 5000; SET hdfs_connect_timeout_ms = 3000;" >&3
step=0
send() { # send: start the scan as step k (async)
  step=$((step + 1)); t0=$(date +%s.%N)
  echo "COPY ($Q) TO '/tmp/r$step.csv' (HEADER false); COPY (SELECT 1) TO '/tmp/done$step';" >&3
}
wait_step() { # wait_step: wait for the sentinel, check the result
  for _ in $(seq 1 1800); do [ -f /tmp/done$step ] && break; kill -0 $DPID 2>/dev/null || break; sleep 0.1; done
  [ -f /tmp/done$step ] || { echo "FAIL: step $step did not finish"; cat /tmp/fo.err; exit 1; }
  local got; got=$(cat /tmp/r$step.csv 2>/dev/null || true)
  secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')
  echo "step $step: $got in ${secs}s ($(awk -v s="$size" -v t="$secs" 'BEGIN { printf "%.1f", s / 1048576 / t }') MB/s)"
  [ "$got" = "$want" ] || { echo "FAIL: step $step result differs"; cat /tmp/fo.err; exit 1; }
}
before=(); for i in $(seq 1 "$N"); do before[$i]=$(blocks_read $i); done

# 1. prime
send; wait_step; t_full=$secs
best=1; served=0
for i in $(seq 1 "$N"); do
  d=$(( $(blocks_read $i) - before[i] )); echo "dn$i served $d blocks"
  [ $d -gt 0 ] && served=$((served + 1))
  [ $d -gt $(( $(blocks_read $best) - before[best] )) ] && best=$i
done
[ $served -ge 2 ] || { echo "FAIL: only $served DataNode(s) served blocks"
  curl -s "http://localhost:9864/jmx?qry=Hadoop:service=DataNode,name=DataNodeActivity*" | head -c 1500; exit 1; }

# 2. kill the busiest DataNode between scans (cached locations, pooled connections to it)
host kill dn$best; echo "killed dn$best"
send; wait_step

# 3. restart it, then kill another DataNode mid-scan
host start dn$best
# the NameNode still lists the killed node as live (dead only after 10 min): wait for its own JMX, then registration
for _ in $(seq 1 90); do curl -sf -o /dev/null "http://localhost:$((9864 + 10 * (best - 1)))/jmx?qry=java.lang:type=Runtime" && break; sleep 1; done
sleep 10; echo "dn$best back, live $(live)"
other=$(( best % N + 1 ))
send; sleep "$(awk -v t="$t_full" 'BEGIN { printf "%.2f", t / 3 }')"
host kill dn$other
[ -f /tmp/done$step ] && { echo "FAIL: scan finished before the kill (${t_full}s scan too short)"; exit 1; }
echo "killed dn$other mid-scan"
wait_step

echo ".quit" >&3; exec 3>&-; wait $DPID || true
grep -iE "error|exception" /tmp/fo.err | head -20 || true
echo "failover test OK"
