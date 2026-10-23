# duckdb-hadoopfs — status

DuckDB `hadoopfs` (hdfs://) extension, rebuilt for DuckDB v1.4.5 (linux_amd64; arm64 optional) with HDFS
read-error / timeout fixes. Sources are fetched by pinned commit (see `sources.env`); only our patches live here.

## Layout
- `sources.env` — pinned upstream commits / tarballs (+ sha256)
- `patches/hadoopfs/` — patches on vincent-chang/duckdb-hdfs 51b7220 (footer version `51b7220-afcN`, N = patch level, set in `scripts/build-ext.sh`)
- `patches/libhdfs3/` — patches on ClickHouse/libhdfs3 (none: the needed fix is upstream, pinned commit 94a9ead)
- `scripts/build-deps.sh` — static protobuf 3.21.12, libgsasl 1.10.0, libhdfs3 -> /opt/deps (cached in CI)
- `scripts/build-ext.sh` — DuckDB `$DUCKDB_VERSION` + extension, EXTENSION_STATIC_BUILD=1, ccache
- `.github/workflows/build.yml` — manual run (`gh workflow run build.yml -f duckdb_version=v1.4.5 -f arch=amd64`);
  builds in `quay.io/pypa/manylinux_2_28_<arch>` (AlmaLinux 8, gcc-toolset-14, glibc 2.28), uploads
  `hadoopfs.duckdb_extension` + `.sha256` as artifact `hadoopfs-<version>-linux_<arch>`.

Runtime needs (dynamically linked, from the OS): libxml2, MIT krb5 (gssapi_krb5/krb5/k5crypto/com_err), libuuid,
OpenSSL. Everything else (libhdfs3, protobuf, gsasl, DuckDB, libstdc++) is inside the extension, symbols hidden.

## Patches
| patch | what |
|---|---|
| 0001 short-circuit settings | `hdfs_shortcircuit` / `hdfs_domain_socket_path` also apply to `hdfs://<namenode>/` URLs (upstream ignored them there). Same as the v1.4.1 build. |
| 0002 IO errors | `hdfsRead() == -1` -> `IOException` with the libhdfs3 error; a positional `Read` that does not return all bytes -> `IOException` (was a silent short read -> "No magic bytes found at end of file" / "Variable-length int over 10 bytes"); write errors -> `IOException`; per-handle mutex around seek+read. |
| 0003 timeouts | settings `hdfs_connect_timeout_ms`, `hdfs_read_timeout_ms` (BIGINT ms; env `HDFS_CONNECT_TIMEOUT_MS` / `HDFS_READ_TIMEOUT_MS`). Precedence: setting > LIBHDFS3_CONF (`input.connect.timeout`, `input.read.timeout`) > default 5000 / 15000 ms (libhdfs3 defaults 600 s / 3600 s). Applied when a namenode connection is first created. |
| 0004 retry rounds, message | `input.read.max.retry` default 3 (libhdfs3 default 60: with every replica of a block hung a read failed only after 60 x (replicas x read timeout + 1 s), measured 428 s with 2 replicas @ 3 s); LIBHDFS3_CONF still wins. Read error message shows the real offset (was `-1`). |

libhdfs3 replica failover on a DataNode read timeout: in ceb428c (used by the v1.4.1 build) a timeout while setting up the
block reader (`HdfsTimeoutException`, e.g. a pooled socket to a silently lost DataNode) was not caught as an
`HdfsIOException`, so the read failed after one timeout without trying the other replica. Fixed upstream by 94a9ead
("Fix HdfsTimeoutException not retried in setupBlockReader and EC createBlockReader"), which we pin.

## Builds
| date | run | DuckDB | arch | result | time | sha256 |
|---|---|---|---|---|---|---|
| 2026-10-20 | 39412215060 | v1.4.5 | amd64 | OK, patches 0001-0003 (`51b7220-afc1`) | 33m25s (deps 6m42s cold, ext 24m45s cold ccache) | 5e98988006240663d8a189e45c6f6d95fc6418724bb4149170d4fc4c52eb0234 |
| 2026-10-22 | 39692669742 | v1.4.5 | amd64 | OK, patches 0001-0004 (`51b7220-afc2`) — **current** | 2m51s (deps cache hit, ext 64 s, ccache 396/401 hits) | e3c8b077d5041a820e0495cd04fce77a8acf86bd3144d000ccb07fef495d1bce |

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
- HDFS machine-loss test on the bench DONE 2026-10-23 (afc-offline bench/tools/agent-hadoopfs/hk.sh, srv.sh; 3 DataNodes,
  replication 2, SF10, one DataNode silently disconnected for 90 s): afc2 0 failures, correct results (direct DuckDB 234
  queries; int6b server 63 queries); v1.4.1 build: `Snappy decompression failure` 16 s after the loss. During the outage
  scans took 24-121 s instead of 1-4 s (repeated connect timeouts to the lost node, see next point).
- libhdfs3 forgets a failed DataNode per block (failedNodes is cleared in seekToBlock), so until the namenode marks the
  node dead (~10.5 min) every block that picks it first costs one read timeout. Upstream cb71a12 (slow-node isolation)
  may help; not evaluated.
