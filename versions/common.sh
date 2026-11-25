# shellcheck shell=bash disable=SC2034
# Build inputs shared by every Python series. Each series has its own versions/<series>.sh, which
# sources this file and sets PYTHON, REVISION and PYTHON_SHA256, plus anything that has to differ
# for that series (e.g. a newer Boost or package versions supporting a newer Python).
#
# A release is "<PYTHON>-r<REVISION>". Changing anything here changes every series: bump REVISION
# in each series file that should be re-released. sha256 sums are checked after download.

# Linux build environment: manylinux_2_28 (AlmaLinux 8, glibc 2.28, GCC 14 from gcc-toolset)
# (tag 2026.11.14-1 of both)
MANYLINUX_I686=quay.io/pypa/manylinux_2_28_i686@sha256:baf927c001d9dfead35e53de68b2c113b623155b7a878cc45e2e1ad61c9fb5e7
MANYLINUX_X86_64=quay.io/pypa/manylinux_2_28_x86_64@sha256:d086f64cddcace250ef0f0073583c51b8298159303290a730c9f59bd91edfd2c

OPENSSL=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBFFI=3.4.8
LIBFFI_SHA256=bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b
ZLIB=1.4
ZLIB_SHA256=02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584
BZIP2=1.0.8
BZIP2_SHA256=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
XZ=5.8.4
XZ_SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9
SQLITE=3500400
SQLITE_YEAR=2025
SQLITE_SHA256=a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18
POSTGRESQL=17.12
POSTGRESQL_SHA256=9cf136a703d8ee2f83465c43be4e9e8e7930c82b0bfba13be7e2537be769ac55
BOOST=1.92.0
BOOST_SHA256=c4a3b310ddd2472416e091067166b0713be97c63f38c212c484ada022fd296ce

# Compiled packages Source.Python vendors; versions must match the requirements.txt in its
# addons/source-python/packages/site-packages for the Source.Python branch pinning the release.
GREENLET=3.5.6
PSYCOPG2=2.9.13
MARKUPSAFE=3.0.4
CHARSET_NORMALIZER=3.5.3
SQLALCHEMY=2.0.58
# Test-only (the import check at the end of each build): sqlalchemy imports typing_extensions, which
# Source.Python vendors as pure Python
TYPING_EXTENSIONS=4.16.0

# Windows only: what building libpq (for psycopg2) needs besides the PostgreSQL sources above.
# OpenSSL: CPython's own build of it (python/cpython-bin-deps), the libssl-3.dll/libcrypto-3.dll its
# Windows package ships; the build checks they are the same files. Its version follows PYTHON.
CPYTHON_OPENSSL_BIN=3.5.9
CPYTHON_OPENSSL_BIN_SHA256=eb1c2b2015c014b94009305f9b07ce1d7fd607bef8902e4aab30ab4cd3318316
# PostgreSQL's meson build needs flex and bison
WINFLEXBISON=2.5.25
WINFLEXBISON_SHA256=8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
# build tools, installed with pip into the build's own Python
MESON=1.12.1
NINJA=1.13.2
DELVEWHEEL=1.13.3
