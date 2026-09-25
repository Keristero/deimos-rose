# Easy mode and passive upgrades

New content, not the original's: the design is
[notes/passive-upgrades-and-easy-mode.md](../../notes/passive-upgrades-and-easy-mode.md).
This records what was built, how each entry of the design was read where it
left room, and what is still provisional. The cross-cutting choice is D36 in
[decisions.md](decisions.md).

## What was built

- **Easy mode** is an extra (`prefs.EXTRAS`, key `easy_mode`, off by
  default), so classic mode switches it off with every other extra. It is
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
- **The reward screen** (`sim/reward.odin`) is part of the simulation. After
  a level's tally, `session_step` opens it instead of advancing, as long as
  another level is to come. Because it is stepped, snapshotted and rolled
  back like play, and a reconnect resync copies it with the rest of `State`,
  netplay needed no new messages for it.
  - While it is open, game time, entities and the playfield stand still.
    Only the frame count moves, plus one RNG draw per option when it opens.
  - Once it closes, the same step's `level_transition` moves on to the next
    level.
- **The passives** (`sim/passives.odin`) are held per player as a level per
  passive, in `Player.passives`.
  - They are kept across levels and cleared by `player_setup` when a session
    starts.
  - Every stat is worked out from the levels held whenever it is needed. It
    is never stored.
- **Presentation** (`game/reward.odin`, `game/passives.odin`):
  - The overlay is drawn over the dimmed play area. The HUD stays as it
    was.
  - Two in-play effects: accent-coloured motes drawn in to a ship whose
    shields are regenerating, and sparks off a charge climbing past the
    weapon's own maximum.

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
- **Weapon passives** count only for their own weapon's shots (`stat_total`'s
  `weapon`). A passive's shots carry `passive_tag` from spawn onwards, so the
  passive can shape them after they spawn.
- **Offering.**
  - There are `min(choosers + 1, available)` options, drawn without repeats.
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
  - The volley delay paces the bomb burst in hundredths.
- **Weapon 1** (Ion Cannon). Accelerating shots leave at the scaled initial
  speed (50% at level 3). They then gain `ACCEL_RATE` a step until they reach
  `ACCEL_TOP`, 150% of the unit's speed.
- **Weapon 2** (Bacta Gun). `projectile_lifetime` scales the shot's timer,
  and so its range.
- **Weapon 3** (Rear Gun)
  - The design's `(1,2,0)` is taken literally: level 3 trades the extra
    volleys for side fire.
  - Side fire makes each forward-facing set fire to the side it is on as
    well. A centre lane fires both ways.
- **Weapon 4** (Photon Beam). `firing_delay` scales
  `delay_between_launches`, and `volley_delay` the spawner's clock.

## Provisional

Each of these is marked in the code, with what would settle it:

- `VOLLEY_INTERVAL` = 2 steps. No original weapon fires volleys from the
  handler to measure. 2 is the gap the Rear Gun's and Photon Beam's
  spawners leave.
- `ACCEL_RATE` = 1.0 and `ACCEL_TOP` = 150%. The design names the effect,
  not the curve.
- `REWARD_RESUME_DELAY` = 10 steps.
- `LANE_SPACING` = 12 px, for a weapon with a single lane.
- Weapon 3's `(1,2,0)`. It may be meant as `(1,2,x)`.
- The ship passives' icons (`pl1b`, `ioca`, `phbe`, `pish`) are the
  existing sprites closest in meaning. A weapon passive uses its weapon's
  score-bar preview.

## Verification

- `mise run ci` is green, with 121 tests. The 13 in `tests/passives_test.odin`
  cover:
  - the level format and stacking, rounding, and lane extension;
  - the reward screen's option count, navigation, lock, refuse, unlock,
    resume and apply;
  - no screen outside easy mode or after the last level;
  - the shield regeneration timing;
  - two rollback peers converging through two reward screens under latency
    and loss;
  - the shipped weapons' lanes, the backwards bomb and each passive's
    weapon being in the data. This test is skipped without `src/assets`.
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
