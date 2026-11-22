#!/bin/bash
# Builds the Linux i686 runtime bundle in Docker and packs it:
#
#   ./build-linux.sh [out dir]        (default ./out)
#
# Produces <out>/sp-python-<release>-manylinux_2_28_i686.tar.gz (+ .sha256) and <out>/logs/.
# Downloaded sources are kept in <out>/src and reused. ALLOW_UNPINNED=1 accepts sources whose
# sha256 isn't in versions.sh yet (printing it); JOBS sets the parallel build jobs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "${1:-$HERE/out}")
mkdir -p "$OUT"
docker build -q -t sp-python-build:linux-i686 "$HERE/linux" >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e ALLOW_UNPINNED -e JOBS \
    -v "$HERE:/repo:ro" -v "$OUT:/out" sp-python-build:linux-i686 /repo/linux/build.sh /repo /out
. "$HERE/versions.sh"
NAME=sp-python-$PYTHON-r$REVISION-manylinux_2_28_i686
# reproducible-ish archive: sorted, fixed owner and mtime
tar -C "$OUT" --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" && cat "$NAME.tar.gz.sha256")
