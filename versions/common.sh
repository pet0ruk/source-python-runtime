# shellcheck shell=bash disable=SC2034
# Build inputs shared by every Python series. Each series has its own versions/<series>.sh, which
# sources this file and sets PYTHON, REVISION and PYTHON_SHA256, plus anything that has to differ
# for that series (e.g. a newer Boost or package versions supporting a newer Python).
#
# A release is "<PYTHON>-r<REVISION>". Changing anything here changes every series: bump REVISION
# in each series file that should be re-released. sha256 sums are checked after download.

# Linux build environment: manylinux_2_28 (AlmaLinux 8, glibc 2.28, GCC 14 from gcc-toolset)
MANYLINUX_I686=quay.io/pypa/manylinux_2_28_i686@sha256:baf927c001d9dfead35e53de68b2c113b623155b7a878cc45e2e1ad61c9fb5e7

OPENSSL=3.5.4
OPENSSL_SHA256=967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99
LIBFFI=3.4.8
LIBFFI_SHA256=bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b
ZLIB=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
BZIP2=1.0.8
BZIP2_SHA256=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
XZ=5.8.1
XZ_SHA256=507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543
SQLITE=3500400
SQLITE_YEAR=2025
SQLITE_SHA256=a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18
POSTGRESQL=17.6
POSTGRESQL_SHA256=e0630a3600aea27511715563259ec2111cd5f4353a4b040e0be827f94cd7a8b0
BOOST=1.87.0
BOOST_SHA256=f55c340aa49763b1925ccf02b2e83f35fdcf634c9d5164a2acb87540173c741d

# Compiled packages Source.Python vendors; versions must match the requirements.txt in its
# addons/source-python/packages/site-packages for the Source.Python branch pinning the release.
GREENLET=3.2.0
PSYCOPG2=2.9.10
MARKUPSAFE=3.0.2
CHARSET_NORMALIZER=3.4.1
