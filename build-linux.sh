#!/bin/bash
# Builds the Linux i686 runtime bundle of one Python series in Docker and packs it:
#
#   ./build-linux.sh <series> [out dir]        e.g. ./build-linux.sh 3.13   (default ./out/<series>)
#
# <series> selects versions/<series>.sh. Produces <out>/sp-python-<release>-manylinux_2_28_i686.tar.gz
# (+ .sha256) and <out>/logs/. Downloaded sources are kept in <out>/src and reused.
# ALLOW_UNPINNED=1 accepts sources whose sha256 isn't in the versions files yet (printing it);
# JOBS sets the parallel build jobs.
#
# The build runs in the manylinux image pinned in versions/common.sh, with seccomp off: its userland is
# 32-bit, and 32-bit glibc creates sockets with socketcall(2), which Docker's default seccomp
# profile refuses (at least from Docker 29.4), so dnf, curl and pip couldn't download anything.
# The packages it needs are installed first, then the build runs as the calling user.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SERIES=${1:?usage: build-linux.sh <series> [out dir]}
[ -f "$HERE/versions/$SERIES.sh" ] || { echo "no versions/$SERIES.sh" >&2; exit 2; }
OUT=$(realpath -m "${2:-$HERE/out/$SERIES}")
mkdir -p "$OUT"
# shellcheck source=versions/3.13.sh
. "$HERE/versions/$SERIES.sh"
docker run --rm --security-opt seccomp=unconfined \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e SERIES="$SERIES" -e ALLOW_UNPINNED -e JOBS \
    -v "$HERE:/repo:ro" -v "$OUT:/out" "$MANYLINUX_I686" bash -c '
        set -e
        # perl-IPC-Cmd, perl-Time-Piece: OpenSSL Configure; flex: PostgreSQL configure (libpq);
        # gcc-c++: the system GCC 8 C++ compiler, for Boost.Python (see linux/build.sh)
        dnf install -q -y perl-IPC-Cmd perl-Time-Piece flex gcc-c++ > /tmp/dnf.log 2>&1 \
            || { tail -20 /tmp/dnf.log; exit 1; }
        groupadd -o -g "$HOST_GID" builder; useradd -o -u "$HOST_UID" -g "$HOST_GID" -M -d /tmp builder
        chown "$HOST_UID:$HOST_GID" /out
        exec runuser -u builder -- env HOME=/tmp /repo/linux/build.sh /repo "$SERIES" /out'
NAME=sp-python-$PYTHON-r$REVISION-manylinux_2_28_i686
# reproducible-ish archive: sorted, fixed owner and mtime
tar -C "$OUT" --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" && cat "$NAME.tar.gz.sha256")
