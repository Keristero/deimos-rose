# Easy mode and passive upgrades

New content, not the original's: the design is
[notes/passive-upgrades-and-easy-mode.md](../../notes/passive-upgrades-and-easy-mode.md).
This records what was built, how each entry of the design was read where it
left room, and what is still provisional. The cross-cutting choice is D36 in
[decisions.md](decisions.md).

## What was built

- **Easy mode** is a mod (`plugins/easy_mode`, off by default; it was an
  extra, key `easy_mode`, until the Mods page: docs/phase-9-ecs.md), so
  classic mode switches it off with every other mod. The passives are a
  mod of their own, `plugins/passives`, which Easy Mode needs. It is
  offered where the design asks:
  - on Level Select, under the level name (`game/menu_level_select.odin`),
    only outside classic mode;
  - in the netplay lobby, where the host can change it until they ready up.
    The guest sees what the host chose (`game/netplay.odin`).
  - The Preferences Extras page lists it as well, since that page is built
    from the table.
- **Where easy mode lives.** `sim.Session.easy` carries it, fixed for the
  session. On the wire:
  - `Level_Choice` gains a flags byte, so the guest's lobby mirrors the
    host's choice.
  - `Start` gains a flags byte (`START_EASY`), so both peers begin the same
    session.
  - Both packets still decode in their old, shorter forms (as flags 0).
- **The reward screen** (`plugins/easy_mode/reward.odin`) is part of the simulation. After
  a level's tally, `session_step` opens it instead of advancing, as long as
  another level is to come. Because it is stepped, snapshotted and rolled
  back like play, and a reconnect resync copies it with the rest of `State`,
  netplay needed no new messages for it.
  - While it is open, game time, entities and the playfield stand still.
    Only the frame count moves, plus one RNG draw per option when it opens.
  - Once it closes, the same step's `level_transition` moves on to the next
    level.
- **The passives** (`plugins/passives`) are held per player as a level per
  passive, in the `Passive_State` component on the player's entity.
  - They are kept across levels, and start at none with each session.
  - Every stat is worked out from the levels held whenever it is needed. It
    is never stored.
  - The plugin's own passives have fixed ids (`passives.Own`). Another
    plugin adds its own with `passive_register` from its registration step,
    naming itself as the passive's `plugin`: the passive is offered only
    while that plugin is on, and its ids follow the plugin's in
    registration order.
  - **New Weapon Upgrades** (`plugins/new_weapon_passives`) adds Weapon 5
    and 6, and their charge passives, that way. It needs Passive Upgrades and New Weapons, and is a
    companion of both (D66): on wherever they are, so a player can keep
    the new weapons and turn their upgrades off. Its tests are its own
    (`plugins/new_weapon_passives/tests`), as each plugin owns the tests
    of what it adds; `tests/support` holds the helpers every test package
    shares.
  - Each `Passive_Def` carries its `name` (lower case; its icon and the DPS
    report go by it) and the `label` the reward screen shows.
- **Presentation** (`plugins/easy_mode/view/reward.odin`,
  `plugins/passives/view/passives.odin`):
  - The overlay is drawn over the dimmed play area. The HUD stays as it
    was.
  - Each passive has a 32x32 icon composited from the game's sprites (see
    Icons).
  - Two in-play effects: accent-coloured motes drawn in to a ship whose
    shields are regenerating, and sparks off a charge climbing past the
    weapon's own maximum.

## Icons

Each passive's icon is a 32x32 PNG in `assets/icons/passives/`, named after
its `Passive_Def.name` (`shield_regen.png`), which is how the
reward screen finds it. The icons are composited from the game's own
sprites by `mise run assets:icons` (`tools/icons`), so they can be rebuilt
from an extraction like everything else in `assets/`. `assets:all` runs the
task after extracting.

`tools/icons/passives.json` is the recipe. Each icon is a stack of layers,
drawn bottom first. A layer is one frame of a sprite plate, with these
fields:

- `fit` scales the frame so its longer side is that many pixels.
- `x` and `y` place its centre.
- `flip_x` and `flip_y` flip it.
- `alpha` fades it.

The current set:

| Passive | Layers |
|---|---|
| Improved Manoeuvring | the ship (`pl1b` 0), with two faint copies either side |
| Auto Charge | the Ion Cannon's charge glow (`ioca` 2), with the editor's gear (`edut` 0) |
| Improved Charge | the Photon Beam's charge glow (`phbe` 1), with a green plus (`edut` 1) |
| Shield Regen | the shield pickup (`pish` 0), with the plus |
| Ground Variant 1 | the ship above the plasma bomb's locked target (`pbta` 1) |
| Ground Variant 2 | the ship ringed by the locked target, faint above and to the sides, full below |
| Weapon 1-4 | the weapon's score-bar symbol (`wesy` 0, 1, 3, 2), with the plus |
| Weapon 5 | the Chaingun's score-bar symbol (`wesy` 4), with the plus |
| Weapon 6 | the Discharge Beam's red symbol (`wesd` 0, New Weapons' own plate), with the plus |
| Weapon 1 Charge | the Ion Cannon's symbol, smaller, in Improved Charge's glow, with the plus: a weapon's charge passive |
| Weapon 2 Charge | the same for the Bacta Gun |
| Weapon 3 Charge | the same for the Rear Gun |
| Weapon 4 Charge | the same for the Photon Beam |
| Weapon 5 Charge | the same for the Chaingun |
| Weapon 6 Charge | the same for the Discharge Beam |

To add an icon, add an entry named after the new passive and rerun the
task. `MENU=reward mise run menu-shot` shows the icons in place.
`RECIPE=` and `OUT=` point the task at another recipe and output folder,
for icons that are not passives. The reward screen draws each icon at the
largest whole multiple of its size, in window pixels, that fits its cell:
3x at the usual cell size.

`plugins/passives/tests`' `every_passive_has_an_icon` checks that every
passive has a recipe entry and, when the assets tree is present, a file.

## The rules as implemented

- **Level format.** Entries are `(a,b,c)` with `X` for the design's `x`.
  - Only the level held counts, and `x` inherits the level below it
    (`mod_value`). A stat that is `x` up to the level held is not touched.
  - The reward screen does not list a stat whose entry at the offered level
    is `x`.
- **Stacking.** Increases and decreases from every passive held are summed
  into one percentage, and the base is scaled once by `100 + sum`, never
  below 0.
  - Integer stats round to nearest, halves up (`scale_i32`).
  - A percentage of 0 returns the base untouched, which is what keeps
    classic play and the demos exact.
  - Extras sum. Enables is on if any passive held turns it on.
- **Weapon passives** count only for their own weapon (`stat_total`'s
  `weapon`), and only in their own scope (`passive_applies`):
  - A weapon passive changes the weapon's shots, and not its charge.
  - A charge passive (`Passive_Def.charge`) changes how the weapon's
    charge climbs and what its release fires, and not its shots.
  - A ship passive counts in both, so Improved Charge raises every
    weapon's charge.
  - The scope is the stat providers' (`sim.Stat_Provider`'s `charge`). The
    core asks for the charge's stats where it charges (`stats.charge_stat`)
    and tags the shots a release fires with it (`stats.shape_spawn`).
  - A shot carries its weapon (`shaped_by`) and scope (`shaped_charge`)
    from spawn onwards, so a passive can shape it after it spawns. A
    weapon nothing shapes leaves its shots untagged, as the original's.
- **The ground weapon's charge** (`Ground_Charge`). The original's one
  ground weapon has no power-up, so a passive can give it one of its own
  (`stats.ground_charges`, `weapon_system.ground_charge_process`):
  - A press still drops the usual burst. Held on for
    `GROUND_CHARGE_HOLD` steps, the charge begins. Letting go once it is
    ready, half a second on (`stats.ground_charge_ready`), drops one more
    volley of the weapon's spawns (`spawn_ground` with `charge`); letting
    go sooner drops nothing. Without the wait, a heavy bomb dropped the
    moment the charge began, straight ahead, outdid the burst.
  - The bomb is the charge's (`charge = true`), so a charge passive can
    make it heavier without touching the burst.
  - While it is held the crosshair may turn about the ship
    (`Weapon_Handler.ground_aim`): round behind it and held there
    (`Charge_Aim_Behind`), or on round it (`Charge_Aim_Around`). The
    volley's spawns turn with it (`stats.weapon_spawns`' `turn`), and are
    sped by the crosshair's distance along that way. Letting go brings
    the crosshair back ahead.
  - A turned crosshair stands on an ellipse about the ship
    (`stats.crosshair_turned`): the full reach ahead, half of it
    behind (there is less room behind the ship), and kept on screen.
  - The charge is the handler's own (`ground_charged`, the steps it has
    been held), apart from the original's ground power-up. Its release does not clear an air
    overload, as that power-up's would.
- **A release's ramp** (`Release_Ramp`). The original's release fires
  a spawn every `powerup_air_time_between_release_spawns + 1` steps
  until its levels are spent. With the ramp, each spawn already fired
  adds the stat's percentage to the release's pace, kept in hundredths
  as the charge rate's is (`stats.powerup_release_due`). It stops at a
  spawn every `sim.hit_gap` steps (2), the most hits one target takes:
  ramped on to one a step, the Chaingun's release lost 20% of its DPS in
  every scenario, as the extra shots were wasted and the release spent
  sooner. A release counts its spawns afresh each time it lets go
  (`weapon_system.powerup_let_go`).
- **An overcharged release** (`Overcharge_Projectiles`, D72). A release
  counts its levels down as it fires them. While the level a spawn fires
  at stands over the weapon's own max power level, the spawn fans out 2
  more lanes for every 25% of that max it is over (`OVERCHARGE_STEP`,
  `stats.overcharge_lanes`). Only a higher max charge takes it over. The
  pairs leave from the outermost lanes, each `OVERCHARGE_FAN` (10°)
  wider than the last, so the release opens wide and narrows back to
  the weapon's own lanes as it is spent. The release's spawner carries
  the count (`Shaped.overcharge`), as it does not know the level it was
  fired at. A weapon with a release of its own (`weapon_fire_register`)
  does not fan out.
- **A shot's size** (`Shot_Scale`). A shaped projectile's states' scales
  are multiplied by it (`Shaped.size`, applied in `appearance_stage`)
  from its first scale on, so a shot that inflates as it leaves inflates
  to the larger size. Its size is what it reaches: collisions are
  measured from its scaled sprite.
- **A wearing shot** (`Wears_Down`, D73). The original's shot takes the
  hit back from what it hits, against its own shields, and nearly
  always bursts on its first. A wearing shot takes no hits. It has its
  damage times its size to give (`stats.wear_pool`). Each hit gives no
  more than it has left, spends what the hit dealt, and shrinks it in
  proportion, to no less than `WEAR_MIN_SIZE` (40%) of its size, so one
  nearly spent can still be seen. A hit the target's hit delay turns
  away spends nothing. Once spent, it is destroyed as the hit back would
  have destroyed it (collision_system's `shot_hit`).
- **Corrosive clouds** (`Hit_Cloud`, D74). A shot whose scope has it
  leaves a cloud where it hits, whether the hit is dealt or turned away
  by the target's hit delay (the core's `Shot_Hit` hook, run after a
  shaped shot's hit). It lingers `CLOUD_SECONDS` (2 s), scaled by
  `Cloud_Lifetime`. A hit within `CLOUD_RADIUS` of a cloud of the same
  player's keeps that one lingering rather than forming another over it.
  Each step every air target a player's shot could hit takes
  `CLOUD_DAMAGE` while inside one, once however many it is in, scored to
  the cloud's player. That damage is not a hit
  (`collision_system.entity_damage`): it neither waits for the target's
  hit delay nor starts it, so it does not turn the shots away, and shows
  nothing of a hit. The clouds are the session's (`passives.Clouds`), so
  a rollback restores them, and are gone when the level ends.
- **Air shots on the ground** (`Hits_Ground`, D75). An air shot's
  collisions are tested against air targets only, in the original. One
  whose scope has the stat is tested against the ground targets it
  overlaps as well (`Shaped.ground`, set as it spawns), and hits them for
  its damage scaled by `Ground_Damage`. It takes their damage back, as
  it would an air target's, so a shot spent on the ground does not fly
  on.
- **Offering.**
  - There are `min(choosers + 2, available)` options, drawn without repeats:
    three for one player, four for two (the design's first count, one more
    than the players, was raised by notes/extra-weapons-and-passives-3.md).
    A chooser is any player still in the game (not Gone).
  - A passive is available if it is not at its top level for at least one
    chooser.
  - An air weapon's passive is offered only on the way into a level where
    that weapon can be flown. The Ion Cannon (`aiic`, levels 1-3) stops
    being offered after level 3.
  - The ground weapon's passives are always offered.
  - **Alternatives.** Passives that share a `Passive_Def.exclusive` group
    give each other up: taking one drops any other of its group held
    (`passives.passive_take`), and the one taken starts from level 1. The
    reward screen says so under the option ("REPLACES REVERSE PLASMA
    BOMB"). Ground Variant 1 and 2, the ground weapon's two charges, are
    the one group.
  - Player 1's cursor starts on the first option, and the others' on the
    last.
- **Choosing.**
  - Left and right step through the options and wrap. Up and down move a
    row and stop at the edge.
  - Fire_Air locks in, and Fire_Ground unlocks.
  - An option another player has locked cannot be locked, and the attempt
    plays the refuse sound.
  - A player with nothing left to lock counts as ready.
  - Play resumes `REWARD_RESUME_DELAY` steps after everyone is ready, leaving
    a beat to take a lock back.
  - The sounds are the menus' own: `mbro` for a move, `lsse` for a lock,
    `lsna` for a refusal and `incl` for an unlock.

## How each entry was read

The weapon names are the data's ids. The four air weapons are numbered in
the order they unlock: `aiic` Ion Cannon from level 1, `aibg` Bacta Gun
from 2, `airg` Rear Gun from 3, `aipb` Photon Beam from 5. Ground Variant 1
and 2 are `plbo`'s, the Plasma Bomb, the only ground weapon.

### Ship passives

- **Improved Manoeuvring**
  - `maneuverability` scales `active_velocity_delta`.
  - `risky_reward` spawns `pi2k` ("Pickup - 2000") every 20 s of game time,
    at a random point 48 px in from the sides, between 48 px from the top
    and two thirds of the way down. It uses two new RNG sites
    (`0xe0000001/2`) that no demo reaches.
- **Auto Charge**
  - The air power-up charges whenever the button is not held (`air_idle`
    stands in for `air_held`).
  - A press releases the charge, and holding autofires, as auto-repeat
    does.
  - Only weapons with an air power-up and no auto-repeat of their own are
    affected.
  - `prevent_overheat` makes the overload time 0 (never).
- **Improved Charge**
  - `maximum_charge` scales `powerup_air_max_power_level`.
  - `charge_rate` scales how often the level climbs. It is kept in
    hundredths of a step (`powerup_level_due`), because a 10% change to a
    2-step interval would otherwise round away.
- **Shield Regen**
  - The design's second `charge_rate` is its own stat here,
    `shield_regen_rate`, since it means percent per second of shields, not
    weapon charge.
  - `recharge_delay` and the rate are flat amounts (seconds, percent per
    second) over a base of none, as the design's values are written.
    "Decreased" there describes the trend across the levels.
  - Any damage restarts the wait. Shields climb in the eighths the shield
    store already rounds to (commit ae6a9f3).

### Weapon passives

- **Lanes.** "Continue the pattern" is read as: the projectiles of a volley
  are lanes, sorted across the spread, and extra lanes carry the end pairs'
  spacing and heading on outwards (`lanes_extend`).
  - An even extra adds half on each side. An odd extra shifts every lane
    half a step, so the spread stays symmetric.
  - Examples: Ion's -5/4 with +2 becomes -14/-5/4/13. The Photon Beam's
    -6/0/6 with +3 becomes -15..15 in steps of 6. A single lane spreads by
    `LANE_SPACING`, 12 px.
  - Each lane takes the unit and timing of the original lane nearest to it.
- **Volleys.** A volley is one set of lanes fired at once.
  - A direct-fire weapon lists its projectiles in its own spawn list (Ion
    Cannon, Bacta Gun). Its extra volleys are fired from the weapon handler
    one `VOLLEY_INTERVAL` apart.
  - A spawner weapon spawns an entity whose spawn sets are the lanes (Rear
    Gun, Photon Beam). Its extra volleys come from the spawner living one
    more volley period each.
  - Volley delay scales the spawner's own clock (`spawn_pace`), or the
    handler's interval.
- **Ground Variant 1** (Reverse Plasma Bomb) and **Ground Variant 2**
  (Orbiting Plasma Bomb), from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  - Each is a charge passive for the bomb (`charge = true`), and gives it
    the ground weapon's charge (`ground_charge`, see The rules as
    implemented). The burst a press drops is the bomb's own.
  - Ground Variant 1's crosshair swings round behind the ship as the
    charge gets ready, and is held there. Its bomb is "a single strong
    shot backwards".
  - Ground Variant 2's crosshair circles the ship once every two seconds
    while it is held, and goes back ahead on release, as the notes ask.
    Its bomb deals more damage than Ground Variant 1's.
  - They are alternatives (`exclusive = "ground_charge"`): taking one
    gives up the other.
  - Ground Variant 1 used to turn the whole weapon round for good: every
    spawn mirrored behind the ship, and the crosshair pushed out by
    holding Up against the top of the screen. The notes asked for the
    bomb to be left as it is, and that went (`Fires_Backwards`).
  - The volley delay paces the bomb burst in hundredths. No passive uses
    it on the bomb any more (see Tuning).
- **Weapon 1** (Ion Cannon). Accelerating shots leave at the scaled initial
  speed (50% at level 3). They then speed up evenly and are back to the
  unit's own speed `ACCEL_SECONDS` (1 s) later, as
  [notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md)
  asks. They used to climb to 150%, which made level 3 strong in the wave.
- **Weapon 2** (Bacta Gun). `projectile_lifetime` scales the shot's timer,
  and so its range.
- **Weapon 1 Charge** (Ion Cannon), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  the release's shots also hit ground targets (see The rules as
  implemented). "Damage is reduced but the penalty goes down each level"
  is `Ground_Damage` at every level: 60%, 45% and 30% off. The penalty
  is never lifted, so the passive does not make the Ion Cannon a ground
  weapon. `MENU=ion_cannon_charge` shows a release at level 3 hitting two
  Laser Tanks.
- **Weapon 2 Charge** (Bacta Gun), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  the release's hits leave corrosive clouds (see The rules as
  implemented), for the notes' "2 seconds base". "Small amounts of
  damage" is `CLOUD_DAMAGE`, 0.3 shields a second, half a release shot's
  hit. The notes set nothing for the levels: they make the clouds linger
  longer (`Cloud_Lifetime`) and the charge faster (`Charge_Rate`).
  `MENU=bacta_gun_charge` shows a release at level 3.
- **Weapon 3** (Rear Gun)
  - Side fire makes each forward-facing set fire to the side it is on as
    well. A centre lane fires both ways. It fires on the first volley of
    each shot only (`Shaped.side_volley` marks the step): on every volley
    it sent 8 bullets sideways a shot, which played too strong. The DPS
    report has no target to the side, so its numbers do not change.
    The bullet (`rgbu`, sprite `regu`) has one frame, facing north, so a
    side shot is drawn turned to its heading (`Shaped.turned`); a shot
    with a frame per direction is left alone. `MENU=rear_gun_side` shows
    it.
- **Weapon 3 Charge** (Rear Gun), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  the release's bubbles wear (see The rules as implemented). "Run out of
  damage to give" is read as the bubble's own damage: a bare bubble
  gives it in one hit and bursts, a wearing one spreads it over its
  hits, shrinking, and a larger one has more to give. "Each level makes
  the bubbles larger and longer lasting" is `Shot_Scale` and
  `Projectile_Lifetime` at every level. The bubble inflates from 30% as
  it leaves, so it reaches the larger size as it would have reached its
  own. `MENU=rear_gun_charge` shows a release at level 3.
- **Weapon 4** (Photon Beam). `firing_delay` scales
  `delay_between_launches`.
- **Weapon 4 Charge** (Photon Beam), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  "gains 2 extra projectiles for every x charge over the base amount" is
  2 lanes for every 25% of the base max (see The rules as implemented),
  which makes the design's "+4 projectiles at full upgrades" a max
  charge 50% over, level 3's. Level 1's 25% rounds the max from 22 to
  28, one pair's worth; level 2's 40% makes it 31, still one; level 3's
  33 is two. "Falls off back to the base amount as the charge level
  depletes" is the count read from each spawn's level. The design asks
  for a wide spread pattern, so the pairs fan 10° apart beyond the
  beam's own 3° lanes. Levels 1 to 3 also charge faster, past the
  design (see Tuning).
- **Weapon 5** (Chaingun, `plugins/chaingun`) and **Weapon 6** (Discharge
  Beam, `plugins/new_weapons`) are the plugins' weapons, from
  [notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md).
  New Weapon Upgrades (`plugins/new_weapon_passives`) registers them, so
  they are offered only while it is on, and each only while its weapon's
  plugin is too (`passive_available` asks `sim.weapon_allowed`).
- **Weapon 5.** "Fires continuously" is read as closing the gap between
  bursts. A burst of 10 rounds takes 20 steps, and the firing delay is 30,
  so level 3's 33% off (20 steps) leaves no gap. `random_spread_range`
  scales a shaped shot's `initialHeadingTolerance`
  (`stats.heading_tolerance`), capped at a full turn. A unit with none
  still flies straight, and draws nothing more.
- **Weapon 6.** The beam is not a projectile, so the plugin reads the
  stats itself (`beam_scaled` in `plugins/new_weapons/beam.odin`).
  `projectile_damage` scales a pulse and a charge's release.
  `base_beam_width` is `Shot_Width`, a stat for any
  shot cast as a line rather than flown; the beam's width is scaled by it
  plus the damage's percentage, as "width also scales with damage" asks,
  so level 3 is 90% wider. The reward screen shows the width stat alone.
- **Weapon 5 Charge** (Chaingun), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  "firing speed ramps up as it fires" is `Release_Ramp` (see The rules
  as implemented). The release's volleys start at the data's every 3
  steps and close to every 2 from the second. Each level raises the max
  charge, as the design asks, and levels 2 and 3 the charge rate too
  (see Tuning).
- **Weapon 6 Charge** (Discharge Beam), a charge passive from
  [notes/extra-weapons-and-passives-3.md](../../notes/extra-weapons-and-passives-3.md):
  the charged beam chains (`Chains`, D70). It goes straight to its first
  target, then from each kill jumps to the nearest target on screen it
  has not hit, "until the laser runs out of damage". A target left
  standing, or one the hit delay protects, stops it too, as it stops a
  straight beam. The pulses still pierce straight on: the passive counts
  in the charge's scope only.
  - "Each level increases max charge and charge speed" is read from level
    2 (see Tuning).

## Tuning (2026-09-25)

The weapon passives' numbers no longer follow the design. They are tuned
with the DPS report (`mise run dps:report`, [dps-report.md](dps-report.md)).
Level 1 adds 10-20% to the weapon's DPS, level 2 20-40%, and level 3
40-60%. This is measured as the report's Gain: the change in the
weapon's DPS averaged over the four scenarios. What a passive reaches
where the bare weapon reaches nothing (behind, for most) adds to it.

A target takes at most one hit every two steps. So a lane that arrives
with another adds nothing to a lone target, and extra volleys add the most.
A percentage off a firing delay counts only once it rounds to a whole step:
the Ion Cannon's 4 steps take 20% to lose one.

| Passive | Level 1 | Level 2 | Level 3 | Gain |
|---|---|---|---|---|
| Weapon 1 (Ion Cannon) | +1 projectile | firing delay -20% | +2 projectiles, accelerating shots, launch speed -50% | +16.8 / +31.0 / +51.1% |
| Weapon 2 (Bacta Gun) | firing delay -20%, range +10% | +2 projectiles, range +20% | firing delay -40%, +4 projectiles, range +50% | +17.2 / +29.4 / +52.7% |
| Weapon 3 (Rear Gun) | firing delay -10% | firing delay -20% | +1 volley, side fire | +10.2 / +22.0 / +39.6% |
| Weapon 4 (Photon Beam) | firing delay -20% | firing delay -40% | firing delay -10%, +1 volley | +18.7 / +32.9 / +45.2% |
| Weapon 5 (Chaingun) | firing delay -13%, spread +25% | firing delay -20%, spread +50% | firing delay -33%, spread +100% | +11.9 / +23.8 / +49.2% |
| Weapon 6 (Discharge Beam) | damage +15%, width +10% | damage +30%, width +20% | damage +60%, width +30% | +10.7 / +21.4 / +42.9% |
| Weapon 1 Charge (Ion Cannon's charge) | hits ground, ground damage -60% | ground damage -45%, charge rate +20% | ground damage -30%, charge rate +40% | +15.6 / +35.7 / +57.1% |
| Weapon 2 Charge (Bacta Gun's charge) | corrosive clouds | cloud time +50%, charge rate +20% | cloud time +100%, charge rate +50% | +19.2 / +32.6 / +50.0% |
| Weapon 3 Charge (Rear Gun's charge) | wearing shots, size +10%, life +20% | size +25%, life +40% | size +45%, life +60% | +15.9 / +30.1 / +50.3% |
| Weapon 4 Charge (Photon Beam's charge) | overcharge shots, max charge +25%, charge rate +20% | max charge +40%, charge rate +40% | max charge +50%, charge rate +80% | +15.8 / +32.8 / +47.7% |
| Weapon 5 Charge (Chaingun's charge) | release ramp +20% a volley, max charge +10% | max charge +20%, charge rate +20% | max charge +40%, charge rate +60% | +12.4 / +25.6 / +46.8% |
| Weapon 6 Charge (Discharge Beam's charge) | chains | max charge +20%, charge rate +20% | max charge +40%, charge rate +40% | +17.3 / +32.8 / +46.2% |
| Ground Variant 1 (Plasma Bomb's charge) | aimed behind, damage +340% | damage +780% | damage +1370% | +14.9 / +29.8 / +49.8% |
| Ground Variant 2 (Plasma Bomb's charge) | aimed around, damage +560% | damage +1200% | damage +2050% | +14.9 / +29.4 / +48.6% |

Levels carry what they do not change (the design's `x`).

- **Weapon 1 level 3.** Shots that start slow and only get back to full
  speed add nothing but delay: alone they measured +31%. The band comes
  from two extra lanes, which pay in the cluster and the wave. One extra
  volley measured +122%, and a 40% shorter firing delay +71%.
- **Weapon 3 level 3** stops at +39.6%. The bare Rear Gun already lands
  two thirds of the hits a lone target can take. A second extra volley
  measures the same as one.
- **Weapon 4** steps its firing delay back to 10% at level 3, where the
  extra volley takes over. With 40% the volley would make it +61%.
- **Ground Variant 1 and 2** are all damage, and a great deal of it: the
  charge drops one bomb (0.4 damage) where a press drops a burst, and
  every gain is from a target the bare bomb cannot reach. Held, aimed and
  let go, a charge comes round about once a second behind for Variant 1
  and every 1.5 s for Variant 2, whose crosshair takes twice as long to
  get there. So their damage climbs to 5.9 and 8.6 a bomb at level 3,
  more than any one ground enemy has. Ahead, taps still beat holding for
  every level of either, so they add nothing there. `projectile_damage`
  is a last resort (see Balance in AGENTS.md); here, with one bomb
  against one target, nothing else adds. Variant 1 had the design's
  shorter volley delay (10%, 20%) once, before it was a charge: a burst
  already lands a bomb every two steps, the most a target takes, so it
  measured -9%, -19% and -19%.
- **Weapon 5 level 1** takes 13% off, not the design's 10%. 10% makes the
  delay 27 steps where 13% makes it 26, and 10% measured +8.6%.
- **Weapon 6** raises the damage 15/30/60%, not the design's 10/20/30%,
  which measured +7.1 / +14.3 / +21.4%. In the wave a pulse already
  kills what it hits and the next column is 40 px away, out of reach of
  any width, so only the single and cluster targets gain: the Gain is
  0.71 times the damage's percentage. The widths are the design's.
- **Weapon 1 Charge** is measured in the Charge-shots set, where the
  DPS report adds a ground target for it (docs/dps-report.md). Its air
  scenarios are unchanged, so the ground target is all the gain, and that
  is in proportion to the share: 50%, 65% and 80% of the damage made
  +19.5 / +25.3 / +31.2%. A faster charge takes levels 2 and 3 into their
  bands.
- **Weapon 2 Charge** is measured in the Charge-shots set. The clouds
  alone gain +19.2%: +7.9% on a lone target or a cluster, and +66.9% on
  the wave, which flies through the clouds the release leaves ahead of
  it. Behind stays at nothing, as the release fires ahead. Doubling the
  clouds' time adds under 2 points, a target being dead or past a cloud
  before it would go, so the charge rate carries levels 2 and 3. In play
  a longer cloud holds more ground.
- **Weapon 3 Charge** is measured in the Charge-shots set. The wear
  alone gains +8.6%: a bubble no longer bursts on a target it cannot
  hurt yet (inside its hit delay), nor spends its whole hit on one
  nearly dead. Size is the lever: 20% more of it adds about 18 points,
  in the single, cluster and wave scenarios alike, as a larger bubble
  gives more and reaches more. The release fires ahead only, so behind
  stays at nothing. The longer life gains nothing there, where every
  bubble hits before it would expire. A first reading gave a bubble 4
  hits' damage to give; level 1 measured +238%, so a bubble gives its
  own damage, and no more.
- **Weapon 4 Charge** is measured in the Charge-shots set. The
  overcharge lanes alone, with the max charges, gain -0.4 / +5.0 /
  +6.1%: the wider lanes miss a lone target, and the release's first
  few spawns are all that fan out. A 5° fan measured less and a 20° one
  about the same. As for Weapon 5 Charge, a higher max charge gains
  nothing alone, so each level also charges faster, past the design.
  Charge rates of 20/40/80% make +15.8 / +32.8 / +47.7%, the cluster
  gaining the most (+77.2% at level 3); 30/60/120% took level 3 to
  +68.6%.
- **Weapon 5 Charge** is measured in the Charge-shots set. The ramp
  gains +12.4%: its release is spent in 2 steps a volley, not 3, so the
  next charge starts sooner. A higher max charge gains nothing in the
  report, since the charge and its release grow with it alike: +20% and
  +40% alone measured as level 1 did. So levels 2 and 3 also charge
  faster, past the design. 20% and 60% make +25.6% and +46.8%; the rate
  rounds in steps, and 25% measured as 20% did.
- **Weapon 6 Charge** is measured in the Charge-shots set, as an air
  weapon's charge passive is: the charge is all it changes. The chain
  alone gains +17.3%, near the top of level 1's band, all of it in the
  wave (+144%), where the charged beam now kills its way across the
  columns. The smallest charge step added on top took level 1 over 20%
  (3% each measured +20.4%), so the charge comes in from level 2. With
  the chain, levels 2 and 3 have the design's increases.
- Charge shots are otherwise not tuned. Weapon passives add at most 1% to them,
  except Weapon 6, whose damage bases the release: +13.2 / +26.4 /
  +52.8%, in the primary fire's bands without a change since the charge
  lost its motes.

## Provisional

Each of these is marked in the code, with what would settle it:

- `VOLLEY_INTERVAL` = 2 steps. No original weapon fires volleys from the
  handler to measure. 2 is the gap the Rear Gun's and Photon Beam's
  spawners leave.
- The accelerating shots' even climb over `ACCEL_SECONDS`. The design says
  when they are back to full speed, not how they get there.
- `REWARD_RESUME_DELAY` = 10 steps.
- `GROUND_CHARGE_HOLD` = 15 steps before the ground weapon's charge
  begins: the air weapons' own time until activation.
- `ground_charge_ready` = half a second more before it can be let go:
  the time its crosshair takes to swing round behind.
- `CHARGE_SWING_DEGREES_A_SECOND` = 360 and
  `CHARGE_ORBIT_DEGREES_A_SECOND` = 180: a charged crosshair swings
  behind in half a second, and circles the ship in two.
- `LANE_SPACING` = 12 px, for a weapon with a single lane.
- `OVERCHARGE_STEP` = 25% and `OVERCHARGE_FAN` = 10°: the design's "every
  x charge over the base amount" and "wide spread pattern" set no number.
  25% makes its +4 projectiles at level 3's max charge.
- `WEAR_HITS` = 1, the hits' worth of damage a wearing shot has to give
  at its own size, and `WEAR_MIN_SIZE` = 40%, the least it shrinks to.
- `CLOUD_RADIUS` = 20 px, picked by eye as a small enemy's size, and
  `CLOUD_DAMAGE` = 0.01 shields a step, the "small amounts of damage",
  tuned by the DPS report. The clouds' look (`plugins/passives/view`) is
  picked by eye.
- The icons' compositions (see Icons) are a first pass, not a
  designed set.

## Verification

- `mise run ci` is green. The passives' own tests (`plugins/passives/tests`)
  and the reward screen's and the stats' (`tests/passives_test.odin`)
  cover:
  - the level format and stacking, rounding, and lane extension;
  - each passive counting in its own scope, shots or charge;
  - the reward screen's option count, navigation, lock, refuse, unlock,
    resume and apply;
  - no screen outside easy mode or after the last level;
  - the shield regeneration timing;
  - two rollback peers converging through two reward screens under latency
    and loss;
  - the shipped weapons' lanes, the bomb's charge turned round and each
    passive's weapon being in the data. This test is skipped without
    `src/assets`;
  - New Weapon Upgrades' own (`plugins/new_weapon_passives/tests`):
    Weapon 5 Charge's release closing from a volley every 3 steps to
    every 2, and no further, in its own weapon's charge only; Weapon 6
    Charge's release jumping to the nearest target it has not
    hit, a run for each jump, until a target stands or its damage is
    spent, while the pulses still pierce straight (skipped without
    `src/assets`);
  - Weapon 1 Charge's release hitting a Laser Tank it flies over for
    40% of its damage at level 1 and 70% at level 3, where a bare
    release passes over (skipped without `src/assets`);
  - Weapon 2 Charge's release hit leaving a cloud that harms the mine
    it hit by `CLOUD_DAMAGE` each step for 2 seconds, from the hit's own
    step, without its last hit changing, where a bare shot only hits
    (skipped without `src/assets`);
  - Weapon 3 Charge's bubble 45% larger at level 3, giving a tough
    mine its 0.8 and then the 0.36 it has left, shrinking, and gone,
    where a bare bubble hits once and bursts (skipped without
    `src/assets`);
  - Weapon 4 Charge's release fanning out 4 more lanes from its first
    spawn at level 3's max of 33, 2 from 32 to 28, and none from 27,
    the outermost 23° off straight ahead (skipped without `src/assets`);
  - the ground charges replacing each other, and Ground Variant 1's
    charge from a hold to its bomb behind the ship (skipped without
    `src/assets`);
  - an icon recipe, and an icon file, for every passive.
- `mise run oracle:diff` still replays all four demos exactly: with no
  passive held, every hook computes what the original does.
- `sim.checksum` mixes the reward screen, passives and regeneration only in
  easy mode, so checksums outside it are unchanged.
- Looked at, headless (`mise run menu-shot`):
  - `MENU=reward`, one player with two options;
  - `MENU=reward_2p`, with player 1 locked inside player 2's dull border on
    the same option;
  - `MENU=level_select_easy`;
  - `MENU=rear_gun_charge`, a Rear Gun release at Weapon 3 Charge's
    level 3, its bubbles flying out larger;
  - `MENU=bacta_gun_charge`, a Bacta Gun release at Weapon 2 Charge's
    level 3, a corrosive cloud lingering where it hit;
  - `MENU=ion_cannon_charge`, an Ion Cannon release at Weapon 1 Charge's
    level 3 hitting two Laser Tanks ahead.

## Open

- Nobody has played it by hand yet: the feel of the provisional constants,
  and of Auto Charge on each weapon, is untested.
- The netplay lobby's toggle has been checked by the packet tests and a
  look at the code, not with two live instances.
