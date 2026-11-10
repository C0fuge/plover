#!/bin/bash
# Kerberized HDFS 3.4.1 with dfs.data.transfer.protection=privacy on non-privileged DataNode ports, block tokens on,
# short-circuit off, 1 MB blocks allowed. Host network; KDC from kdc.sh.
# DATANODES (default 1): containers dn1..dnN, DataNode i on xfer port 9866+10*(i-1) (http 9864+.., ipc 9867+..);
# replication min(2, N). RPC_PROTECTION (default authentication): hadoop.rpc.protection of the cluster.
set -euo pipefail
IMG=apache/hadoop:3.4.1
R=EXAMPLE.TEST
N=${DATANODES:-1}
RPC=${RPC_PROTECTION:-authentication}
REPL=$(( N < 2 ? N : 2 ))
docker pull -q almalinux:8 >/dev/null; docker pull -q $IMG >/dev/null
docker run -d --name kdc --network host -v "$PWD:/w" almalinux:8 bash /w/tests/hdfs-sasl/kdc.sh
for i in $(seq 1 90); do [ -f krb/ready ] && break; sleep 2; done
[ -f krb/ready ] || { docker logs kdc; echo "KDC not up"; exit 1; }
echo "KDC up"
CONF=(-e "CORE-SITE.XML_fs.defaultFS=hdfs://localhost:8020"
      -e "CORE-SITE.XML_hadoop.security.authentication=kerberos"
      -e "CORE-SITE.XML_hadoop.security.authorization=false"
      -e "CORE-SITE.XML_hadoop.rpc.protection=$RPC"
      -e "HDFS-SITE.XML_dfs.namenode.rpc-address=localhost:8020"
      -e "HDFS-SITE.XML_dfs.replication=$REPL"
      -e "HDFS-SITE.XML_dfs.permissions.enabled=false"
      -e "HDFS-SITE.XML_dfs.namenode.safemode.extension=0"
      -e "HDFS-SITE.XML_dfs.namenode.fs-limits.min-block-size=65536"
      -e "HDFS-SITE.XML_dfs.block.access.token.enable=true"
      -e "HDFS-SITE.XML_dfs.data.transfer.protection=privacy"
      -e "HDFS-SITE.XML_ignore.secure.ports.for.testing=true"
      -e "HDFS-SITE.XML_dfs.webhdfs.enabled=false"
      -e "HDFS-SITE.XML_dfs.namenode.kerberos.principal=nn/localhost@$R"
      -e "HDFS-SITE.XML_dfs.namenode.keytab.file=/w/krb/hdfs.keytab"
      -e "HDFS-SITE.XML_dfs.datanode.kerberos.principal=dn/localhost@$R"
      -e "HDFS-SITE.XML_dfs.datanode.keytab.file=/w/krb/hdfs.keytab"
      -e "HDFS-SITE.XML_dfs.web.authentication.kerberos.principal=HTTP/localhost@$R"
      -e "HDFS-SITE.XML_dfs.web.authentication.kerberos.keytab=/w/krb/hdfs.keytab"
      -e "HADOOP_OPTS=-Djava.security.krb5.conf=/w/tests/hdfs-sasl/krb5.conf -Dsun.security.krb5.disableReferrals=true")
docker run -d --name nn --network host -v "$PWD:/w" "${CONF[@]}" -e ENSURE_NAMENODE_DIR=/tmp/hadoop-hadoop/dfs/name $IMG hdfs namenode
for i in $(seq 1 "$N"); do
  b=$((9864 + 10 * (i - 1)))
  docker run -d --name dn$i --network host -v "$PWD:/w" "${CONF[@]}" \
    -e "HDFS-SITE.XML_dfs.datanode.http.address=0.0.0.0:$b" -e "HDFS-SITE.XML_dfs.datanode.address=0.0.0.0:$((b + 2))" \
    -e "HDFS-SITE.XML_dfs.datanode.ipc.address=0.0.0.0:$((b + 3))" $IMG hdfs datanode
done
FSN="http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState"
for i in $(seq 1 60); do
  live=$(curl -sf "$FSN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["beans"][0]["NumLiveDataNodes"])' 2>/dev/null || echo 0)
  if [ "$live" -ge "$N" ]; then echo "secure HDFS up ($N DataNodes, replication $REPL, rpc $RPC) after ${i}x2 s"; exit 0; fi
  sleep 2
done
curl -s "$FSN" || true; docker logs nn 2>&1 | tail -60; for i in $(seq 1 "$N"); do docker logs dn$i 2>&1 | tail -40; done; exit 1
