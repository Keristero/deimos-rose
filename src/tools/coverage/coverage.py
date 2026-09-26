#!/usr/bin/env python3
"""Block coverage of the simulation (notes/ecs-refactor.md asks for it).

Odin has no coverage instrumentation of its own, so this makes a copy of
the source tree with a counter at the head of every block of the
simulation's code -- sim/ and the plugins' simulation halves, not their
view/ packages -- runs the test suite against the copy, and reports the
blocks that never ran.

    coverage.py instrument SRC OUT   copy SRC to OUT, instrumented
    coverage.py report OUT           summarise OUT/hits.bin

A block is a procedure body, the body of an if, else, for or when, or a
case of a switch, where it starts on a line of its own. One-line blocks
(`if x { return }`) are not counted.
"""
import json
import os
import re
import shutil
import sys

COPY = ['sim', 'plugins', 'third_party', 'data', 'net', 'prefs', 'render', 'ui', 'game', 'oracle', 'tests']
PKG = 'drcov'

TOK = re.compile(r'''(?P<lc>//[^\n]*)|(?P<bc>/\*.*?\*/)|(?P<str>"(?:\\.|[^"\\\n])*")|(?P<raw>`[^`]*`)|(?P<rune>'(?:\\.|[^'\\\n])+')|(?P<other>[^/"`']+|.)''', re.S)
PROC_BODY = re.compile(r'\bproc\s*(?:"[^"]*"\s*)?\(')
BLOCK_START = re.compile(r'^\s*(?:\}\s*)?(?:if|else|for|when)\b')
SIG_END = re.compile(r'^\s*\)(?:\s*->.*)?\s*(?:where\b.*)?\{$')
CASE = re.compile(r'^\s*case\b.*:$')


def code_lines(text):
    """Each line with comments and literals blanked, and the brace depth at
    its start."""
    blank = []
    for m in TOK.finditer(text):
        s = m.group()
        if m.lastgroup in ('lc', 'bc', 'str', 'raw', 'rune'):
            s = re.sub(r'[^\n]', ' ', s)
        blank.append(s)
    lines = ''.join(blank).split('\n')
    depth, out = 0, []
    for l in lines:
        out.append((l, depth))
        depth += l.count('{') - l.count('}')
    return out


def instrument_file(path, counters):
    text = open(path).read()
    src = text.split('\n')
    code = code_lines(text)
    out = []
    added = False
    for i, line in enumerate(src):
        out.append(line)
        c, depth = code[i]
        s = c.rstrip()
        hit = False
        if s.endswith('{') and depth > 0 and not re.search(r'\bswitch\b', s):
            hit = bool(BLOCK_START.match(s) or PROC_BODY.search(s) or SIG_END.match(s))
        elif s.endswith('{') and depth == 0 and PROC_BODY.search(s):
            hit = True
        elif CASE.match(s) and depth > 0:
            hit = True
        if hit:
            indent = re.match(r'^\s*', line).group() + '\t'
            out.append(f'{indent}{PKG}.hits[{len(counters)}] = 1')
            counters.append((path, i + 1, line.strip()))
            added = True
    if added:
        out = add_import(out)
    open(path, 'w').write('\n'.join(out))


def add_import(lines):
    for i, l in enumerate(lines):
        if l.startswith('package '):
            return lines[:i + 1] + ['', f'import {PKG} "dr:{PKG}"'] + lines[i + 1:]
    return lines


def simulation_files(root):
    for top in ('sim', 'plugins'):
        for d, _, fs in os.walk(os.path.join(root, top)):
            if os.sep + 'view' in d[len(root):]:
                continue
            for f in sorted(fs):
                if f.endswith('.odin'):
                    yield os.path.join(d, f)


def instrument(src, out):
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    for d in COPY:
        shutil.copytree(os.path.join(src, d), os.path.join(out, d))
    counters = []
    for f in sorted(simulation_files(out)):
        instrument_file(f, counters)
    os.makedirs(os.path.join(out, PKG))
    open(os.path.join(out, PKG, PKG + '.odin'), 'w').write(f'''package {PKG}

import "base:runtime"
import "core:strings"
import "core:os"
import "core:sys/posix"

// Where each block's counter is. With DR_COV_OUT set, the counters are
// that file, mapped in, so they are on disk however the process ends --
// the test runner ends with os.exit, which runs no `@(fini)`.
hits: [^]u8

@(private)
own: [{len(counters)}]u8

@(init)
map_counters :: proc "contextless" () {{
	context = runtime.default_context()
	hits = &own[0]
	path := os.get_env("DR_COV_OUT", context.temp_allocator)
	if path == "" {{
		return
	}}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {{.CREAT, .RDWR}}, {{.IRUSR, .IWUSR}})
	if fd < 0 || posix.ftruncate(fd, {len(counters)}) != .OK {{
		return
	}}
	p := posix.mmap(nil, {len(counters)}, {{.READ, .WRITE}}, {{.SHARED}}, fd)
	if p != posix.MAP_FAILED {{
		hits = ([^]u8)(p)
	}}
}}
''')
    rel = [(os.path.relpath(p, out), n, t) for p, n, t in counters]
    json.dump(rel, open(os.path.join(out, 'counters.json'), 'w'))
    print(f'coverage: {len(counters)} blocks in {len({p for p, _, _ in rel})} files')


def report(out):
    counters = json.load(open(os.path.join(out, 'counters.json')))
    hits = open(os.path.join(out, 'hits.bin'), 'rb').read()
    per = {}
    missed = []
    for (p, n, t), h in zip(counters, hits):
        tot = per.setdefault(p, [0, 0])
        tot[0] += 1
        tot[1] += 1 if h else 0
        if not h:
            missed.append(f'{p}:{n}: {t}')
    groups = {}
    for p, (n, h) in per.items():
        g = os.path.dirname(p)
        tot = groups.setdefault(g, [0, 0])
        tot[0] += n
        tot[1] += h
    width = max(len(g) for g in groups)
    for g in sorted(groups):
        n, h = groups[g]
        print(f'{g:<{width}}  {h:5d} / {n:5d}  {100 * h / n:5.1f}%')
    n, h = len(counters), sum(1 for x in hits if x)
    print(f'{"total":<{width}}  {h:5d} / {n:5d}  {100 * h / n:5.1f}%')
    open(os.path.join(out, 'missed.txt'), 'w').write('\n'.join(missed) + '\n')
    print(f'blocks never run: {os.path.join(out, "missed.txt")}')


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'instrument':
        instrument(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == 'report':
        report(sys.argv[2])
    else:
        sys.exit(__doc__)
