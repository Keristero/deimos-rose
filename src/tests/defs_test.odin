package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:sim"

Fill_Probe :: struct {
	count:  i32       `dr:"count_INT"`,
	speed:  f32       `dr:"speed_FLOAT"`,
	flag:   bool      `dr:"flag_BOOL"`,
	unit:   sim.Res_ID `dr:"unit_ID"`,
	area:   sim.Rect  `dr:"area_RECT"`,
	label:  string    `dr:"label_STR"`,
	absent: i32       `dr:"absent_INT"`,
	plain:  i32,
}

@(test)
def_fill_reads_fields_by_tag :: proc(t: ^testing.T) {
	fields := []data.Tag {
		{"count_INT", "12"},
		{"speed_FLOAT", "1.5"},
		{"flag_BOOL", "TRUE"},
		{"unit_ID", "air "},
		{"area_RECT", "0, 0, 480, 3600"},
		{"label_STR", "Tank"},
	}
	p := Fill_Probe{absent = 7, plain = 9}
	r: data.Defs_Report
	data.def_fill(&p, fields, &r, context.temp_allocator)

	testing.expect_value(t, p.count, i32(12))
	testing.expect_value(t, p.speed, f32(1.5))
	testing.expect(t, p.flag)
	testing.expect_value(t, p.unit, sim.res_id("air "))
	testing.expect_value(t, p.area, sim.Rect{0, 0, 480, 3600})
	testing.expect_value(t, p.label, "Tank")
	// Absent keys keep their preset value; untagged fields are left alone.
	testing.expect_value(t, p.absent, i32(7))
	testing.expect_value(t, p.plain, i32(9))
	testing.expect_value(t, r.missing, 1)
	testing.expect_value(t, r.malformed, 0)
}

@(test)
state_find_takes_the_last_match :: proc(t: ^testing.T) {
	states := []sim.Unit_State{{}, {}, {}}
	states[0].name = "Wait"
	states[1].name = "Fire"
	states[2].name = "Wait"
	u := sim.Unit{states = states}
	i, ok := sim.state_find(&u, "Wait")
	testing.expect(t, ok)
	testing.expect_value(t, i, 2)
	_, ok = sim.state_find(&u, "Hide")
	testing.expect(t, !ok)
}

@(test)
defs_load_from_the_original :: proc(t: ^testing.T) {
	if !os.exists("../game/ Data/Paks/Game.pak") {
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)

	p := data.provider_open("../game", alloc)
	defs, r := data.defs_load(&p, alloc)

	testing.expect_value(t, r.units, 386)
	testing.expect_value(t, r.malformed, 0)
	// Every shipped record supplies every key the original's loaders read,
	// so G_UnitDef_SetToDefaults never shows through.
	testing.expect_value(t, r.missing, 0)
	testing.expect_value(t, r.perm_floats, sim.PERM_FLOATS)
	testing.expect_value(t, defs.perm_objects[0], sim.res_id("pl01"))

	// Spot values the reference trace shows the original using: the first
	// placement-level state timer in de01 is RandomInt(40, 40).
	u := sim.unit_find(&defs, sim.res_id("01b1"))
	testing.expect(t, u != nil)
	if u != nil {
		testing.expect_value(t, u.name, "Level 1 - Bridge")
		testing.expect_value(t, u.states[0].name, "Wait")
		testing.expect_value(t, u.states[0].on_timer_min, i32(40))
		testing.expect_value(t, u.states[0].on_timer_max, i32(40))
	}
	log.infof("defs: %d units, %d missing keys", r.units, r.missing)
}
