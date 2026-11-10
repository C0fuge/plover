#!/bin/bash
# Kerberized single-node HDFS 3.4.1 with dfs.data.transfer.protection=privacy on a non-privileged DataNode port
# (9866), block tokens on, short-circuit off, 1 MB blocks allowed. Host network; KDC from kdc.sh.
set -euo pipefail
IMG=apache/hadoop:3.4.1
R=EXAMPLE.TEST
docker pull -q almalinux:8 >/dev/null; docker pull -q $IMG >/dev/null
docker run -d --name kdc --network host -v "$PWD:/w" almalinux:8 bash /w/tests/hdfs-sasl/kdc.sh
for i in $(seq 1 90); do [ -f krb/ready ] && break; sleep 2; done
[ -f krb/ready ] || { docker logs kdc; echo "KDC not up"; exit 1; }
echo "KDC up"
CONF=(-e "CORE-SITE.XML_fs.defaultFS=hdfs://localhost:8020"
      -e "CORE-SITE.XML_hadoop.security.authentication=kerberos"
      -e "CORE-SITE.XML_hadoop.security.authorization=false"
      -e "CORE-SITE.XML_hadoop.rpc.protection=authentication"
      -e "HDFS-SITE.XML_dfs.namenode.rpc-address=localhost:8020"
      -e "HDFS-SITE.XML_dfs.replication=1"
      -e "HDFS-SITE.XML_dfs.permissions.enabled=false"
      -e "HDFS-SITE.XML_dfs.namenode.safemode.extension=0"
      -e "HDFS-SITE.XML_dfs.namenode.fs-limits.min-block-size=65536"
      -e "HDFS-SITE.XML_dfs.block.access.token.enable=true"
      -e "HDFS-SITE.XML_dfs.data.transfer.protection=privacy"
      -e "HDFS-SITE.XML_dfs.datanode.address=0.0.0.0:9866"
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
docker run -d --name dn --network host -v "$PWD:/w" "${CONF[@]}" $IMG hdfs datanode
FSN="http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState"
for i in $(seq 1 60); do
  live=$(curl -sf "$FSN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["beans"][0]["NumLiveDataNodes"])' 2>/dev/null || echo 0)
  if [ "$live" -ge 1 ]; then echo "secure HDFS up after ${i}x2 s"; exit 0; fi
  sleep 2
done
curl -s "$FSN" || true; docker logs nn 2>&1 | tail -60; docker logs dn 2>&1 | tail -60; exit 1
