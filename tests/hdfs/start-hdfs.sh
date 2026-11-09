#!/bin/bash
# single-node HDFS (apache/hadoop image), host network: namenode localhost:8020 (web/JMX 9870), datanode 9866
set -euo pipefail
IMG=apache/hadoop:3.4.1
CONF=(-e "CORE-SITE.XML_fs.defaultFS=hdfs://localhost:8020"
      -e "HDFS-SITE.XML_dfs.namenode.rpc-address=localhost:8020"
      -e "HDFS-SITE.XML_dfs.replication=1"
      -e "HDFS-SITE.XML_dfs.permissions.enabled=false"
      -e "HDFS-SITE.XML_dfs.namenode.safemode.extension=0")
docker pull -q $IMG
docker run -d --name nn --network host -v "$PWD:/w" "${CONF[@]}" -e ENSURE_NAMENODE_DIR=/tmp/hadoop-hadoop/dfs/name $IMG hdfs namenode
docker run -d --name dn --network host "${CONF[@]}" $IMG hdfs datanode
for i in $(seq 1 60); do
  if docker exec nn hdfs dfsadmin -report 2>/dev/null | grep -q "Live datanodes (1)"; then
    docker exec nn hdfs dfsadmin -safemode leave >/dev/null 2>&1 || true
    echo "HDFS up after ${i}x2 s"; exit 0
  fi
  sleep 2
done
docker logs nn 2>&1 | tail -50; docker logs dn 2>&1 | tail -50; exit 1
