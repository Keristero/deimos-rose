package game

// Easy mode's passive upgrades as the player sees them: names, icons and
// how each stat reads on the reward screen (game/reward.odin), and the two
// effects that show a passive at work in play. The passives themselves are
// sim/passives.odin; nothing here feeds back into the simulation.

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"

import rl "vendor:raylib"

import "dr:sim"

// The icons are assets/icons/passives/<name>.png, 32x32, composited from the
// game's own sprites by `mise run assets:icons` (tools/icons/passives.json
// holds the recipes), each named after its sim.Passive in lower case.
@(rodata)
PASSIVE_NAMES := [sim.Passive]string {
	.Improved_Manoeuvring = "IMPROVED MANOEUVRING",
	.Auto_Charge          = "AUTO CHARGE",
	.Improved_Charge      = "IMPROVED CHARGE",
	.Shield_Regen         = "SHIELD REGENERATION",
	.Ground_Variant_1     = "REVERSE PLASMA BOMB",
	.Weapon_1             = "ION CANNON UPGRADE",
	.Weapon_2             = "BACTA GUN UPGRADE",
	.Weapon_3             = "REAR GUN UPGRADE",
	.Weapon_4             = "PHOTON BEAM UPGRADE",
}

// A passive's icon, loaded on first use and cached with the other derived
// images (a missing file is cached too, so it is tried once).
passive_icon :: proc(t: ^Textures, pa: sim.Passive) -> (rl.Texture2D, bool) {
	key := fmt.tprintf("icons/passives/%s", strings.to_lower(fmt.tprint(pa), context.temp_allocator))
	if tex, ok := t.images[key]; ok {
		return tex, tex.id != 0
	}
	tex := rl.LoadTexture(fmt.ctprintf("%s/%s.png", t.root, key))
	t.images[strings.clone(key)] = tex
	return tex, tex.id != 0
}

Stat_Format :: enum {
	Percent, // of the base value: 100% is unchanged
	Count,   // a flat number added
	Seconds,
	Rate,    // percentage points a second
	Toggle,
}

Stat_Display :: struct {
	label:  string,
	format: Stat_Format,
	// Meaningless until this is on: the shield regeneration's delay and
	// rate read "--" before Shield_Regenerates.
	needs:  Maybe(sim.Stat),
}

@(rodata)
STAT_DISPLAY := [sim.Stat]Stat_Display {
	.Maneuverability          = {"MANOEUVRABILITY", .Percent, nil},
	.Risky_Reward             = {"RISKY REWARD", .Toggle, nil},
	.Auto_Charge_Air_To_Air   = {"AUTO CHARGE", .Toggle, nil},
	.Prevent_Overheat         = {"OVERHEAT PROTECTION", .Toggle, nil},
	.Charge_Rate              = {"CHARGE RATE", .Percent, nil},
	.Overheat_Delay           = {"OVERHEAT DELAY", .Percent, nil},
	.Maximum_Charge           = {"MAXIMUM CHARGE", .Percent, nil},
	.Shield_Regenerates       = {"SHIELD REGENERATION", .Toggle, nil},
	.Recharge_Delay           = {"RECHARGE DELAY", .Seconds, .Shield_Regenerates},
	.Shield_Regen_Rate        = {"REGENERATION RATE", .Rate, .Shield_Regenerates},
	.Fires_Backwards          = {"FIRES BACKWARDS", .Toggle, nil},
	.Volley_Delay             = {"VOLLEY DELAY", .Percent, nil},
	.Extra_Projectiles        = {"EXTRA PROJECTILES", .Count, nil},
	.Extra_Volley             = {"EXTRA VOLLEYS", .Count, nil},
	.Accelerating_Projectiles = {"ACCELERATING SHOTS", .Toggle, nil},
	.Initial_Projectile_Speed = {"LAUNCH SPEED", .Percent, nil},
	.Projectile_Lifetime      = {"RANGE", .Percent, nil},
	.Side_Firing_Volley       = {"SIDE FIRE", .Toggle, nil},
	.Firing_Delay             = {"FIRING DELAY", .Percent, nil},
	.Projectile_Damage        = {"DAMAGE", .Percent, nil},
}

// A stat's value for a player holding `levels`, as the reward screen shows
// it. Every passive's contribution is in it, not only the one on offer.
stat_text :: proc(levels: ^sim.Passive_Levels, stat: sim.Stat, weapon: sim.Res_ID) -> string {
	d := STAT_DISPLAY[stat]
	if needs, ok := d.needs.?; ok && !sim.stat_total(levels, needs, weapon).enabled {
		return "--"
	}
	t := sim.stat_total(levels, stat, weapon)
	switch d.format {
	case .Percent:
		return fmt.tprintf("%d%%", max(100 + t.percent, 0))
	case .Count:
		return fmt.tprintf("+%d", t.extra)
	case .Seconds:
		return fmt.tprintf("%dS", t.extra)
	case .Rate:
		return fmt.tprintf("%d%%/S", t.extra)
	case .Toggle:
		return t.enabled ? "ON" : "OFF"
	}
	return ""
}

// In-play effects, stepped with the particles once per sim step: accent
// motes drawn in to a ship whose shields are regenerating, and sparks off
// a charge climbing past the weapon's own maximum. Presentation only, so
// core:math/rand is fine here.

@(private = "file") REGEN_EVERY :: 3      // steps between motes
@(private = "file") REGEN_RADIUS :: 26    // how far out they start
@(private = "file") REGEN_STEPS :: 9      // steps to reach the ship
@(private = "file") REGEN_FADE :: 14      // starting fade: faint, out of 32
@(private = "file") SPARK_MAX :: 3        // sparks a step at the raised maximum
@(private = "file") SPARK_SPEED :: 3

passive_particles_step :: proc(p: ^Particles, s: ^sim.State, r: ^Renderer) {
	if !s.session.easy || sim.session_frozen(s) {
		return
	}
	for &pl, i in s.players {
		if pl.state != .Playing {
			continue
		}
		if sim.player_regenerating(s, &pl) && sim.single(s, sim.Clock).time % REGEN_EVERY == 0 {
			a := rand.float32() * 2 * math.PI
			from := pl.loc + sim.Vec{math.cos(a), math.sin(a)} * REGEN_RADIUS
			shade := colour5(accent_color(int(r.accents[i].hue)))
			append(&p.live, Particle {
				loc    = from - 3,
				prev   = from - 3,
				vel    = (pl.loc - from) / REGEN_STEPS,
				shade  = shade,
				fringe = shade / 2,
				fade   = REGEN_FADE,
			})
		}
		if over := sim.player_overcharge(s, &pl); over > 0 {
			n := int(math.ceil(over * SPARK_MAX))
			for _ in 0 ..< n {
				a := rand.float32() * 2 * math.PI
				at := pl.loc + {0, -f32(pl.half.y)}
				append(&p.live, Particle {
					loc    = at - 3,
					prev   = at - 3,
					vel    = sim.Vec{math.cos(a), math.sin(a)} * SPARK_SPEED * (0.5 + rand.float32()),
					shade  = {31, 31, 24},
					fringe = {31, 20, 8},
					fade   = i32(16 - over * 12),
				})
			}
		}
	}
}

@(private = "file")
colour5 :: proc(c: rl.Color) -> [3]u8 {
	return {c.r >> 3, c.g >> 3, c.b >> 3}
}
