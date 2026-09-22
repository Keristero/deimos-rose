#!/usr/bin/env python3
"""Parse the CodeView NB11 debug blob Metrowerks CodeWarrior appended to
DeimosRising.exe.

CodeWarrior emits CV5-era "ST" symbol records (S_PUB32_ST = 0x1009), which is
why stock CodeView-4 parsers -- and 7-Zip's NSIS/PE handling -- come up empty.

Outputs into <outdir>:
  modules.txt   translation-unit (.obj) list, in link order
  segments.txt  CodeView segment map correlated with PE sections
  symbols.csv   every symbol: rva, va, section, size estimate, name, basename
  functions.csv .text symbols only, with inferred sizes (gap to next symbol)

Usage: cv_parse.py <DeimosRising.exe|blob.cv> <outdir>
"""
import sys, os, re, struct, csv

SST = {0x120: "sstModule", 0x121: "sstTypes", 0x122: "sstPublic",
       0x123: "sstPublicSym", 0x124: "sstSymbols", 0x125: "sstAlignSym",
       0x127: "sstSrcModule", 0x128: "sstLibraries", 0x129: "sstGlobalSym",
       0x12a: "sstGlobalPub", 0x12b: "sstGlobalTypes", 0x12d: "sstSegMap",
       0x133: "sstFileIndex", 0x134: "sstStaticSym"}

# CV5 "ST" (length-prefixed name) symbol records.
S_LDATA32, S_GDATA32, S_PUB32 = 0x1007, 0x1008, 0x1009
S_LPROC32, S_GPROC32 = 0x100a, 0x100b
KIND = {S_LDATA32: "LDATA", S_GDATA32: "GDATA", S_PUB32: "PUB",
        S_LPROC32: "LPROC", S_GPROC32: "GPROC"}


def pe_sections(data):
    e = struct.unpack_from("<I", data, 0x3c)[0]
    nsec = struct.unpack_from("<H", data, e + 6)[0]
    ohsz = struct.unpack_from("<H", data, e + 20)[0]
    base = struct.unpack_from("<I", data, e + 24 + 28)[0]
    secs = []
    for i in range(nsec):
        o = e + 24 + ohsz + i * 40
        name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
        vs, va, rs, ra = struct.unpack_from("<IIII", data, o + 8)
        secs.append({"name": name, "va": va, "vsize": vs, "raw": ra, "rsize": rs})
    return secs, base


def find_blob(data):
    if data[:4] == b"NB11":
        return data, None, 0x400000
    secs, base = pe_sections(data)
    e = struct.unpack_from("<I", data, 0x3c)[0]
    oh = e + 24
    dva, dsz = struct.unpack_from("<II", data, oh + 96 + 6 * 8)
    off = None
    for s in secs:
        if s["va"] <= dva < s["va"] + max(s["vsize"], s["rsize"]):
            off = s["raw"] + (dva - s["va"])
    for i in range(dsz // 28):
        o = off + i * 28
        typ, sz, _rva, fp = struct.unpack_from("<IIII", data, o + 12)
        if typ == 2:
            return data[fp:fp + sz], secs, base
    raise SystemExit("no CodeView debug directory entry")


def pstr(b, o):
    n = b[o]
    return b[o + 1:o + 1 + n].decode("ascii", "replace"), o + 1 + n


def directory(blob):
    lfo = struct.unpack_from("<I", blob, 4)[0]
    cbh, cbe, cdir = struct.unpack_from("<HHI", blob, lfo)
    out = []
    for i in range(cdir):
        out.append(struct.unpack_from("<HHII", blob, lfo + cbh + i * cbe))
    return out


def parse_module(b):
    _ovl, _ilib, cseg = struct.unpack_from("<HHH", b, 0)
    style = b[6:8].decode("ascii", "replace")
    segs, o = [], 8
    for _ in range(cseg):
        seg, _pad, off, cb = struct.unpack_from("<HHII", b, o)
        segs.append((seg, off, cb))
        o += 12
    name, _ = pstr(b, o)
    return name, style, segs


def parse_segmap(b):
    cseg = struct.unpack_from("<H", b, 0)[0]
    out = []
    for i in range(cseg):
        o = 4 + i * 20
        flags, _ovl, _grp, _frame, _isn, _icn, off, cb = \
            struct.unpack_from("<HHHHHHII", b, o)
        out.append({"index": i + 1, "flags": flags, "offset": off, "size": cb})
    return out


def parse_symrun(b, start, end):
    out, o = [], start
    while o + 4 <= end:
        ln, typ = struct.unpack_from("<HH", b, o)
        if ln < 2:
            break
        body = o + 4
        try:
            if typ in (S_PUB32, S_LDATA32, S_GDATA32):
                # typind(4), off(4), seg(2), pstr name
                _ti, off, seg = struct.unpack_from("<IIH", b, body)
                name, _ = pstr(b, body + 10)
                out.append((KIND[typ], name, seg, off, 0))
            elif typ in (S_LPROC32, S_GPROC32):
                (_pp, _pe, _pn, plen, _ds, _de, _ti, off, seg) = \
                    struct.unpack_from("<IIIIIIIIH", b, body)
                name, _ = pstr(b, body + 34 + 1)
                out.append((KIND[typ], name, seg, off, plen))
        except (struct.error, IndexError):
            pass
        o += ln + 2
    return out


SPECIAL = {"0": "%s::%s", "1": "%s::~%s", "_G": "%s::~%s [scalar deleting]",
           "_E": "%s::~%s [vector deleting]", "4": "%s::operator=",
           "2": "%s::operator new", "3": "%s::operator delete"}


def basename(name):
    """Best-effort readable name from MSVC-style CodeWarrior mangling."""
    # ??0Class@@...  ctor / ??1Class@@... dtor / other special names
    m = re.match(r"^[?][?](_?[0-9A-Z])([\w$]+)@@", name)
    if m:
        op, cls = m.group(1), m.group(2)
        fmt = SPECIAL.get(op)
        if fmt:
            return fmt % ((cls, cls) if fmt.count("%s") == 2 else (cls,))
        return "%s::op%s" % (cls, op)
    m = re.match(r"^[?]([\w$]+)@([\w$]+)@@", name)   # Class::method
    if m:
        return "%s::%s" % (m.group(2), m.group(1))
    m = re.match(r"^[?]([\w$]+)@@", name)             # free function
    if m:
        return m.group(1)
    return name.lstrip("?_")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    raw = open(sys.argv[1], "rb").read()
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    blob, secs, imagebase = find_blob(raw)

    modules, syms, segmap = {}, [], []
    counts = {}
    for sub, imod, lfo, cb in directory(blob):
        counts[SST.get(sub, hex(sub))] = counts.get(SST.get(sub, hex(sub)), 0) + 1
        chunk = blob[lfo:lfo + cb]
        if sub == 0x120:
            modules[imod] = parse_module(chunk)
        elif sub == 0x12d:
            segmap = parse_segmap(chunk)
        elif sub == 0x125:                       # sstAlignSym
            syms += parse_symrun(chunk, 4, len(chunk))
        elif sub in (0x122, 0x123, 0x129, 0x12a, 0x134):
            cbsym = struct.unpack_from("<I", chunk, 4)[0]
            syms += parse_symrun(chunk, 16, 16 + cbsym)

    # CodeView segment N (1-based) == PE section N-1.
    def sec_of(seg):
        if secs and 1 <= seg <= len(secs):
            return secs[seg - 1]
        return None

    rows = []
    for kind, name, seg, off, plen in syms:
        s = sec_of(seg)
        rva = (s["va"] + off) if s else off
        rows.append({"kind": kind, "section": s["name"] if s else "seg%d" % seg,
                     "seg": seg, "off": off, "rva": rva, "va": imagebase + rva,
                     "size": plen, "name": name, "base": basename(name)})
    rows.sort(key=lambda r: (r["seg"], r["rva"]))

    # Infer sizes from the gap to the next symbol in the same section.
    for i, r in enumerate(rows):
        if r["size"]:
            continue
        nxt = rows[i + 1] if i + 1 < len(rows) else None
        if nxt and nxt["section"] == r["section"] and nxt["rva"] > r["rva"]:
            r["size"] = nxt["rva"] - r["rva"]
        else:
            s = sec_of(r["seg"])
            r["size"] = (s["va"] + s["vsize"] - r["rva"]) if s else 0

    with open(os.path.join(outdir, "modules.txt"), "w") as f:
        f.write("# CodeWarrior link order: %d translation units\n" % len(modules))
        f.write("# imod  style  object                                       segments\n")
        for imod in sorted(modules):
            name, style, segs = modules[imod]
            f.write("%5d  %-2s  %-44s %s\n" % (
                imod, style, name,
                " ".join("seg%d:0x%x+0x%x" % s for s in segs)))

    with open(os.path.join(outdir, "segments.txt"), "w") as f:
        f.write("# CodeView segment map vs PE sections (imagebase 0x%x)\n" % imagebase)
        f.write("# seg  section   rva         vsize     cv_size\n")
        for sg in segmap:
            s = sec_of(sg["index"])
            f.write("  %2d   %-8s  0x%08x  0x%06x  0x%06x\n" % (
                sg["index"], s["name"] if s else "?",
                s["va"] if s else 0, s["vsize"] if s else 0, sg["size"]))

    fields = ["kind", "section", "rva", "va", "size", "base", "name"]
    def dump(path, sel):
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                if not sel(r):
                    continue
                w.writerow(dict(r, rva="0x%08x" % r["rva"], va="0x%08x" % r["va"]))

    dump(os.path.join(outdir, "symbols.csv"), lambda r: True)
    dump(os.path.join(outdir, "functions.csv"), lambda r: r["section"] == ".text")

    text = [r for r in rows if r["section"] == ".text"]
    print("subsections :", counts)
    print("modules     :", len(modules))
    print("symbols     :", len(rows), "(.text %d)" % len(text))
    if text:
        cov = sum(r["size"] for r in text)
        tsec = [s for s in secs if s["name"] == ".text"][0]
        print("text coverage: 0x%x / 0x%x bytes (%.1f%%)"
              % (cov, tsec["vsize"], 100.0 * cov / tsec["vsize"]))


if __name__ == "__main__":
    main()
