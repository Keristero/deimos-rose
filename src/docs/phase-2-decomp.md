# Phase 2 — Decompilation corpus

**Status: complete.**

```
mise run decomp:setup      # fetch Ghidra 12.1.4 into ~/.cache (~876 MB)
mise run decomp:export     # analyse + export (reuses the project if present)
mise run decomp:reanalyse  # discard the project and re-import from scratch
mise run decomp:index      # summarise the corpus
mise run decomp:find G_Player
mise run decomp:find -- -c G_Film::GetInputs
```

Result: **1,942 functions decompiled, 0 failures**, 8.6 MB of C across 1,942
files in `work/decomp/export/`, grouped by translation unit, with an
`index.tsv` mapping module → RVA → size → file.

The corpus is derived from the copyrighted executable, so `work/` is
gitignored. It regenerates in about a minute once the Ghidra project exists.

## Correction: Ghidra reads the CodeView symbols itself

The plan claimed our symbol map is what makes this possible, and that stock
tooling "comes up empty". **That is wrong for Ghidra.** Its PE loader ships a
complete CodeView parser — `DebugCodeView`, `DebugCodeViewSymbolTable`,
`OMFDirHeader`, `OMFDirEntry`, `OMFModule`, `OMFSegMap`, `OMFGlobal`,
`OMFLibrary` — so it reads the NB11 blob and demangles the MSVC names without
help.

The clean re-import reports it plainly:

```
DeimosDecomp: 1942 .text symbols from symbols/functions.csv
DeimosDecomp: renamed 0, kept Ghidra's name for 1920, created 22
DeimosDecomp: exported 1942, failed 0
```

Ghidra had already named 1,920 of the 1,942 functions. What our map still
contributes:

- **22 functions Ghidra's analyser never found.** Our addresses create them, so
  they get decompiled rather than sitting as raw bytes.
- **Independent corroboration.** Two separate parsers agreeing on 1,920
  addresses is much stronger evidence than either alone — on top of the 99.9%
  instruction-boundary check in `tools/validate_symbols.py`.
- **A portable artifact.** `symbols/functions.csv` drove the size/scope
  analysis, feeds the Odin side, and needs no 876 MB dependency.

What remains true: `7z` cannot open the installer, and a CodeView-4 parser
finds nothing because CodeWarrior emits CV5 "ST" records. Ghidra was simply
never in that category, and the earlier note overstated the case.

## Corpus layout

| Module group | Functions | Bytes |
|---|---:|---:|
| `_other` (QTML, misc runtime) | 429 | 122,051 |
| `_msl` (Metrowerks C++ stdlib) | 224 | 31,510 |
| `_thirdparty` (libpng/jpeg/zlib) | 205 | 112,049 |
| `_ambrosia_IT` / `_DT` / `_FT` / `_ST` | 335 | 161,853 |
| `_burgerlib` | 61 | 19,457 |
| `G_*` / `U_*` game modules | ~666 | ~311,000 |

Only the last row needs reading. The rest is identified so it can be skipped.

## What the corpus gave up immediately

### The film format, complete

`G_Film::Load`, `::GetInputs` and `::SetInputs` together specify it.

- Loaded with `U_Pak_GetPtrToTagData(0x6d6c6966, id)` — `0x6d6c6966` is `"film"`.
- The blob is **0x9d68 = 40,296 bytes**, exactly the size of
  `Data/Local/film/Last Film[last].film`.
- Version magic is **0x2715 = 10005**, independently confirming the remaster
  project's "v10005" naming.
- **Films are stored big-endian.** `Load` compares the magic and, on mismatch,
  runs every field through `_SwapULong` — the Mac byte order survives into the
  Windows build.

Layout, with offsets relative to the start of the blob:

| Offset | Field |
|---|---|
| `+0x00` | version, `10005` |
| `+0x04` | random seed (`GetRandomSeed` returns this) |
| `+0x08` | 8 bytes not yet identified — likely game type |
| `+0x10 + p*0x4eac` | frame count for player `p` |
| `+0x14 + p*0x4eac` | a timestamp-like value (`arg + 0xb3ac2`) |
| `+0x18 + p*0x4eac` | level id (`G_Game_GetLevelID`) |
| `+0x1c + p*0x4eac` | one input byte per frame, **max 20,000 frames** |

Per-player stride is `0x4eac` = 20,140 bytes, and
`0x10 + 2 * 0x4eac = 40,296` accounts for the whole blob exactly.

### Input is one byte, seven bits

`SetInputs` packs seven booleans into a single byte per player per frame, and
`GetInputs` unpacks them. This confirms the seven-button model already in
`sim/input.odin`, and means a rollback input word is one byte per player.

The bit-to-field mapping is a permutation, so the on-disk bit order differs
from the `G_Input_PlayerInputs` struct order:

| Bit | Struct field |
|---|---|
| `0x01` | `[3]` |
| `0x02` | `[1]` |
| `0x04` | `[0]` |
| `0x08` | `[2]` |
| `0x10` | `[4]` |
| `0x20` | `[5]` |
| `0x40` | `[6]` |

Which button each field *is* needs `G_Input_CachePlayerInputs` and
`U_Prefs_GetPlayerKeyCodes`. That is Phase 3.

## Notes on running it

- **Ghidra rejects any path element starting with `.`** — including the `..`
  that mise leaves in `{{config_root}}/../` values. `export.sh` runs every path
  through `realpath -m` before handing it over. Both a `~/.cache` project path
  and an unnormalised `src/../game/...` import path fail with
  `Path element starting with '.' is not permitted`.
- `ERROR Invalid GIF data`/`Invalid PNG data` during analysis are noise: the
  data-type scanner finds false image signatures in `.data`, unsurprising with
  libpng and libjpeg statically linked. Harmless.
- Do not set the fully qualified name on a C++ function. Ghidra already owns
  the class namespace, so `setName("G_Film::GetRandomSeed")` yields
  `G_Film::G_Film__GetRandomSeed`. The script now only renames functions whose
  name is still a Ghidra default.

## Open questions

- The 8 bytes at film `+0x08`, presumably game type.
- The `+0xb3ac2` constant added to the timestamp argument.
- Which physical button each `G_Input_PlayerInputs` field represents.
