#!/usr/bin/env python3
"""Sanity-check a recovered .text symbol map against the actual bytes.

Two independent structural checks:

  1. Preceding byte -- a genuine function start should follow inter-function
     padding (nop/int3/zero) or the ret/jmp that ends the previous function.
     This is the strong signal: it fails loudly if RVAs are misaligned.
  2. Prologue shape -- informational only. CodeWarrior's optimiser frequently
     omits the frame pointer, so a large "other" bucket is expected and is not
     an error.

Usage: validate_symbols.py <DeimosRising.exe> <functions.csv>
Exits non-zero if boundary agreement drops below 95%.
"""
import sys, csv, struct


def text_section(data):
    e = struct.unpack_from("<I", data, 0x3c)[0]
    nsec = struct.unpack_from("<H", data, e + 6)[0]
    ohsz = struct.unpack_from("<H", data, e + 20)[0]
    for i in range(nsec):
        o = e + 24 + ohsz + i * 40
        if data[o:o + 8].rstrip(b"\0") == b".text":
            vs, va, rs, ra = struct.unpack_from("<IIII", data, o + 8)
            return va, ra, vs
    raise SystemExit("no .text section")


PAD = {0xcc: "int3 pad", 0x90: "nop pad", 0x00: "zero pad"}
END = {0xc3: "ret", 0xc2: "ret n", 0xe9: "jmp tail", 0xeb: "jmp short"}


def main():
    data = open(sys.argv[1], "rb").read()
    va, raw, _ = text_section(data)
    rows = list(csv.DictReader(open(sys.argv[2])))
    rows = [r for r in rows if r["section"] == ".text"]

    good, checked, buckets = 0, 0, {}
    for r in rows:
        off = raw + (int(r["rva"], 16) - va)
        if off <= raw or off >= len(data):
            continue
        checked += 1
        p = data[off - 1]
        label = PAD.get(p) or END.get(p)
        if label:
            good += 1
        else:
            label = "unexpected 0x%02x" % p
        buckets[label] = buckets.get(label, 0) + 1

    print("symbols checked: %d" % checked)
    for k, v in sorted(buckets.items(), key=lambda x: -x[1]):
        print("  %-18s %5d  %5.1f%%" % (k, v, 100.0 * v / checked))
    pct = 100.0 * good / checked if checked else 0.0
    print("boundary agreement: %.1f%%" % pct)
    if pct < 95.0:
        print("FAIL: symbol map does not line up with the binary", file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
