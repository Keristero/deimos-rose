package editor

// The level's own properties (Stage 8): its names, its words for the
// campaign's screens, its music, briefing and sky, and the weapons a
// player starts it with (D54). Part of the settings, so a change undoes as
// one; a text box's change counts once it is left.

import "core:c"
import "core:mem/virtual"
import "core:strings"

import rl "vendor:raylib"

import "dr:sim"
import "dr:terrain"

Properties :: struct {
	text:         [Field]string,
	start_air:    string, // weapon ids, empty for what the level's number brings
	start_ground: string,
}

Field :: enum c.int {
	Name,
	Identifier,
	Description,
	Copyright,
	Music,
	Briefing,
	Skybox,
}

@(private = "file")
FIELD_LABELS := [Field]cstring {
	.Name        = "Name",
	.Identifier  = "Identifier",
	.Description = "Description",
	.Copyright   = "Copyright",
	.Music       = "Music",
	.Briefing    = "Briefing",
	.Skybox      = "Sky",
}

// Each text box's own copy, and which one is being typed in, or -1.
Level_Panel :: struct {
	buffers: [Field][256]u8,
	editing: c.int,
}

@(private = "file")
field_of :: proc(p: ^terrain.Project, f: Field) -> ^string {
	l := &p.level
	switch f {
	case .Name:
		return &l.name
	case .Identifier:
		return &l.identifier
	case .Description:
		return &l.description
	case .Copyright:
		return &l.copyright
	case .Music:
		return &l.music
	case .Briefing:
		return &l.briefing
	case .Skybox:
		return &l.skybox
	}
	unreachable()
}

properties_of :: proc(p: ^terrain.Project) -> (s: Properties) {
	for f in Field {
		s.text[f] = field_of(p, f)^
	}
	s.start_air, s.start_ground = p.level.start_weapons.air, p.level.start_weapons.ground
	return
}

properties_set :: proc(p: ^terrain.Project, s: Properties) {
	for f in Field {
		field_of(p, f)^ = s.text[f]
	}
	p.level.start_weapons = {s.start_air, s.start_ground}
}

// Sets a property to `text`, kept in the project's memory.
editor_property_set :: proc(e: ^Editor, f: Field, text: string) {
	s := field_of(&e.project, f)
	if s^ != text {
		s^ = strings.clone(text, virtual.arena_allocator(e.arena))
	}
}

level_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	lp := &e.level_panel
	heading(x, y, w, "Level")
	for f in Field {
		buf := &lp.buffers[f]
		if lp.editing != c.int(f) {
			buf^ = {}
			copy(buf[:len(buf) - 1], field_of(&e.project, f)^)
		}
		rl.GuiLabel({x, y^, 76, 20}, FIELD_LABELS[f])
		if rl.GuiTextBox({x + 76, y^, w - 76, 20}, cstring(raw_data(buf[:])), c.int(len(buf) - 1), lp.editing == c.int(f)) {
			if lp.editing == c.int(f) {
				editor_property_set(e, f, string(cstring(raw_data(buf[:]))))
				lp.editing = -1
			} else {
				level_panel_leave(e)
				lp.editing = c.int(f)
			}
		}
		y^ += ROW
	}
	y^ += 4
	heading(x, y, w, "Start weapons")
	start_weapon(e, x, y, w, "Air", sim.WEP_AIR, &e.project.level.start_weapons.air)
	start_weapon(e, x, y, w, "Ground", sim.WEP_GROUND, &e.project.level.start_weapons.ground)
	y^ += 4
	help(x, y, w, {"Enter, or a click elsewhere, keeps what", "was typed.  The start weapons replace", "what the level's number brings; a", "plugin's weapon needs its plugin on.", "Music, briefing and sky are ids: an", "audio id, a briefing id, an im16 image."})
}

// Keeps what is being typed, if anything.
level_panel_leave :: proc(e: ^Editor) {
	lp := &e.level_panel
	if lp.editing >= 0 {
		f := Field(lp.editing)
		editor_property_set(e, f, string(cstring(raw_data(lp.buffers[f][:]))))
		lp.editing = -1
	}
}

// A combo box of the weapons of `type`, the originals' and the plugins',
// and none: a click takes the next.
@(private = "file")
start_weapon :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, label: cstring, type: sim.Res_ID, id: ^string) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "None")
	ids := make([dynamic]string, context.temp_allocator)
	append(&ids, "")
	active := c.int(0)
	for &wp in e.units.defs.weapons {
		if wp.type != type {
			continue
		}
		wid := string(wp.id[:])
		if wid == id^ {
			active = c.int(len(ids))
		}
		append(&ids, wid)
		strings.write_byte(&sb, ';')
		strings.write_string(&sb, wp.name != "" ? wp.name : wid)
	}
	rl.GuiLabel({x, y^, 76, 20}, label)
	before := active
	rl.GuiComboBox({x + 76, y^, w - 76, 20}, strings.to_cstring(&sb), &active)
	if active != before && int(active) < len(ids) {
		// The weapon's own id, which lives as long as the catalogue.
		id^ = ids[active]
	}
	y^ += ROW
}
