package game

import "dr:sim"

// High refresh rate interpolation's record of the simulation as it was before
// the latest step (render.odin's build_frame). Presentation only: nothing
// reads it back into the simulation.
//
// Copying the State is no longer enough on its own: the singletons live in
// the world (D39), which a copy shares with the live state, so what the
// renderer compares or blends from them is captured here by value.
Interp_Prev :: struct {
	state:       sim.State, // entities; its ecs is the live one
	players:     [sim.MAX_PLAYERS]Interp_Player,
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
	p.state = s^
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
