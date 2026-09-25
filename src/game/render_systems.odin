package game

import "base:runtime"

import "dr:sim"

// Render systems: what draws a frame from the state, in a loop of their own
// (notes/ecs-refactor.md). They read the simulation and never change it;
// what they change is the Renderer's (its layers, the terrain buffer, the
// score bar's easing). Placed against each other by name as the
// simulation's systems are (sim/schedule.odin), and otherwise run in the
// order they were registered, which for the core is FUN_00420740's.
//
// Every draw only appends to its own layer's list, and present draws the
// layers in order, so what the order decides is the order within a layer.

MAX_RENDER_SYSTEMS :: 32

// What one frame is drawn from besides the state.
Frame :: struct {
	// The state as it was a step ago, when interpolating (Interp_Prev); nil
	// draws everything where it is.
	prev:    ^Interp_Prev,
	blurs:   ^Blurs,
	notices: ^Notices,
}

Render_System :: struct {
	name:   string,
	after:  []string,
	before: []string,
	run:    proc(r: ^Renderer, s: ^sim.State, f: ^Frame),
}

@(private = "file")
render_systems: [MAX_RENDER_SYSTEMS]Render_System
@(private = "file")
render_system_count: int

// Called from `@(init)` procedures only, like sim.system_register, and as
// there the `after` and `before` lists must outlive the call: package
// variables, not slice literals, which live on the caller's stack.
render_system_register :: proc(sys: Render_System) {
	assert(render_system_count < MAX_RENDER_SYSTEMS, "game: too many render systems")
	render_systems[render_system_count] = sys
	render_system_count += 1
}

registered_render_systems :: proc "contextless" () -> []Render_System {
	return render_systems[:render_system_count]
}

// The render systems a renderer runs, in order, by registry index.
Render_Schedule :: struct {
	order: [MAX_RENDER_SYSTEMS]u8,
	count: u8,
	built: bool,
}

render_schedule_build :: proc(sched: ^Render_Schedule) {
	registered := render_systems[:render_system_count]
	items := make([]sim.Order_Item, len(registered), context.temp_allocator)
	for sys, i in registered {
		items[i] = {sys.name, sys.after, sys.before}
	}
	order, ok := sim.schedule(items, context.temp_allocator)
	assert(ok, "game: a cycle in the order of the render systems")
	for idx, i in order {
		sched.order[i] = u8(idx)
	}
	sched.count = u8(len(order))
	sched.built = true
}

run_render_systems :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	if !r.render_schedule.built {
		render_schedule_build(&r.render_schedule)
	}
	for idx in r.render_schedule.order[:r.render_schedule.count] {
		render_systems[idx].run(r, s, f)
	}
}

@(init)
register_core_render_systems :: proc "contextless" () {
	context = runtime.default_context()
	render_system_register({name = "layers_clear", run = layers_clear_render})
	render_system_register({name = "terrain", run = terrain_render})
	render_system_register({name = "scorebar", run = scorebar_render})
	render_system_register({name = "view", run = view_render})
	render_system_register({name = "entities", run = entities_render})
	render_system_register({name = "players", run = players_render})
	render_system_register({name = "blurs", run = blurs_render})
	render_system_register({name = "notices", run = notices_render})
	// Self Outline: under the local player's ship, so ahead of it.
	render_system_register({name = "outline", before = OUTLINE_BEFORE, run = outline_render})
}

@(private = "file", rodata)
OUTLINE_BEFORE := []string{"players"}

@(private = "file")
layers_clear_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	for &l in r.layers {
		clear(&l)
	}
}

// The map buffer, and the marks burned into it this step.
@(private = "file")
terrain_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	terrain_prepare(r, s)
	terrain_stamp(r, s)
}

// The score bar is drawn separately, straight to its panel rather than
// through a layer (scorebar_draw); this only eases its meters.
@(private = "file")
scorebar_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	scorebar_process(&r.scorebar, s)
}

// The scroll the frame is drawn at, and what it blends from.
@(private = "file")
view_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	f.prev = r.interp_prev
	info := sim.single(s, sim.Level_Info)
	if f.prev != nil && (f.prev.level != info.number || f.prev.played != info.played || f.prev.frame > sim.frame_of(s)) {
		// A different level, or a new session: nothing on screen was there
		// a step ago.
		f.prev = nil
	}
	bg := sim.single(s, sim.Bgnd)
	r.view_top, r.side_scroll = f32(bg.view_top), f32(bg.side_scroll)
	if f.prev != nil {
		r.view_top = interp(f32(f.prev.view_top), r.view_top, r.interp_alpha)
		r.side_scroll = interp(f32(f.prev.side_scroll), r.side_scroll, r.interp_alpha)
	}
}

// Every entity, group by group.
@(private = "file")
entities_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	prev := f.prev
	pool := sim.single(s, sim.Pool)
	for g := pool.active.head; g != sim.NO_LINK; g = sim.link_of(sim.group_links(s), g).next {
		for i := sim.group_at(s, g).entities.head; i != sim.NO_LINK; i = sim.link_of(sim.entity_links(s), i).next {
			e := sim.entity_at(s, i)
			// G_EG_BuildDrawList draws neither an entity nor its shadow
			// until its appear delay (+0xa4) has run out; units waiting
			// just off the field would otherwise show there, or cast a
			// shadow onto it.
			if e.appear_delay >= 1 {
				continue
			}
			u := &s.defs.units[e.unit]
			// The same slot holding the same entity a step ago (numbers are
			// unique, so a reused slot does not match).
			before: ^sim.Game_Object
			if prev != nil && prev.numbers[i] == e.number {
				before = &prev.objects[i]
			}
			draw_object(r, s, e.obj, u.casts_shadows, before, shot_accent(r, s, e))
		}
	}
}

// A playing ship as it was a step ago, when it was playing then too.
@(private = "file")
ship_before :: proc(f: ^Frame, k: int) -> ^sim.Game_Object {
	if f.prev != nil && f.prev.players[k].active && f.prev.players[k].state == .Playing {
		return &f.prev.players[k].obj
	}
	return nil
}

// Both players: each one's crosshair, then their ship.
@(private = "file")
players_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	for p, k in sim.players_of(s) {
		if !p.active || p.state != .Playing {
			continue
		}
		before := ship_before(f, k)
		// G_Player::BuildDrawList draws the ground weapon's crosshair
		// first (G_WeaponHandler::BuildDrawList, 0x447ad0: only once
		// crosshair_shown, +0x117), then the ship. No shadow: the
		// handler's Process clears the crosshair's +0x38 every step.
		ac := r.accents[k]
		if p.weapons.crosshair_shown && !ac.hide_crosshair {
			cbefore: ^sim.Game_Object
			if before != nil && f.prev.players[k].crosshair_shown {
				cbefore = &f.prev.players[k].crosshair
			}
			// Locked keeps its own red, so a lock still shows. Unlocked
			// is the accent washed towards white, so that even a red
			// accent reads differently from the lock.
			recolour := ac.on && !p.weapons.crosshair_locked
			draw_object(r, s, p.weapons.crosshair, false, cbefore, {hue = ac.hue, recolour = recolour, lighten = CROSSHAIR_LIGHTEN})
		}
		draw_object(r, s, p.obj, true, before, {hue = ac.hue, trim = ac.on})
	}
}

// The ship's own shape in its accent, one pixel out in each of the eight
// directions: Self Outline, for the local player.
@(private = "file")
outline_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	for p, k in sim.players_of(s) {
		ac := r.accents[k]
		if !ac.outline || !p.active || p.state != .Playing {
			continue
		}
		place, ok := object_place(r, p.obj, ship_before(f, k))
		if !ok {
			continue
		}
		alpha := u8(clamp(p.obj.visibility, 0, 100) * 255 / 100)
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			dst := place.dst
			dst.x += d.x
			dst.y += d.y
			push_item(r, place.layer, Item {
				texture = place.texture, src = place.src, dst = dst, tint = {255, 255, 255, alpha},
				effect = .Silhouette, hue = ac.hue, sat = ACCENT_SATURATION,
			})
		}
	}
}

// Motion blur ghosts. The original builds them in Process, ahead of the
// entities and players; since every draw only appends to its own layer, the
// order only matters within one.
@(private = "file")
blurs_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	for &o in f.blurs.live {
		draw_object(r, s, &o, false)
	}
}

// The notice banner, one more item in the HUD layer.
@(private = "file")
notices_render :: proc(r: ^Renderer, s: ^sim.State, f: ^Frame) {
	notices_draw(r, f.notices)
}
