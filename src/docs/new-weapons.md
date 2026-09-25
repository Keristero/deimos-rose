# New Weapons: the loadout screen and the Chaingun

This is new content, not the original's. The design is in
[notes/new-weapons.md](../../notes/new-weapons.md). This page records:

- what was built;
- how each point of the design was read, where it left room;
- what is still provisional.

The cross-cutting choice is D37 in [decisions.md](decisions.md). It builds
on D35 (extras) and D36 (screens that live in the simulation).

## What was built

### New Weapons, the extra

New Weapons is an extra: its `prefs.EXTRAS` key is `new_weapons`. Classic
mode switches it off along with every other extra.

It is **on by default**, unlike Easy Mode. The design asks for it outside
classic mode, and classic mode remains the way to play the original.

Where it can be changed:
- on the Preferences Extras page;
- in the netplay lobby, where the host can change it. It sits beside Easy
  Mode, and the guest sees what the host chose.

A session only turns it on when the new content has loaded. That content
is `assets/extra`, which `Flow.extra_content` checks for.

### Carrying the setting

`sim.Session.loadout` carries it, and it is fixed for the session. On the
wire it is `net.START_LOADOUT`, the second bit of the flags byte that
`Level_Choice` and `Start` already carry (D36).

`game/flow.odin`'s `flow_session_flags` and `session_from_flags` build the
`Session` for both local and netplay starts. Before this, each built its
own.

### The loadout

The loadout is in `sim/loadout.odin`. `Weapon_Handler` gains:
- `loadout`: three slots;
- `spare`: up to eight spares.

`Change_Air` cycles the loadout's filled slots, wrapping, through
`sim.air_weapon_next`. It never reaches a spare. The score bar's "next two
weapons" read the same procedure.

At a session start, the weapons unlocked at the starting stage fill the
slots in unlock order, up to three. Anything left over is handed over by
the first loadout screen.

### The loadout screen

The screen is part of the simulation, like the reward screen (D36). It is
stepped by `session_step` with the players' ordinary inputs, snapshotted,
rolled back and resynced, so netplay needed no new messages.

While it is open:
- game time, entities and the playfield stand still;
- only the frame count moves;
- it draws nothing from the RNG.

The presentation effects freeze too, through `sim.session_frozen`.

### The Chaingun

The Chaingun is `aicg`, with its units in `assets/extra/data`. It is air
weapon number five and unlocks at stage 7. Its ship is dark grey:
`pl1k`/`pl2k`, recoloured from the Bacta Gun's green by `tools/recolour`
(see Content).

- **Standard attack.** A press spawns `cgbs`, a spawner cloned from the
  turrets' `rgbs`. The spawner fires 10 of `cgbu`, the turrets' spinning
  rice round, 2 steps apart. Each round draws its heading within ±8°
  (`initialHeadingTolerance`). The weapon's delay between launches is 30
  steps, where the others' is shorter.
- **Charge attack.** Holding fire charges as the original's weapons do,
  with the ordinary power-up state machine. A weapon marked
  `x_AimedRelease_BOOL` changes one step, `aimed_release_spawn` in
  `sim/aimed.odin`. Every release volley:
  - finds the nearest enemy a player shot could hit;
  - leads it by its current velocity;
  - fires two parallel `cgpb` rounds at that point, 3 px either side of
    the line of fire. These rounds do not spin; they have one frame per
    direction.

  With nothing to aim at, the volley flies straight ahead. It keeps firing
  until the charge is spent, one volley per level.

The original selection procedures never return a weapon marked `extra`.
These are `best_air_weapon`, `level_air_weapon` and `next_weapon_of_type`.
So classic play and the demo films never meet the Chaingun, even though it
is loaded in every session. `oracle:diff` stays exact.

### Presentation

The drawing is in `game/loadout.odin`:
- There is one panel per player choosing, stacked: rows NEW, LOADOUT and
  SPARE, then READY.
- The weapons are drawn with their score bar symbols (`wesy`).
- A weapon new this stage is lit in the header colour wherever it sits.
- The cursor has a border in the player's accent colour, and a picked-up
  weapon's cell is filled with it.
- Under the rows, the weapon under the cursor is named and its
  `description1` is word-wrapped. On READY, the panel says why READY is
  refused.

## The rules as implemented

- **When the screen opens.** At every stage but the first of the game
  (`level_number > 1`), once the stage's title notice has gone. `level_start`
  keeps a reference to the notice, and `loadout_due` waits until it is no
  longer valid. The screen opens once a stage (`Loadout.shown`), and not
  once the stage is ending or the game is over.
- **Who chooses.** Every player still in the game, using the reward
  screen's `reward_chooser`. The screen closes `REWARD_RESUME_DELAY` steps
  after everyone is ready.
- **Which weapons are new.** Every air weapon unlocked by this stage
  (`minimumLevelAvailable <= level`) that the player does not hold, in
  unlock order. The maximum level does not count, so a weapon once held is
  kept; the original takes the Ion Cannon away after stage 3. Choosing
  stage 7 from Level Select therefore hands over everything up to the
  Chaingun at once.
- **Fewer than three weapons held.** New weapons go straight into the free
  slots, lit so the player can see where they went. The cursor starts on
  READY, so a single confirm carries on.
- **Three weapons held.** Weapons that do not fit wait in the NEW row. The
  cursor starts there.
  - Fire Air picks up the weapon under the cursor. Fire Air again puts it
    down, swapping with whatever is there, in any row.
  - Fire Ground puts it back.
  - On READY, Fire Air readies up. That is refused while anything is held,
    the NEW row is not empty, or the loadout is not as full as the weapons
    held allow. Fire Ground takes a ready back.
  - The SPARE row has exactly one cell per weapon beyond three, so once
    the NEW row is empty the loadout is full.
- **The selected weapon.** It is remembered. If it is still in the
  loadout it stays selected, and a new weapon is never selected for you.
  If it was moved to the spares, the first slot's weapon is taken up.

## Provisional

Each of these was picked by eye or by analogy with the original's weapons,
and each is waiting for a hand playtest:

- the Chaingun's 30-step delay between bursts;
- the burst's 10 rounds, 2 steps apart, within ±8°;
- round speed 14 and damage 0.5 for the burst;
- speed 16 and damage 0.6 for the aimed rounds;
- a charge of 20 levels, 2 steps each, releasing a volley every 2 steps;
- `AIMED_PAIR_OFFSET` (3 px);
- `aimed_intercept`, which leads by velocity alone, so a target that turns
  or accelerates is missed by as much as it changes.

The last two are marked provisional in the code. The rest are data, which
has no room for a comment, so this list is where they are marked. The
loadout screen reuses the reward screen's sounds.

## Content

`assets/extra` holds the new content: records in `data/` and sprites in
`sprites/`, laid out like `assets/`. `data.extra_defs_load` appends it after
the original definitions. Each weapon it loads is marked `extra`, and
`x_AimedRelease_BOOL` is read into `aimed_release`. `assets_open` reads the
extra sprite index beside the game's own.

- **Records.** Each was cloned from its nearest original record and then
  edited:
  - `rgbu` became `cgbu`;
  - `rgbs` became `cgbs`;
  - `airg` became `aicg`.

  They are the source now, and are edited by hand.
- **Ships.** `mise run assets:extra` (`tools/recolour`, following the
  recipe in `tools/recolour/extra.json`) writes the dark grey ships from the
  extracted Bacta Gun plates. Pixels in the green hue band keep 12% of their
  saturation and 60% of their value. `assets:all` runs it after extracting.
- **Glows.** The charge glow and its particles reuse `jgli`, tinted
  A8A8A8, rather than a new plate.

## Verification

- `tests/loadout_test.odin`, which uses the synthetic fixture:
  - classic play never picks or cycles to a new weapon, and never opens
    the screen;
  - there is no screen on stage 1;
  - new weapons fill free slots and the rest wait;
  - READY is refused until they are placed;
  - swaps, putting back, and taking a ready back;
  - applying keeps the weapon flown, or takes up the first slot's;
  - `loadout_next` wraps past empty slots;
  - the intercept meets a crossing target, closes on an approaching one,
    and falls back to aiming straight at a target it cannot catch;
  - against `src/assets` (skipped without it):
    - the Chaingun loads as extra and aimed, with its units;
    - a stage-7 session opens the screen only after the title has gone,
      with the Chaingun in it;
    - a release volley at a mine placed up and to the right of the ship is
      two shots, both on the lead heading, flying abreast 6 px apart.
- `mise run ci` is green: 130 tests.
- `mise run oracle:diff` still matches all four demos call for call.
- Looked at with `mise run menu-shot`:
  - `MENU=loadout`, `loadout_2p` and `loadout_placed` for the screen;
  - `chaingun` for a burst in flight;
  - `chaingun_charge` for aimed pairs after a release;
  - `netplay_lobby_connected_host` and `netplay_lobby_connected` for the
    lobby toggles.
- Not yet done:
  - a hand playtest;
  - a netplay loopback run with New Weapons on. `netplay:loopback` opens
    real game instances, sound included, so it was not run here.
  - A picture of a volley turning. In the `chaingun_charge` shot only
    ground targets were on screen, so the volleys flew straight ahead, as
    they should. The turn is covered by the test above.
