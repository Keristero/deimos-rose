package chaingun_view

// The Chaingun's muzzle flash: a bright flash, gone within a few steps,
// with every round it fires, at half strength for the burst's and full for
// a charge's aimed rounds
// (notes/extra-weapon-passives-and-base-adjustments.md). New content, and
// presentation only: effect systems (render/render_systems.odin) that find
// the rounds by their entity numbers, which count up through a level, so a
// step a rollback replays does not flash again. core:math/rand is fine
// here.
//
// The burst's flash is at the gun, in the ship's nose, and drawn over the
// ships, as the gun is inside the ship's outline. A charge's rounds go any
// way, so their flash is centred on the ship and drawn under it
// (notes/extra-weapons-and-passives-3.md), showing round its edges.
//
// Provisional: every number here was picked by eye.

import "core:math"
import "core:math/rand"

import rl "vendor:raylib"

import "dr:plugins/chaingun"
import "dr:render"
import "dr:sim"

// The Chaingun's rounds: the burst's, and the charge's aimed pairs.
@(private = "file") CHAINGUN_ROUND :: sim.Res_ID{'c', 'g', 'b', 'u'}
@(private = "file") CHAINGUN_AIMED_ROUND :: sim.Res_ID{'c', 'g', 'p', 'b'}

@(private = "file") FLASH_LIFE :: 3 // steps from full to gone
@(private = "file") FLASH_BURST :: 0.5 // the burst's strength against the charge's
@(private = "file") FLASH_RADIUS :: 12 // px, at full strength
// A charge's flash, under the ship, is wider and reaches further out, so
// it shows past the ship's outline (about 16 px from its centre).
@(private = "file") FLASH_UNDER_RADIUS :: 26
@(private = "file") FLASH_UNDER_REACH :: 14 // px from the centre its streak and sparks start
@(private = "file") FLASH_GUN :: sim.Vec{0, -18} // from the ship: its nose
@(private = "file") FLASH_SPARKS :: 3 // at full strength
@(private = "file") FLASH_SPARK_SPEED :: 5
@(private = "file") FLASH_INNER :: rl.Color{255, 244, 214, 255}
@(private = "file") FLASH_OUTER :: rl.Color{255, 168, 64, 255}
@(private = "file") FLASH_RINGS :: 4

@(private = "file")
Flash :: struct {
	player: int,
	age:    i32,
	power:  f32, // 1 full
	dir:    sim.Vec, // the round's
	under:  bool, // a charge's: under the ship, at its centre
}

// A spark thrown out with a flash, kept from where the flash is so it
// follows the ship.
@(private = "file")
Spark :: struct {
	player: int,
	at:     sim.Vec,
	vel:    sim.Vec,
	age:    i32,
	power:  f32,
	under:  bool,
}

// Where each player's ship was the step before and this step.
@(private = "file")
Ship :: struct {
	prev, loc: sim.Vec,
	live:      bool,
}

@(private = "file") flashes: [dynamic]Flash
@(private = "file") sparks: [dynamic]Spark
@(private = "file") ships: [sim.MAX_PLAYERS]Ship
@(private = "file") seen: i32 // the highest entity number looked at

register_flash :: proc() {
	render.effect_system_register({
		name   = "chaingun_flash",
		plugin = chaingun.ID,
		step   = flash_step,
		draw   = flash_draw_over,
		layer  = render.layer_of(sim.res_id("play"), true), // over the ships
		clear  = flash_clear,
	})
	render.effect_system_register({
		name   = "chaingun_flash_under",
		plugin = chaingun.ID,
		draw   = flash_draw_under,
		layer  = render.layer_of(sim.res_id("plwe"), true), // over the rounds, under the ships
	})
}

@(init)
register_flash_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/chaingun/view register_flash", register_flash)
}

@(private = "file")
flash_clear :: proc() {
	clear(&flashes)
	clear(&sparks)
	ships = {}
	seen = 0
}

@(private = "file")
flash_step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	if sim.session_frozen(s) {
		return
	}
	n := 0
	for f in flashes {
		f := f
		f.age += 1
		if f.age < FLASH_LIFE {
			flashes[n] = f
			n += 1
		}
	}
	resize(&flashes, n)
	n = 0
	for k in sparks {
		k := k
		k.age += 1
		k.at += k.vel
		if k.age < FLASH_LIFE {
			sparks[n] = k
			n += 1
		}
	}
	resize(&sparks, n)
	for pl, i in sim.players_of(s) {
		if pl.obj == nil || pl.state != .Playing {
			ships[i].live = false
			continue
		}
		ships[i] = {prev = ships[i].live ? ships[i].loc : pl.loc, loc = pl.loc, live = true}
	}

	round := sim.unit_index(s.defs, CHAINGUN_ROUND)
	aimed := sim.unit_index(s.defs, CHAINGUN_AIMED_ROUND)
	top: i32
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		top = max(top, e.number)
		if e.number <= seen || e.deleted || (e.unit != i32(round) && e.unit != i32(aimed)) {
			continue
		}
		pi := int(e.owner_player)
		if pi < 0 || pi >= sim.MAX_PLAYERS || !ships[pi].live {
			continue
		}
		charge := e.unit == i32(aimed)
		dir := sim.Vec{0, -1}
		if l := math.sqrt(e.vel.x * e.vel.x + e.vel.y * e.vel.y); l > 0 {
			dir = e.vel / l
		}
		flash_add(pi, charge ? 1 : FLASH_BURST, dir, charge)
	}
	// A new level numbers its entities from the start again.
	seen = top < seen ? top : max(seen, top)
}

// One flash of each kind a player a step, the strongest of the rounds fired
// on it, and sparks for each round.
@(private = "file")
flash_add :: proc(player: int, power: f32, dir: sim.Vec, under: bool) {
	found := false
	for &f in flashes {
		if f.player == player && f.age == 0 && f.under == under {
			f.power = max(f.power, power)
			found = true
		}
	}
	if !found {
		append(&flashes, Flash{player = player, power = power, dir = dir, under = under})
	}
	for _ in 0 ..< int(math.round(FLASH_SPARKS * power)) {
		a := (rand.float32() - 0.5) * 1.2 // radians either side of the round
		c, sn := math.cos(a), math.sin(a)
		d := sim.Vec{dir.x * c - dir.y * sn, dir.x * sn + dir.y * c}
		append(&sparks, Spark {
			player = player,
			at     = under ? d * FLASH_UNDER_REACH : {},
			vel    = d * FLASH_SPARK_SPEED * (0.6 + 0.8 * rand.float32()),
			power  = power,
			under  = under,
		})
	}
}

@(private = "file")
flash_draw_over :: proc(r: ^render.Renderer, scale, side, t: f32) {
	flash_draw(scale, side, t, false)
}

@(private = "file")
flash_draw_under :: proc(r: ^render.Renderer, scale, side, t: f32) {
	flash_draw(scale, side, t, true)
}

// Where a flash of the kind is, between the ship's last two steps.
@(private = "file")
flash_origin :: proc(sh: Ship, t: f32, under: bool) -> sim.Vec {
	at := sh.prev + (sh.loc - sh.prev) * t
	return under ? at : at + FLASH_GUN
}

// The flashes and sparks of one kind: the burst's over the ships, or a
// charge's under them.
@(private = "file")
flash_draw :: proc(scale, side, t: f32, under: bool) {
	if len(flashes) == 0 && len(sparks) == 0 {
		return
	}
	screen :: proc(at: sim.Vec, scale, side: f32) -> rl.Vector2 {
		return {(render.VIEW_X + at.x - side) * scale, at.y * scale}
	}
	with_alpha :: proc(c: rl.Color, a: f32) -> rl.Color {
		c := c
		c.a = u8(clamp(a, 0, 1) * 255)
		return c
	}
	rl.BeginBlendMode(.ADDITIVE)
	for f in flashes {
		k := 1 - (f32(f.age) + t) / FLASH_LIFE // 1 as it fires .. 0 gone
		sh := ships[f.player]
		if f.under != under || k <= 0 || !sh.live {
			continue
		}
		gun := flash_origin(sh, t, under)
		c := screen(gun + f.dir * 2, scale, side)
		a := f.power * k
		// A glow in rings, each smaller and brighter, adding up to white.
		radius := (under ? FLASH_UNDER_RADIUS : FLASH_RADIUS) * (0.5 + 0.5 * f.power) * (0.6 + 0.4 * k) * scale
		for ring in 0 ..< FLASH_RINGS {
			u := f32(ring) / FLASH_RINGS
			rl.DrawCircleV(c, radius * (1 - u), with_alpha(ring == 0 ? FLASH_OUTER : FLASH_INNER, a * 0.5))
		}
		reach: f32 = under ? FLASH_UNDER_REACH : 4
		rl.DrawLineEx(c, screen(gun + f.dir * (reach + 8 * f.power * k), scale, side), 2 * scale, with_alpha(FLASH_INNER, a))
		rl.DrawCircleV(c, (1.5 + 2 * f.power) * scale, with_alpha({255, 255, 255, 255}, a))
	}
	for k in sparks {
		sh := ships[k.player]
		if k.under != under || !sh.live {
			continue
		}
		fade := 1 - (f32(k.age) + t) / FLASH_LIFE
		if fade <= 0 {
			continue
		}
		head := flash_origin(sh, t, under) + k.at + k.vel * t
		rl.DrawLineEx(screen(head - k.vel * 0.6, scale, side), screen(head, scale, side), 1 * scale, with_alpha(FLASH_INNER, k.power * fade))
	}
	rl.EndBlendMode()
}
