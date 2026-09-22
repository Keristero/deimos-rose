# Phase 0 — Scaffold

**Status: complete.** `mise run ci` is green and `mise run run` opens a window.

## What exists

```
src/
├── mise.toml          every task; nothing is run any other way
├── game/              entry point, raylib window, input capture
├── sim/               deterministic core — no raylib, no I/O
├── data/              parsers: zip, resource names, TGA, AIFF
├── tools/
│   ├── setupdeps/     X11/GL dev symlinks for immutable hosts
│   ├── purity/        CI guard on sim/
│   ├── extract/       Phase 1 asset pipeline
│   └── verify/        Phase 1 verification
└── tests/             15 tests, no original game data required
```

## Tasks

| Task | Purpose |
|---|---|
| `setup` | create `.deps/lib` symlinks and `build/` |
| `build` / `dev` / `run` | optimised build, debug build, run |
| `check` | type-check and vet every package **including `tools/`** |
| `test` | Odin test suite |
| `purity` | assert `sim/` imports nothing forbidden |
| `assets:extract` | PAKs → `assets/` |
| `assets:verify` | validate `assets/` against manifest and PAKs |
| `ci` | `check` + `purity` + `test` |

## Things that needed solving

### raylib would not link on Bazzite

raylib's prebuilt Linux `.so` links against unversioned `-lX11 -lGL …`. Image-
based distributions ship only the versioned runtime libraries (`libX11.so.6`),
so `ld` fails with `cannot find -lX11`.

Rather than mutate the host, `tools/setupdeps/setup.sh` materialises the dev
symlinks into a project-local `.deps/lib` and every build task adds
`-extra-linker-flags:-L…/.deps/lib`. Verified working with raylib 6.0.

### `odin check` rejects linker flags

The collection flag and the linker flag had to be separated into `$DR_COLL`
and `$DR_LINK`; `check` takes only the former.

### `check` initially missed `tools/`

A refactor broke `tools/extract` while `mise run check` stayed green, because
the task only covered `game`, `sim` and `data`. `tools/extract` and
`tools/verify` are now checked too. Any new package must be added to the
`check` task — this is the one piece of the scaffold that fails silently.

### core:os is the os2-style API

This Odin nightly (`dev-2026-09`) returns `Error` values rather than `bool`,
and uses `Permissions` bit sets. `os.read_entire_file` needs an explicit
allocator argument.

## The simulation purity rule

`sim/` must not import `vendor:raylib`, `core:os`, `core:fmt`, `core:time`,
`core:math/rand`, `core:thread` or `core:net`. It takes inputs plus a seed and
produces state; nothing else may influence it.

This is not stylistic. Film replay, rollback netcode and fast headless tests
all require it, and it is very expensive to retrofit. `tools/purity/check.sh`
enforces it as part of `ci`.

The RNG lives in the state (`sim.Rand`, xorshift32) precisely because an
ambient global generator would desync rollback silently.

## What Phase 0 proved

The `sim`/presentation split already works end to end: `game/main.odin`
captures input from raylib and hands `sim.Frame_Input` to `sim.step`, while
`sim` knows nothing about raylib. `sim.replay` runs a film through the same
`step` the live game uses, and a test asserts the two produce identical
checksums.
