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

A session only turns it on when its content has loaded: the plugin is
marked `content`, and `sim.mods_with_content` drops it when
`plugins/new_weapons/data` is missing (D49, D51).

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

The Chaingun is a plugin of its own, `plugins/chaingun`, which needs New
Weapons and lists under it on the Mods page, on by default (D49). All of
it is there: its content in `data/` and `sprites/`, its recolour recipe
`tools/recolour/chaingun.json`, its definition key, its firing hook and
its screenshot scenarios (`MENU=chaingun`, `chaingun_charge`,
`chaingun_release`).

The Chaingun is `aicg`. It is air weapon number five and unlocks at
stage 7. Its ship is dark grey: `pl1k`/`pl2k`, recoloured from the Bacta
Gun's green by `tools/recolour` (see Content).

- **Standard attack.** A press spawns `cgbs`, a spawner cloned from the
  turrets' `rgbs`. The spawner fires 10 of `cgbu`, the turrets' spinning
  rice round, 2 steps apart. It draws `CGBU`, a copy of the round's `jgbu`
  plate made 2.5 times as opaque (see Content). Each round draws its heading within ±8°
  (`initialHeadingTolerance`). The weapon's delay between launches is 30
  steps, where the others' is shorter.
- **Charge attack.** Holding fire charges as the original's weapons do,
  with the ordinary power-up state machine. A weapon marked
  `x_AimedRelease_BOOL` changes one step: the Chaingun plugin fires
  each volley through the core's Weapon_Fire hook, `aimed_release_spawn`
  in `plugins/chaingun/aimed.odin`. Every release volley:
  - finds the nearest enemy a player shot could hit;
  - leads it by its current velocity;
  - fires two parallel `cgpb` rounds at that point, 3 px either side of
    the line of fire. These rounds do not spin; they have one frame per
    direction.
- **Muzzle flash.** Every round fired flashes, bright white fading to
  orange, gone within 3 steps, with a few sparks thrown along the round's
  heading: at full strength for a charge's aimed rounds and half for the
  burst's
  ([notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md)).
  The burst's flashes at the ship's nose, drawn over the ship. A charge's
  rounds can leave in any direction, so their flash is centred on the
  ship and drawn under it, wider (26 px) so it shows round the outline,
  with its streak and sparks starting 14 px out along the round's heading
  ([notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md)).
  It is presentation only, two effect systems in
  `plugins/chaingun/view/flash.odin`, one for each layer. They find each
  new round by its entity number, which counts up through a level, so a
  step a rollback replays does not flash again. Several rounds of one
  kind on one step make one flash, the strongest.

  With nothing to aim at, the volley flies straight ahead. It keeps firing
  until the charge is spent, one volley per level.

The original selection procedures never return a weapon marked `extra`.
These are `best_air_weapon`, `level_air_weapon` and `next_weapon_of_type`.
So classic play and the demo films never meet the Chaingun, even though it
is loaded in every session. `oracle:diff` stays exact.

### The Discharge Beam

The Discharge Beam is `aidb`, with its units in
`plugins/new_weapons/data`. It is air weapon number six and unlocks at stage 10. Its ship is red:
`pl1d`/`pl2d`, turned from the Ion Cannon's yellow by `tools/recolour`
(see Content).

The original has no instant shot, so the beam is a new mechanic, in
`plugins/new_weapons/beam.odin`, fired through the core's Weapon_Fire hook.
A weapon with `x_Beam_BOOL` fires no projectile of its own. Its spawn list holds only the precharge, `dbpc`, a glow at the gun
that plays the wind-up sound.

- **Wind-up.** A press does not fire at once. The core's Weapon_Fire hook
  has a `windup` part: steps from a press to its shot, 6 for the beam
  (`x_BeamWindup_INT`), 0.2 s. The press spawns the precharge and sets
  `Weapon_Handler.air_windup`, which counts down each step whatever the
  button does; at 0 the shot fires and the weapon's delay (8 steps) starts
  from it. So a pulse comes about every 15 steps while the button is
  tapped, and the next press waits for both. Switching weapon drops a
  wind-up in progress.
- **Standard attack.** When a press has wound up, `beam_shot` spawns the
  muzzle flash, `dbmf`, which plays the zap, and calls `beam_fire`. It
  casts a line straight up from the muzzle
  and takes every target on it, nearest first. A target is on the line if
  a player's air shot could hit it (`air_shot_can_hit`, shared with the
  Chaingun's aiming) and its hit circle comes within half the beam's width
  of the line.
  - The first target takes the pulse's 3.0 damage through `entity_hit`,
    as a shot would. The line is 7 px wide.
  - A kill bursts into particles, and the damage its shields did not
    soak carries on to the next target. It throws nothing out.
  - The beam stops at the first target left standing, or one the hit
    delay protects. With nothing to stop it, it goes off the top of the
    screen.
- **Charge attack.** Holding charges as the original's weapons do. On
  release, `beam_release` fires one beam at once in place of the release
  spawns, with no wind-up: 6.0 damage, 14 px wide, scaled by the level
  reached against the weapon's own max. A part charge deals part, and
  Improved Charge's higher max deals more than the full 6.0. The width
  never falls below the pulse's. It pierces as a pulse does.
- **Drawing.** Each beam is pushed as a `Beam_Event`, a plugin's effect
  event (`sim/queue_effects.odin`) that lasts the step, like the particle
  and blur queues: where it started, where it stopped, its width and
  whether it was charged. The plugin's view,
  `plugins/new_weapons/view/beams.odin`, is an effect system that keeps
  each for 6 steps (12 charged) and draws them over the air enemies and
  under the ships, additively, as a soft red glow three times the beam's
  width, a red body and a white core, with a flare where it stopped. It
  fades from the first frame.
  - While a press winds up, `plugins/new_weapons/view/precharge.odin`
    draws red motes drawn in to the gun, 3 a step starting 20–36 px out.
    Each closes as (1 − u)², fast at first and slowing as it arrives, and
    reaches the gun as the pulse fires. They are kept relative to the gun,
    so they follow the ship, and drawn over the ships, as the gun is
    inside the ship's outline.

#### How the design was read

- **"Raycast ahead until it hits something."** Straight up the screen, as
  every forward shot flies. It is not aimed.
- **"Leftover damage carries on."** The leftover is the pulse's damage
  minus the shields of everything it killed. Against one tough target the
  whole pulse is dealt, so the single-target DPS is simply damage × rate.
- **"Until the beam leaves the screen."** Targets above the top edge are
  out of reach. A target whose circle still overlaps the top edge is hit.
- **The base changes.** The design asked for a longer time between
  shots, a 0.2 s wind-up with red particles drawn in and a precharge
  sound, a wider, more vivid beam with more damage for the delays, and no
  shrapnel but the piercing kept ([notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md)).
  The delay went from 7 to 8 steps, counted from the shot, so with the
  wind-up a pulse takes about 15 steps where it took 8. The damage went
  from 1.6 to 3.0 to keep the single-target DPS at 6.00, and the width
  from 4 to 7 px.
- **The charged beam.** A single heavier beam, twice as wide as a pulse
  and drawn brighter and longer, that pierces like one. For a while it
  also left lingering red motes along its path that burst, after a delay
  set by the charge, into white fragments
  ([notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md)).
  That did not play well, and the charge went back to the plain piercing
  beam ([notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md)).
  Its damage went from 7.5 to 5.0 while the fragments carried part of it,
  and is 6.0 now (see Balance).
- **Weapon passives.** The Weapon 1–4 passives belong to the original's
  weapons, so none applies. Weapon 6 is the beam's own: more damage and a
  wider beam ([passive-upgrades.md](passive-upgrades.md)). Improved
  Charge and Auto Charge work through the ordinary power-up code.

#### Balance

The target was "competitive with the other weapons, assuming they had 2
upgrades by this point", which is stage 10. It was checked with
`mise run dps:report` at its default stage 7, in the four scenarios of
[dps-report.md](dps-report.md). Its bare numbers are set against the
others' with their weapon passive at level 2, or with Improved Charge 2
for charge shots. The primary fire's numbers are from after the base
changes (the wind-up), the charge's from after the motes were taken out.
Its own passive, Weapon 6, takes the pulse to 7.20 ahead at level 2 and
9.60 at level 3.

Primary fire, DPS (single / cluster / behind / wave, mean):

| Weapon | Single | Cluster | Behind | Wave | Mean |
|---|---|---|---|---|---|
| Bacta Gun, Weapon 2 at 2 | 7.18 | 10.76 | 0 | 12.47 | 7.60 |
| Photon Beam, Weapon 4 at 2 | 8.00 | 8.00 | 0 | 5.55 | 5.38 |
| Rear Gun, Weapon 3 at 2 | 5.14 | 5.14 | 5.14 | 4.50 | 4.98 |
| **Discharge Beam** | **6.00** | **6.00** | **0** | **4.80** | **4.20** |
| Chaingun, Weapon 5 at 2 | 5.99 | 5.99 | 0 | 3.81 | 3.95 |
| Ion Cannon, Weapon 1 at 2 | 3.00 | 3.00 | 0 | 4.99 | 2.74 |

Charge shots, with Improved Charge 2:

| Weapon | Single | Wave |
|---|---|---|
| **Discharge Beam** | **3.96** | **0.96** |
| Bacta Gun | 3.86 | 1.63 |
| Rear Gun | 3.35 | 3.70 |
| Chaingun | 3.22 | 3.36 |
| Ion Cannon | 3.21 | 1.61 |
| Photon Beam | 1.28 | 3.20 |

So the beam is near the best single-target damage and mid-table on the
average. It is a single-lane weapon: it gains nothing from a cluster, and
in a wave the pulse clears one column. Before the base changes its wave
was 8.90, as the shrapnel chipped at the neighbouring columns; with the
shrapnel gone it is 4.80. That drop was accepted: the design removed the
shrapnel, and the beam keeps its piercing. Its charge is the best ahead
and the weakest in the wave, where it too holds one column.

- The pulse's damage, 3.0, keeps the single-target DPS at 6.00 over the
  longer cycle (6 steps of wind-up and a delay of 8 from the shot).
- The release's 6.0 was chosen by a sweep (5.0 to 7.5, 0.19 single-target
  DPS a step of 0.5), to keep the charge near the others' with the
  fragments gone: 3.50 bare, against 3.43 for the Bacta Gun's and 3.02
  for the Chaingun's. The wave stays at 0.96 whatever the damage, as a
  release already kills the column it hits. With the motes it was 5.0,
  3.34 single and 1.53 in the wave; before the base changes, 7.5, 2.90
  and 1.85.

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
  or accelerates is missed by as much as it changes;
- the muzzle flash's size, colours, 3-step life and sparks, all in
  `plugins/chaingun/view/flash.odin`.

The last three are marked provisional in the code. The rest are data, which
has no room for a comment, so this list is where they are marked. The
loadout screen reuses the reward screen's sounds.

The Discharge Beam's numbers were set against the DPS report (see
Balance), but its feel is untested by hand:
- a 6-step wind-up, then a delay of 8 steps from the shot;
- a pulse of 3.0 damage, 7 px wide;
- the release's 6.0 damage and 14 px, a charge of 20 levels, 2 steps each;
- the pulse's sound: the Laser Gun Bullet's (`lgbu`), pitched down, a
  stand-in for a proper zap;
- the precharge's sound, `icpo` (the Ion Cannon's charge-up) at pitch
  1.8: a stand-in as well;
- in the code: the kill burst's size and colour
  (`plugins/new_weapons/beam.odin`), the beam's lifetimes, widths and
  colours (`plugins/new_weapons/view/beams.odin`), and the wind-up motes'
  count, distances and colours
  (`plugins/new_weapons/view/precharge.odin`).

## Content

`plugins/<plugin>/` holds each plugin's own content beside its code:
records in `data/` and sprites in `sprites/`, laid out like `assets/`
(D49, D51). A release carries it in `deimos/plugins/<plugin>/`.
`data.extra_defs_load` appends it after the original definitions, ordered
by id whichever plugin it came from. Each weapon it loads is marked
`extra`, and records its plugin, which lets it into play while on. Its
`x_` keys are read into `Weapon.keys` for the plugin that registered them
(`sim/def_keys.odin`); the loader knows none of them. `assets_open` reads the
extra sprite index beside the game's own.

- **Records.** Each was cloned from its nearest original record and then
  edited:
  - `rgbu` became `cgbu`;
  - `rgbs` became `cgbs`;
  - `airg` became `aicg`.

  They are the source now, and are edited by hand.
- **Ships.** `mise run assets:extra` (`tools/recolour`, following the
  recipe for the plugin in `tools/recolour/`) writes the dark grey ships from the
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
  tinted F83820. `aicg` became `aidb`. For the base changes:
  - `dbmf` became `dbpc`, the precharge, a glow at the gun that grows over
    the wind-up;
  - `dbpp` became `dbcm`, the charged beam's mote, and `dbcs`, the same
    with the burst sound; `bagb` became `dbfr`, the fragment (it was
    `dbsh`, the shrapnel, before), and `bagh` became `dbsx`, its hit. All
    four went again with the motes.
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
    nearest first, leaves the third at 4.5 and stops there, and never
    touches a target beside the line;
  - a press winds up: its pulse lands on the wind-up's last step, and
    pulses held down come one cycle (wind-up, delay and one) apart;
  - a second pulse on the same step is stopped by the hit delay;
  - with nothing left standing, the beam leaves the screen;
  - a full charge deals the release damage, half a charge half;
  - through the fire button, a press fires one pulse and a held charge
    releases one charged beam.
- `mise run ci` is green: 135 tests.
- `mise run oracle:diff` still matches all four demos call for call.
- Looked at with `mise run menu-shot`:
  - `MENU=loadout`, `loadout_2p` and `loadout_placed` for the screen;
  - `chaingun` for a burst in flight and its half-strength muzzle flash;
  - `chaingun_charge` for aimed pairs after a release;
  - `chaingun_release` for the full-strength flash of a charge's release;
  - `discharge_windup` for the motes drawn in to the gun, and `discharge`
    and `discharge_charge` for a pulse and a charged beam;
  - `netplay_lobby_connected_host` and `netplay_lobby_connected` for the
    lobby toggles.
- Not yet done:
  - a hand playtest;
  - a netplay loopback run with New Weapons on. `netplay:loopback` opens
    real game instances, sound included, so it was not run here.
  - A picture of a volley turning. In the `chaingun_charge` shot only
    ground targets were on screen, so the volleys flew straight ahead, as
    they should. The turn is covered by the test above.
