# shellcheck shell=bash disable=SC2034
# Python 3.13 series. A release is "<PYTHON>-r<REVISION>": bump REVISION when anything that goes
# into it changes (here or in common.sh) without a Python version change; reset it to 1 when
# PYTHON changes.
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PYTHON=3.13.17
# Python-<PYTHON>.tar.xz, checked against its sigstore signature (thomas@python.org)
PYTHON_SHA256=6020bd10aff3bf4821be16f088ebb1591beb7b811dcd8fab1da8f7c22a7b27e7
# Windows: the official 32-bit build, as NuGet package pythonx86 <PYTHON>
PYTHON_WIN32_SHA256=0160a96db8fd328eb1fd6fde9354736aeb6be2425bb1f66b059bea6ebf228a5f
REVISION=4
