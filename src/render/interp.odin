package render

import "dr:sim"

// High refresh rate interpolation's record of the simulation as it was before
// the latest step (render.odin's build_frame). Presentation only: nothing
// reads it back into the simulation.
//
// The state lives in the world (D39), which a copy of the State would share
// with the live one, so what the renderer compares or blends is captured
// here by value.
Interp_Prev :: struct {
	players:     [sim.MAX_PLAYERS]Interp_Player,
	// Each pool slot's entity, by its unique number (-1 for a free slot),
	// and its object.
	numbers:     [sim.MAX_ENTITIES]i32,
	objects:     [sim.MAX_ENTITIES]sim.Game_Object,
	level:       i32,
	played:      i32,
	frame:       u32,
	view_top:    i32,
	side_scroll: i32,
}

// What build_frame blends a ship and its crosshair from.
Interp_Player :: struct {
	active:          bool,
	state:           sim.Player_State,
	obj:             sim.Game_Object,
	crosshair:       sim.Game_Object,
	crosshair_shown: bool,
}

interp_capture :: proc(p: ^Interp_Prev, s: ^sim.State) {
	for used, i in sim.single(s, sim.Pool).entity_used {
		p.numbers[i] = -1
		if used {
			e := sim.entity_at(s, i32(i))
			p.numbers[i], p.objects[i] = e.number, e.obj^
		}
	}
	for pl, i in sim.players_of(s) {
		p.players[i] = {
			active          = pl.active,
			state           = pl.state,
			obj             = pl.obj^,
			crosshair       = pl.weapons.crosshair^,
			crosshair_shown = pl.weapons.crosshair_shown,
		}
	}
	info := sim.single(s, sim.Level_Info)
	p.level, p.played = info.number, info.played
	p.frame = sim.frame_of(s)
	bg := sim.single(s, sim.Bgnd)
	p.view_top, p.side_scroll = bg.view_top, bg.side_scroll
}
