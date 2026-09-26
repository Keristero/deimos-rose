# New Weapons: the loadout screen, the Chaingun and the Discharge Beam

This is new content, not the original's. The design is in
[notes/new-weapons.md](../../notes/new-weapons.md). This page records:

- what was built;
- how each point of the design was read, where it left room;
- what is still provisional.

The cross-cutting choice is D37 in [decisions.md](decisions.md). It builds
on D35 (extras) and D36 (screens that live in the simulation). The
Discharge Beam's instant shot is D38.

## What was built

### New Weapons, the extra

New Weapons is a mod, `plugins/new_weapons` (it was an extra, key
`new_weapons`, until the Mods page: docs/phase-9-ecs.md). Classic mode
switches it off along with every other mod. The loadout screen is a mod
of its own, `plugins/loadout`, which New Weapons needs.

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
  rice round, 2 steps apart. It draws `CGBU`, a copy of the round's `jgbu`
  plate made 2.5 times as opaque (see Content). Each round draws its heading within ±8°
  (`initialHeadingTolerance`). The weapon's delay between launches is 30
  steps, where the others' is shorter.
- **Charge attack.** Holding fire charges as the original's weapons do,
  with the ordinary power-up state machine. A weapon marked
  `x_AimedRelease_BOOL` changes one step, `aimed_release_spawn` in
  `sim/systems/weapon_system/aimed.odin`. Every release volley:
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

### The Discharge Beam

The Discharge Beam is `aidb`, with its units in `assets/extra/data`. It is
air weapon number six and unlocks at stage 10. Its ship is red:
`pl1d`/`pl2d`, turned from the Ion Cannon's yellow by `tools/recolour`
(see Content).

The original has no instant shot, so the beam is a new mechanic, in
`sim/systems/weapon_system/beam.odin`. A weapon with `x_Beam_BOOL` fires no projectile of its
own. Its spawn list holds only the muzzle flash, `dbmf`, which also plays
the sound.

- **Standard attack.** Every press, at most one every 8 steps, calls
  `beam_fire` on that step. It casts a line straight up from the muzzle
  and takes every target on it, nearest first. A target is on the line if
  a player's air shot could hit it (`air_shot_can_hit`, shared with the
  Chaingun's aiming) and its hit circle comes within half the beam's width
  of the line.
  - The first target takes the pulse's 1.6 damage through `entity_hit`,
    as a shot would.
  - A kill bursts into particles and throws 3 pieces of shrapnel, `dbsh`,
    evenly spaced from a random heading. The damage its shields did not
    soak carries on to the next target.
  - The beam stops at the first target left standing, or one the hit
    delay protects. With nothing to stop it, it goes off the top of the
    screen.
- **Charge attack.** Holding charges as the original's weapons do. On
  release, `beam_release` fires one beam at once in place of the release
  spawns: 7.5 damage, 14 px wide, scaled by the level reached against the
  weapon's own max. A part charge deals part, and Improved Charge's higher
  max deals more than the full 7.5. The width never falls below the
  pulse's.
- **Drawing.** `sim.State.beams` holds this step's beams, like the
  particle and blur queues: where each started, where it stopped, its
  width and whether it was charged. `render/beams.odin` keeps each for 6
  steps (12 charged), drawn additively as a soft glow, a body and a white
  core, with a flare where it stopped. It fades from the first frame.

#### How the design was read

- **"Raycast ahead until it hits something."** Straight up the screen, as
  every forward shot flies. It is not aimed.
- **"Leftover damage carries on."** The leftover is the pulse's damage
  minus the shields of everything it killed. Against one tough target the
  whole pulse is dealt, so the single-target DPS is simply damage × rate.
- **"Until the beam leaves the screen."** Targets above the top edge are
  out of reach. A target whose circle still overlaps the top edge is hit.
- **Shrapnel, "short-lived, decent damage".** Each piece flies about 11
  steps at speed 9–10 and deals 0.4. Pieces are ordinary player
  projectiles, so they obey the hit delay and can kill, but a shrapnel kill
  throws no more shrapnel.
- **"Brighter and wider, pierces more."** The charged beam is a single
  heavier beam, so it pierces more because it carries more damage. It is
  3.5 times as wide and drawn brighter and longer.
- **Weapon passives.** The Weapon 1–4 passives belong to the original's
  weapons, so none applies. Improved Charge and Auto Charge work through
  the ordinary power-up code.

#### Balance

The target was "competitive with the other weapons, assuming they had 2
upgrades by this point", which is stage 10. It was checked with
`mise run dps:report` at its default stage 7, in the four scenarios of
[dps-report.md](dps-report.md). The Discharge Beam gets no weapon passive,
so its bare numbers are set against the others' with their weapon passive
at level 2, or with Improved Charge 2 for charge shots.

Primary fire, DPS (single / cluster / behind / wave, mean):

| Weapon | Single | Cluster | Behind | Wave | Mean |
|---|---|---|---|---|---|
| Bacta Gun, Weapon 2 at 2 | 5.98 | 8.96 | 0 | 10.64 | 6.40 |
| Photon Beam, Weapon 4 at 2 | 6.00 | 6.00 | 0 | 13.53 | 6.38 |
| Rear Gun, Weapon 3 at 2 | 6.00 | 6.00 | 6.00 | 4.80 | 5.70 |
| **Discharge Beam** | **6.00** | **6.00** | **0** | **8.90** | **5.23** |
| Ion Cannon, Weapon 1 at 2 | 4.79 | 4.79 | 0 | 11.13 | 5.18 |

Charge shots, with Improved Charge 2:

| Weapon | Single | Wave |
|---|---|---|
| Bacta Gun | 3.86 | 1.63 |
| **Discharge Beam** | **3.47** | **1.85** |
| Rear Gun | 3.35 | 3.70 |
| Chaingun | 3.22 | 3.36 |
| Ion Cannon | 3.21 | 1.61 |
| Photon Beam | 1.28 | 3.20 |

So the beam matches the best single-target damage, sits mid-table on the
average, and is weaker than the spread weapons in a wave. It is a
single-lane weapon: it gains nothing from a cluster, and in a wave the
pulse clears one column and the shrapnel chips at its neighbours. Its
charge is near the top ahead, and in the wave mid-table: 7.5 into a
3-deep column of 0.8 is mostly overkill. Since it has no weapon passive,
it doesn't grow past these numbers, while the others' level 3 does
(Weapon 1 at 3 takes the Ion Cannon's wave to 14.3).

The first guess, 1.45 damage, gave 5.44 ahead and a mean of 4.84, last of
the five. It was raised to 1.6 to meet the others' 6.00 ahead.

### Presentation

The drawing is in `plugins/loadout/view/loadout.odin`:
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

The Discharge Beam's numbers were set against the DPS report (see
Balance), but its feel is untested by hand:
- a pulse every 8 steps, of 1.6 damage, 4 px wide;
- the release's 7.5 damage and 14 px, a charge of 20 levels, 2 steps each;
- 3 shrapnel pieces of 0.4 damage, speed 9–10, 7 steps of flight and 4 of
  dwindling;
- the sound: the Laser Gun Bullet's (`lgbu`), pitched down, a stand-in
  for a proper zap;
- in the code: the kill burst's size and colour (`sim/systems/weapon_system/beam.odin`), and
  the beam's lifetimes, widths and colours (`render/beams.odin`).

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
- **Rounds.** `jgbu` is white at full value, a bright core in a halo
  mostly 3-45% opaque, so a tint can only darken it. `tools/recolour`'s
  `alpha` scale writes `CGBU` with every pixel 2.5 times as opaque.
  `cgbu` and `cgpb` draw it, so both the standard and charge rounds stand
  out against sand. Before and after were compared on `MENU=chaingun` and
  `chaingun_charge`.
- **Glows.** The charge glow and its particles reuse `jgli`, tinted
  A8A8A8, rather than a new plate.
- **The Discharge Beam's records.** `pbbf` (the Photon Beam's muzzle
  flash) became `dbmf`, the pulse's flash and sound, and `dbrf`, the
  release's. `cgpo` and `cgpp` became `dbpo` and `dbpp`, the charge glow,
  tinted F83820. `bagb` and `bagh` became `dbsh` and `dbsx`, the shrapnel
  and its hit, recoloured orange-red. `aicg` became `aidb`.
- **Red ships.** The same recipe turns the Ion Cannon's plates (`PL1O`,
  `PL2O`) and the score bar symbols (`WESY`) red: pixels with a hue from
  20° to 75° have it turned by −50°, keeping their saturation and value.
  `hue_shift` is the recipe's new field, 0 when left out. `WESD` is the
  red symbol set, whose first frame is the beam's.

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
- `tests/beam_test.odin`, against `src/assets` (skipped without it):
  - the Discharge Beam loads as extra, at stage 10, with its units, and
    the original's selection never picks it;
  - a pulse of 2.5 through targets of 1, 1 and 5 kills the first two
    nearest first, leaves the third at 4.5 and stops there, never touches
    a target beside the line, and throws 6 pieces of shrapnel;
  - a second pulse on the same step is stopped by the hit delay;
  - with nothing left standing, the beam leaves the screen;
  - a full charge deals the release damage, half a charge half;
  - through the fire button, a press fires one pulse and a held charge
    releases one charged beam.
- `mise run ci` is green: 135 tests.
- `mise run oracle:diff` still matches all four demos call for call.
- Looked at with `mise run menu-shot`:
  - `MENU=loadout`, `loadout_2p` and `loadout_placed` for the screen;
  - `chaingun` for a burst in flight;
  - `chaingun_charge` for aimed pairs after a release;
  - `discharge` and `discharge_charge` for a pulse and a charged beam;
  - `netplay_lobby_connected_host` and `netplay_lobby_connected` for the
    lobby toggles.
- Not yet done:
  - a hand playtest;
  - a netplay loopback run with New Weapons on. `netplay:loopback` opens
    real game instances, sound included, so it was not run here.
  - A picture of a volley turning. In the `chaingun_charge` shot only
    ground targets were on screen, so the volleys flew straight ahead, as
    they should. The turn is covered by the test above.
