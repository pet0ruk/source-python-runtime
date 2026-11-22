# shellcheck shell=bash disable=SC2034
# Python 3.13 series. A release is "<PYTHON>-r<REVISION>": bump REVISION when anything that goes
# into it changes (here or in common.sh) without a Python version change; reset it to 1 when
# PYTHON changes.
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PYTHON=3.13.2
PYTHON_SHA256=d984bcc57cd67caab26f7def42e523b1c015bbc5dc07836cf4f0b63fa159eb56
REVISION=1
