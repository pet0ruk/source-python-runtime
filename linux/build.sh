#!/bin/bash
# Builds the Linux runtime bundle for ARCH (i686, the default, or x86_64). Runs inside the
# manylinux image for that architecture (see ../build-linux.sh):
#
#   [ARCH=...] linux/build.sh <repo dir> <series> <out dir>
#
# - CPython is configured for the image's architecture (SOABI cpython-3XX-i386-linux-gnu or
#   cpython-3XX-x86_64-linux-gnu) with --enable-shared.
# - OpenSSL, libffi, zlib, bzip2, xz and sqlite are built from source as static PIC archives and
#   linked into the extension modules, so the server needs none of them installed.
#   -Wl,--exclude-libs,ALL keeps their symbols private: srcds can already have an older system copy
#   loaded (e.g. libsqlite3.so.0 3.31 on Ubuntu 20.04), which would otherwise be bound instead.
# - plat-linux/libsqlite3.so.0 is still built and shipped, because Source.Python preloads that
#   path (packages/source-python/__init__.py setup_sqlite); _sqlite3 doesn't depend on it.
# - readline/curses/dbm/gdbm/tkinter/uuid are not built: their sonames differ between distros and a
#   server plugin doesn't need them (uuid falls back to pure Python).
# - The compiled packages are built from source as wheels and repaired with auditwheel (psycopg2
#   links a minimal libpq, which auditwheel vendors with its shared OpenSSL, as psycopg2-binary
#   does). Boost.Python is built against this interpreter's headers.
#
# Output in <out>: the bundle directory sp-python-<release>-<platform>/ and logs/.
set -euo pipefail
REPO=$(realpath "${1:?repo dir}")
SERIES=${2:?series}
OUT=$(realpath -m "${3:?out dir}")
# shellcheck source=../versions/3.13.sh
. "$REPO/versions/$SERIES.sh"
case $PYTHON in "$SERIES".*) ;; *) echo "!! versions/$SERIES.sh sets PYTHON=$PYTHON" >&2; exit 2;; esac
ARCH=${ARCH:-i686}
PLATFORM=manylinux_2_28_$ARCH
# per architecture: OpenSSL's Configure target, CPython's multiarch triplet, Boost's address-model,
# the dynamic loader's name
case $ARCH in
    i686) OSSL_TARGET=linux-x86 TRIPLET=i386-linux-gnu ADDRESS_MODEL=32 LDSO='ld-linux\.so\.2' ;;
    x86_64) OSSL_TARGET=linux-x86_64 TRIPLET=x86_64-linux-gnu ADDRESS_MODEL=64 LDSO='ld-linux-x86-64\.so\.2' ;;
    *) echo "!! ARCH must be i686 or x86_64, not $ARCH" >&2; exit 2 ;;
esac
[ "$(uname -m)" = "$ARCH" ] || { echo "!! ARCH=$ARCH, but this image is $(uname -m)" >&2; exit 2; }
M="-m$ADDRESS_MODEL"
PYV=${PYTHON%.*}                       # 3.13
PYN=${PYV/./}                          # 313
RELEASE=$PYTHON-r$REVISION
NAME=sp-python-$RELEASE-$PLATFORM
JOBS=${JOBS:-$(nproc)}

SRC=$OUT/src L=$OUT/logs/$ARCH B=$OUT/$NAME
D=/tmp/deps DP=/tmp/pq P=/tmp/python W=/tmp/w
rm -rf "$B" "$L" "$D" "$DP" "$P" "$W"
mkdir -p "$SRC" "$L" "$D" "$W"
cd "$W"
export CFLAGS="-O2 -fPIC" PKG_CONFIG_PATH=$D/lib/pkgconfig

# fetch <url> <file> <sha256 var name>: download once into $SRC, verify, unpack into $W.
fetch() {
    local url=$1 file=$2 var=$3 want sum
    want=${!var}
    if [ ! -f "$SRC/$file" ]; then
        curl -fsSL --retry 3 -o "$SRC/$file.part" "$url" && mv "$SRC/$file.part" "$SRC/$file"
    fi
    sum=$(sha256sum "$SRC/$file" | cut -d' ' -f1)
    if [ -z "$want" ]; then
        [ "${ALLOW_UNPINNED:-}" = 1 ] || { echo "!! $var is not set in versions/ ($file: $sum)" >&2; exit 1; }
        echo "   $var=$sum   (unpinned)"
    elif [ "$sum" != "$want" ]; then
        echo "!! $file: sha256 $sum, expected $want ($var)" >&2; exit 1
    fi
    tar -xf "$SRC/$file"
}
echo ">> sources"
fetch "https://www.python.org/ftp/python/$PYTHON/Python-$PYTHON.tar.xz" "Python-$PYTHON.tar.xz" PYTHON_SHA256
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" "openssl-$OPENSSL.tar.gz" OPENSSL_SHA256
fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI/libffi-$LIBFFI.tar.gz" "libffi-$LIBFFI.tar.gz" LIBFFI_SHA256
fetch "https://github.com/madler/zlib/releases/download/v$ZLIB/zlib-$ZLIB.tar.gz" "zlib-$ZLIB.tar.gz" ZLIB_SHA256
fetch "https://sourceware.org/pub/bzip2/bzip2-$BZIP2.tar.gz" "bzip2-$BZIP2.tar.gz" BZIP2_SHA256
fetch "https://github.com/tukaani-project/xz/releases/download/v$XZ/xz-$XZ.tar.gz" "xz-$XZ.tar.gz" XZ_SHA256
fetch "https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE.tar.gz" "sqlite-autoconf-$SQLITE.tar.gz" SQLITE_SHA256
fetch "https://ftp.postgresql.org/pub/source/v$POSTGRESQL/postgresql-$POSTGRESQL.tar.bz2" "postgresql-$POSTGRESQL.tar.bz2" POSTGRESQL_SHA256
fetch "https://archives.boost.io/release/$BOOST/source/boost_${BOOST//./_}.tar.gz" "boost_${BOOST//./_}.tar.gz" BOOST_SHA256

echo ">> openssl $OPENSSL"
# openssldir /etc/ssl: CA lookup in /etc/ssl/certs (Debian/Ubuntu/Arch); SSL_CERT_FILE/DIR override.
(cd "openssl-$OPENSSL" && ./Configure $OSSL_TARGET no-shared no-tests no-docs -fPIC --prefix=$D \
    --libdir=lib --openssldir=/etc/ssl && make -j"$JOBS" && make install_sw) > "$L/openssl.log" 2>&1
# A second, shared OpenSSL for libpq only: libpq's build rejects a static libcrypto (it contains
# pthread_exit). auditwheel vendors these .so files into psycopg2's wheel.
mkdir -p "$W/ossl-shared" && tar -C "$W/ossl-shared" -xf "$SRC/openssl-$OPENSSL.tar.gz"
(cd "$W/ossl-shared/openssl-$OPENSSL" && ./Configure $OSSL_TARGET shared no-tests no-docs --prefix=$DP \
    --libdir=lib --openssldir=/etc/ssl && make -j"$JOBS" && make install_sw) > "$L/openssl-shared.log" 2>&1
echo ">> libffi $LIBFFI"
(cd "libffi-$LIBFFI" && ./configure --prefix=$D --libdir=$D/lib --disable-shared --enable-static \
    --with-pic --disable-docs && make -j"$JOBS" && make install) > "$L/libffi.log" 2>&1
echo ">> zlib $ZLIB"
(cd "zlib-$ZLIB" && ./configure --prefix=$D --static && make -j"$JOBS" && make install) > "$L/zlib.log" 2>&1
echo ">> bzip2 $BZIP2"
(cd "bzip2-$BZIP2" && make -j"$JOBS" libbz2.a CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64" \
    && install -D -m644 libbz2.a $D/lib/libbz2.a && install -D -m644 bzlib.h $D/include/bzlib.h) > "$L/bzip2.log" 2>&1
echo ">> xz $XZ"
(cd "xz-$XZ" && ./configure --prefix=$D --disable-shared --enable-static --with-pic --disable-xz \
    --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc \
    && make -j"$JOBS" && make install) > "$L/xz.log" 2>&1
echo ">> sqlite $SQLITE"
(cd "sqlite-autoconf-$SQLITE" && ./configure --prefix=$D --enable-static --disable-shared \
    --disable-readline && make -j"$JOBS" && make install) > "$L/sqlite.log" 2>&1
# The shipped libsqlite3.so.0. --soname=legacy: without it sqlite >= 3.48 builds an unversioned
# libsqlite3.so.
mkdir -p "$W/sqlite-so" && tar -C "$W/sqlite-so" -xf "$SRC/sqlite-autoconf-$SQLITE.tar.gz"
# Our static zlib (in $D/lib, searched first), so it doesn't need the system's libz.so.1.
(cd "$W/sqlite-so/sqlite-autoconf-$SQLITE" && ./configure --prefix=/tmp/sqlite-so --disable-static \
    --enable-shared --disable-readline --soname=legacy CPPFLAGS="-I$D/include" \
    LDFLAGS="-L$D/lib -Wl,-z,noexecstack -Wl,--exclude-libs,ALL" \
    && make -j"$JOBS" && make install) > "$L/sqlite-shared.log" 2>&1

echo ">> libpq $POSTGRESQL (minimal: shared OpenSSL, no gssapi/ldap/readline/icu)"
(cd "postgresql-$POSTGRESQL" && ./configure --prefix=$DP --with-ssl=openssl --without-readline \
    --without-icu --without-gssapi --without-ldap --without-zlib --without-zstd --without-lz4 \
    CPPFLAGS="-I$DP/include" LDFLAGS="-L$DP/lib -Wl,-rpath,$DP/lib" \
    && make -C src/include install && make -C src/common install && make -C src/port install \
    && make -C src/interfaces/libpq install && make -C src/bin/pg_config install) > "$L/libpq.log" 2>&1

echo ">> cpython $PYTHON"
cd "$W/Python-$PYTHON"
# pkg-config --static so libcrypto's -ldl/-pthread come along with the static archives
# CFLAGS_NODIST (used for Python itself and its lib-dynload modules, not recorded in sysconfig for
# extensions built later): the initial-exec TLS model, so the interpreter reads its thread-local
# state (_Py_tss_tstate, read on every allocation) directly instead of calling ___tls_get_addr.
# libpython is dlopen()ed by the loader, where general-dynamic TLS costs a call per access, and
# glibc >= 2.39's i386 ___tls_get_addr saves and restores the extended register state
# (xsavec/xrstor) on every call: that made Python 5-10x slower in srcds on current distributions.
# The TLS block (16 bytes) comes from the static TLS that glibc reserves for dlopen()ed libraries.
# The same model is used on x86_64, where __tls_get_addr is cheaper but still a call per access.
./configure --enable-shared --prefix=$P --with-ensurepip=install --with-openssl=$D \
    PKG_CONFIG="pkg-config --static" CPPFLAGS="-I$D/include" CFLAGS_NODIST="-ftls-model=initial-exec" \
    LDFLAGS="-L$D/lib -Wl,-z,noexecstack -Wl,--exclude-libs,ALL" \
    py_cv_module__tkinter=n/a py_cv_module__curses=n/a py_cv_module__curses_panel=n/a \
    py_cv_module_readline=n/a py_cv_module__dbm=n/a py_cv_module__gdbm=n/a py_cv_module__uuid=n/a \
    > "$L/configure.log" 2>&1
make -j"$JOBS" > "$L/make.log" 2>&1 || { tail -50 "$L/make.log"; exit 1; }
grep -E -A6 'necessary bits|failed to build|Failed to build' "$L/make.log" || true
make install > "$L/install.log" 2>&1
# The initial-exec model must have reached libpython: no ___tls_get_addr calls, and STATIC_TLS set.
# (i386: ___tls_get_addr, x86_64: __tls_get_addr)
calls=$(objdump -d "$P/lib/libpython$PYV.so.1.0" | grep -c '__tls_get_addr' || true)
[ "$calls" = 0 ] || { echo "!! libpython calls __tls_get_addr $calls times" >&2; exit 1; }
readelf -d "$P/lib/libpython$PYV.so.1.0" | grep -q STATIC_TLS || { echo "!! libpython: no STATIC_TLS flag" >&2; exit 1; }
PYBIN=$P/bin/python$PYV
export LD_LIBRARY_PATH=$P/lib
SOABI=$($PYBIN -c 'import sysconfig; print(sysconfig.get_config_var("SOABI"))')
$PYBIN -c 'import sys, ssl, ctypes, sqlite3, zlib, lzma, bz2, hashlib, _ctypes
print(sys.version); print(ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version, "| zlib", zlib.ZLIB_RUNTIME_VERSION)'

echo ">> boost.python $BOOST (system GCC 8)"
# Boost.Python is a static library that Source.Python links with its own compiler. Built with
# gcc-toolset's GCC 14 it references libstdc++ symbols newer than GCC 9 provides (e.g.
# std::__throw_bad_array_new_length, from libstdc++_nonshared.a), which core.so then needs from
# the server's libstdc++ (GCC >= 11). The system GCC 8 needs only libstdc++ 8's.
cd "$W/boost_${BOOST//./_}"
./bootstrap.sh --with-toolset=gcc > "$L/boost-bootstrap.log" 2>&1
# Boost.Python only needs the headers; nothing is executed when the include and lib dirs are given.
{ echo "using gcc : : /usr/bin/g++ ;"
  echo "using python : $PYV : /usr/bin/false : $P/include/python$PYV : $P/lib ;"; } > user-config.jam
./b2 --user-config=user-config.jam -j"$JOBS" -q toolset=gcc address-model=$ADDRESS_MODEL architecture=x86 \
    link=static runtime-link=shared threading=multi variant=release visibility=hidden \
    cxxflags="$M -fPIC" cflags="$M -fPIC" linkflags=$M \
    python="$PYV" libs/python/build//boost_python > "$L/boost.log" 2>&1 \
    || { tail -40 "$L/boost.log"; exit 1; }
# Only that target: `--with-python stage` also builds what Boost.Python's tests need (Boost.Math,
# Container, Serialization, ... since Boost's modular build), and GCC 8 crashes on Boost.Math.
BOOST_PY_A=$(find "$PWD/bin.v2/libs/python" -name "libboost_python$PYN.a")
[ "$(wc -l <<<"$BOOST_PY_A")" = 1 ] && [ -f "$BOOST_PY_A" ] || { echo "!! libboost_python$PYN.a: $BOOST_PY_A" >&2; exit 1; }
{ strings -a "$BOOST_PY_A" | grep '^GCC: ' | sort -u; } || true

echo ">> wheels: greenlet $GREENLET, psycopg2 $PSYCOPG2, markupsafe $MARKUPSAFE, charset-normalizer $CHARSET_NORMALIZER, sqlalchemy $SQLALCHEMY"
mkdir -p "$W/wheels" "$W/repaired" "$W/site"
# CHARSET_NORMALIZER_USE_CYTHON: the compiled (Cython, since 3.5) build, as published on PyPI;
# REQUIRE_SQLALCHEMY_CEXT: fail instead of falling back to pure Python without its extensions.
# LDFLAGS: libstdc++/libgcc linked statically and kept private, so the C++ ones (greenlet) don't
# depend on the server's libstdc++: some games ship an old one in bin/ that srcds puts first on
# the library path (L4D2: no CXXABI_1.3.7).
PATH=$DP/bin:$PATH CHARSET_NORMALIZER_USE_CYTHON=1 REQUIRE_SQLALCHEMY_CEXT=1 HOME=$W \
    LDFLAGS="-static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL -Wl,-z,noexecstack" \
    $PYBIN -m pip -q wheel --no-deps \
    --no-binary :all: -w "$W/wheels" "greenlet==$GREENLET" "psycopg2==$PSYCOPG2" \
    "markupsafe==$MARKUPSAFE" "charset-normalizer==$CHARSET_NORMALIZER" "sqlalchemy==$SQLALCHEMY" \
    > "$L/wheels.log" 2>&1 \
    || { tail -30 "$L/wheels.log"; exit 1; }
for w in "$W"/wheels/*.whl; do
    LD_LIBRARY_PATH=$DP/lib:$P/lib auditwheel repair --plat "$PLATFORM" -w "$W/repaired" "$w" >> "$L/auditwheel.log" 2>&1
done
for w in "$W"/repaired/*.whl; do $PYBIN -m zipfile -e "$w" "$W/site"; done

echo ">> bundle $NAME"
R=$B/runtime/addons/source-python/Python3
S=$B/runtime/addons/source-python/packages/site-packages
mkdir -p "$B/build/lib" "$B/build/include" "$R/plat-linux" "$S" "$B/licenses"
# build/: what compiling Source.Python needs
cp -a "$P/include/python$PYV" "$B/build/include/"
cp -L "$P/lib/libpython$PYV.so.1.0" "$P/lib/python$PYV/config-$PYV-$TRIPLET/libpython$PYV.a" "$B/build/lib/"
cp "$BOOST_PY_A" "$B/build/lib/"
# all of Boost's headers (header-only, so they match Boost.Python above by construction);
# Source.Python uses other Boost libraries besides Boost.Python
cp -a "$W/boost_${BOOST//./_}/boost" "$B/build/include/"
# runtime/: laid over the Source.Python tree. The stdlib without the parts a server doesn't use
# (the same selection Source.Python has always shipped).
(cd "$P/lib/python$PYV" && tar -c --exclude=__pycache__ --exclude='./test' --exclude='./idlelib' \
    --exclude='./tkinter' --exclude='./turtledemo' --exclude='./curses' --exclude='./site-packages' \
    --exclude="./config-$PYV-*" --exclude='./lib-dynload' --exclude='./_sysconfigdata_*' .) | tar -x -C "$R"
cp -a "$P/lib/python$PYV/lib-dynload" "$R/"
rm -f "$R"/lib-dynload/*_test*.so "$R"/lib-dynload/xx*.so
cp "$P/lib/python$PYV/_sysconfigdata__linux_$TRIPLET.py" "$S/"
cp -L "$P/lib/libpython$PYV.so.1.0" "$R/plat-linux/"
cp -L /tmp/sqlite-so/lib/libsqlite3.so.0 "$R/plat-linux/"
cp -a "$W"/site/{greenlet,psycopg2,markupsafe,charset_normalizer,sqlalchemy} "$S/"
cp -a "$W"/site/*.libs "$S/" 2>/dev/null || true
rm -rf "$S/greenlet/tests"
# build-time rpaths (/tmp/...) must not leak into the shipped files (the wheels' rpaths were
# already rewritten by auditwheel to point at their vendored libraries)
find "$R" "$B/build" -name '*.so*' -type f | while read -r f; do patchelf --remove-rpath "$f"; done
cp "$W/Python-$PYTHON/LICENSE" "$B/licenses/cpython.txt"
cp "$W/openssl-$OPENSSL/LICENSE.txt" "$B/licenses/openssl.txt"
cp "$W/libffi-$LIBFFI/LICENSE" "$B/licenses/libffi.txt"
cp "$W/zlib-$ZLIB/LICENSE" "$B/licenses/zlib.txt"
cp "$W/bzip2-$BZIP2/LICENSE" "$B/licenses/bzip2.txt"
cp "$W/xz-$XZ/COPYING" "$B/licenses/xz.txt"
cp "$W/postgresql-$POSTGRESQL/COPYRIGHT" "$B/licenses/postgresql.txt"
cp "$W/boost_${BOOST//./_}/LICENSE_1_0.txt" "$B/licenses/boost.txt"

cat > "$B/manifest.txt" <<EOF
release=$RELEASE
platform=$PLATFORM
python=$PYTHON
python_abi=$PYV
soabi=$SOABI
libpython=libpython$PYV.so.1.0
boost=$BOOST
boost_include=build/include
openssl=$OPENSSL
libffi=$LIBFFI
zlib=$ZLIB
bzip2=$BZIP2
xz=$XZ
sqlite=$SQLITE
postgresql=$POSTGRESQL
greenlet=$GREENLET
psycopg2=$PSYCOPG2
markupsafe=$MARKUPSAFE
charset_normalizer=$CHARSET_NORMALIZER
sqlalchemy=$SQLALCHEMY
EOF

echo ">> checks"
# every shipped ELF: glibc <= 2.28, libstdc++ 8's symbol versions, no executable stack
find "$B" -type f \( -name '*.so' -o -name '*.so.*' \) | sort | xargs python3 "$REPO/tools/symver.py" \
    --max-glibc 2.28 --max-glibcxx 3.4.25 > "$L/symver.txt" || { grep -B0 'limit\|EXECSTACK' "$L/symver.txt"; exit 1; }
# only system libraries (or our own) may be NEEDED; not libstdc++/libgcc_s, which are linked in
find "$B" -type f \( -name '*.so' -o -name '*.so.*' \) | sort | while read -r f; do
    readelf -dW "$f" | awk -v f="${f#"$B"/}" '/NEEDED/ {gsub(/[][]/, "", $5); print f, $5}'
done > "$L/needed.txt"
if grep -vE " (libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libutil\.so\.1|$LDSO|libpython[0-9.]+\.so\.1\.0|lib(pq|ssl|crypto)-[0-9a-f]+\.so[.0-9]*)\$" "$L/needed.txt"; then
    echo "!! unexpected NEEDED libraries (above)" >&2; exit 1
fi
# the shipped runtime imports its native modules and packages from the bundle alone
# test-only: sqlalchemy imports typing_extensions, which Source.Python vendors as pure Python
HOME=$W "$PYBIN" -m pip -q install --no-deps --target "$W/testdeps" typing_extensions==$TYPING_EXTENSIONS > "$L/testdeps.log" 2>&1
LD_LIBRARY_PATH=$R/plat-linux "$PYBIN" -I -S -B -c '
import sys
b = sys.argv[1]
r = b + "/runtime/addons/source-python/Python3"
sys.path[:] = [r, r + "/lib-dynload", b + "/runtime/addons/source-python/packages/site-packages", sys.argv[2]]
import ssl, ctypes, sqlite3, zlib, lzma, bz2, hashlib, json, decimal
import greenlet, psycopg2, markupsafe, charset_normalizer.md, sqlalchemy.cyextension.collections
assert markupsafe._speedups and greenlet._greenlet
assert charset_normalizer.md.__file__.endswith(".so"), charset_normalizer.md.__file__
assert sqlalchemy.cyextension.collections.__file__.endswith(".so")
for m in (ssl, sqlite3, greenlet, psycopg2, markupsafe, sqlalchemy):
    assert m.__file__.startswith(b), (m.__name__, m.__file__)
print("   imports ok:", ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version, "| psycopg2", psycopg2.__version__)' "$B" "$W/testdeps" 2>&1 | tee "$L/imports.txt"
du -sh "$B"
