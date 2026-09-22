#!/usr/bin/env python3
"""Read initialised globals from the original executable.

Usage: peek.py <exe> <va> [<va> ...]
Each VA may carry a type suffix: 0x4e34b8:f (f32, default), :d (f64),
:i (i32), :u (u32), :s (C string), :4 (four-cc).
"""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from layout import PE  # noqa: E402


def main():
    pe = PE(sys.argv[1])
    for arg in sys.argv[2:]:
        va, _, kind = arg.partition(":")
        va = int(va, 16)
        kind = kind or "f"
        for start, size, raw in pe.secs:
            if start <= va < start + size:
                off = raw + va - start
                break
        else:
            print(f"{va:#x}: not in a section")
            continue
        b = pe.b
        v = {
            "f": lambda: struct.unpack_from("<f", b, off)[0],
            "d": lambda: struct.unpack_from("<d", b, off)[0],
            "i": lambda: struct.unpack_from("<i", b, off)[0],
            "u": lambda: hex(struct.unpack_from("<I", b, off)[0]),
            "s": lambda: b[off : b.index(b"\0", off)].decode("latin-1"),
            "4": lambda: b[off : off + 4].decode("latin-1"),
        }[kind]()
        print(f"{va:#x}:{kind} = {v!r}")


if __name__ == "__main__":
    main()
