# The DPS report

This is a balance tool, not game content. The request is in
[notes/dps-report.md](../../notes/dps-report.md). This page records:

- how the tool measures;
- how each point of the request was read;
- the current numbers, which are the baseline for later changes;
- what is still provisional.

`mise run dps:report` builds and runs `tools/dps`. It writes
`work/reports/dps-YYYY-MM-DD.html` and prints the same tables as text.

Options:
- `OUT=` sets the output directory.
- `DPS_SECONDS=` sets the play measured per run (60 by default).
- `DPS_STAGE=` sets the stage (7 by default).

A run takes about 8 s across 32 cores, which is 29,064 runs of 60 s of
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
3. waits 90 steps for the crosshair to settle, keeping the air
   power-up from charging, so every run starts uncharged;
4. spawns the targets.

Under Auto Charge a charge builds while fire is let go, so the settle
steps would otherwise end on a full charge. The tool zeroes `air_idle`
after each settle step. That is the state holding fire would leave,
without the shots holding would fire.

**Targets.** Four stand-in units are appended to `Defs.units`:
- `dpsa`, copied from the BlackHawk, for air weapons;
- `dpsg`, copied from the Laser Tank, for the Plasma Bomb;
- `dpwa` and `dpwg`, the same two copied again with 0.8 shields, for the
  wave.

Each copy is a group of one with no placement offsets, spawned stationary.
It has one state: the unit's first, stripped of timers, rules, spawn sets,
movement and invulnerability, with `pause_vertical_scrolling` on. The copy
keeps:
- the source unit's sprite, and so its hit circle;
- the source unit's `damage`, so a shot that hits is spent as it would be
  against the real enemy.

A copy leaves nothing when it dies: no destruct spawn, coins, random bonus
or obstacle, so nothing it drops can take or give a hit.

Outside the wave, the run adds up how much the targets' shields dropped
after every step, then puts them back to 10,000, so they never die.

In the wave, the targets die. Each step the run takes what each target's
shields dropped since the last step. A target shot down counts only the
shields it had left, so damage past a kill is not counted, unless it
carries on to another target. It is replaced 12 steps later.

**Scenarios.**
- **Single target:** one target 120 px straight ahead of the ship for air
  weapons. For the Plasma Bomb it stands as far away as the crosshair,
  ahead of the ship.
- **Cluster:** that target plus four more in a V, 40 px either side and
  two 34 px further back.
- **Target behind:** the single target mirrored behind the ship, at the
  same distance.
- **Wave of 9:** three rows of three, 40 px apart across and 34 px deep,
  the first row where the single target stands. Each target has 0.8
  shields, about a stage 9–12 air enemy's, and is replaced 12 steps after
  it dies. This is the one scenario where overkill is wasted, and where
  damage that carries through a kill (the Discharge Beam's leftover and
  its shrapnel) counts.

The ground target is placed ahead or behind by rule, not on the crosshair
itself. Otherwise a passive that turns the crosshair round (Ground
Variant 1) would take its target with it.

**Two sets.** Every scenario is measured twice. Each cell is the best
policy in its set, so the numbers are a perfect player's.
- **Primary fire** never builds a charge. It takes the best of a tap every
  2 to 40 steps and, under Auto Charge, of holding, where holding
  autofires. Without Auto Charge, holding a charge weapon only sits on a
  full charge until it overheats. Under Auto Charge a slow enough tap lets
  a charge build between presses; a run in which the weapon under test
  began a charge is left out of this set.
- **Charge shots** hold until the charge is full, let go for one step,
  and hold again. Under Auto Charge this is inverted, since the charge
  builds while fire is released. The Plasma Bomb has no charge, so it is
  not in this set.

**DPS is over the whole run.** Every figure is the damage dealt in the
measured 60 s, divided by 60. A charge shot's DPS therefore includes the
time spent charging. It is the rate a player gets by keeping to that
pattern for a minute, not the damage of one release.

**Passives.** The run tests every passive at every level, one at a time,
against every weapon: 25 levels plus the baseline. A weapon passive only
changes its own weapon (`stat_total`), so it shows 0 elsewhere, which
checks the harness. Shield Regen doesn't change firing, and it comes out
at exactly 0 on every weapon in both sets, as does Auto Charge in the
primary set. That confirms the pairing is noise-free.

Improved Manoeuvring is 0 everywhere but one cell: level 2 adds +0.4%
(0.01 DPS, under one hit's damage over the run) to the Rear Gun's charge
shots ahead. It changes the ship's acceleration, so the likeliest cause is
a sub-pixel difference in where the entry leaves the ship. This has not
been confirmed.

## How the request was read

- **"A fast DPS check for each weapon."** Every air weapon and the ground
  weapon in `Defs.weapons` are checked, the Chaingun and the Discharge
  Beam included. They are loaded from `assets/extra` and flown without a
  New Weapons session.
- **"Every passive, at each possible level."** One passive at a time, not
  combinations. There are 25 levels, and combinations would multiply them.
- **The report.** There is one section per set. Weapons are sorted by
  the mean of their four scenarios. Each is a `<details>` element that
  opens to its passives, ranked by the DPS they add. The overall list
  averages each passive level's DPS added over the set's weapons and
  scenarios. A second column averages it over only the weapons the
  passive changes, since a weapon passive's plain average is diluted
  across every weapon.
  Every table, and the weapon list, sorts by the column clicked; a
  second click reverses it. Numbers start highest first, text A to Z, and
  a cell with nothing to show ("–") sorts last either way.
- **Gains in DPS, not percent.** A weapon that deals nothing to a target
  behind has nothing to take a percentage of, and a passive that turns it
  round is worth most there. The per-scenario change is still shown as a
  percentage, or as "from 0".
- **"Charge time averaged."** This is read as the whole-run rate above:
  total damage over total time, charging included.

## Run: 2026-09-25, stage 7, 60 s

### Primary fire

| Weapon | Single | Cluster | Behind | Wave | Best policy (single) |
|---|---|---|---|---|---|
| Bacta Gun | 5.98 | 8.96 | 0 | 8.55 | tap every 2 |
| Discharge Beam | 6.00 | 6.00 | 0 | 8.90 | tap every 2 |
| Rear Gun | 4.00 | 4.00 | 4.00 | 4.33 | tap every 3 |
| Photon Beam | 5.33 | 5.33 | 0 | 5.55 | tap every 3 |
| Chaingun | 4.83 | 4.83 | 0 | 3.09 | tap every 31 |
| Plasma Bomb | 4.90 | 4.90 | 0 | 1.40 | tap every 17 |
| Ion Cannon | 2.40 | 2.40 | 0 | 3.58 | tap every 5 |

Ranked by the four-scenario mean. Only the Rear Gun reaches a target
behind.

Passive changes that are not 0, as single / cluster / behind / wave:

| Passive | Weapon | Change | DPS added |
|---|---|---|---|
| Weapon 1 (Ion) 3 | Ion Cannon | +99.7% / +499.2% / 0 / +300.4% | +6.28 |
| Weapon 2 (Bacta) 3 | Bacta Gun | +50.0% / +100.0% / 0 / +58.6% | +4.24 |
| Weapon 4 (Photon) 3 | Photon Beam | +28.5% / +28.5% / 0 / +178.4% | +3.23 |
| Weapon 1 (Ion) 2 | Ion Cannon | +99.7% / +99.7% / 0 / +211.0% | +3.08 |
| Weapon 4 (Photon) 2 | Photon Beam | +12.5% / +12.5% / 0 / +143.7% | +2.33 |
| Weapon 3 (Rear) 2 | Rear Gun | +49.9% / +49.9% / +49.9% / +10.9% | +1.61 |
| Weapon 3 (Rear) 1 | Rear Gun | +33.2% / +33.2% / +33.2% / +10.9% | +1.11 |
| Weapon 1 (Ion) 1 | Ion Cannon | 0 / 0 / 0 / +84.0% | +0.75 |
| Weapon 2 (Bacta) 2 | Bacta Gun | 0 / 0 / 0 / +24.4% | +0.52 |
| Weapon 2 (Bacta) 1 | Bacta Gun | 0 / 0 / 0 / +16.7% | +0.36 |
| Weapon 4 (Photon) 1 | Photon Beam | +12.5% / +12.5% / 0 / 0 | +0.33 |
| Ground Variant 1 1 | Plasma Bomb | −100% / −100% / 4.46 from 0 / −100% | −1.69 |
| Ground Variant 1 2, 3 | Plasma Bomb | −100% / −100% / 3.97 from 0 / −100% | −1.81 |

Every other passive level is 0 on every weapon, apart from a +0.1% on the
Discharge Beam's wave from Improved Manoeuvring 2 (see Method). That
includes Auto Charge and Improved Charge, since neither touches a shot
that is not charged. No weapon passive touches the Discharge Beam: it has
none of its own.

The Plasma Bomb's burst grows by one bomb per stage, up to 8, so its DPS
depends on the stage. Taking the best cadence at each stage:
- stage 1: 2.38;
- stage 3: 3.96;
- stage 5: 4.57;
- stage 7: 4.90;
- stages 9 and 12: 5.01.

### Charge shots

| Weapon | Single | Cluster | Behind | Wave |
|---|---|---|---|---|
| Chaingun | 3.02 | 3.02 | 2.94 | 3.09 |
| Rear Gun | 2.98 | 2.98 | 0.02 | 3.39 |
| Bacta Gun | 3.43 | 3.44 | 0 | 1.63 |
| Discharge Beam | 2.90 | 2.90 | 0 | 1.85 |
| Ion Cannon | 2.84 | 2.84 | 0 | 1.60 |
| Photon Beam | 1.20 | 1.20 | 0 | 3.07 |

| Passive | Change on each weapon, ahead | DPS added, average |
|---|---|---|
| Improved Charge 1 | +1.3% (Rear) to +9.9% (Discharge) | +0.12 |
| Improved Charge 2 | +6.6% (Chaingun) to +19.8% (Discharge) | +0.21 |
| Improved Charge 3 | +11.2% (Rear) to +29.7% (Discharge) | +0.33 |
| Auto Charge 1, 2 | −38.8% to −44.0% | −0.88 |

The weapon passives add at most +0.05 DPS here. That comes through the
plain shot the first press fires before a charge begins. The Rear Gun's
0.02 behind is that shot too.

### What the numbers say

- **The hit delay decides most of it.** `entity_hit` ignores a hit within
  `perm_floats[0xa7]` = 1 step of the enemy's last hit. So an enemy
  registers at most one hit every 2 steps, 15 hits a second, however many
  shots reach it.
  - Shots that land together are spent for one hit's damage. The Ion
    Cannon's pair of bullets deals the damage of one, which is 2.40 DPS
    from taps: 6 volleys a second × 0.4.
  - For the same reason, every *Extra Projectiles* modifier is worth 0
    against a single target. Only lanes wide enough to reach a second
    enemy count: Weapon 1 level 3's +6 lanes, in the cluster.
  - *Extra Volley*, which fires again 2 steps later, is what the gains are
    made of.
- **Primary fire beats charge shots for six of seven weapons.** Measured
  over the whole run, a charge cycle deals less than tapping does in the
  same time. The Photon Beam's charge is under a quarter of its taps
  (1.20 against 5.33). The exception is the Ion Cannon, whose charge
  (2.84) beats its taps (2.40).
- **Only two weapons reach a target behind.** The Rear Gun's primary
  fire deals the same 4.00 behind as ahead, and its passives add the same
  there. The Chaingun's aimed charge deals 2.94 behind, nearly its 3.02
  ahead. Every other weapon fires forward.
- **Improved Charge is the only passive that helps charge shots.** At
  level 3 it adds +9% to +18%.
- **Auto Charge costs about 40% of every weapon's charge DPS.** After a
  release, the charge waits the full activation time with fire let go
  before it starts again. A held button starts the next charge as soon as
  the release is spent. In the primary set Auto Charge changes nothing,
  because fast taps never let a charge build.
- **Weapon 3 level 3 is a downgrade.** It trades level 2's two extra
  volleys (+49.9%, ahead and behind) for side fire, which never meets
  either target. As written, `(1,2,0)`, it takes the Rear Gun back to its
  bare DPS. That entry is already marked provisional in
  `sim/passives.odin`.
- **Ground Variant 1 turns the Plasma Bomb round.** `Fires_Backwards`
  puts the crosshair behind the ship, so level 1 deals 0 ahead and 4.46
  behind. Levels 2 and 3 fall to 3.97. The bombs of a burst fall 2 steps
  apart, exactly the hit delay. The Volley Delay cut packs them closer,
  so some land inside the delay and are ignored. Level 3's extra lane
  lands on the same spot, so it adds nothing.
- **The wave rewards spread and pierce, and punishes slow heavy hits.**
  With 0.8 shields a target dies to two or three hits, so what counts is
  how many targets a weapon reaches, not how hard it hits one. The
  passives that add lanes gain far more here than ahead: Weapon 4 level 2
  +144%, Weapon 1 level 2 +211%. The Plasma Bomb and the Chaingun's burst
  fall to 1.40 and 3.09, since most of each burst lands on a target
  already dead. Charge releases lose the same way, except where they
  spread (the Photon Beam's and the Rear Gun's).
- **The Discharge Beam leads the wave's straight lines.** Its pulse kills
  the front target and carries the rest into the next, and its shrapnel
  reaches the columns beside it: 8.90, against 4.33 to 5.55 for the other
  single-lane weapons. Its charged beam carries 7.5 into a column only
  2.4 deep, so in the wave most of it is overkill, and Improved Charge adds
  nothing there.
- **Straight-firing weapons get nothing from a cluster.** Only the Bacta
  Gun's spread (+50%) and Weapon 1 level 3's wide lanes reach past the
  front target, which soaks every other shot.

## Provisional

Each of these was picked by eye and would change the numbers:
- the 120 px range to air targets, ahead and behind;
- the V's spacing, and the wave's;
- the BlackHawk and Laser Tank as the stand-ins;
- the wave's 0.8 shields and its 12-step respawn.

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
