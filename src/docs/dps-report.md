# The DPS report

This is a balance tool, not game content. The request is in
[notes/dps-report.md](../../notes/dps-report.md). This page records:

- how the tool measures;
- how each point of the request was read;
- the first run's numbers, which are the baseline for later changes;
- what is still provisional.

`mise run dps:report` builds and runs `tools/dps`. It writes
`work/reports/dps-YYYY-MM-DD.html` and prints the same tables as text.

Options:
- `OUT=` sets the output directory.
- `DPS_SECONDS=` sets the play measured per run (60 by default).
- `DPS_STAGE=` sets the stage (7 by default).

A run takes about 2 s across 32 cores, which is 12,448 runs of 60 s of
play each.

## Method

**The sim alone.** The tool imports `dr:sim` and `dr:data` and nothing
that draws or plays sound. Every run starts a fresh `sim.State`:
- on a copy of the stage with its placements removed, so nothing else
  spawns;
- with one player;
- with a fixed seed, so a passive's run is paired with the baseline's.

The same invocation gives the same report on 1, 3, 32 or 64 threads.

**Setup.** Once the ship is in play, the run:
1. sets `Player.passives`;
2. gives the ship the weapon with `sim.change_weapon`;
3. waits 90 steps for the crosshair to settle;
4. spawns the targets.

**Targets.** Two stand-in units are appended to `Defs.units`:
- `dpsa`, copied from the BlackHawk, for air weapons;
- `dpsg`, copied from the Laser Tank, for the Plasma Bomb.

Each copy is a group of one with no placement offsets, spawned stationary.
It has one state: the unit's first, stripped of timers, rules, spawn sets,
movement and invulnerability, with `pause_vertical_scrolling` on. The copy
keeps:
- the source unit's sprite, and so its hit circle;
- the source unit's `damage`, so a shot that hits is spent as it would be
  against the real enemy.

After every step, the run adds up how much the targets' shields dropped,
then puts them back to 10,000.

**Scenarios.**
- **Single target:** one target 120 px straight ahead of the ship for air
  weapons, or on the crosshair for the Plasma Bomb.
- **Cluster:** that target plus four more in a V, 40 px either side and
  two 34 px further back.

**Policies.** A weapon's DPS is the best result from any of these firing
policies, so the numbers are a perfect player's:
- a tap every 2 to 40 steps;
- charge and release, for weapons with an air power-up: hold until the
  charge is full, let go for one step, hold again. Under Auto Charge this
  is inverted, since the charge builds while fire is released;
- hold, only under Auto Charge, where holding autofires. Otherwise holding
  a charge weapon sits on a full charge until it overheats.

The report also gives each kind of policy's own best result, so the
charge attack's DPS is visible even where tapping beats it.

**Passives.** The run tests every passive at every level, one at a time,
against every weapon: 25 levels plus the baseline. A weapon passive only
changes its own weapon (`stat_total`), so it shows 0% elsewhere, which
checks the harness. Improved Manoeuvring and Shield Regen don't change
firing, and they come out at exactly 0% on every weapon. That confirms
the pairing is noise-free.

## How the request was read

- **"A fast DPS check for each weapon."** Every air weapon and the ground
  weapon in `Defs.weapons` are checked, the Chaingun included. It is
  loaded from `assets/extra` and flown without a New Weapons session.
- **"Every passive, at each possible level."** One passive at a time, not
  combinations. There are 25 levels, and combinations would multiply them.
- **The report.** Weapons are sorted by the mean of their single-target
  and cluster DPS. Each is a `<details>` element that opens to its
  passives ranked by gain. The overall list averages each passive level's
  gain over all six weapons and both scenarios. A second column averages it
  over only the weapons the passive changes, since a weapon passive's
  plain average is diluted six ways.

## First run: 2026-09-25, stage 7, 60 s

| Weapon | Single | Cluster | Best policy | Charge only |
|---|---|---|---|---|
| Bacta Gun | 5.98 | 8.96 | tap every 2 | 3.43 |
| Photon Beam | 5.33 | 5.33 | tap every 3 | 1.20 |
| Plasma Bomb | 4.90 | 4.90 | tap every 17 | – |
| Chaingun | 4.83 | 4.83 | tap every 31 | 3.02 |
| Rear Gun | 4.00 | 4.00 | tap every 3 | 2.98 |
| Ion Cannon | 2.84 | 2.84 | charge | 2.84 (taps 2.40) |

The Plasma Bomb's burst grows by one bomb per stage, up to 8, so its DPS
depends on the stage. Taking the best cadence at each stage:
- stage 1: 2.38;
- stage 3: 3.96;
- stage 5: 4.57;
- stage 7: 4.90;
- stages 9 and 12: 5.01.

Passive gains that are not 0%, as single / cluster:

| Passive | Weapon | Gain |
|---|---|---|
| Weapon 1 (Ion) 2 | Ion Cannon | +68.5% / +68.5% |
| Weapon 1 (Ion) 3 | Ion Cannon | +68.5% / +405.4% |
| Weapon 2 (Bacta) 3 | Bacta Gun | +50.0% / +100.0% |
| Weapon 3 (Rear) 1 | Rear Gun | +33.2% |
| Weapon 3 (Rear) 2 | Rear Gun | +49.9% |
| Weapon 4 (Photon) 1, 2 | Photon Beam | +12.5% |
| Weapon 4 (Photon) 3 | Photon Beam | +28.5% |
| Improved Charge 1 / 2 / 3 | Ion Cannon | +9.1% / +12.9% / +17.9% |
| Auto Charge 1, 2 | Ion Cannon | −13.3% |
| Auto Charge 1, 2 | the others | −0.5% to +1.2% |
| Ground Variant 1 1 | Plasma Bomb | −9.0% |
| Ground Variant 1 2, 3 | Plasma Bomb | −19.0% |

Every other passive level is 0% on every weapon. That includes:
- Weapon 1 level 1;
- Weapon 2 levels 1 and 2;
- Weapon 3 level 3.

### What the numbers say

- **The hit delay decides most of it.** `entity_hit` ignores a hit within
  `perm_floats[0xa7]` = 1 step of the enemy's last hit. So an enemy
  registers at most one hit every 2 steps, 15 hits a second, however many
  shots reach it.
  - Shots that land together are spent for one hit's damage. The Ion
    Cannon's pair of bullets deals the damage of one, which is 2.40 DPS
    from taps: 6 volleys a second × 0.4.
  - For the same reason, every *Extra Projectiles* modifier is worth 0%
    against a single target. Only lanes wide enough to reach a second
    enemy count: Weapon 1 level 3's +6 lanes, in the cluster.
  - *Extra Volley*, which fires again 2 steps later, is what the gains are
    made of.
- **Tapping beats charging for five of six weapons.** The exception is the
  Ion Cannon, whose charge (2.84) beats its taps (2.40). Photon Beam's
  charge is under a quarter of its taps (1.20 against 5.33). Improved
  Charge therefore only helps the Ion Cannon, and Auto Charge is a small
  loss or wash everywhere. For the Ion Cannon it is −13.3%, because it
  halves the charge rate.
- **Weapon 3 level 3 is a downgrade.** It trades level 2's two extra
  volleys (+49.9%) for side fire, which never meets a target ahead. As
  written, `(1,2,0)`, it takes the Rear Gun back to its bare DPS. That
  entry is already marked provisional in `sim/passives.odin`.
- **Ground Variant 1 lowers the Plasma Bomb's DPS.** The bombs of a burst
  fall 2 steps apart, exactly the hit delay. The Volley Delay cut packs
  them closer, so some land inside the delay and are ignored. Level 3's
  extra lane lands on the same spot, so it adds nothing.
- **Straight-firing weapons get nothing from a cluster.** Only the Bacta
  Gun's spread (+50%) and Weapon 1 level 3's wide lanes reach past the
  front target. It soaks every other shot.

## Provisional

Each of these was picked by eye and would change the numbers:
- the 120 px range to air targets;
- the V's spacing;
- the BlackHawk and Laser Tank as the stand-ins.

The range matters most for passives that change reach (Projectile
Lifetime, Accelerating Projectiles). At 120 px they cannot show a gain.

## Not measured

- Damage that needs a moving target. Nothing here dodges or crosses the
  line of fire, so aimed or spread weapons get no credit for tracking.
- Two passives at once.
- Two players.
- What the ship takes: survivability passives are outside this report.
- No test covers the tool. `mise run check` compiles it, and a run
  confirms itself: a run that cannot set up its targets fails the report.
