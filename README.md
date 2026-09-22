# Deimos Rising — decompilation groundwork

Preparation work for decompiling the Windows build of **Deimos Rising 1.0.2**
(Swoop Software / Ambrosia Software, 2001–2003), a vertically scrolling
shooter. Ambrosia shut down in 2019 and the game is abandonware.

This repository holds the extracted distribution, recovered symbol data and
the tooling to regenerate both. It does **not** yet contain decompiled source.

## Layout

```
orig/      pristine download: NSIS installer + Read Me   (not in git)
game/      extracted 1.0.2 install tree, 78 files        (not in git)
symbols/   recovered CodeView symbol data                (text outputs tracked)
tools/     extraction and symbol-recovery tooling
notes/     analysis write-ups
```

`orig/SHA256SUMS` and `game/SHA256SUMS` pin every input and output;
`sha256sum -c SHA256SUMS` in either directory verifies them.

## Headline findings

**The shipped executable was never stripped.** Its entire PE overlay — 271,280
bytes — is a CodeView `NB11` debug blob carrying **2,692 public symbols**,
covering 100% of the text section, plus the full 685-entry object list in link
order. Function names, the `U_`/`G_`/`W_` module structure, and 75 struct/enum/
class names all come back.

**The toolchain is Metrowerks CodeWarrior, not MSVC** (`.exc` section, MSL
runtime objects, linker version 3.0). A matching decomp needs CodeWarrior for
x86.

**It is a Mac port running on QuickTime Media Layer.** QTML is statically
linked, Apple's build paths survive in the debug info, and Mac Toolbox types
(`CGrafPort`, `BitMap`, `ColorTable`) appear in mangled signatures.

Full detail in [notes/binary-triage.md](notes/binary-triage.md).

## Extracting the installer

`Install Deimos Rising.exe` is **NSIS 2.0b1** (February 2003). That beta's
archive layout is not understood by 7-Zip's `Nsis` handler — tested 26.02 on
the host and via Debian's p7zip, both fail with:

```
Open ERROR: Cannot open the file as [Nsis] archive
```

The payload is a single solid stream: there is no parseable block chain from
the first header, and the stream is not stock deflate, bzip2 or LZMA (NSIS
ships modified codecs). Rather than reimplement a 2003 beta's decompressor,
the extraction runs the installer's own silent mode under Wine, in a
throwaway container with networking disabled:

```sh
tools/extract_installer.sh              # -> game/
```

It builds `tools/Containerfile` (Debian + Wine + Xvfb) on first use. The
NSIS-generated `Uninstall.exe` is dropped, since it is created at install time
rather than shipped.

## Recovering symbols

```sh
python3 tools/cv_parse.py game/DeimosRising.exe symbols/
python3 tools/cv_types.py symbols/symbols.csv symbols/types.txt
```

Outputs:

| File | Contents |
|---|---|
| `symbols/DeimosRising.cv` | raw CodeView blob carved from the overlay |
| `symbols/modules.txt` | 685 translation units in link order |
| `symbols/segments.txt` | CodeView segment map vs PE sections |
| `symbols/symbols.csv` | all 2,692 symbols: RVA, VA, section, size, demangled base name |
| `symbols/functions.csv` | the 1,942 `.text` symbols |
| `symbols/types.txt` | 75 struct/enum/class names mined from mangled signatures |

Sizes are exact where CodeView supplies them and otherwise inferred from the
gap to the next symbol, which is reliable here because symbol coverage of
`.text` is complete.

The map is checked against the binary itself:

```sh
python3 tools/validate_symbols.py game/DeimosRising.exe symbols/functions.csv
```

**99.9% of the 1,941 checked symbol addresses** land immediately after `nop`
padding or a `ret` — i.e. exactly where function boundaries belong. Two
addresses do not, out of 1,941. The map lines up with the binary.

`symbols.csv` loads directly into Ghidra or IDA as a symbol map — `va` is the
absolute address at the default image base of `0x400000`.

## Suggested next steps

1. Import `symbols/functions.csv` into a disassembler. `validate_symbols.py`
   already confirms the addresses are real function boundaries, so this is
   about naming quality rather than correctness.
2. Reverse struct layouts from the disassembly. **There is no shortcut**: the
   `sstGlobalTypes` subsection is present but empty (8 bytes), so the debug
   data supplies type *names* only, never field offsets. This is the dominant
   cost of the whole project.
3. Source a CodeWarrior for Windows x86 release contemporary with the 2003
   build if a byte-matching decomp is the goal.
4. Decide the scope boundary. ~22% of `.text` is vendored libpng, libjpeg,
   zlib, Burgerlib and MSL; identify it against upstream rather than
   reconstruct it. See [notes/porting-to-linux.md](notes/porting-to-linux.md).

## Related work

[adamjvr/Deimos-Rising-Remastered](https://github.com/adamjvr/Deimos-Rising-Remastered)
is a clean-room C++20 reimplementation — explicitly *not* a decompilation —
with useful format documentation under `reverse/formats/` (`PAK_FORMAT.md`,
`LEVEL_FORMAT.md`, `FILM_V10005.md`, `PEF_1_0_6.md`, `DATA_FORMAT_LEDGER.md`).
Its findings on the PAK layout match what is observed here: stored-method ZIP
archives keyed by FourCC.

Note that its `PEF_1_0_6.md` targets the **Mac PowerPC** build. The Windows
binary analysed here ships full CodeView symbols, which the PEF build is
unlikely to have — so this symbol map may be new information for that project.

Because that project maintains a clean-room policy, symbol data and
disassembly derived from the original executable should **not** be contributed
to it without checking its `docs/CLEAN_ROOM.md` and `docs/ASSET_POLICY.md`
first.

## Legal

Deimos Rising is © 2001–2003 Swoop Software and Ambrosia Software, Inc. The
game binaries and assets under `orig/` and `game/` are not redistributed by
this repository and are excluded from version control. Only tooling, derived
symbol listings and analysis notes are tracked. Supply your own copy of the
installer to reproduce the extraction.
