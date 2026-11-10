# duckdb-hadoopfs — status

DuckDB `hadoopfs` (hdfs://) extension, rebuilt for DuckDB v1.4.5 (linux_amd64; arm64 optional) with HDFS
read-error / timeout fixes. Sources are fetched by pinned commit (see `sources.env`); only our patches live here.

## Next steps

> **Maintainer, 2026-11-10 11:25 - check first (DONE, session (4) below):** the real cluster's DataNodes use `dfs.data.transfer.protection =
> authentication,privacy` (several QOPs, client and DataNode negotiate). Add that value to the SASL HDFS test (DataNode
> side `authentication,privacy`, client side the same and also `privacy` only / `authentication` only) and fix the
> negotiation if needed; release the fix as the next afc build.

> **Session 2026-11-10 (4): multi-QOP `authentication,privacy` checked - works with afc8 as it is, no fix needed, no new
> build (afc8 stays current).** SASL HDFS test 42785434422 (afc8 build 42777872495, 3 DataNodes with
> `dfs.data.transfer.protection=authentication,privacy` + AES suites, failover included): every client setting reads
> correctly (full scan, point reads, metadata cache off/on). Negotiated as Hadoop's own client does it - **the first QOP
> of the CLIENT's list that the DataNode offers**: client `authentication,privacy` -> **auth (no encryption)**;
> `privacy,authentication` -> auth-conf (3des, or AES/CTR with the cipher suites set); `privacy` -> auth-conf / AES;
> `authentication` -> auth; a client without the setting is refused. Throughput on a 147 MB scan, one runner:
> 3des 23-26 MB/s, AES 168-185 MB/s, auth 271-279 MB/s (local file 544 MB/s). **For the server:** to get encryption
> against these DataNodes put `privacy` (or `privacy,authentication`) + `dfs.encrypt.data.transfer.cipher.suites=AES/CTR/NoPadding`
> into LIBHDFS3_CONF; `authentication,privacy` on the client means auth only (fastest, block token authenticated, data
> not encrypted). Regression: privacy-only DataNodes 42785442912 OK (an authentication-only client is refused there),
> JDK interop 42785438826 OK (new cases: server auth,auth-conf with each client order). Remaining candidates, only on
> request: as in session (3) below.

> **Session 2026-11-10 (3): item (1) pin bump done - afc8 released (https://github.com/C0fuge/plover/releases/tag/hadoopfs-51b7220-afc8-duckdb-v1.5.6); nothing open from the maintainer's list.**
> libhdfs3 pin 94a9ead -> 85dabf0 (master 2026-11-05: c5dc2bd/c67cd2e slow-DataNode avoidance, d9c26dc malformed
> Datanode/Namenode response validation, 952ee51 no thread/object addresses in logs). Our libhdfs3 0002-0005 applied
> unchanged (rebased); 0001 conflicted in `InputStreamImpl::choseBestNode` with upstream's `SlowNodeTracker`: merged so
> that with the tracker enabled it chooses among the replicas not on our dead list first (all replicas if none is left);
> without it (default) our dead-list choice as before. The slow-node avoidance is **off by default**; to try it put
> `dfs.client.read.write.metric.enable=true` and `dfs.client.slow.datanode.kickout.enable=true` into LIBHDFS3_CONF
> (not tested in CI here). Build 42777872495, all tests green (JDK interop 42777876381, HDFS 42779492218, SASL HDFS
> with 3 DataNodes/AES/failover 42779497473). Remaining candidates, only on request: (3) `dfs.encrypt.data.transfer`
> (DataEncryptionKey), (4) SASL on the write path, NameNode RPC integrity/privacy (option (A) below), a CI test of the
> slow-node avoidance together with the dead-node list.

> **Maintainer, 2026-11-10 10:15:** rpc privacy -> (B), leave it: the target cluster works with the current extension,
> so its `hadoop.rpc.protection` is authentication. Go on with AES (3des at 18-24 MB/s per scan is too slow for the
> server's direct SASL reads; target: within ~20 % of a plain read).

> **Session 2026-11-10 (2): item (5) done for `hadoop.rpc.protection=authentication`; `privacy` is BLOCKED in libhdfs3 -
> your decision needed.** Test run 42766835989 (afc6 build 42753149137, 3 DataNodes, replication 2, data transfer privacy,
> metadata cache on, DuckDB external file cache off, one DuckDB process): 140 MB / 35-block file, blocks served by all 3
> DataNodes (22/19/34); busiest DataNode killed between scans (cached locations + pooled SaslSockets still point to it):
> correct, 75 blocks from the other two, 5.7 s; restarted, another DataNode killed 2.2 s into a 6 s scan: correct.
> Throughput with 3des privacy: 18-24 MB/s per scan (one runner, 2 vCPU).
> **Finding: libhdfs3 has no NameNode RPC integrity/privacy.** With `hadoop.rpc.protection=privacy` the extension cannot
> connect (run 42765021834: "Unable to connect to HDFS"; NameNode "Auth failed ... Problem with callback handler").
> ClickHouse/libhdfs3 had it (cb9a82a, 2016, "support secure rpc transfer ... privacy/integrity/authentication") but
> **reverted it** in 3f13d9e (2023-02); not in our pin 94a9ead, not in master 85dabf0. (The P2 note below that says RPC SASL
> "is there with all three QOPs" was wrong.) `git revert 3f13d9e` applies cleanly on 94a9ead (15 files, +402/-62).
> Options: (A) libhdfs3 patch 0005 = re-apply cb9a82a and fix it (its QOP choice `findPreferred` prefers auth over conf,
> it reads the server's QOP byte from the last challenge; needs a check that libgsasl 1.10's GSSAPI client does
> integrity/confidentiality - gsasl_encode/decode via gss_wrap - and which QOP it picks; else reuse our DigestMd5Client for
> tokens and gss_wrap/gss_unwrap directly for Kerberos), test = this workflow with `-f rpc_protection=privacy`
> (and `integrity`); (B) leave it, if the server's cluster uses `hadoop.rpc.protection=authentication` (it must, if the
> extension connects there today). Recommendation: (A) before (2) AES, if the real cluster needs it.

> **Maintainer, 2026-11-10 08:20 - next, in this order (from your candidate list):** (5) first: the SASL HDFS test with
> 2-3 DataNodes and `hadoop.rpc.protection=privacy` too: non-local block reads, a DataNode killed mid-scan (failover to
> another replica under SASL), metadata cache on; (2) AES cipher-option negotiation (`dfs.encrypt.data.transfer.cipher.suites`
> = AES/CTR/NoPadding) with a throughput number 3des vs AES on a large scan; (1) the pin bump to newer ClickHouse/libhdfs3
> as its own build; (3) and (4) only on request. Release each as afc7, afc8, ... with the tests green.

> **Session 2026-11-10: P3 and P4 done (afc5, afc6 released).** Nothing open from the maintainer's list. Candidates, waiting
> for the maintainer's choice: (1) pin bump to newer ClickHouse/libhdfs3 (c5dc2bd slow-DataNode avoidance, d9c26dc malformed
> response validation; overlaps our libhdfs3 0001; maintainer: only after P4 - now possible); (2) AES cipher option for
> privacy (CipherOptionProto in datatransfer.proto, AES/CTR keys unwrapped with DigestMd5Client; much faster than 3des for
> large scans); (3) `dfs.encrypt.data.transfer` (DataEncryptionKey via getDataEncryptionKey); (4) SASL on the write path
> (Pipeline); (5) CI: the SASL test with `hadoop.rpc.protection=privacy` too and 2 DataNodes (non-local reads + failover).

> **Maintainer, 2026-11-10 00:10 - answers.** Thanks for P1/P2. Next, in this order:
> **P3 (small, first):** listing cache with the same TTL (`getListing` of a directory / the glob of `read_parquet`),
> invalidated with the metadata cache; HDFS test: a repeated point query with a glob makes 0 NameNode calls after the
> first. Build `51b7220-afc5` for DuckDB v1.5.6, release as before.
> **P4 (go, several sessions): SASL data-transfer protection in libhdfs3, read path only** (DIGEST-MD5 on the block
> token in RemoteBlockReader, QOP authentication / integrity / privacy with wrap/unwrap; `dfs.data.transfer.protection`
> and the encryption key path if cheap), using the bdrosen96 fork as reference, as a libhdfs3 patch here. CI: a
> Kerberos (KDC container) single-node HDFS with `dfs.data.transfer.protection=privacy` on a non-privileged DataNode
> port, short-circuit OFF, reading a multi-block file correctly + the existing tests. Release when green
> (`afc6`). This lets the server read non-local blocks without node-local copies.
> Pin bump to newer ClickHouse/libhdfs3: only after P4, separately.

**P3 DONE hadoopfs-51b7220-afc5-duckdb-v1.5.6** (2026-11-10; https://github.com/C0fuge/plover/releases/tag/hadoopfs-51b7220-afc5-duckdb-v1.5.6,
build 42701198877, HDFS test 42702336389): patch 0007 listing cache, same setting `hdfs_metadata_cache_ttl_ms`. HDFS test, 20 point
queries with a glob over 4 files: cache off 20 getListing + 364 getfileinfo + 364 getBlockLocations; cache on: 1 getListing,
0 getfileinfo, 4 getBlockLocations, all in the first query - **0 NameNode calls after the first query**.

**P4 DONE hadoopfs-51b7220-afc6-duckdb-v1.5.6** (2026-11-10; https://github.com/C0fuge/plover/releases/tag/hadoopfs-51b7220-afc6-duckdb-v1.5.6,
build 42753149137, SASL HDFS test 42754573118, regression HDFS test 42753829079, JDK interop test 42752599247). Server: put
`dfs.data.transfer.protection` (same value as the cluster, e.g. `privacy`) and `hadoop.security.authentication=kerberos` into the
LIBHDFS3_CONF file; then non-local blocks are read from DataNodes on non-privileged ports with SASL (DIGEST-MD5 on the block token,
auth-conf with 3des preferred). Not covered: `dfs.encrypt.data.transfer` (DataEncryptionKey), the AES cipher-option
negotiation (`dfs.encrypt.data.transfer.cipher.suites`; without it the DataNode wraps with DIGEST-MD5 3des, slower than
AES), and the write path (Pipeline) - see Next steps.

**P4 plan** (SASL data-transfer protection, read path, libhdfs3 patches 0003+):
- Finding 2026-11-10: libgsasl (1.10.0 and gsasl master 2026-09) DIGEST-MD5 has **no auth-conf**: the client step returns
  an error for qop=auth-conf and `digest_md5_encode` returns -1 for it. The bdrosen96 fork's privacy path therefore cannot
  work through gsasl (it uses gsasl_encode/decode). Even the AES cipher option needs one DIGEST-MD5 auth-conf unwrap (the
  DataNode sends the AES keys SASL-wrapped). So we carry our own DIGEST-MD5 client.
- Step 1 (2026-11-10): libhdfs3 **0003** `src/rpc/DigestMd5Client.{h,cpp}` (OpenSSL libcrypto only): RFC 2831 client,
  auth / auth-int / auth-conf, ciphers 3des/des/rc4/rc4-56/rc4-40 as the JDK's DigestMD5Base, rspauth check, wrap/unwrap,
  maxRawSendSize. Test `scripts/test-sasl.sh` + `.github/workflows/sasl-test.yml` (RFC 2831 known answer, then handshake
  + 39 wrapped messages each way (1 B .. 65000 B) against the JDK's DIGEST-MD5 SaslServer with protocol "hdfs", server "0", for every
  QOP/cipher, and a wrong password). Not wired in yet.
- Step 2 (2026-11-10, done): libhdfs3 **0004** `src/client/DataTransferSasl.{h,cpp}` + RemoteBlockReader +
  SessionConfig `dfs.data.transfer.protection`. Protocol as Hadoop SaslDataTransferClient: int 0xDEADBEEF, varint-delimited
  `DataTransferEncryptorMessageProto{SUCCESS, payload ""}`, challenge, response (user base64(token identifier), password
  base64(token password), digest-uri `hdfs/0`), rspauth; ERROR / ERROR_UNKNOWN_KEY -> HdfsIOException (next replica).
  auth-int/auth-conf: `SaslSocket : Socket` decorator, frames `int32 length + token` both ways (writes chunked by
  maxRawSendSize, poll(read) true while unwrapped bytes are buffered); only new connections do the handshake, pooled
  ones are the SaslSocket already. Used when protection set + block token non-empty + xfer port >= 1024.
- Step 3 (2026-11-10, done, run 42754573118): `.github/workflows/hdfs-sasl-test.yml` + `tests/hdfs-sasl/` (kdc.sh: MIT KDC
  in almalinux:8, realm EXAMPLE.TEST, principals nn/dn/HTTP@localhost + client, keytabs and ccaches in ./krb; start.sh:
  Hadoop 3.4.1 with kerberos, block tokens, `dfs.data.transfer.protection=privacy`, DataNode 9866,
  `ignore.secure.ports.for.testing=true` (no HTTPS needed), webhdfs off; run.sh: kinit, LIBHDFS3_CONF with
  hadoop.security.authentication=kerberos + protection privacy, full scan + point reads of an 11-block file (1 MB blocks)
  vs the local file, cache off/on; negative check: without the client setting the read must fail).
  Gotcha: MIT krb5 >= 1.18 appends the DNS search domain to `localhost` (`qualify_shortname`) -> krb5.conf sets it to "".
- Later/cheap: `dfs.encrypt.data.transfer` (DataEncryptionKey from getDataEncryptionKey, user = keyId/blockPoolId/nonce
  form) and the AES cipher option (CipherOptionProto is missing from our datatransfer.proto).

**P1 DONE hadoopfs-51b7220-afc4-duckdb-v1.5.6** (2026-11-09; https://github.com/C0fuge/plover/releases/tag/hadoopfs-51b7220-afc4-duckdb-v1.5.6,
build 42643919332, HDFS test 42678080745). Server: `SET hdfs_metadata_cache_ttl_ms = <ms>` (or env `HDFS_METADATA_CACHE_TTL_MS`);
default 0 = off.

**P2 findings (research, 2026-11-09)** - libhdfs3 SASL data-transfer protection:
- ClickHouse/libhdfs3 (our pin 94a9ead and master 85dabf0, 2026-11-05) has **no** data-transfer SASL: `dfs.data.transfer.protection`
  and `dfs.encrypt.data.transfer` are not read; `datatransfer.proto` has `DataTransferEncryptorMessageProto` and
  `ClientNamenodeProtocol.proto` `getDataEncryptionKey`, but nothing uses them. RemoteBlockReader / Pipeline speak plain
  DataTransferProtocol, so a DataNode that requires SASL (non-privileged port + protection) refuses the read.
- NameNode RPC SASL is there with all three QOPs (authentication / integrity / privacy): commit cb9a82a (2016, "support secure rpc
  transfer, including all three modes").
- An implementation exists in the bdrosen96/libhdfs3 fork (the one Dask's hdfs3 used), 2016-10..2017-09: commits 286bff3
  "partially working encryption", 03cc884, d913c95 "Don't reuse socket when we do SASL for data transfer", 12b6721 non-SASL fallback,
  64338e9/49b06fa AES, 92522e7 "Partially plumb through encryption keys", PRs #18/#19 "fix_privacy". It reads both settings
  (SessionConfig) and does the DIGEST-MD5 handshake on the block token in RemoteBlockReader and Pipeline, with QOP auth-conf wrap
  and AES. Size: `git diff --stat 286bff3^ 1178d61 -- src` = 43 files, +1871/-233 (SaslClient.cpp +711 alone). Its base is the
  2016 Pivotal code, so a port onto ClickHouse's tree is a rewrite of the hunks in RemoteBlockReader/Pipeline/SaslClient, not a
  cherry-pick; `encrypt.data.transfer` with DataEncryptionKey was only "partially plumbed" there.
- Estimate: libhdfs3 patch ~1000-1500 lines (SASL handshake + wrap/unwrap on the block reader stream; read path only - we do not
  need the write Pipeline), plus a CI cluster with Kerberos (KDC container) and `dfs.data.transfer.protection=privacy`. Several
  sessions. Not started - waiting for the maintainer's decision.

Open follow-ups (not asked yet, for the maintainer):
- the glob `read_parquet('.../*.parquet')` still costs one `getListing` per query (20 in 20 queries); the metadata cache does
  not cache listings. A listing cache with the same TTL would make a repeated point query NameNode-free.
- (b) was done as "open lazily from the cached block locations" (no NameNode call per re-open), not as one stream shared by all
  DuckDB handles of a file: every re-open still sets up its own DataNode block reader.
- ClickHouse/libhdfs3 master has new commits since our pin: c5dc2bd "Add HDFS slow DataNode avoidance", d9c26dc "Validate
  malformed responses from Datanode and Namenode", 952ee51. Worth a look for a pin bump (would overlap our libhdfs3 0001).


> **Maintainer, 2026-11-09 18:20 - ITEM P1 (first): cut the NameNode round trips per query (server item 39 (c), Q9).**
> Measured by the server's HDFS point-query cell: every point query opens every Parquet file of its table about 5 times
> (once per row group scanned + footer + bind), and every open comes with a `getfileinfo` (the stat before open) and
> a `getBlockLocations`: ~20 opens + ~20 `getfileinfo` NameNode RPCs per point query. On a real Kerberos + SASL
> (privacy) cluster that is tens of NameNode round trips per query - the likeliest cause of the server's point-query
> collapse there (13-27 q/s, CPU idle). Do in a patch `0006`:
> (a) a process-wide metadata cache in the extension: file status (length, mtime, isdir) and located blocks per path,
>     TTL setting `hdfs_metadata_cache_ttl_ms` (BIGINT ms, env `HDFS_METADATA_CACHE_TTL_MS`, default 0 = off for now;
>     the server will set it), invalidated when a fresh stat shows another length/mtime, never caching errors; bounded
>     size (LRU, e.g. 10 000 entries); `getfileinfo` for `FileExists`/`GetFileSize`/`GetLastModifiedTime` served from it;
> (b) reuse an open libhdfs3 input stream (and its located blocks) across the row-group reads of one DuckDB file handle
>     instead of re-opening (check where DuckDB opens per row group: `OpenFile` per scan state vs the extension);
> (c) make the extension report the file's modification time correctly (DuckDB's Parquet metadata cache and external
>     file cache rely on it) - test it.
> Tests: unit tests where possible (no HDFS), and a check on a single-node HDFS in CI (Hadoop 3.x container, like the
> server's cells) counting NameNode RPCs per repeated `SELECT ... WHERE id = k` before/after (NameNode audit log or
> RPC metrics). Build for **DuckDB v1.5.6** (the server's version) amd64, footer version `51b7220-afc4`; record the run
> and sha256 in "Builds". Then attach the extension + `.sha256` to a release `hadoopfs-51b7220-afc4-duckdb-v1.5.6` here
> and write "P1 DONE <release>" - the server lanes take it from there.
> **P2 (after P1, research only, write findings here):** can libhdfs3 (ClickHouse fork) do the SASL data-transfer
> handshake (`dfs.data.transfer.protection` authentication/privacy, `dfs.encrypt.data.transfer`)? Which upstream
> commits/PRs, how big a patch; that would let DuckDB read non-local blocks without the server's local copies.

## Layout
- `sources.env` — pinned upstream commits / tarballs (+ sha256)
- `patches/hadoopfs/` — patches on vincent-chang/duckdb-hdfs 51b7220 (footer version `51b7220-afcN`, N = patch level, set in `scripts/build-ext.sh`)
- `patches/libhdfs3/` — patches on ClickHouse/libhdfs3 85dabf0 (94a9ead up to afc7) (0001 process-wide dead DataNode list; part of the deps cache key)
- `tests/libhdfs3/` + `scripts/test-libhdfs3.sh` — unit test of the libhdfs3 patch (no HDFS; CI step before the deps)
- `scripts/build-deps.sh` — static protobuf 3.21.12, libgsasl 1.10.0, libhdfs3 -> /opt/deps (cached in CI)
- `scripts/build-ext.sh` — DuckDB `$DUCKDB_VERSION` + extension, EXTENSION_STATIC_BUILD=1, ccache
- `.github/workflows/build.yml` — manual run (`gh workflow run build.yml -f duckdb_version=v1.4.5 -f arch=amd64`);
  builds in `quay.io/pypa/manylinux_2_28_<arch>` (AlmaLinux 8, gcc-toolset-14, glibc 2.28), uploads
  `hadoopfs.duckdb_extension` + `.sha256` as artifact `hadoopfs-<version>-linux_<arch>`.

- `tests/hadoopfs/` + `scripts/test-hadoopfs.sh` — unit test of the metadata cache (patch 0006, no HDFS; CI step)
- `.github/workflows/hdfs-test.yml` + `tests/hdfs/` — runs a build's extension against a single-node HDFS 3.4.1 (containers) and
  counts NameNode RPCs (JMX NameNodeActivity, read after the 10 s metrics cache) per repeated point query, cache off vs on;
  checks results and mtime (`-f build_run_id=<id> -f duckdb_version=v1.5.6`)
- `scripts/test-sasl.sh` + `.github/workflows/sasl-test.yml` + `tests/libhdfs3/digestmd5_test.cpp`, `DigestServer.java` — libhdfs3 0003
  DIGEST-MD5 client vs the JDK's SaslServer (ubuntu runner, ~40 s, no deps)
- `.github/workflows/hdfs-sasl-test.yml` + `tests/hdfs-sasl/` — Kerberos (KDC container) HDFS 3.4.1 with
  `dfs.data.transfer.protection=privacy`, 1..3 DataNodes (`-f datanodes=3`, default; ports 9866/9876/9886, replication
  min(2,N)), `-f rpc_protection=authentication|integrity|privacy`; reads an 11-block file through the extension, checks a
  plain read is refused; with 3 DataNodes also `failover.sh` (kill the busiest DataNode between scans, restart, kill
  another mid-scan; one DuckDB process fed by a FIFO, the workflow's host loop does docker kill/start)
  `-f cipher_suites=AES/CTR/NoPadding` (default; "" = off): DataNodes accept AES, run.sh also reads with the AES option
  (checks it was negotiated) and compares full-scan throughput 3des vs AES; failover then runs with AES
  (`-f build_run_id=<id> -f duckdb_version=v1.5.6`, ~3.5 min)
- `.github/workflows/release.yml` — attaches a build run's extension + `.sha256` to a release (`-f build_run_id -f tag`)

Runtime needs (dynamically linked, from the OS): libxml2, MIT krb5 (gssapi_krb5/krb5/k5crypto/com_err), libuuid,
OpenSSL. Everything else (libhdfs3, protobuf, gsasl, DuckDB, libstdc++) is inside the extension, symbols hidden.

## Patches
| patch | what |
|---|---|
| 0001 short-circuit settings | `hdfs_shortcircuit` / `hdfs_domain_socket_path` also apply to `hdfs://<namenode>/` URLs (upstream ignored them there). Same as the v1.4.1 build. |
| 0002 IO errors | `hdfsRead() == -1` -> `IOException` with the libhdfs3 error; a positional `Read` that does not return all bytes -> `IOException` (was a silent short read -> "No magic bytes found at end of file" / "Variable-length int over 10 bytes"); write errors -> `IOException`; per-handle mutex around seek+read. |
| 0003 timeouts | settings `hdfs_connect_timeout_ms`, `hdfs_read_timeout_ms` (BIGINT ms; env `HDFS_CONNECT_TIMEOUT_MS` / `HDFS_READ_TIMEOUT_MS`). Precedence: setting > LIBHDFS3_CONF (`input.connect.timeout`, `input.read.timeout`) > default 5000 / 15000 ms (libhdfs3 defaults 600 s / 3600 s). Applied when a namenode connection is first created. |
| 0004 retry rounds, message | `input.read.max.retry` default 3 (libhdfs3 default 60: with every replica of a block hung a read failed only after 60 x (replicas x read timeout + 1 s), measured 428 s with 2 replicas @ 3 s); LIBHDFS3_CONF still wins. Read error message shows the real offset (was `-1`). |
| 0005 dead-node TTL | setting `hdfs_dead_node_ttl_ms` (BIGINT ms, env `HDFS_DEAD_NODE_TTL_MS`) -> libhdfs3 `input.deadnode.ttl` (needs libhdfs3 0001). Precedence: setting (>= 0, 0 = off) > LIBHDFS3_CONF > default 60000. |
| 0006 metadata cache, lazy open, mtime | setting `hdfs_metadata_cache_ttl_ms` (BIGINT ms, env `HDFS_METADATA_CACHE_TTL_MS`, default 0 = off): file status and the located blocks of finalized files cached per namenode+path for that long, 10 000 paths LRU, process-wide; only successful lookups stored; a fresh status with another length/mtime drops the blocks; writes/deletes/renames/truncates invalidate. With the cache on, a read-only file is opened lazily (first read/seek) from the cached locations (libhdfs3 0002): a repeated open costs no NameNode call. `GetLastModifiedTime` fixed (upstream returned seconds*1000 microseconds = January 1970). Unit test `tests/hadoopfs/metadata_cache_test.cpp` (TSan). |
| 0007 listing cache | `ListFiles` (the glob of `read_parquet`): a successful listing cached per namenode+directory for `hdfs_metadata_cache_ttl_ms` (same LRU as 0006); the listing primes the status cache of its children (no `getfileinfo` after the glob); invalidating a path also drops its parent's listing. |
| libhdfs3 0003 DIGEST-MD5 client | `src/rpc/DigestMd5Client.{h,cpp}` (OpenSSL libcrypto): RFC 2831 client with auth / auth-int / auth-conf (3des, des, rc4, rc4-56, rc4-40 as the JDK's DigestMD5Base), rspauth check, wrap/unwrap. libgsasl has no auth-conf. Test `scripts/test-sasl.sh` (RFC 2831 known answer + interop with the JDK's DIGEST-MD5 SaslServer for every QOP/cipher). |
| libhdfs3 0004 data-transfer SASL (read) | `dfs.data.transfer.protection` (authentication/integrity/privacy): RemoteBlockReader does Hadoop's SaslDataTransferClient handshake on new connections to DataNodes on ports >= 1024 when a block token is present; auth-int/auth-conf through a `SaslSocket` decorator (int32-length frames); pooled connections keep their SaslSocket. Short-circuit and writes unchanged. |
| libhdfs3 0005 AES/CTR cipher option | `dfs.encrypt.data.transfer.cipher.suites` = `AES/CTR/NoPadding` (with privacy): CipherOptionProto added to datatransfer.proto; the client sends the option with its DIGEST-MD5 response (as SaslDataTransferClient), unwraps the DataNode's inKey/outKey with the auth-conf session and continues on an `AesCtrSocket` (OpenSSL AES-128/192/256-CTR, client writes with inKey/inIv, reads with outKey/outIv). A DataNode without the setting answers without an option -> DIGEST-MD5 3des as before. DEBUG1 log of the negotiated qop/cipher per connection (needs `HDFS_ENABLE_LOGGING=true`). |
| libhdfs3 0001 dead-node list | `DeadNodes`: process-wide list keyed by DataNode UUID@ip:xferPort. A node whose remote block reader fails (setup timeout/IO error, or read error mid-block) is avoided by all streams for `input.deadnode.ttl` ms (libhdfs3 default with the patch 60000, 0 = upstream behaviour); `choseBestNode` prefers replicas not on the list, a listed one is still tried when it is the only replica left; a successful block reader setup removes the node. EC (striped) reads unchanged. Since afc8 (pin 85dabf0): with upstream's slow-DataNode avoidance enabled, the SlowNodeTracker chooses among the replicas not on the list first, else among all. |
| libhdfs3 0002 open from block locations | C API `hdfsGetBlockLocationsForRead` / `hdfsOpenFileWithBlockLocations` / `hdfsFreeBlockLocations`: open a read stream from pre-fetched located blocks without the `getBlockLocations` RPC (the stream still fetches further blocks and refreshes after failures). |

libhdfs3 replica failover on a DataNode read timeout: in ceb428c (used by the v1.4.1 build) a timeout while setting up the
block reader (`HdfsTimeoutException`, e.g. a pooled socket to a silently lost DataNode) was not caught as an
`HdfsIOException`, so the read failed after one timeout without trying the other replica. Fixed upstream by 94a9ead
("Fix HdfsTimeoutException not retried in setupBlockReader and EC createBlockReader"), which we pin.

## Builds
| date | run | DuckDB | arch | result | time | sha256 |
|---|---|---|---|---|---|---|
| 2026-11-10 | 42777872495 | v1.5.6 | amd64 | OK, patches 0001-0007 + libhdfs3 0001-0005 on libhdfs3 85dabf0 (`51b7220-afc8`) — **current**, release `hadoopfs-51b7220-afc8-duckdb-v1.5.6` (release run 42780313283); SASL HDFS test 42779497473 OK, HDFS test 42779492218 OK, JDK interop 42777876381 OK | 6m31s (deps rebuild 3m56s, ext 53 s, ccache 322/324 hits) | 78fdd5d7b9621f6eb1e77cfd9d3f3abd54207bb4d34990c42d0341f6af96dcef |
| 2026-10-20 | 39412215060 | v1.4.5 | amd64 | OK, patches 0001-0003 (`51b7220-afc1`) | 33m25s (deps 6m42s cold, ext 24m45s cold ccache) | 5e98988006240663d8a189e45c6f6d95fc6418724bb4149170d4fc4c52eb0234 |
| 2026-10-22 | 39692669742 | v1.4.5 | amd64 | OK, patches 0001-0004 (`51b7220-afc2`) | 2m51s (deps cache hit, ext 64 s, ccache 396/401 hits) | e3c8b077d5041a820e0495cd04fce77a8acf86bd3144d000ccb07fef495d1bce |
| 2026-10-23 | 39952752512 | v1.4.5 | amd64 | OK, patches 0001-0005 + libhdfs3 0001 (`51b7220-afc3`) | 10m14s (unit tests 4 s, deps rebuild 6m51s, ext 88 s) | 044b5162efed99cb2df395ec2344b80fa5dc07c2a009525b814be9ba32cadecb |
| 2026-11-10 | 42771355611 | v1.5.6 | amd64 | OK, patches 0001-0007 + libhdfs3 0001-0005 (`51b7220-afc7`), release `hadoopfs-51b7220-afc7-duckdb-v1.5.6` (release run 42773268258); SASL HDFS test 42772691546 OK (AES + 3des, failover with AES), HDFS test 42772100404 OK | 6m13s (deps rebuild, ext ccache 322/324 hits) | 5a461ef2bafadf8d1ca149e53ab309d90e483c8a20de12301a76d80eb103f3ab |
| 2026-11-10 | 42753149137 | v1.5.6 | amd64 | OK, patches 0001-0007 + libhdfs3 0001-0004 (`51b7220-afc6`), release `hadoopfs-51b7220-afc6-duckdb-v1.5.6` (release run 42754920767); SASL HDFS test 42754573118 OK, HDFS test 42753829079 OK | 4m29s (deps rebuild 2m22s, ext 39 s, ccache 322/324 hits) | 836299dc639b2fd0f829723e3c7bfe28a403a04be7244482bde88191d8b40948 |
| 2026-11-09 | 42701198877 | v1.5.6 | amd64 | OK, patches 0001-0007 + libhdfs3 0001-0002 (`51b7220-afc5`), release `hadoopfs-51b7220-afc5-duckdb-v1.5.6` (release run 42751613733); HDFS test 42702336389 OK | 2m32s (deps cache hit, ext 56 s, ccache 320/324 hits) | bb50f86c1e83e9801bc3638262b3e56e73072208331b35c6d8c6297f732fdf7b |
| 2026-11-09 | 42643919332 | v1.5.6 | amd64 | OK, patches 0001-0006 + libhdfs3 0001-0002 (`51b7220-afc4`), release `hadoopfs-51b7220-afc4-duckdb-v1.5.6`; HDFS test 42678080745 OK | 16m41s (deps rebuild 4m05s, ext 10m37s, ccache 79/324 hits: first v1.5.6 build) | 64a97a6b08e1f725c980d46f25d664a1c3edde8a73b624ac31bdc75f9095942c |

## Verification (local, DuckDB JDBC 1.4.5 in an AlmaLinux 8 container)
- `afc1`: loads (file must be named `hadoopfs.duckdb_extension`: DuckDB derives the init symbol from the file name);
  `hdfs_connect_timeout_ms` / `hdfs_read_timeout_ms` listed in `duckdb_settings()` (BIGINT, NULL by default), SET works.
- isolated 2-DataNode HDFS 3.4.1 (replication 2, 8 MB blocks, TPC-H SF1 orders + customer): counts/sums identical to the
  v1.4.1 build, short-circuit fd requests seen on the DataNode.
- one DataNode paused (silent hang), read timeout 3 s: new build returns correct results (setting path and LIBHDFS3_CONF
  path; each block whose first choice is the hung node pays one timeout); v1.4.1 build fails after 3 s with
  `No magic bytes found at end of file` (the production bug).
- both DataNodes paused: new build fails with `IO Error: Failed to read from HDFS file ... HdfsTimeoutException` (no
  short read), but only after 428 s with afc1 -> patch 0004; `afc2`: same error after 27 s, real offset in the message.
- `afc2` repeated all of the above: same counts, short-circuit used, one DataNode hung -> correct results (12.4 s / 6.2 s /
  12.2 s with SET 3 s), v1.4.1 build -> `TProtocolException: Invalid data` after 3.1 s (another short-read symptom).

## Open
- 2026-11-10: maintainer item multi-QOP: test-only change (dn_protection input, client QOP matrix, auth throughput,
  JDK interop cases); afc8 passes all (42785434422, 42785442912, 42785438826) on the first try; no fix, no new release.
- 2026-11-10: item (1) pin bump: libhdfs3 94a9ead -> 85dabf0, patches rebased (0001 merged with SlowNodeTracker in
  choseBestNode), afc8 build 42777872495 + all tests green on the first try; released afc8.
- 2026-11-10: item (2) AES done: libhdfs3 0005, afc7 build 42771355611, SASL test 42772691546 (first run 42772097200 failed
  on the test's own check: ClickHouse libhdfs3 logs only with env `HDFS_ENABLE_LOGGING=true`), throughput 3des ~20 MB/s vs
  AES ~130 MB/s; regression HDFS test 42772100404 OK. Released afc7. RPC privacy decision still open.
- 2026-11-10: item (5) multi-DataNode SASL test: 3 DataNodes + failover green with rpc authentication (run 42766835989,
  after test fixes in 42764563840/42765018742/42765611346/42766154093: container name, DataNode JMX metrics cache, DuckDB's
  external file cache hid the reads); rpc privacy fails in libhdfs3 (run 42765021834) - see Next steps. No code change,
  no new release (afc6 stays current).
- 2026-11-10: P3 done: afc5 (patch 0007 listing cache) build 42701198877 (first try 42699593573 failed: C++14 code, the
  extension builds with -std=c++11; fixed), HDFS test 42702336389 (getListing 20 -> 1, 0 NameNode calls after the first
  query), released `hadoopfs-51b7220-afc5-duckdb-v1.5.6`. P4 started: gsasl cannot do DIGEST-MD5 auth-conf (see P4 plan).
- 2026-11-10: P4 done. libhdfs3 0003 (DigestMd5Client; JDK interop test 42752599247 green after 2 test fixes: LSan on OpenSSL's
  globals, the JDK wraps an empty message to an empty token) + 0004 (data-transfer SASL on the read path); afc6 build
  42753149137; SASL HDFS test 42754573118 (third run; fixes: krb5 qualify_shortname): 11-block file, privacy, full scan and
  point reads identical to the local file with the metadata cache off/on, plain read refused; regression HDFS test 42753829079
  OK. Released `hadoopfs-51b7220-afc6-duckdb-v1.5.6`.
- 2026-11-09: afc4 (patch 0006 + libhdfs3 0002) built for DuckDB v1.5.6 (run 42643919332). HDFS test 42678080745 (after two
  fixes to the test itself: DataNode wait via JMX, JMX metrics cache): 20 point queries over 4 files (4 row groups each), cache off:
  364 getfileinfo + 364 getBlockLocations (36 per query); cache on (600 s): 4 + 4 in total (first query only); results identical,
  full scan identical, `last_modified` correct. Released `hadoopfs-51b7220-afc4-duckdb-v1.5.6`. P2 research written under Next steps.
- HDFS machine-loss test on the bench DONE 2026-10-23 (afc-offline bench/tools/agent-hadoopfs/hk.sh, srv.sh; 3 DataNodes,
  replication 2, SF10, one DataNode silently disconnected for 90 s): afc2 0 failures, correct results (direct DuckDB 234
  queries; int6b server 63 queries); v1.4.1 build: `Snappy decompression failure` 16 s after the loss. During the outage
  scans took 24-121 s instead of 1-4 s (repeated connect timeouts to the lost node, see next point).
- afc3 (libhdfs3 0001 dead-node list, TTL 60 s) fixes the slow failover. Same test, 2026-10-23: direct DuckDB k4 (afc2 = k3):
  0 failures, correct; lineitem scan max during the outage 15.5 / 17.3 s with defaults 5 s/15 s (k3 106.7 / 98.4 s), 3.8 s with
  SET connect 3 s (k3 120.6 s), median 0.4-0.6 s; 32-77 queries per probe during the outage (k3: 1-2). int6b server s2 (S-s1 =
  afc2): 414 queries, 0 failures, correct; during the 90 s outage 116 queries (S-s1: 3), max li 0.2 s (24.5 s), ord 22.1 s
  (60.6 s, the first query after the loss), join 11.3 s (34.0 s), all others 0.1-0.3 s. The first reads that meet the lost
  node still pay one connect/read timeout each (before it is on the list).
