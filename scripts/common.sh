# shared by build-deps.sh / build-ext.sh (bash, inside quay.io/pypa/manylinux_2_28_<arch>)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$HERE/sources.env"
J=${JOBS:-$(nproc)}
PREFIX=${DEPS_PREFIX:-/opt/deps}
WORK=${WORK_DIR:-/build}
POL=-DCMAKE_POLICY_VERSION_MINIMUM=3.5
log() { echo "==> $(date +%H:%M:%S) $*"; }
# git_at <repo> <commit-or-tag> <dir>: shallow fetch of one commit
git_at() {
  rm -rf "$3"; git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
}
fetch() { # fetch <url> <sha256> <file>
  curl -sSfL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}
