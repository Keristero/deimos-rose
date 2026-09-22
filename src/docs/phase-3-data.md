# Phase 3 — Definition and data layer

**Status: core complete.** Tagged-text decoding, the level loader, the film
parser and JSON export are done and tested. Typed loaders for unit, weapon and
player definitions remain — see *What is left* below.

```
mise run assets:records   # tagged text -> assets/data/**.json
mise run assets:all       # media + records in one go
mise run test             # 29 tests
```

## Exit criteria

| Criterion | Result |
|---|---|
| All 12 levels parse | yes, field order validated |
| Declared object counts reconcile | yes, **565 placements** exactly |
| Cross-resource references resolve | yes — every unit, image and music id |
| Records available as JSON | 473 records, 474 JSON files, 19 MB |

565 matches the figure the clean-room remaster reports for the Mac 1.0.6
corpus, reached independently here from the Windows 1.0.2 data.

## The resources are text, not binary structs

Ten of the eleven families — `leve`, `unde`, `plde`, `wede`, `idli`, `flli`,
`coli`, `tefo`, `stli`, `reli` — are seven-bit ASCII behind a reversible
per-byte transform:

```
v = ((c & 0x07) << 4) | (c >> 4)
if c & 0x08: v ^= 0x7f
```

Verified over the entire corpus: **all 473 records decode to pure ASCII**, with
no replacement characters. This matches the transform the remaster documents
for Mac 1.0.6, so the same encoding shipped on both platforms — a useful
independent cross-check, and the reason this phase went quickly.

The only non-printable bytes after decoding are one trailing NUL per record,
plus four stray control characters (`0x7f` ×3, `0x04` ×1) sitting inside
human-written `#description_STR` values in `aieg`, `plde`, `s2bu` and `scbu`.
Those are typos in the original data, not an encoding subtlety.

The grammar is `#key <value>` with CR line endings, free indentation, `//`
comments, inline comments after a value, and bare lines for `.stli` string
lists. **FourCC whitespace is significant** — the air layer really is `"air "`
with a trailing space — so codes are never trimmed.

Note that `decode(c) == decode(c ~ 0xff)`: two encoded bytes can produce the
same character. Decoding is well defined; re-encoding cannot be guaranteed to
reproduce the original byte stream, so `tests/` uses a canonical encoder for
synthetic fixtures and makes no round-trip claim about shipped data.

## Levels

Eleven header fields in fixed order, then exactly `numObjects_INT` placements
of seven fields each. The loader checks field order rather than assuming it.

The original data misspells the second field as `indentifier_STR`. That
misspelling is part of the format and is matched verbatim.

Corpus observations, not engine rules:

- every level background is `0, 0, 480, 3600`;
- every level uses `mu03` for music and `none` for briefing;
- exactly two layer ids appear: `"grnd"` (353 placements) and `"air "` (212);
- 114 distinct unit types are placed, most often `fl02` (51 times).

## Films

`.film` is the one binary family, and Phase 2 recovered its layout from
`G_Film::Load`. Now implemented and checked against all five shipped films.

Endianness is per file: the parser accepts whichever order makes the version
read as 10005. The four demos in `Game.pak` are **big-endian**, authored on the
Mac; `Data/Local/film/Last Film[last].film`, written by this Windows build, is
little-endian. Only version, seed, frame count and timestamp are swapped —
FourCCs and the game-type byte read identically either way, which is why the
original never swaps them.

Each demo is single-player: track 1 is empty with level id `"none"`. Demo
levels are `le07`, `le06`, `le02` and `le08`.

### Two corrections to `sim/`

Phase 0 guessed at two types. Both were wrong and are now fixed:

- **`Game_Type.Single` is 1, not 0.** `G_Player::Priv_ResetPosition` reads the
  single-player start position from `G_PlayerDef` when the value is 1 and the
  two-player start otherwise, and `G_Player`'s constructor defaults it to 1.
  The co-operative value is still **provisional** — nothing pins it yet.
- **`level_id` is a FourCC, not a `u16`.** Levels are addressed as `"le01"` …
  `"le12"`, with `"none"` as the empty id. `sim.Level_ID` is now a 4-byte id.

### Input bits: mapping known, semantics not

`SetInputs` packs seven booleans into one byte per player per frame, and the
bit-to-field mapping is exact. What each `G_Input_PlayerInputs` *field* means
is still unproven, so `BIT_TO_BUTTON` in `data/film.odin` is marked provisional
and is the single place to correct once `U_Prefs_PlayerControlCodes` field
order is established. The trail runs
`G_Input_CachePlayerInputs` → `U_Prefs_GetPlayerKeyCodes` → the controls
configuration UI; the label strings were not found in a first pass.

## JSON output

```
assets/data/levels/le01.json   typed: header plus placements
assets/data/<type>/<id>.json   ordered {key, value} fields
assets/data/index.json         counts and total placements
```

Levels get a typed schema because the layout is fully understood. The other
nine families are emitted as ordered key/value lists — lossless, and a typed
loader can be layered on later without re-deriving the encoding. Unit
definitions are substantial: `01b1` alone carries 498 fields.

## What is left

- Typed loaders for `unde` (386), `wede` (5) and `plde` (2). The JSON is
  already usable; what is missing is a schema. 717 distinct field tags appear
  across the corpus.
- The 17-condition unit-behaviour vocabulary and state/rule execution.
- `Data/Local` override lookup — the engine checks it before the PAKs.
- The co-operative `G_Game_Type` value, and the input field semantics.
