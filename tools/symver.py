#!/usr/bin/env python3
"""Report (and optionally enforce) the newest GLIBC/GLIBCXX/CXXABI symbol versions ELF files need.

  symver.py <file>... [--max-glibc 2.28] [--max-glibcxx 3.4.25]

Reads .gnu.version_r via `readelf -V` (binutils). Exit 1 if a limit is exceeded. Also flags an
executable stack (PT_GNU_STACK RWE), which glibc >= 2.41 refuses to dlopen.
"""
import re
import subprocess
import sys


def ver(s):
    return tuple(int(x) for x in s.split('.'))


def main(argv):
    files, lim, i = [], {}, 0
    while i < len(argv):
        if argv[i] in ('--max-glibc', '--max-glibcxx'):
            lim[{'--max-glibc': 'GLIBC', '--max-glibcxx': 'GLIBCXX'}[argv[i]]] = ver(argv[i + 1]); i += 2
        else:
            files.append(argv[i]); i += 1
    bad = False
    for f in files:
        out = subprocess.run(['readelf', '-VW', f], capture_output=True, text=True).stdout
        need = {}
        for m in re.finditer(r'Name: (GLIBC|GLIBCXX|CXXABI)_([0-9.]+)', out):
            need.setdefault(m[1], []).append(ver(m[2]))
        top = {k: max(v) for k, v in need.items()}
        phdr = subprocess.run(['readelf', '-lW', f], capture_output=True, text=True).stdout
        execstack = bool(re.search(r'GNU_STACK.*RWE', phdr))
        msgs = []
        for k, v in sorted(top.items()):
            over = k in lim and v > lim[k]
            bad |= over
            msgs.append(f"{k}_{'.'.join(map(str, v))}{' (> limit!)' if over else ''}")
        if execstack:
            msgs.append('EXECSTACK'); bad |= bool(lim)
        print(f'  {f.rsplit("/", 1)[-1]:40} ' + '  '.join(msgs))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
