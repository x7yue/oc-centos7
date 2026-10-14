#!/usr/bin/env python3
"""Install only conda-forge's GCC 13 C++ headers and static support libraries."""
import hashlib
import io
import json
import pathlib
import tarfile
import urllib.request
import zipfile

import zstandard

root = pathlib.Path('/opt/gcc13')
root.mkdir(parents=True, exist_ok=True)
records = []
for name in ('libgcc-devel_linux-64', 'libstdcxx-devel_linux-64'):
    url = f'https://api.anaconda.org/release/conda-forge/{name}/13.4.0'
    with urllib.request.urlopen(url, timeout=120) as response:
        metadata = json.load(response)
    candidates = [d for d in metadata['distributions']
                  if d['attrs']['subdir'] in ('noarch', 'linux-64')]
    package = max(candidates, key=lambda d: (d['attrs'].get('build_number', 0), d['basename']))
    url = 'https://conda.anaconda.org/conda-forge/' + package['basename']
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == package['sha256'], (url, digest)
    records.append({'url': url, 'sha256': digest, 'version': '13.4.0'})
    if url.endswith('.conda'):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            member = next(n for n in archive.namelist() if n.startswith('pkg-'))
            with zstandard.ZstdDecompressor().stream_reader(archive.open(member)) as stream:
                with tarfile.open(fileobj=stream, mode='r|') as payload:
                    payload.extractall(root, filter='data')
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as payload:
            payload.extractall(root, filter='data')

install = root / 'lib/gcc/x86_64-conda-linux-gnu/13.4.0'
assert (install / 'libstdc++.a').is_file()
assert (install / 'libgcc.a').is_file()
assert (install / 'include/c++/expected').is_file()
common = f'--target=x86_64-unknown-linux-gnu\n--sysroot=/\n--gcc-install-dir={install}\n-fuse-ld=lld\n'
path = pathlib.Path('/opt/llvm21/bin')
(path / 'clang.cfg').write_text(common)
(path / 'clang++.cfg').write_text(
    common + f'-isystem {install}/include/c++\n'
    + f'-isystem {install}/include/c++/x86_64-conda-linux-gnu\n'
    + '-static-libstdc++\n-static-libgcc\n')
(root / 'packages.json').write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps(records, indent=2))
