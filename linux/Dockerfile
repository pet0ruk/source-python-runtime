# Linux i686 build environment: manylinux_2_28 (AlmaLinux 8, glibc 2.28, GCC 14 from gcc-toolset).
# gcc-toolset links C++ features newer than the system libstdc++ 8 statically, so the output only
# needs glibc 2.28 and libstdc++ 8's symbol versions.
FROM quay.io/pypa/manylinux_2_28_i686
# perl-IPC-Cmd, perl-Time-Piece: OpenSSL's Configure; flex: PostgreSQL's configure (libpq);
# gcc-c++: the system GCC 8 C++ compiler, for Boost.Python (see linux/build.sh)
RUN dnf install -y perl-IPC-Cmd perl-Time-Piece flex gcc-c++ && dnf clean all
WORKDIR /work
