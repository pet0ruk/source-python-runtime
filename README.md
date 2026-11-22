# source-python-runtime

Builds the Python runtime that Source.Python embeds: CPython, the compiled packages Source.Python
ships, and Boost.Python built against that exact interpreter. The output is one bundle per platform,
published as GitHub release assets and pinned by checksum in the Source.Python repository
(`src/makefiles/linux/python-runtime.cmake`).

## Releases

A release is `<python version>-r<revision>`, e.g. `3.13.2-r1`. Every input is in
[`versions.sh`](versions.sh) (versions and the sha256 of every source archive). Bump `REVISION` when
anything changes without a Python version change; reset it to 1 for a new Python version. A
published release is never replaced, so an existing pin always refers to the same files.

Assets are named after Python's wheel platform tags:

| Asset | Status |
|---|---|
| `sp-python-<release>-manylinux_2_28_i686.tar.gz` | built here |
| `sp-python-<release>-win32.zip` | not yet (Windows still uses Source.Python's vendored files) |
| `…-manylinux_2_28_x86_64`, `…-win_amd64` | reserved for 64-bit builds |

plus `SHA256SUMS`.

## Building

```bash
./build-linux.sh [out]      # Docker; ~10 min. out/ gets the .tar.gz, .sha256, logs/ and src/
```

The GitHub workflow builds on every pull request and on manual dispatch. Dispatching it on `main`
with **release** set also publishes the release.

## Linux i686 bundle

Built in `manylinux_2_28_i686` (AlmaLinux 8, glibc 2.28):

- **CPython**, configured for i686 (`SOABI cpython-3XX-i386-linux-gnu`), shared, without an
  executable stack.
- **OpenSSL, libffi, zlib, bzip2, xz, sqlite** built from source and linked statically into the
  extension modules with their symbols hidden, so the server needs none of them installed and an
  older copy already loaded by the server can't be bound instead.
- **greenlet, psycopg2, markupsafe, charset-normalizer** built from source as wheels and repaired
  with auditwheel (psycopg2 carries a minimal libpq and its own OpenSSL, like `psycopg2-binary`).
- **Boost.Python**, built against this interpreter with the system GCC 8. It is a static library
  that Source.Python links with its own compiler; GCC 8's objects need only libstdc++ 8.

Checks run at the end of every build: every shipped ELF needs at most glibc 2.28 and libstdc++ 8's
symbol versions and has no executable stack (`tools/symver.py`); only system libraries are
`NEEDED`; the runtime imports its native modules and packages from the bundle alone.

Not built: `_tkinter`, `_curses`, `readline`, `_dbm`/`_gdbm`, `_uuid` (their system libraries
differ between distributions and a server doesn't need them; `uuid` falls back to pure Python),
and CPython's test modules.

Layout:

```
sp-python-<release>-<platform>/
  manifest.txt     key=value: release, platform, python, python_abi, soabi, libpython, versions
  build/include/python3.X/                       headers
  build/lib/       libpython3.X.a, libpython3.X.so.1.0, libboost_python3X.a
  runtime/         laid over the Source.Python release tree:
    addons/source-python/Python3/                 stdlib, lib-dynload/, plat-linux/
    addons/source-python/packages/site-packages/  the compiled packages, _sysconfigdata
  licenses/
```
