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
	state:       sim.State, // players and entities; its ecs is the live one
	level:       i32,
	played:      i32,
	frame:       u32,
	view_top:    i32,
	side_scroll: i32,
}

interp_capture :: proc(p: ^Interp_Prev, s: ^sim.State) {
	p.state = s^
	info := sim.single(s, sim.Level_Info)
	p.level, p.played = info.number, info.played
	p.frame = sim.frame_of(s)
	bg := sim.single(s, sim.Bgnd)
	p.view_top, p.side_scroll = bg.view_top, bg.side_scroll
}
