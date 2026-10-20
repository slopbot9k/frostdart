#!/usr/bin/env python3
"""Writes hook/prebuilt_hashes.json from SHA256SUMS files.

    write_prebuilt_hashes.py [--merge] <native-version> <release-url> <output.json> <SHA256SUMS>...

Only dynamic libraries are recorded. With --merge, entries are added to an
existing file for the same release instead of replacing it."""
import json, sys

args = sys.argv[1:]
merge = '--merge' in args
if merge:
    args.remove('--merge')
version, url, out, *sums = args
files = {}
if merge:
    with open(out) as f:
        existing = json.load(f)
    if existing.get('nativeVersion') not in (None, version):
        sys.exit(f'{out} records {existing["nativeVersion"]}, not {version}')
    files = dict(existing.get('files') or {})
for path in sums:
    for line in open(path):
        parts = line.split()
        if len(parts) != 2:
            continue
        digest, name = parts
        name = name[2:] if name.startswith('./') else name
        if name.endswith(('.so', '.dylib', '.dll')):
            files[name] = digest
with open(out, 'w') as f:
    json.dump({'nativeVersion': version, 'releaseUrl': url, 'files': dict(sorted(files.items()))}, f, indent=2)
    f.write('\n')
print(f'{out}: {len(files)} libraries for {version}')
