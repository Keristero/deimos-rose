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
    and 6 that way. It needs Passive Upgrades and New Weapons, and is a
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
| Weapon 1-4 | the weapon's score-bar symbol (`wesy` 0, 1, 3, 2), with the plus |
| Weapon 5 | the Chaingun's score-bar symbol (`wesy` 4), with the plus |
| Weapon 6 | the Discharge Beam's red symbol (`wesd` 0, New Weapons' own plate), with the plus |

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
  - The ground weapon's passive is always offered.
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
is `plbo`, the Plasma Bomb, the only ground weapon.

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
- **Ground Variant 1**
  - Fires backwards: every spawn is mirrored behind the ship, heading
    `180 - angle`.
  - The crosshair sits at half its reach below the ship, and against the
    bottom edge it stops as it normally stops against the top.
  - `fires_backwards` is listed as a stat, so the reward screen shows it
    like the rest.
  - The volley delay paces the bomb burst in hundredths. No passive uses
    it on the bomb any more (see Tuning).
- **Weapon 1** (Ion Cannon). Accelerating shots leave at the scaled initial
  speed (50% at level 3). They then speed up evenly and are back to the
  unit's own speed `ACCEL_SECONDS` (1 s) later, as
  [notes/extra-weapon-passives-and-base-adjustments.md](../../notes/extra-weapon-passives-and-base-adjustments.md)
  asks. They used to climb to 150%, which made level 3 strong in the wave.
- **Weapon 2** (Bacta Gun). `projectile_lifetime` scales the shot's timer,
  and so its range.
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
- **Weapon 4** (Photon Beam). `firing_delay` scales
  `delay_between_launches`.
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

## Tuning (2026-09-25)

The weapon passives' numbers no longer follow the design. They are tuned
with the DPS report (`mise run dps:report`, [dps-report.md](dps-report.md)).
Level 1 adds 10-20% to the weapon's DPS, level 2 20-40%, and level 3
40-60%. This is measured as the report's Gain: the mean over the
scenarios the bare weapon reaches. For Ground Variant 1 it is its DPS
behind against the bare bomb's single target ahead.

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
| Ground Variant 1 (Plasma Bomb) | fires backwards, damage +15% | damage +30% | damage +50%, +1 projectile | +14.9 / +29.8 / +49.8% |

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
- **Ground Variant 1** had the design's shorter volley delay (10%, 20%).
  A burst already lands a bomb every two steps, so any bombs closer than
  that were ignored. It measured -9%, -19% and -19%. With every rate
  lever at the cap, the bands come from `projectile_damage`, a stat the
  design does not have. See Balance in AGENTS.md for why that stat is a
  last resort.
- **Weapon 5 level 1** takes 13% off, not the design's 10%. 10% makes the
  delay 27 steps where 13% makes it 26, and 10% measured +8.6%.
- **Weapon 6** raises the damage 15/30/60%, not the design's 10/20/30%,
  which measured +7.1 / +14.3 / +21.4%. In the wave a pulse already
  kills what it hits and the next column is 40 px away, out of reach of
  any width, so only the single and cluster targets gain: the Gain is
  0.71 times the damage's percentage. The widths are the design's.
- Charge shots are not tuned. Weapon passives add at most 1% to them,
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
- `LANE_SPACING` = 12 px, for a weapon with a single lane.
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
  - the shipped weapons' lanes, the backwards bomb and each passive's
    weapon being in the data. This test is skipped without `src/assets`;
  - an icon recipe, and an icon file, for every passive.
- `mise run oracle:diff` still replays all four demos exactly: with no
  passive held, every hook computes what the original does.
- `sim.checksum` mixes the reward screen, passives and regeneration only in
  easy mode, so checksums outside it are unchanged.
- Looked at, headless (`mise run menu-shot`):
  - `MENU=reward`, one player with two options;
  - `MENU=reward_2p`, with player 1 locked inside player 2's dull border on
    the same option;
  - `MENU=level_select_easy`.

## Open

- Nobody has played it by hand yet: the feel of the provisional constants,
  and of Auto Charge on each weapon, is untested.
- The netplay lobby's toggle has been checked by the packet tests and a
  look at the code, not with two live instances.
