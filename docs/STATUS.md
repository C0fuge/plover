# duckdb-hadoopfs — status

DuckDB `hadoopfs` (hdfs://) extension, rebuilt for DuckDB v1.4.5 (linux_amd64; arm64 optional) with HDFS
read-error / timeout fixes. Sources are fetched by pinned commit (see `sources.env`); only our patches live here.

## Layout
- `sources.env` — pinned upstream commits / tarballs (+ sha256)
- `patches/hadoopfs/` — patches on vincent-chang/duckdb-hdfs 51b7220
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

libhdfs3 replica failover on a DataNode read timeout: in ceb428c (used by the v1.4.1 build) a timeout while setting up the
block reader (`HdfsTimeoutException`, e.g. a pooled socket to a silently lost DataNode) was not caught as an
`HdfsIOException`, so the read failed after one timeout without trying the other replica. Fixed upstream by 94a9ead
("Fix HdfsTimeoutException not retried in setupBlockReader and EC createBlockReader"), which we pin.

## Builds
| date | run | DuckDB | arch | result | time | sha256 |
|---|---|---|---|---|---|---|
