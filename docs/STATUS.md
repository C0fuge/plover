# duckdb-hadoopfs — status

DuckDB `hadoopfs` (hdfs://) extension, rebuilt for DuckDB v1.4.5 (linux_amd64; arm64 optional) with HDFS
read-error / timeout fixes. Sources are fetched by pinned commit (see `sources.env`); only our patches live here.

## Next steps

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

**P4 (in progress)** - see "P4 plan" below.

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
- `patches/libhdfs3/` — patches on ClickHouse/libhdfs3 94a9ead (0001 process-wide dead DataNode list; part of the deps cache key)
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
| libhdfs3 0001 dead-node list | `DeadNodes`: process-wide list keyed by DataNode UUID@ip:xferPort. A node whose remote block reader fails (setup timeout/IO error, or read error mid-block) is avoided by all streams for `input.deadnode.ttl` ms (libhdfs3 default with the patch 60000, 0 = upstream behaviour); `choseBestNode` prefers replicas not on the list, a listed one is still tried when it is the only replica left; a successful block reader setup removes the node. EC (striped) reads unchanged. |
| libhdfs3 0002 open from block locations | C API `hdfsGetBlockLocationsForRead` / `hdfsOpenFileWithBlockLocations` / `hdfsFreeBlockLocations`: open a read stream from pre-fetched located blocks without the `getBlockLocations` RPC (the stream still fetches further blocks and refreshes after failures). |

libhdfs3 replica failover on a DataNode read timeout: in ceb428c (used by the v1.4.1 build) a timeout while setting up the
block reader (`HdfsTimeoutException`, e.g. a pooled socket to a silently lost DataNode) was not caught as an
`HdfsIOException`, so the read failed after one timeout without trying the other replica. Fixed upstream by 94a9ead
("Fix HdfsTimeoutException not retried in setupBlockReader and EC createBlockReader"), which we pin.

## Builds
| date | run | DuckDB | arch | result | time | sha256 |
|---|---|---|---|---|---|---|
| 2026-10-20 | 39412215060 | v1.4.5 | amd64 | OK, patches 0001-0003 (`51b7220-afc1`) | 33m25s (deps 6m42s cold, ext 24m45s cold ccache) | 5e98988006240663d8a189e45c6f6d95fc6418724bb4149170d4fc4c52eb0234 |
| 2026-10-22 | 39692669742 | v1.4.5 | amd64 | OK, patches 0001-0004 (`51b7220-afc2`) | 2m51s (deps cache hit, ext 64 s, ccache 396/401 hits) | e3c8b077d5041a820e0495cd04fce77a8acf86bd3144d000ccb07fef495d1bce |
| 2026-10-23 | 39952752512 | v1.4.5 | amd64 | OK, patches 0001-0005 + libhdfs3 0001 (`51b7220-afc3`) | 10m14s (unit tests 4 s, deps rebuild 6m51s, ext 88 s) | 044b5162efed99cb2df395ec2344b80fa5dc07c2a009525b814be9ba32cadecb |
| 2026-11-09 | 42701198877 | v1.5.6 | amd64 | OK, patches 0001-0007 + libhdfs3 0001-0002 (`51b7220-afc5`) — **current**, release `hadoopfs-51b7220-afc5-duckdb-v1.5.6` (release run 42751613733); HDFS test 42702336389 OK | 3m40s (deps cache hit, ext 56 s, ccache 320/324 hits) | bb50f86c1e83e9801bc3638262b3e56e73072208331b35c6d8c6297f732fdf7b |
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
- 2026-11-10: P3 done: afc5 (patch 0007 listing cache) build 42701198877 (first try 42699593573 failed: C++14 code, the
  extension builds with -std=c++11; fixed), HDFS test 42702336389 (getListing 20 -> 1, 0 NameNode calls after the first
  query), released `hadoopfs-51b7220-afc5-duckdb-v1.5.6`. P4 started: gsasl cannot do DIGEST-MD5 auth-conf (see P4 plan).
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
