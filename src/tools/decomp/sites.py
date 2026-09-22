#!/usr/bin/env python3
"""List every call to U_Utils_RandomInt / RandomFloat, by function.

Each ported random call passes the original's call-site return address
(sim.Site) so the oracle diff can name divergences. This scans .text for
`call rel32` (E8) instructions targeting the two helpers and prints
return address, helper and containing function (from the Ghidra index).

Usage: sites.py <exe> <export-index.tsv> [function-substring]
"""
import bisect
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from layout import PE  # noqa: E402

TARGETS = {0x40F7E0: "RandomInt", 0x40F840: "RandomFloat"}


def main():
    pe = PE(sys.argv[1])
    funcs = []
    for line in Path(sys.argv[2]).read_text().splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 6 and f[5] == "ok":
            funcs.append((int(f[1], 16), int(f[2]), f[3]))
    funcs.sort()
    starts = [f[0] for f in funcs]
    want = sys.argv[3] if len(sys.argv) > 3 else ""
    for start, size, raw in pe.secs:
        if start != pe.base + 0x1000:
            continue
        b = pe.b[raw : raw + size]
        for i in range(len(b) - 5):
            if b[i] != 0xE8:
                continue
            rel = struct.unpack_from("<i", b, i + 1)[0]
            ret = start + i + 5
            tgt = (ret + rel) & 0xFFFFFFFF
            if tgt not in TARGETS:
                continue
            j = bisect.bisect_right(starts, ret) - 1
            fs, fz, fn = funcs[j]
            if want and want not in fn:
                continue
            print(f"{ret:#x}\t{TARGETS[tgt]}\t{fn}+{ret - fs:#x}")


if __name__ == "__main__":
    main()
