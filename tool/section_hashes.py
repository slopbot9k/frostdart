#!/usr/bin/env python3
"""Prints a per-section digest of every ELF and PE file under a directory,
plus the contents of ELF .comment sections, so two builds can be compared
section by section. Usage: section_hashes.py <directory>"""
import hashlib, os, struct, sys


def elf_sections(b):
    bits64 = b[4] == 2
    if bits64:
        shoff = struct.unpack_from('<Q', b, 0x28)[0]
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
        fmt, name_off, off_i, size_i = '<IIQQQQIIQQ', 0, 4, 5
    else:
        shoff = struct.unpack_from('<I', b, 0x20)[0]
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x2e)
        fmt, name_off, off_i, size_i = '<IIIIIIIIII', 0, 4, 5
    secs = [struct.unpack_from(fmt, b, shoff + i * shentsize) for i in range(shnum)]
    stroff = secs[shstrndx][off_i]
    out = []
    for s in secs:
        end = b.index(b'\0', stroff + s[name_off])
        name = b[stroff + s[name_off]:end].decode(errors='replace')
        data = b'' if s[1] == 8 else b[s[off_i]:s[off_i] + s[size_i]]  # SHT_NOBITS has no file data
        out.append((name, s[size_i], data))
    return out


def pe_sections(b):
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    nsec, = struct.unpack_from('<H', b, pe + 6)
    opt_size, = struct.unpack_from('<H', b, pe + 20)
    table = pe + 24 + opt_size
    out = [('(headers)', table + nsec * 40, b[:table + nsec * 40])]
    for i in range(nsec):
        e = table + i * 40
        name = b[e:e + 8].rstrip(b'\0').decode(errors='replace')
        vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', b, e + 8)
        out.append((name, rawsize, b[rawptr:rawptr + rawsize]))
    return out


def archive_members(b):
    """Yields (name, data) for each member of a GNU or COFF ar archive."""
    pos, longnames = 8, b''
    while pos + 60 <= len(b):
        name = b[pos:pos + 16].decode(errors='replace').rstrip()
        size = int(b[pos + 48:pos + 58].decode().strip() or 0)
        data = b[pos + 60:pos + 60 + size]
        if name == '//':
            longnames = data
        elif name.startswith('/') and name[1:].isdigit():
            # GNU tables terminate names with "/\n", COFF tables with NUL.
            off = int(name[1:])
            ends = [i for i in (longnames.find(b'/\n', off), longnames.find(b'\0', off), longnames.find(b'\n', off)) if i >= 0]
            end = min(ends) if ends else len(longnames)
            yield longnames[off:end].decode(errors='replace').rstrip('/'), data
        elif name not in ('/', '/SYM64/'):
            yield name.rstrip('/'), data
        pos += 60 + size + (size & 1)


def digest(rel, b):
    if b[:8] == b'!<arch>\n':
        print(f'{rel}  size={len(b)}  sha256={hashlib.sha256(b).hexdigest()[:16]}')
        for name, data in archive_members(b):
            print(f'  {name[:60]:60} {len(data):9} {hashlib.sha256(data).hexdigest()[:16]}')
        return
    if b[:4] == b'\x7fELF':
        secs = elf_sections(b)
    elif b[:2] == b'MZ':
        secs = pe_sections(b)
    else:
        return
    print(f'{rel}  size={len(b)}  sha256={hashlib.sha256(b).hexdigest()[:16]}')
    for name, size, data in secs:
        print(f'  {name:24} {size:9} {hashlib.sha256(data).hexdigest()[:16]}')
        if name == '.comment':
            for part in data.split(b'\0'):
                if part:
                    print(f'      {part.decode(errors="replace")[:100]}')


def main(root):
    # A parse failure on one file must not fail the build that records it.
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            path = os.path.join(dirpath, f)
            rel = os.path.relpath(path, root)
            try:
                digest(rel, open(path, 'rb').read())
            except Exception as e:  # noqa: BLE001
                print(f'{rel}: could not digest: {e!r}', file=sys.stderr)
                print(f'{rel}  (not digested: {e!r})')


main(sys.argv[1] if len(sys.argv) > 1 else '.')
