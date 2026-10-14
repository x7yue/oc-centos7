#!/usr/bin/env python3
"""Reject a dynamic build that imports a glibc ABI newer than CentOS 7."""
import pathlib
import re
import subprocess
import sys

for argument in sys.argv[1:]:
    path = pathlib.Path(argument)
    versions = subprocess.check_output(['readelf', '--version-info', '-W', str(path)], text=True)
    dynamic = subprocess.check_output(['readelf', '-dW', str(path)], text=True)
    program = subprocess.check_output(['readelf', '-lW', str(path)], text=True)
    symbols = subprocess.check_output(['readelf', '--dyn-syms', '-W', str(path)], text=True)
    required = {tuple(map(int, v.split('.'))) for v in re.findall(r'GLIBC_(\d+(?:\.\d+)+)', versions)}
    assert all(v <= (2, 17) for v in required), (path, sorted(required))
    assert 'GLIBC_PRIVATE' not in versions, path
    needed = re.findall(r'Shared library: \[(.*?)\]', dynamic)
    print(f'{path.name}: NEEDED={needed}; GLIBC_MAX={max(required, default=None)}')
    if path.name == 'bun':
        assert '/lib64/ld-linux-x86-64.so.2' in program, program
        assert 'libc.so.6' in needed, needed
        assert 'libstdc++.so.6' not in needed, needed
        assert re.search(r'UND\s+dlopen@GLIBC_', symbols), 'system dlopen must be imported'
        assert not re.search(r'\b(?!UND\b)\d+\s+dlopen(?:@|\s|$)', symbols), 'unexpected dlopen definition'
        print('BUN_INTERPRETER=/lib64/ld-linux-x86-64.so.2; SYSTEM_DLOPEN=PASS')
print('ELF_GLIBC217=PASS')
