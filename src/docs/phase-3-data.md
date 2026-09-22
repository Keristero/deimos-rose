# Phase 3 — Definition and data layer

**Status: complete.** Tagged-text decoding, typed loaders for every definition
family, the film parser, resource precedence and JSON export, all tested
against the full corpus. 39 tests.

```
mise run assets:records   # tagged text -> assets/data/**.json
mise run assets:all       # media + records in one go
mise run test             # 39 tests
```

## Exit criteria

| Criterion | Result |
|---|---|
| All 12 levels parse | yes, field order validated |
| Declared object counts reconcile | yes, **565 placements** exactly |
| Cross-resource references resolve | yes — every unit, image and music id |
| Records available as JSON | 473 records, structured where typed |
| Unit definitions reconcile | 386 records: **1,167 states, 5,835 rules, 532 spawn sets** |
| Rule conditions all known | every value is one of the 17 |
| `Data/Local` precedence | implemented, both real override cases tested |

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

## Definitions

`unde` nests; `wede` and `plde` are flat. A unit definition is a header, then
`numStates_INT` states, each declaring `stateNumSpawnSets_INT` spawn sets and
`stateNumRules_INT` rules.

**Parsing is scope-driven, not positional.** A positional reader built from the
first record matches 359 of 386 and then fails: 27 records carry optional extra
fields — `stateFleeNorth_BOOL` among them — inside the state block. Keying on
field names, with `stateName_STR`, `stateSpawnSetName_STR` and
`stateRuleName_STR` as scope openers, handles those. All 386 then reconcile
against their declared counts:

| | |
|---|---:|
| unit definitions | 386 |
| states | 1,167 |
| rules | 5,835 |
| spawn sets | 532 |

> **Correction (Phase 4).** The counts reconciled, but field *attribution*
> was wrong. The last spawn set in a state is followed by more of the
> state's own keys, because `FUN_004431f0` reads the spawn sets partway
> through. The parser filed those keys into the spawn set, so 379 of the
> 1,167 states lost about 30 fields each: particles, motion blur, collision,
> hunting and more. Spawn-set scope is now decided by key prefix
> (`stateSpawnSet*`). A check against the definition layouts recovered from
> the original's loaders (`symbols/layouts/`) confirms every record now
> supplies every key the loaders read. Found when the Phase 4 typed loader
> reported 12,916 missing keys.

### The 17-condition vocabulary

Rule conditions are a closed set, read from a 17-entry table of 64-byte strings
in the executable at file offset 805379 (an identical second copy sits at
903169). This independently confirms the count the remaster reports for Mac
1.0.6. The shipped campaign exercises 9 of the 17; `Rule_Condition` carries all
of them in table order, so the enum index matches the engine's dispatch index.

`stateRuleAction_STR` is **not** resolved. It is neither an engine verb nor
reliably a state name: only 118 of 2,974 actions name a state in their own
record, and none name one in the unit the rule targets. It is kept verbatim.

Most rules look like editor-written placeholders — 2,773 of them are
`Is Tracking Player` → `Delete` with no target unit — so Phase 4 should not
assume every rule is meaningful.

## Resource precedence

`U_Pak_BuildTagIndex` scans fifteen `Data/Local/<type>/` directories first and
only then the archives in `Data/Paks/`, appending everything to one list;
`U_Pak_GetPtrToTagData` takes the first match. **Loose files in `Data/Local`
shadow the same id inside a PAK.** The fifteen types in the switch match the
fifteen directories the game creates exactly.

The shipped tree has two real override cases, both tested:

| Resource | Shadows |
|---|---|
| `im08/TESM` | `Interface.pak` |
| `stli/cred` | `Game.pak` |

Plus `film/last` and `pref/pref`, which exist only locally. 873 distinct ids
across 875 index entries.

This also corrects a Phase 1 claim: `TESM` is not an alpha-only plate. Both
its plates are in `Interface.pak`; the local file overrides only the alpha.

## The input bits, resolved

Phase 3 closed the last provisional item in `sim/`. Three pieces of evidence
compose:

1. `G_Film::SetInputs` maps each bit to a `G_Input_PlayerInputs` field index:
   `0x01`→3, `0x02`→1, `0x04`→0, `0x08`→2, `0x10`→4, `0x20`→5, `0x40`→6.
2. `G_Input_CachePlayerInputs` maps `U_Prefs_PlayerControlCodes` entry *i* to
   those same field indices: 0→0, 1→3, 2→1, 3→2, 4→5, 5→4, 6→6.
3. The "Edit Key Controls" dialog — resource 102, read out of `.rsrc` — lists
   its entries in order: Move Up, Move Down, Move Left, Move Right, Fire Air,
   Fire Ground, Switch Weapon.

Composing them:

| Bit | Button |
|---|---|
| `0x01` | Move Down |
| `0x02` | Move Left |
| `0x04` | Move Up |
| `0x08` | Move Right |
| `0x10` | Fire Ground |
| `0x20` | Fire Air |
| `0x40` | Switch Weapon |

> **Correction (Phase 4).** The directions above are wrong. Step 3 assumed
> the dialog lists controls in `U_Prefs_PlayerControlCodes` order, which it
> does not. `G_Player::Process` shows what each field does: field 0 moves
> up, 1 right, 2 down, 3 left. The movement in de01's film confirms it. The
> correct mapping is `0x01` Left, `0x02` Right, `0x04` Up, `0x08` Down; the
> fire and switch bits stand. See `data/film.odin`.

Up/down and left/right are not adjacent in the on-disk order, and fire-air and
fire-ground are transposed relative to the prefs order. The provisional table
written in the previous pass had five of the seven wrong, which is the whole
argument for proving this rather than assuming it.

**`G_Game_Type.Co_Op` is 2**, also now verified: `G_Game_Play` switches on the
value to label the session, `case 1` → `"1 Player"`, `case 2` → `"2 Player"`.

## What is left for later phases

- `stateRuleAction_STR` dispatch — what an action actually does.
- Executing states and rules at runtime. The data is loaded and validated;
  running it is Phase 4.
- Typed schemas for the remaining header/state fields. 717 distinct tags appear
  across the corpus; the loader exposes all of them by name and types the ones
  that are used structurally.
