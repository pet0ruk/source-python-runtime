# source-python-runtime

Builds the Python runtime that Source.Python embeds: CPython, the compiled packages Source.Python
ships, and Boost.Python built against that exact interpreter. The output is one bundle per platform,
published as GitHub release assets and pinned by checksum in the Source.Python repository
(`src/makefiles/linux/python-runtime.cmake`).

## Releases

A release is `<python version>-r<revision>`, e.g. `3.13.2-r1`. Several Python series are built side
by side (say 3.13 and 3.15), each from its own file in [`versions/`](versions):

- `versions/common.sh`: inputs shared by every series (the build image, OpenSSL, zlib, sqlite, ...,
  Boost, the compiled packages), with the sha256 of every source archive.
- `versions/<series>.sh`: `PYTHON`, `PYTHON_SHA256` and `REVISION` for that series, plus anything that
  has to differ from `common.sh` (for a newer series typically Boost or package versions).

Bump a series' `REVISION` when anything that goes into it changes without a Python version change
(a change to `common.sh` affects every series); reset it to 1 for a new Python version. A published
release is never replaced, so an existing pin always refers to the same files. Adding a series is
adding a file.

Assets are named after Python's wheel platform tags:

| Asset | Server |
|---|---|
| `sp-python-<release>-manylinux_2_28_i686.tar.gz` | Linux, 32-bit |
| `sp-python-<release>-manylinux_2_28_x86_64.tar.gz` | Linux, 64-bit (from 3.13.17-r5) |
| `sp-python-<release>-win32.zip` | Windows, 32-bit |
| `sp-python-<release>-win_amd64.zip` | Windows, 64-bit (from 3.13.17-r5) |

plus `SHA256SUMS`.

## Building

```bash
./build-linux.sh 3.13 [out]          # Docker; ~10 min. out/ (default out/3.13) gets the .tar.gz,
ARCH=x86_64 ./build-linux.sh 3.13    # .sha256, logs/<arch>/ and src/ (ARCH default i686)
./build-windows.sh 3.13 [out]        # Git Bash on Windows with Visual Studio 2022 (v143); the .zip
ARCH=win_amd64 ./build-windows.sh 3.13   # (ARCH default win32)
```

The GitHub workflow builds every series on pull requests, and the series given (default all) on
manual dispatch. Dispatching it on `main` with **release** set also publishes each built series
whose release doesn't exist yet.

## Linux bundles (i686, x86_64)

Built in `manylinux_2_28_i686` / `manylinux_2_28_x86_64` (AlmaLinux 8, glibc 2.28); the two
architectures differ only in the target, everything below applies to both:

- **CPython**, configured for the image's architecture (`SOABI cpython-3XX-i386-linux-gnu` or
  `cpython-3XX-x86_64-linux-gnu`), shared, without an executable stack.
- **OpenSSL, libffi, zlib, bzip2, xz, sqlite** built from source and linked statically into the
  extension modules with their symbols hidden, so the server needs none of them installed and an
  older copy already loaded by the server can't be bound instead.
- **greenlet, psycopg2, markupsafe, charset-normalizer, sqlalchemy** built from source as wheels and repaired
  with auditwheel (psycopg2 carries a minimal libpq and its own OpenSSL, like `psycopg2-binary`),
  with libstdc++/libgcc linked statically: some games ship an old libstdc++ that the server loads
  first (L4D2).
- **Boost.Python**, built against this interpreter with the system GCC 8. It is a static library
  that Source.Python links with its own compiler; GCC 8's objects need only libstdc++ 8.

Checks run at the end of every build: every shipped ELF needs at most glibc 2.28 and libstdc++ 8's
symbol versions and has no executable stack (`tools/symver.py`); only system libraries are
`NEEDED` (not libstdc++ or libgcc_s); the runtime imports its native modules and packages from the bundle alone.

Not built: `_tkinter`, `_curses`, `readline`, `_dbm`/`_gdbm`, `_uuid` (their system libraries
differ between distributions and a server doesn't need them; `uuid` falls back to pure Python),
and CPython's test modules.

## Windows bundles (win32, win_amd64)

Built on `windows-2022`:

- **CPython**: the official build (NuGet package `pythonx86` for win32, `python` for win_amd64,
  sha256 pinned per series),
  repackaged: `python3X.dll`, its `DLLs/` (extension modules, OpenSSL, libffi, sqlite), the stdlib
  (without test, idlelib, tkinter, turtledemo; the package has no Tcl/Tk or test modules),
  headers and import libraries.
- **Boost.Python**, built against it with MSVC v143 (Visual Studio 2022, the oldest supported
  toolset: newer ones link its libraries, not the other way round), statically and with the
  static C runtime (`/MT`), like Source.Python's Windows build.
- **markupsafe, charset-normalizer, sqlalchemy** from their official `win32`/`win_amd64` wheels;
  **greenlet** (no `win32` wheel) built from source on both. The win_amd64 bundle also ships
  `vcruntime140_1.dll`, which 64-bit Python needs. psycopg2 isn't shipped on Windows.

The same import check runs at the end of the build.

Layout:

```
sp-python-<release>-<platform>/
  manifest.txt     key=value: release, platform, python, python_abi, soabi, libpython, versions
  build/include/python3.X/                       Python headers
  build/include/boost/                           Boost headers (all of them; manifest boost_include)
  build/lib/       Linux: libpython3.X.a, libpython3.X.so.1.0, libboost_python3X.a
                   Windows: python3X.lib, python3.lib, libboost_python3X-vc143-mt-s-x{32,64}-<boost>.lib
  runtime/         laid over the Source.Python release tree:
    addons/source-python/Python3/                 stdlib, lib-dynload/ + plat-linux/ (Linux)
                                                  or plat-win/ (Windows)
    addons/source-python/packages/site-packages/  the compiled packages, _sysconfigdata
  licenses/
```
