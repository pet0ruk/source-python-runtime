#!/bin/bash
# Builds the Windows runtime bundle of one Python series and packs it. Runs in Git Bash on Windows
# (CI: windows-2022) and needs Visual Studio with the C++ desktop workload (v143) and any Python 3
# (only to unpack the CPython package; everything else runs with that interpreter).
#
#   [ARCH=win32|win_amd64] ./build-windows.sh <series> [out dir]   e.g. ./build-windows.sh 3.13
#                                                                  (default ARCH win32, out ./out/<series>)
#
# Produces <out>/sp-python-<release>-<ARCH>.zip (+ .sha256) and <out>/logs/<ARCH>/.
#
# - CPython is the official build (NuGet package pythonx86 for win32, python for win_amd64, sha256
#   pinned in the series file): python313.dll, its DLLs/ (.pyd extension modules, OpenSSL, libffi,
#   sqlite), the stdlib, headers and import libraries. Nothing of CPython is compiled here.
# - Boost.Python is built against it with MSVC, statically and with the static C runtime
#   (runtime-link=static, i.e. /MT, as Source.Python's Windows build links), using the oldest
#   supported toolset (v143, Visual Studio 2022): newer MSVC versions link v143 libraries, not
#   the other way round.
# - markupsafe, charset-normalizer and sqlalchemy come from their official wheels;
#   greenlet has none and is built from source.
# - psycopg2 is built from source against a minimal libpq (PostgreSQL's meson build, only libpq)
#   that links CPython's own OpenSSL build; delvewheel vendors libpq.dll and those OpenSSL DLLs into
#   the wheel under mangled names, as psycopg2's official wheels do (and auditwheel on Linux). They
#   end up next to _psycopg.pyd, so psycopg2's Python files are the same as on Linux.
#   Needs Strawberry Perl (on the CI image) for PostgreSQL's build.
# - As on Linux, the stdlib is shipped without the parts a server doesn't use (test, idlelib,
#   tkinter, turtledemo, ...); the package already omits Tcl/Tk and CPython's test modules.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SERIES=${1:?usage: build-windows.sh <series> [out dir]}
[ -f "$HERE/versions/$SERIES.sh" ] || { echo "no versions/$SERIES.sh" >&2; exit 2; }
OUT=$(realpath -m "${2:-$HERE/out/$SERIES}")
# shellcheck source=versions/3.13.sh
. "$HERE/versions/$SERIES.sh"
case $PYTHON in "$SERIES".*) ;; *) echo "!! versions/$SERIES.sh sets PYTHON=$PYTHON" >&2; exit 2;; esac
PLATFORM=${ARCH:-win32}
# per architecture: the NuGet package and its pinned sha256, Boost's address-model and library tag
case $PLATFORM in
    win32) NUGET=pythonx86 NUGET_SHA256_VAR=PYTHON_WIN32_SHA256 ADDRESS_MODEL=32 ;;
    win_amd64) NUGET=python NUGET_SHA256_VAR=PYTHON_WIN_AMD64_SHA256 ADDRESS_MODEL=64 ;;
    *) echo "!! ARCH must be win32 or win_amd64, not $PLATFORM" >&2; exit 2 ;;
esac
PYV=${PYTHON%.*}                       # 3.13
PYN=${PYV/./}                          # 313
RELEASE=$PYTHON-r$REVISION
NAME=sp-python-$RELEASE-$PLATFORM
BOOSTN=boost_${BOOST//./_}
BOOST_TAG=${BOOST%.*}; BOOST_TAG=${BOOST_TAG/./_}      # 1_87
TOOLSET=msvc-14.3

SRC=$OUT/src L=$OUT/logs/$PLATFORM B=$OUT/$NAME W=$OUT/work-$PLATFORM
rm -rf "$B" "$L" "$W" "$OUT/$NAME.zip" "$OUT/$NAME.zip.sha256"
mkdir -p "$SRC" "$L" "$W"

fetch() {   # fetch <url> <file> <sha256 var name>
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
}
echo ">> sources"
fetch "https://api.nuget.org/v3-flatcontainer/$NUGET/$PYTHON/$NUGET.$PYTHON.nupkg" "$NUGET.$PYTHON.nupkg" "$NUGET_SHA256_VAR"
fetch "https://archives.boost.io/release/$BOOST/source/$BOOSTN.tar.gz" "$BOOSTN.tar.gz" BOOST_SHA256
fetch "https://ftp.postgresql.org/pub/source/v$POSTGRESQL/postgresql-$POSTGRESQL.tar.bz2" "postgresql-$POSTGRESQL.tar.bz2" POSTGRESQL_SHA256
fetch "https://github.com/python/cpython-bin-deps/archive/refs/tags/openssl-bin-$CPYTHON_OPENSSL_BIN.tar.gz" "cpython-openssl-bin-$CPYTHON_OPENSSL_BIN.tar.gz" CPYTHON_OPENSSL_BIN_SHA256
fetch "https://github.com/lexxmark/winflexbison/releases/download/v$WINFLEXBISON/win_flex_bison-$WINFLEXBISON.zip" "win_flex_bison-$WINFLEXBISON.zip" WINFLEXBISON_SHA256

echo ">> python $PYTHON ($NUGET)"
P=$W/python
mkdir -p "$P"
# unzip with any Python on the runner (the package itself is a zip)
PY_HOST=$(command -v python3 || command -v python)
"$PY_HOST" -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$SRC/$NUGET.$PYTHON.nupkg" "$W/nupkg"
mv "$W/nupkg/tools"/* "$P/"
PYBIN=$P/python.exe
"$PYBIN" -c 'import sys, ssl, sqlite3, ctypes, sysconfig
print(sys.version); print(ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version, "|", sysconfig.get_platform())'
# the interpreter must be the architecture asked for (sysconfig: win32 / win-amd64)
[ "$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_platform().replace("-", "_"))')" = "$PLATFORM" ] \
    || { echo "!! $NUGET is not a $PLATFORM interpreter" >&2; exit 1; }
SOABI=$("$PYBIN" -c 'import sys, sysconfig; print(sysconfig.get_config_var("SOABI") or "cp" + sysconfig.get_config_var("py_version_nodot") + "-" + sys.argv[1])' "$PLATFORM")

echo ">> boost.python $BOOST ($TOOLSET)"
tar -C "$W" -xzf "$SRC/$BOOSTN.tar.gz"
cd "$W/$BOOSTN"
cmd //c bootstrap.bat > "$L/boost-bootstrap.log" 2>&1 || { tail -30 "$L/boost-bootstrap.log"; exit 1; }
PW=$(cygpath -m "$P")
echo "using python : $PYV : $PW/python.exe : $PW/include : $PW/libs ;" > user-config.jam
./b2.exe --user-config=user-config.jam -j"${JOBS:-$(nproc)}" -q toolset=$TOOLSET address-model=$ADDRESS_MODEL \
    architecture=x86 link=static runtime-link=static threading=multi variant=release \
    python="$PYV" libs/python/build//boost_python > "$L/boost.log" 2>&1 \
    || { tail -40 "$L/boost.log"; exit 1; }
# Only that target, as on Linux (`--with-python stage` also builds what Boost.Python's tests need).
BOOST_LIB=libboost_python$PYN-vc143-mt-s-x$ADDRESS_MODEL-$BOOST_TAG.lib
BOOST_PY_LIB=$(find "$PWD/bin.v2/libs/python" -name "$BOOST_LIB")
[ "$(wc -l <<<"$BOOST_PY_LIB")" = 1 ] && [ -f "$BOOST_PY_LIB" ] || { echo "!! $BOOST_LIB: $BOOST_PY_LIB" >&2; exit 1; }
cd "$HERE"

echo ">> wheels: greenlet $GREENLET (source), markupsafe $MARKUPSAFE, charset-normalizer $CHARSET_NORMALIZER, sqlalchemy $SQLALCHEMY"
WH=$W/wheels SITE=$W/site
mkdir -p "$WH" "$SITE"
"$PYBIN" -m pip -q download --no-deps --only-binary :all: -d "$WH" \
    "markupsafe==$MARKUPSAFE" "charset-normalizer==$CHARSET_NORMALIZER" "sqlalchemy==$SQLALCHEMY" \
    > "$L/wheels.log" 2>&1 || { tail -30 "$L/wheels.log"; exit 1; }
"$PYBIN" -m pip -q wheel --no-deps --no-binary :all: -w "$WH" "greenlet==$GREENLET" \
    >> "$L/wheels.log" 2>&1 || { tail -30 "$L/wheels.log"; exit 1; }
for w in "$WH"/*.whl; do
    case $w in *-cp$PYN-cp$PYN-$PLATFORM.whl) ;; *) echo "!! not a cp$PYN $PLATFORM wheel: $w" >&2; exit 1;; esac
    "$PYBIN" -m zipfile -e "$w" "$SITE"
done

echo ">> libpq $POSTGRESQL (minimal: CPython's OpenSSL $CPYTHON_OPENSSL_BIN, no gssapi/ldap/icu/zlib)"
case $PLATFORM in win32) VCVARS_ARCH=x86 OSSL_ARCH=win32 ;; *) VCVARS_ARCH=amd64 OSSL_ARCH=amd64 ;; esac
"$PYBIN" -I -m tarfile -e "$SRC/postgresql-$POSTGRESQL.tar.bz2" "$W"
"$PYBIN" -I -m tarfile -e "$SRC/cpython-openssl-bin-$CPYTHON_OPENSSL_BIN.tar.gz" "$W"
"$PYBIN" -I -m zipfile -e "$SRC/win_flex_bison-$WINFLEXBISON.zip" "$W/winflexbison"
OSSL=$W/cpython-bin-deps-openssl-bin-$CPYTHON_OPENSSL_BIN/$OSSL_ARCH
# libpq links exactly the OpenSSL that CPython's package ships
for f in libssl-3.dll libcrypto-3.dll; do
    cmp -s "$OSSL/$f" "$P/DLLs/$f" || { echo "!! $f of openssl-bin-$CPYTHON_OPENSSL_BIN differs from CPython $PYTHON's (CPYTHON_OPENSSL_BIN must follow PYTHON)" >&2; exit 1; }
done
"$PYBIN" -m pip -q install "meson==$MESON" "ninja==$NINJA" "delvewheel==$DELVEWHEEL" > "$L/tools.log" 2>&1 \
    || { tail -30 "$L/tools.log"; exit 1; }
PERL_EXE=/c/Strawberry/perl/bin/perl.exe
[ -x "$PERL_EXE" ] || { echo "!! Strawberry Perl not found at $PERL_EXE" >&2; exit 1; }
VS=$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' \
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')
[ -n "$VS" ] || { echo "!! no Visual Studio with the C++ tools found" >&2; exit 1; }
PG=$W/postgresql-$POSTGRESQL
# cmd.exe in the Visual Studio environment for the target architecture; --auto-features=disabled
# leaves out every optional dependency, then only OpenSSL is enabled; only the libpq target is built
win() { cygpath -w "$1"; }
printf '%s\r\n' '@echo off' \
    "call \"$VS\\VC\\Auxiliary\\Build\\vcvarsall.bat\" $VCVARS_ARCH >nul || exit /b 1" \
    "set PATH=$(win "$P/Scripts");%PATH%" \
    "cd /d \"$(win "$PG")\" || exit /b 1" \
    "meson setup build --buildtype=release --auto-features=disabled -Dssl=openssl -Dextra_include_dirs=\"$(win "$OSSL/include")\" -Dextra_lib_dirs=\"$(win "$OSSL")\" -DPERL=\"$(win "$PERL_EXE")\" -DFLEX=\"$(win "$W/winflexbison/win_flex.exe")\" -DBISON=\"$(win "$W/winflexbison/win_bison.exe")\" || exit /b 1" \
    'meson compile -C build src/interfaces/libpq/libpq:shared_library || (meson introspect build --targets > build\targets.json & exit /b 1)' \
    > "$W/libpq.bat"
cmd //c "$(win "$W/libpq.bat")" > "$L/libpq.log" 2>&1 || { tail -40 "$L/libpq.log"; cp "$PG/build/meson-logs/meson-log.txt" "$L/" 2>/dev/null || true; exit 1; }
cp "$PG/build/meson-logs/meson-log.txt" "$L/"
PQLIB=$W/libpq/lib PQINC=$W/libpq/include
mkdir -p "$PQLIB" "$PQINC/libpq"
cp "$PG/build/src/interfaces/libpq/libpq.dll" "$PG/build/src/interfaces/libpq/libpq.lib" "$PQLIB/"
cp "$PG/src/interfaces/libpq/libpq-fe.h" "$PG/src/interfaces/libpq/libpq-events.h" "$PG/src/include/postgres_ext.h" \
    "$PG/build/src/include/pg_config.h" "$PG/build/src/include/pg_config_ext.h" "$PQINC/"
cp "$PG/src/include/libpq/libpq-fs.h" "$PQINC/libpq/"
# psycopg2's setup.py asks pg_config for these paths only; this stands in for it (as psycopg2's own
# Windows wheel build does)
printf '%s\r\n' '@echo off' \
    "if \"%1\"==\"--libdir\" (echo $(win "$PQLIB")& exit /b 0)" \
    "if \"%1\"==\"--includedir\" (echo $(win "$PQINC")& exit /b 0)" \
    "if \"%1\"==\"--includedir-server\" (echo $(win "$PQINC")& exit /b 0)" \
    "if \"%1\"==\"--version\" (echo PostgreSQL $POSTGRESQL& exit /b 0)" \
    'if "%1"=="--ldflags" (echo.& exit /b 0)' \
    'if "%1"=="--cppflags" (echo.& exit /b 0)' \
    'exit /b 1' > "$W/libpq/pg_config.bat"

echo ">> psycopg2 $PSYCOPG2 (source)"
"$PYBIN" -m pip -q download --no-deps --no-binary :all: -d "$W/psycopg2-sdist" "psycopg2==$PSYCOPG2" > "$L/psycopg2.log" 2>&1 \
    || { tail -30 "$L/psycopg2.log"; exit 1; }
"$PYBIN" -I -m tarfile -e "$W/psycopg2-sdist/psycopg2-$PSYCOPG2.tar.gz" "$W/psycopg2-sdist"
PSRC=$W/psycopg2-sdist/psycopg2-$PSYCOPG2
sed -i "s|^pg_config *=.*|pg_config = $(win "$W/libpq/pg_config.bat" | sed 's/\\/\\\\/g')|" "$PSRC/setup.cfg"
grep -q '^pg_config = .*pg_config.bat' "$PSRC/setup.cfg" || { echo "!! setup.cfg: pg_config not set" >&2; exit 1; }
"$PYBIN" -m pip -q wheel --no-deps -w "$W/psycopg2-wheel" "$(win "$PSRC")" >> "$L/psycopg2.log" 2>&1 \
    || { tail -30 "$L/psycopg2.log"; exit 1; }
"$PYBIN" -m delvewheel repair --add-path "$(win "$PQLIB");$(win "$OSSL")" -w "$(win "$WH")" \
    "$(win "$(ls "$W"/psycopg2-wheel/psycopg2-*.whl)")" >> "$L/psycopg2.log" 2>&1 \
    || { tail -30 "$L/psycopg2.log"; exit 1; }
"$PYBIN" -m zipfile -e "$(ls "$WH"/psycopg2-*.whl)" "$SITE"
# delvewheel puts the DLLs in psycopg2.libs and patches psycopg2/__init__.py to add that directory
# with os.add_dll_directory. Source.Python's release zips hold one copy of each file for Linux and
# Windows, so keep psycopg2's own __init__.py (the one Linux has) and put the DLLs next to
# _psycopg.pyd instead: Windows looks for an extension module's DLLs in its own directory.
ls "$SITE"/psycopg2.libs
mv "$SITE"/psycopg2.libs/*.dll "$SITE/psycopg2/"
rmdir "$SITE/psycopg2.libs"
cp "$PSRC/lib/__init__.py" "$SITE/psycopg2/__init__.py"

echo ">> bundle $NAME"
R=$B/runtime/addons/source-python/Python3
S=$B/runtime/addons/source-python/packages/site-packages
mkdir -p "$B/build/lib" "$B/build/include" "$R/plat-win" "$S" "$B/licenses"
# build/: what compiling Source.Python needs
cp -r "$P/include" "$B/build/include/python$PYV"
cp "$P/libs/python$PYN.lib" "$P/libs/python3.lib" "$B/build/lib/"
cp "$BOOST_PY_LIB" "$B/build/lib/"
# all of Boost's headers (header-only, so they match Boost.Python above by construction);
# Source.Python uses other Boost libraries besides Boost.Python
cp -r "$W/$BOOSTN/boost" "$B/build/include/"
# runtime/: laid over the Source.Python tree. Lib/ minus what a server doesn't use, as on Linux.
(cd "$P/Lib" && tar -c --exclude=__pycache__ --exclude='./test' --exclude='./idlelib' \
    --exclude='./tkinter' --exclude='./turtledemo' --exclude='./curses' --exclude='./site-packages' \
    --exclude='./ensurepip/_bundled' .) | tar -x -C "$R"
cp "$P"/DLLs/*.pyd "$P"/DLLs/*.dll "$R/plat-win/"
cp "$P/python$PYN.dll" "$P/python3.dll" "$P/vcruntime140.dll" "$R/plat-win/"
# x64 builds also need vcruntime140_1.dll (C++ exception handling)
[ "$PLATFORM" = win32 ] || cp "$P/vcruntime140_1.dll" "$R/plat-win/"
cp -r "$SITE"/{greenlet,psycopg2,markupsafe,charset_normalizer,sqlalchemy} "$S/"
rm -rf "$S/greenlet/tests"
cp "$P/LICENSE.txt" "$B/licenses/cpython.txt"
cp "$W/$BOOSTN/LICENSE_1_0.txt" "$B/licenses/boost.txt"
cp "$PG/COPYRIGHT" "$B/licenses/postgresql.txt"
cp "$OSSL/LICENSE.txt" "$B/licenses/openssl.txt"

cat > "$B/manifest.txt" <<EOF
release=$RELEASE
platform=$PLATFORM
python=$PYTHON
python_abi=$PYV
soabi=$SOABI
libpython=python$PYN.dll
python_lib=python$PYN.lib
boost=$BOOST
boost_include=build/include
boost_python_lib=$BOOST_LIB
toolset=$TOOLSET
openssl=$CPYTHON_OPENSSL_BIN
postgresql=$POSTGRESQL
greenlet=$GREENLET
markupsafe=$MARKUPSAFE
charset_normalizer=$CHARSET_NORMALIZER
sqlalchemy=$SQLALCHEMY
psycopg2=$PSYCOPG2
EOF

echo ">> checks"
# the shipped runtime imports its native modules and packages from the bundle alone (test-only:
# sqlalchemy imports typing_extensions, which Source.Python vendors as pure Python)
"$PYBIN" -m pip -q install --no-deps --target "$W/testdeps" typing_extensions==$TYPING_EXTENSIONS > "$L/testdeps.log" 2>&1
"$PYBIN" -I -S -B -c '
import os, sys
b = sys.argv[1]
r = os.path.join(b, "runtime", "addons", "source-python", "Python3")
sys.path[:] = [r, os.path.join(r, "plat-win"), os.path.join(b, "runtime", "addons", "source-python", "packages", "site-packages"), sys.argv[2]]
import ssl, ctypes, sqlite3, zlib, lzma, bz2, hashlib, json, decimal, uuid
import greenlet, psycopg2, markupsafe, charset_normalizer.md, sqlalchemy.cyextension.collections
assert markupsafe._speedups and greenlet._greenlet
for m in (charset_normalizer.md, sqlalchemy.cyextension.collections, greenlet._greenlet):
    assert m.__file__.endswith(".pyd"), m.__file__
assert psycopg2._psycopg.__file__.endswith(".pyd"), psycopg2._psycopg.__file__
for m in (ssl, sqlite3, greenlet, psycopg2, markupsafe, sqlalchemy, json):
    assert os.path.normcase(m.__file__).startswith(os.path.normcase(b)), (m.__name__, m.__file__)
print("   imports ok:", ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version, "| psycopg2", psycopg2.__version__, "| libpq", psycopg2.extensions.libpq_version())' "$(cygpath -w "$B")" "$(cygpath -w "$W/testdeps")" 2>&1 | tee "$L/imports.txt"
du -sh "$B"

# zip with sorted entries and fixed timestamps
"$PYBIN" -I -c '
import os, sys, zipfile
root, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, dirs, files in os.walk(os.path.join(root, name)):
        dirs.sort()
        for f in sorted(files):
            path = os.path.join(base, f)
            info = zipfile.ZipInfo(os.path.relpath(path, root).replace(os.sep, "/"), (2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as src:
                z.writestr(info, src.read())' "$(cygpath -w "$OUT")" "$NAME" "$(cygpath -w "$OUT/$NAME.zip")"
(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" && cat "$NAME.zip.sha256")
