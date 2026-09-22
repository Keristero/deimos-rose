# Deimos Rising → Odin: reimplementation plan

## The reframe that makes this tractable

The goal is **not** a decompilation. It is a new game in Odin that behaves like
the original. That single change deletes most of the work measured in
[porting-to-linux.md](porting-to-linux.md).

Decompiler output stops being a deliverable and becomes *reference material* —
something to read when a behaviour is unclear, not something to reproduce.

### What that deletes

Of 1,942 named functions in `.text`:

| Origin | Functions | Bytes | Fate |
|---|---:|---:|---|
| Ambrosia `*_Tool.x86.LIB` | 356 | 173,771 | **delete** → raylib |
| QTML / Mac Toolbox | 401 | 117,166 | **delete** → raylib |
| libpng / libjpeg / zlib / unzip | 257 | 120,782 | **delete** → Odin core + raylib |
| MSL C++ stdlib | 190 | 30,086 | **delete** → Odin core |
| Burgerlib | 72 | 22,665 | **delete** → raylib |
| `U_*` platform/util | 198 | 60,240 | **delete** → raylib + Odin core |
| **Game behaviour (`G_*` + sim-relevant `U_*`)** | **468** | **251,312** | **port** |

**468 functions is the real project.** Everything else is a library someone
else already wrote, and raylib covers nearly all of it.

The heavy modules, in the order they matter:

```
G_EG 19   G_Player 54   G_UnitDef 17   G_Game 18   G_Entity 30
G_Interface 8   G_Text 11   G_ScoreBar 7   G_Particle 7
G_WeaponHandler 24   G_WepDef 11   G_GameObject 23   U_PixelScale16 17
```

## Shortcuts, ranked by leverage

### 1. The clean-room project is now fully usable to us

[adamjvr/Deimos-Rising-Remastered](https://github.com/adamjvr/Deimos-Rising-Remastered)
is 316 KB of C++20 plus 338 KB of format research under `reverse/formats/`. It
has no playable target and is dormant since 2026-08-29 — but as *reference* it
is excellent, and we are under no clean-room obligation.

Directly reusable:

- `reverse/formats/` — `PAK_FORMAT`, `LEVEL_FORMAT`, `FILM_V10005`,
  `LEGACY_TAGGED_TEXT`, `ENTITY_CONSTRUCTION`, `DATA_FORMAT_LEDGER`, and ~20
  runtime contracts (collision, particle, spawn, terrain, sprite, player).
- `src/core/*.cpp` — working parsers for PAK, levels, unit/weapon/player
  definitions, films, sprite plates, audio resources.
- Their validation numbers as our acceptance targets: **871 files CRC-validate
  across four PAKs, 763 in `Game.pak`, 12 levels, 565 placements, 386 unit
  definitions, 5 weapons, 2 player definitions, 4 films.**

Treat it as a second opinion, not gospel: it was produced in 23 commits over
two days, and its "binary-confirmed" labels are self-asserted. Where it and the
disassembly disagree, the binary wins.

Cross-check it against our symbol map. Their `render_backend.hpp` cites
"0x19570", which lands inside `G_EG_BuildDrawList` in `symbols/functions.csv` —
their address references can be named automatically.

### 2. Our symbol map turns Ghidra into a batch tool

`symbols/functions.csv` has 1,942 names at validated addresses. Ghidra headless
can import them and export decompiled C per function, unattended:

```
analyzeHeadless <proj> DR -import game/DeimosRising.exe \
  -preScript ImportSymbols.java symbols/functions.csv \
  -postScript ExportDecompiled.java build/decomp/
```

Output: a named C file per function, grouped by module. Not pretty, but it
answers "what does `G_Player_ApplyDamage` actually do" in seconds instead of
an afternoon. Only ~468 of those files ever need reading.

### 3. The assets are already in ordinary formats

Probed directly from the PAKs — **every archive is stored (method 0) ZIP**, so
no decompression is needed at all:

| Archive | Entries | Contents |
|---|---:|---|
| `Game.pak` | 763 | `im08/` 248 GIF, `im16/` 38, `unde/` 386, `tefo/` 54, `leve/` 12, `idli/` 6, `stli/` 5, `wede/` 5, `film/` 4, `plde/` 2, `coli/` 1, `flli/` 1, `reli/` 1 |
| `Audio.pak` | 96 | AIFF `FORM` containers, IMA ADPCM |
| `Music.pak` | 3 | AIFF + IMA |
| `Interface.pak` | 9 | uncompressed TGA (type 2) |

Sprites ship as **GIF pairs**: `Expl Small Red IA[EXSR].gif` is the alpha
plate, `Expl Small Red IC[exsr].gif` the colour plate — uppercase FourCC for
alpha, lowercase for colour. Combining them into RGBA PNG is a dozen lines.

So the asset pipeline is: unzip → pair IA/IC → PNG; TGA → PNG; AIFF/IMA →
OGG; `unde`/`wede`/`plde`/`leve`/`tefo`/`stli`/`idli` → JSON. All batch, all
verifiable by count and checksum. No reverse engineering needed for the media
itself — only for the definition records, which the remaster already documents.

### 4. The shipped demo films are free golden tests

`G_Film` records and replays **player input**, and the game ships 4 films in
`Game.pak` plus `Last Film[last].film`. Two consequences:

- **The original simulation is deterministic and input-driven.** That is the
  hardest prerequisite for rollback netcode, and it is already proven.
- **We inherit regression vectors we did not have to author.** Feed a 2003 film
  into the Odin sim; if the resulting state trace diverges, we are wrong.

This is the backbone of the test strategy and it comes free.

## Decisions to make before coding

### GGPO will not link on Linux as shipped

`$ODIN_ROOT/vendor/ggpo/ggpo.odin` contains exactly one foreign import:

```odin
foreign import lib "GGPO.lib"
```

No `when ODIN_OS` branches anywhere in the file, and no `lib/` directory. It is
Windows-only. `vendor/ENet` is fine — it falls back to
`foreign import ENet "system:enet"` on non-Windows — but `libenet` is not
installed on this machine, so it needs to come from mise or the distro.

Two options:

- **(A) Build GGPO for Linux** from source, emit a static lib, and patch the
  vendor binding's foreign import. Keeps the requested dependency. Upstream
  `pond3r/ggpo` is dormant and Windows-centric; expect friction.
- **(B) Write the rollback layer over ENet directly.** For a 2-player game with
  an already-deterministic sim and a fixed input word, synchronised rollback is
  roughly 600–1000 lines: input queue, prediction, confirmed frame, state
  save/restore ring, resimulation.

**Recommendation: (B).** The hard part of rollback is deterministic state
save/restore, which we must build regardless; GGPO would not provide it. Going
direct also removes a dormant C dependency from a project whose whole premise
is a clean Odin foundation. Keep the GGPO binding as a later alternative
backend behind the same interface if you want it.

### Faithful vs. delightful

These pull against each other. Suggested rule: **`sim/` is faithful, everything
else is delightful.** Gameplay-visible behaviour matches the original bit for
bit where films can prove it; rendering, audio, UI, netcode and tooling are
written the way you would write them today.

### Where `/src` lives

Assumed `deimos_rising/src/`, alongside `game/`, `symbols/` and `tools/`,
matching how `/decomp/deimos_rising` was project-relative. Say the word if you
meant a separate top-level repository.

## Target layout

```
src/
├── mise.toml            # every task: build, run, test, assets, decomp, ci
├── game/                # entry point, scene/mode flow
├── sim/                 # deterministic core — MUST NOT import raylib
│   ├── entity/ player/ weapon/ particle/ collision/ spawn/ level/
├── data/                # JSON + asset loading into sim structs
├── render/              # raylib presentation
├── audio/               # raylib audio
├── net/                 # rollback + ENet + lobby UI
├── platform/            # paths, prefs, config
├── tools/               # asset pipeline, ghidra scripts, film differ
├── tests/
└── assets/              # generated, gitignored
```

The one architectural rule that matters: **`sim/` imports nothing from raylib
and performs no I/O.** It takes inputs and a seed, and produces state. That is
what makes films replayable, rollback possible, and tests fast. Enforce it with
a CI grep, not good intentions.

### `src/mise.toml` sketch

```toml
[tools]
odin = "dev-2026-09"

[env]
DR_ORIG = "{{config_root}}/../game"
DR_ASSETS = "{{config_root}}/assets"

[tasks.setup]           # fetch libenet, verify raylib, build ghidra image
[tasks.build]           run = "odin build game -out:build/deimos -o:speed"
[tasks.run]             depends = ["build"]
[tasks.test]            run = "odin test tests -all-packages"
[tasks.check]           run = "odin check game -vet -strict-style"
[tasks."assets:extract"] # PAK -> PNG/OGG/JSON
[tasks."assets:verify"]  # counts + checksums vs manifest
[tasks."decomp:export"]  # ghidra headless -> build/decomp/<module>/<fn>.c
[tasks."test:films"]     # replay original films, diff state traces
[tasks.ci]              depends = ["check", "test", "assets:verify", "test:films"]
```

## Phases

Each phase ends in something runnable and testable.

### Phase 0 — Scaffold (days)
`src/` tree, `mise.toml`, Odin + raylib window, CI running `check` + `test`.
Add the `sim/` purity check to CI on day one.
**Exit:** `mise run ci` is green; a raylib window opens.

### Phase 1 — Asset pipeline (1–2 weeks)
Stored-ZIP reader; IA/IC GIF pairs → RGBA PNG; TGA → PNG; AIFF/IMA → OGG;
FourCC record types → JSON. Written as Odin tools so the language gets
exercised early on a low-risk task.
**Exit:** 871 files extracted and checksum-verified; 386 unit definitions, 12
levels, 5 weapons, 2 player definitions round-trip through JSON.

### Phase 2 — Decomp corpus (days, mostly unattended)
Ghidra headless with our symbols; export named C per function; index it so a
module maps to its files. Run it once, keep the output out of git.
**Exit:** `build/decomp/G_Player/*.c` exists and is navigable.

### Phase 3 — Definition & data layer (2–3 weeks)
Odin structs for units, weapons, players, levels, text, string tables. The
17-condition behaviour vocabulary and state/rule execution the remaster
documents. Pure data, heavily tested.
**Exit:** all 565 level placements resolve; cross-resource references validate.

### Phase 4 — Deterministic simulation (6–10 weeks — the bulk)
Entity/group model, spawn scheduler, state machines, collision and damage,
particles, debris, player motion, weapons, scoring. Headless throughout.
**Exit:** original films replay to a matching state trace. This is the
milestone that proves the whole project.

### Phase 5 — Presentation (2–4 weeks)
raylib rendering of the sim's draw list, sprites, terrain scroll, particles,
score bar, text; audio; input; menus. The original composites
`group0 → terrain → group1 → particles → group2` at 416×480×16 — reproduce the
ordering, not the 16-bit blitter.
**Exit:** playable single-player start to finish.

### Phase 6 — Netplay (3–5 weeks)
State save/restore ring over the sim, input prediction, rollback,
resimulation; ENet transport; lobby UI (host/join by address, ping, ready,
desync detection). Two-player co-op already exists in the original design.
**Exit:** two machines play a full level with induced latency and no desync.

### Phase 7 — Polish
Restored assets, widescreen, rebindable controls, packaging.

## Honest estimate

**Roughly 4–6 months of sustained part-time work to Phase 5 (playable
single-player)**, plus 1–2 months for netplay. Full-time and focused, compress
that to perhaps 10–14 weeks.

The distribution is lopsided: Phases 0–3 are mechanical and will go fast and
feel great. **Phase 4 is 60–70% of the total effort** and is where projects
like this stall — it is 468 functions of behaviour with no struct layouts
available, and the films are unforgiving. Budget accordingly, and get the film
replay harness working *before* writing the entity system, not after.

The two things that de-risk everything else: the film-replay test harness, and
the `sim/` purity rule. Both are cheap on day one and expensive to retrofit.
