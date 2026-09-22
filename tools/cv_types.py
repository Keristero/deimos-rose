#!/usr/bin/env python3
"""Mine struct/class/enum names out of the MSVC-style mangled symbols in
symbols.csv. CodeWarrior encodes parameter types in the mangling, so the
public symbol table doubles as a partial type inventory.

  U<Name>@@   struct        V<Name>@@   class        W4<Name>@@  enum

Usage: cv_types.py <symbols.csv> <out.txt>
"""
import sys, csv, re
from collections import defaultdict

PAT = re.compile(r"(W4|[UV])([A-Za-z_][\w$]*)@@")
TAG = {"U": "struct", "V": "class", "W4": "enum"}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    kinds = defaultdict(set)
    users = defaultdict(set)
    with open(src, newline="") as f:
        for row in csv.DictReader(f):
            # Skip the qualified-name part: type encoding starts after the
            # first "@@". Otherwise a free function "?Name@@YA..." is
            # indistinguishable from a struct reference "UName@@".
            sym = row["name"]
            cut = sym.find("@@")
            if cut < 0:
                continue
            for m in PAT.finditer(sym[cut + 2:]):
                kind, name = TAG[m.group(1)], m.group(2)
                kinds[name].add(kind)
                users[name].add(row["base"])
    with open(dst, "w") as f:
        f.write("# Types recovered from mangled symbol signatures\n")
        f.write("# %d distinct type names\n\n" % len(kinds))
        for name in sorted(kinds):
            f.write("%-10s %-46s referenced by %d symbol(s)\n"
                    % ("/".join(sorted(kinds[name])), name, len(users[name])))
    print("types:", len(kinds))
    by = defaultdict(int)
    for n, ks in kinds.items():
        by["/".join(sorted(ks))] += 1
    print(dict(by))


if __name__ == "__main__":
    main()
