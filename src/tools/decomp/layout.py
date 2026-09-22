#!/usr/bin/env python3
"""Recover in-memory definition layouts from the original's loaders.

Each definition type (unit, unit state, weapon, player, level) is read
by one function that calls U_Token_Get<Type>(text, &cursor, "#key TYPE",
&base[offset]) once per key. Scraping those calls from the Ghidra corpus gives
a table of key -> type -> byte offset, which is how decompiled gameplay code
reading `*(float *)(def + 0x268)` is mapped back to a named field.

Ghidra truncates string labels (s__doNotSpawnIfTypeAlreadyExists_B_004f6d4d),
so the full key is read from the executable at the label's address.

Usage: layout.py <exe> <export-dir> <out-dir>
Writes <out-dir>/<loader>.tsv: offset, type, key, loader.
"""
import re
import struct
import sys
from pathlib import Path

LOADERS = {
    "unitdef": "G_UnitDef/FUN_004422a0.c",
    "unitdef_state": "G_UnitDef/FUN_004431f0.c",
    "wepdef": "G_WepDef/FUN_00445cf0.c",
    "playerdef": "G_PlayerDef/FUN_004368a0.c",
    "level": "G_Level/FUN_00429b70.c",
}

CALL = re.compile(
    r"U_Token_Get(\w+)\s*\((.*?)\);", re.S)
LABEL = re.compile(r"\b(?:s|DAT)_\w*?_?([0-9a-f]{8})\b")
OFFSET = re.compile(r"\(\s*(\w+)\s*\+\s*(0x[0-9a-f]+|\d+)\s*\)\s*(?:,|$)")


class PE:
    def __init__(self, path):
        self.b = Path(path).read_bytes()
        pe = struct.unpack_from("<I", self.b, 0x3C)[0]
        nsec = struct.unpack_from("<H", self.b, pe + 6)[0]
        opt = struct.unpack_from("<H", self.b, pe + 20)[0]
        self.base = struct.unpack_from("<I", self.b, pe + 24 + 28)[0]
        self.secs = []
        o = pe + 24 + opt
        for _ in range(nsec):
            vsize, va, rsize, raw = struct.unpack_from("<IIII", self.b, o + 8)
            self.secs.append((self.base + va, max(vsize, rsize), raw))
            o += 40

    def cstr(self, va):
        for start, size, raw in self.secs:
            if start <= va < start + size:
                off = raw + va - start
                end = self.b.index(b"\0", off)
                return self.b[off:end].decode("latin-1")
        return None


def main():
    exe, export, out = sys.argv[1:4]
    pe = PE(exe)
    Path(out).mkdir(parents=True, exist_ok=True)
    for name, rel in LOADERS.items():
        src = (Path(export) / rel).read_text()
        rows = []
        for m in CALL.finditer(src):
            kind, args = m.group(1), " ".join(m.group(2).split())
            lab = LABEL.search(args)
            off = OFFSET.search(args)
            if not lab or not off:
                continue
            key = pe.cstr(int(lab.group(1), 16))
            if key is None:
                continue
            rows.append((int(off.group(2), 0), kind, key.strip()))
        rows.sort()
        with open(Path(out) / f"{name}.tsv", "w") as f:
            f.write("offset\ttype\tkey\n")
            for o, k, key in rows:
                f.write(f"{o:#06x}\t{k}\t{key}\n")
        print(f"{name}: {len(rows)} keys")


if __name__ == "__main__":
    main()
