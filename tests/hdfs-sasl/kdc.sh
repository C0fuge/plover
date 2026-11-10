#!/bin/bash
# KDC for the SASL test (almalinux:8, host network, run as root): realm EXAMPLE.TEST on localhost:88 (TCP).
# Writes /w/krb: hdfs.keytab (nn/localhost, dn/localhost, HTTP/localhost), client.keytab (client), and ticket
# caches nn.ccache / client.ccache readable by the Hadoop containers' user; then runs krb5kdc in the foreground.
set -euo pipefail
dnf install -y -q krb5-server krb5-workstation >/dev/null
cp /w/tests/hdfs-sasl/krb5.conf /etc/krb5.conf
cat > /var/kerberos/krb5kdc/kdc.conf <<'K'
[kdcdefaults]
  kdc_ports = 88
  kdc_tcp_ports = 88
[realms]
  EXAMPLE.TEST = {
    database_name = /var/kerberos/krb5kdc/principal
    acl_file = /var/kerberos/krb5kdc/kadm5.acl
    key_stash_file = /var/kerberos/krb5kdc/.k5.EXAMPLE.TEST
    supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
    max_life = 24h
  }
K
kdb5_util create -s -r EXAMPLE.TEST -P masterpw >/dev/null
for p in nn/localhost dn/localhost HTTP/localhost client; do kadmin.local -q "addprinc -randkey $p@EXAMPLE.TEST" >/dev/null; done
mkdir -p /w/krb && rm -f /w/krb/*
kadmin.local -q "ktadd -k /w/krb/hdfs.keytab nn/localhost dn/localhost HTTP/localhost" >/dev/null
kadmin.local -q "ktadd -k /w/krb/client.keytab client" >/dev/null
krb5kdc -n &
sleep 2
kinit -kt /w/krb/hdfs.keytab -c FILE:/w/krb/nn.ccache nn/localhost@EXAMPLE.TEST
kinit -kt /w/krb/client.keytab -c FILE:/w/krb/client.ccache client@EXAMPLE.TEST
chmod 644 /w/krb/*
klist -c FILE:/w/krb/client.ccache
touch /w/krb/ready
wait
