#!/bin/bash
# Builds the Windows (win32) runtime bundle of one Python series and packs it. Runs in Git Bash on
# Windows (CI: windows-2022) and needs Visual Studio with the C++ desktop workload (v143) and any
# Python 3 (only to unpack the CPython package; everything else runs with that interpreter).
#
#   ./build-windows.sh <series> [out dir]        e.g. ./build-windows.sh 3.13   (default ./out/<series>)
#
# Produces <out>/sp-python-<release>-win32.zip (+ .sha256) and <out>/logs/.
#
# - CPython is the official 32-bit build (NuGet package pythonx86, sha256 pinned in the series
#   file): python313.dll, its DLLs/ (.pyd extension modules, OpenSSL, libffi, sqlite), the
#   stdlib, headers and import libraries. Nothing of CPython is compiled here.
# - Boost.Python is built against it with MSVC, statically and with the static C runtime
#   (runtime-link=static, i.e. /MT, as Source.Python's Windows build links), using the oldest
#   supported toolset (v143, Visual Studio 2022): newer MSVC versions link v143 libraries, not
#   the other way round.
# - markupsafe, charset-normalizer and sqlalchemy come from their official win32 wheels;
#   greenlet has none and is built from source. psycopg2 isn't shipped on Windows.
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
PLATFORM=win32
PYV=${PYTHON%.*}                       # 3.13
PYN=${PYV/./}                          # 313
RELEASE=$PYTHON-r$REVISION
NAME=sp-python-$RELEASE-$PLATFORM
BOOSTN=boost_${BOOST//./_}
BOOST_TAG=${BOOST%.*}; BOOST_TAG=${BOOST_TAG/./_}      # 1_87
TOOLSET=msvc-14.3

SRC=$OUT/src L=$OUT/logs B=$OUT/$NAME W=$OUT/work
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
fetch "https://api.nuget.org/v3-flatcontainer/pythonx86/$PYTHON/pythonx86.$PYTHON.nupkg" "pythonx86.$PYTHON.nupkg" PYTHON_WIN32_SHA256
fetch "https://archives.boost.io/release/$BOOST/source/$BOOSTN.tar.gz" "$BOOSTN.tar.gz" BOOST_SHA256

echo ">> python $PYTHON (pythonx86)"
P=$W/python
mkdir -p "$P"
# unzip with any Python on the runner (the package itself is a zip)
PY_HOST=$(command -v python3 || command -v python)
"$PY_HOST" -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$SRC/pythonx86.$PYTHON.nupkg" "$W/nupkg"
mv "$W/nupkg/tools"/* "$P/"
PYBIN=$P/python.exe
"$PYBIN" -c 'import sys, ssl, sqlite3, ctypes, sysconfig
print(sys.version); print(ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version, "|", sysconfig.get_platform())'
SOABI=$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_config_var("SOABI") or "cp" + sysconfig.get_config_var("py_version_nodot") + "-win32")')

echo ">> boost.python $BOOST ($TOOLSET)"
tar -C "$W" -xzf "$SRC/$BOOSTN.tar.gz"
cd "$W/$BOOSTN"
cmd //c bootstrap.bat > "$L/boost-bootstrap.log" 2>&1 || { tail -30 "$L/boost-bootstrap.log"; exit 1; }
PW=$(cygpath -m "$P")
echo "using python : $PYV : $PW/python.exe : $PW/include : $PW/libs ;" > user-config.jam
./b2.exe --user-config=user-config.jam -j"${JOBS:-$(nproc)}" -q toolset=$TOOLSET address-model=32 \
    architecture=x86 link=static runtime-link=static threading=multi variant=release \
    python="$PYV" --with-python stage > "$L/boost.log" 2>&1 || { tail -40 "$L/boost.log"; exit 1; }
BOOST_LIB=$(cd stage/lib && ls libboost_python$PYN-vc143-mt-s-x32-$BOOST_TAG.lib)
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
    case $w in *-cp$PYN-cp$PYN-win32.whl) ;; *) echo "!! not a cp$PYN win32 wheel: $w" >&2; exit 1;; esac
    "$PYBIN" -m zipfile -e "$w" "$SITE"
done

echo ">> bundle $NAME"
R=$B/runtime/addons/source-python/Python3
S=$B/runtime/addons/source-python/packages/site-packages
mkdir -p "$B/build/lib" "$B/build/include" "$R/plat-win" "$S" "$B/licenses"
# build/: what compiling Source.Python needs
cp -r "$P/include" "$B/build/include/python$PYV"
cp "$P/libs/python$PYN.lib" "$P/libs/python3.lib" "$B/build/lib/"
cp "$W/$BOOSTN/stage/lib/$BOOST_LIB" "$B/build/lib/"
# all of Boost's headers (header-only, so they match Boost.Python above by construction);
# Source.Python uses other Boost libraries besides Boost.Python
cp -r "$W/$BOOSTN/boost" "$B/build/include/"
# runtime/: laid over the Source.Python tree. Lib/ minus what a server doesn't use, as on Linux.
(cd "$P/Lib" && tar -c --exclude=__pycache__ --exclude='./test' --exclude='./idlelib' \
    --exclude='./tkinter' --exclude='./turtledemo' --exclude='./curses' --exclude='./site-packages' \
    --exclude='./ensurepip/_bundled' .) | tar -x -C "$R"
cp "$P"/DLLs/*.pyd "$P"/DLLs/*.dll "$R/plat-win/"
cp "$P/python$PYN.dll" "$P/python3.dll" "$P/vcruntime140.dll" "$R/plat-win/"
cp -r "$SITE"/{greenlet,markupsafe,charset_normalizer,sqlalchemy} "$S/"
rm -rf "$S/greenlet/tests"
cp "$P/LICENSE.txt" "$B/licenses/cpython.txt"
cp "$W/$BOOSTN/LICENSE_1_0.txt" "$B/licenses/boost.txt"

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
greenlet=$GREENLET
markupsafe=$MARKUPSAFE
charset_normalizer=$CHARSET_NORMALIZER
sqlalchemy=$SQLALCHEMY
EOF

echo ">> checks"
# the shipped runtime imports its native modules and packages from the bundle alone (test-only:
# sqlalchemy imports typing_extensions, which Source.Python vendors as pure Python)
"$PYBIN" -m pip -q install --no-deps --target "$W/testdeps" typing_extensions==4.13.2 > "$L/testdeps.log" 2>&1
"$PYBIN" -I -S -B -c '
import os, sys
b = sys.argv[1]
r = os.path.join(b, "runtime", "addons", "source-python", "Python3")
sys.path[:] = [r, os.path.join(r, "plat-win"), os.path.join(b, "runtime", "addons", "source-python", "packages", "site-packages"), sys.argv[2]]
import ssl, ctypes, sqlite3, zlib, lzma, bz2, hashlib, json, decimal, uuid
import greenlet, markupsafe, charset_normalizer.md, sqlalchemy.cyextension.collections
assert markupsafe._speedups and greenlet._greenlet
for m in (charset_normalizer.md, sqlalchemy.cyextension.collections, greenlet._greenlet):
    assert m.__file__.endswith(".pyd"), m.__file__
for m in (ssl, sqlite3, greenlet, markupsafe, sqlalchemy, json):
    assert os.path.normcase(m.__file__).startswith(os.path.normcase(b)), (m.__name__, m.__file__)
print("   imports ok:", ssl.OPENSSL_VERSION, "| sqlite", sqlite3.sqlite_version)' "$(cygpath -w "$B")" "$(cygpath -w "$W/testdeps")" 2>&1 | tee "$L/imports.txt"
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
