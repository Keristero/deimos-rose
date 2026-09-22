# What stands between here and a Linux build

Status: **no decompiled code exists yet.** This repository is groundwork —
extraction, a validated symbol map, and analysis. The estimate below is what
remains.

## Where the 776 KB of code goes

| Origin | Symbols | Bytes | Share | Disposition |
|---|---:|---:|---:|---|
| Game logic (`G_*`) | 361 | 228,576 | 29.5% | **reconstruct** |
| Ambrosia `*_Tool.x86.LIB` (`DT_ FT_ IT_ ST_ PT_ SSP_ RT_`) | 356 | 173,771 | 22.4% | **reconstruct or replace** |
| libpng / libjpeg / zlib / unzip | 257 | 120,782 | 15.6% | upstream sources |
| QTML + unresolved | 401 | 117,166 | 15.1% | mostly delete (see below) |
| Portable utility (`U_*`) | 305 | 82,976 | 10.7% | **reconstruct** |
| MSL C++ stdlib | 190 | 30,086 | 3.9% | libstdc++ |
| Burgerlib (`BurgerW95.Lib`) | 72 | 22,665 | 2.9% | upstream (open source) |

**~485 KB across 1,022 functions has to be written by hand.** Roughly 22% can
come from existing sources instead.

## What makes this easier than a typical decomp

- **Complete symbol coverage.** 1,942 named functions over 100% of `.text`,
  boundary-validated at 99.9%. You never have to guess where a function starts
  or what it is called. Most decomp projects spend months getting to this point.
- **Module structure is known.** 685 translation units in link order, with the
  original `U_`/`G_`/`W_` layering recovered.
- **The architecture is documented by the original developers.** The shipped
  `DeimosRisingWin32.log` enumerates all 23 engine managers.
- **No GPU dependency.** The game is a software blitter writing 16-bit pixels
  into a DIB. Nothing to reimplement in GL or Vulkan; the render path is a
  memory buffer and one blit.
- **Tiny platform surface.** GDI blit, `waveOut`, `joyGetPosEx`, `timeGetTime`.
  All four map onto SDL directly.
- **The porting seam already exists.** `W_*` modules implement `U_App_*` and
  friends for Win32; a Linux build replaces those 15 modules rather than
  touching `G_*` or `U_*` at all. The original codebase was already
  cross-platform (it shipped on Mac).
- **QTML mostly evaporates.** QuickTime Media Layer is an artifact of running
  Mac Toolbox code on Windows. A Linux target reimplements the handful of
  services the game actually wants instead of porting the emulation layer.

## What makes it hard

- **No struct layouts, at all.** `sstGlobalTypes` is empty. The debug data
  gives type *names* (75 of them) and function names, never field offsets.
  Recovering `G_Entity`, `G_UnitDef`, `G_WepDef`, `G_Level` and the rest from
  disassembly is the single largest cost in the project, and nothing in the
  binary shortcuts it.
- **1,022 functions is a lot of functions.** At a sustained 5–10 functions per
  day — optimistic for a solo effort, and it will be slower through the dense
  entity/particle/blitter code — that is roughly **6–12 months of focused
  solo work** to a readable, compiling C/C++ reconstruction. Then integration
  and debugging on top.
- **The Ambrosia toolkits are proprietary and undocumented.** 174 KB of
  `Draw_Tool`, `Interface_Tool`, `File_Tool`, `sound_tool`. Some of it —
  windowing, dialogs, buffered file I/O — is replaceable with SDL and stdio
  rather than reconstructed, but that is a design decision, not a free pass.
- **A *matching* decomp is substantially harder still.** Byte-identical output
  requires Metrowerks CodeWarrior for Windows x86 from around 2003. That
  compiler is out of print and awkward to source. If matching is not a goal,
  drop this constraint — it buys correctness assurance at a very high price.

## Two honest routes

**Route A — decompile, then port.** 6–12 months solo to readable source, plus
integration. You end up owning the real engine, bit-accurate behaviour, and
the ability to diff against the original. This is the route this repository is
set up for.

**Route B — build on the reimplementation.**
[adamjvr/Deimos-Rising-Remastered](https://github.com/adamjvr/Deimos-Rising-Remastered)
is C++20 + CMake and genuinely parses the real PAKs: 871 files CRC-validate
across four archives, all 12 levels and 386 unit definitions parse.

But it is **not closer to a playable Linux build than a decomp is** — it has no
platform layer whatsoever. `CMakeLists.txt` builds exactly one static library
(`deimos_core`, zero external dependencies) plus a `deimos_reference_probe`
validation tool and the test binaries. There is no `main`, no window, no input
handling and no audio output; `render_backend.hpp` composites into a
`std::vector<std::uint16_t>` held in memory. `docs/PLATFORM_PLAN.md` is 605
bytes of intent, and it ranks Linux third behind macOS and iPadOS.

On its own roadmap (7 phases), it self-reports as Phase 1 with early Phase-2
primitives. **Playable is Phase 4; Linux is Phase 5.**

Its value to this project is the format and behaviour research in
`reverse/formats/`, not a shortcut to a running game.

### The clean-room policy is less restrictive than it first appears

`docs/CLEAN_ROOM.md` forbids copying "decompiler pseudocode or
machine-translated original implementation" into their source tree. Its
explicitly **allowed** observations include:

- "hashes, sizes, offsets, resource tags, filenames, and paths";
- "API/library imports and linkage structure";
- "original source filenames/assertion text as correspondence evidence";
- "manually assigned semantic names supported by evidence".

Everything in `symbols/` falls in that allowed column — it is names, offsets,
linkage and the object-file list, not translated code. An earlier note in this
repository claimed the two efforts could not be merged; that overstated the
policy.

There is a concrete reason to think the symbol map is useful to them: their
`include/deimos/render_backend.hpp` carries the comment *"Exact low request
bits consumed by 0x19570"*. In this repository's map, `0x19570` falls inside
`G_EG_BuildDrawList` (RVA `0x19060`, 2,160 bytes) — an entity-group draw-list
builder, exactly the subsystem that header reconstructs. They are citing
addresses this map can name. One corroborating data point rather than proof,
but a promising one.

## Highest-leverage next steps

1. Load `symbols/functions.csv` into Ghidra and start on `U_Pak`, `U_File`,
   `U_String`, `U_Math` — small, leaf-heavy, well-understood, and they unblock
   everything above them.
2. Recover the core struct layouts (`G_Entity`, `G_UnitDef`, `G_WepDef`,
   `G_Level`) early. Every later function depends on them, and getting them
   wrong late is expensive.
3. Diff the libpng/libjpeg/zlib regions against contemporary upstream releases
   to pin exact versions, then exclude ~121 KB from scope entirely.
4. Decide up front whether matching matters. It changes the toolchain, the
   schedule, and whether the project is feasible solo.
