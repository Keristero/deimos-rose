package new_weapons_view

// The Discharge Beam's wind-up, drawn: red motes drawn in to the gun while
// a press winds up (Weapon_Fire.windup, plugins/new_weapons/beam.odin),
// fast at first and slowing as they close, each arriving as the pulse
// fires. New content, with no original to match; the precharge unit
// (dbpc) brings the sound and a glow at the gun. The motes are kept
// relative to the gun, so they follow the ship, and drawn over the ships,
// as the gun is inside the ship's outline. Presentation only, so
// core:math/rand is fine here.
//
// Provisional: every number here was picked by eye.

import "core:math"
import "core:math/rand"

import rl "vendor:raylib"

import "dr:plugins/new_weapons"
import "dr:render"
import "dr:sim"

@(private = "file") PRECHARGE_PER_STEP :: 3
@(private = "file") PRECHARGE_RADIUS_MIN :: 20 // px from the gun they start
@(private = "file") PRECHARGE_RADIUS_MAX :: 36
@(private = "file") PRECHARGE_COLOR :: rl.Color{255, 56, 32, 255}
@(private = "file") PRECHARGE_CORE :: rl.Color{255, 200, 170, 255}

@(private = "file")
Precharge_Mote :: struct {
	player: int,
	from:   sim.Vec, // where it started, from the gun
	age:    i32,
	life:   i32, // steps to the gun: the wind-up left when it started
}

// Where each player's gun was the step before and this step, to draw the
// motes between them at high refresh rates.
@(private = "file")
Gun :: struct {
	prev, loc: sim.Vec,
	live:      bool,
}

@(private = "file")
motes: [dynamic]Precharge_Mote
@(private = "file")
guns: [sim.MAX_PLAYERS]Gun

register_precharge :: proc() {
	render.effect_system_register({
		name   = "beam_precharge",
		plugin = new_weapons.ID,
		step   = precharge_step,
		draw   = precharge_draw,
		layer  = render.layer_of(sim.res_id("play"), true), // over the ships
		clear  = precharge_clear,
	})
}

@(init)
register_precharge_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/new_weapons/view register_precharge", register_precharge)
}

@(private = "file")
precharge_clear :: proc() {
	clear(&motes)
	guns = {}
}

@(private = "file")
precharge_step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	if sim.session_frozen(s) {
		return
	}
	n := 0
	for m in motes {
		m := m
		m.age += 1
		if m.age < m.life && guns[m.player].live {
			motes[n] = m
			n += 1
		}
	}
	resize(&motes, n)
	for pl, i in sim.players_of(s) {
		h := pl.weapons
		wd := sim.weapon_def(s, h.air.weapon)
		if pl.obj == nil || pl.state != .Playing || h.air_windup <= 0 || !sim.weapon_bool(wd, new_weapons.BEAM) {
			guns[i].live = false
			continue
		}
		gun := new_weapons.beam_origin(wd, pl.loc)
		guns[i] = {prev = guns[i].live ? guns[i].loc : gun, loc = gun, live = true}
		for _ in 0 ..< PRECHARGE_PER_STEP {
			a := rand.float32() * 2 * math.PI
			d := PRECHARGE_RADIUS_MIN + rand.float32() * (PRECHARGE_RADIUS_MAX - PRECHARGE_RADIUS_MIN)
			append(&motes, Precharge_Mote{player = i, from = {math.cos(a), math.sin(a)} * d, life = h.air_windup})
		}
	}
}

// A mote's distance from the gun falls as (1 - u)^2 over its life: fast at
// first, slowing as it arrives. It brightens as it closes.
@(private = "file")
precharge_draw :: proc(r: ^render.Renderer, scale, side, t: f32) {
	if len(motes) == 0 {
		return
	}
	rl.BeginBlendMode(.ADDITIVE)
	for &m in motes {
		g := guns[m.player]
		u := clamp((f32(m.age) + t) / f32(max(m.life, 1)), 0, 1)
		gun := g.prev + (g.loc - g.prev) * t
		at := gun + m.from * (1 - u) * (1 - u)
		c := rl.Vector2{(render.VIEW_X + at.x - side) * scale, at.y * scale}
		glow, core := PRECHARGE_COLOR, PRECHARGE_CORE
		glow.a = u8((0.35 + 0.4 * u) * 255)
		core.a = u8((0.5 + 0.5 * u) * 255)
		rl.DrawCircleV(c, 2.2 * scale, glow)
		rl.DrawCircleV(c, 0.9 * scale, core)
	}
	rl.EndBlendMode()
}
