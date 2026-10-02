package editor

// The level's own properties (Stage 8): its names, its words for the
// campaign's screens, its music, briefing and sky, and the weapons a
// player starts it with (D54); and where its preview is cut from the map
// (Stage 9), shown as Level Select will show it. Part of the settings, so
// a change undoes as one; a text box's change counts once it is left.

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
	preview:      [2]int, // the preview's crop, its top left in map pixels
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

// Each text box's own copy, and which one is being typed in, or -1; and
// the preview as made from the map, made again when the map or the crop
// changes while the tab is open.
Level_Panel :: struct {
	buffers:       [Field][256]u8,
	editing:       c.int,
	preview:       rl.Texture2D,
	preview_at:    [2]int,
	preview_stale: bool,
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
	s.preview = p.preview
	return
}

properties_set :: proc(p: ^terrain.Project, s: Properties) {
	for f in Field {
		field_of(p, f)^ = s.text[f]
	}
	p.level.start_weapons = {s.start_air, s.start_ground}
	p.preview = s.preview
}

// Sets a property to `text`, kept in the project's memory.
editor_property_set :: proc(e: ^Editor, f: Field, text: string) {
	s := field_of(&e.project, f)
	if s^ != text {
		s^ = strings.clone(text, virtual.arena_allocator(e.arena))
	}
}

level_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32, view: rl.Rectangle) {
	lp := &e.level_panel
	heading(x, y, w, "Level")
	for f in Field {
		buf := &lp.buffers[f]
		if lp.editing != c.int(f) {
			box_set(buf[:], field_of(&e.project, f)^)
		}
		rl.GuiLabel({x, y^, 76, 20}, FIELD_LABELS[f])
		if rl.GuiTextBox({x + 76, y^, w - 76, 20}, cstring(raw_data(buf[:])), c.int(len(buf) - 1), lp.editing == c.int(f)) {
			if lp.editing == c.int(f) {
				editor_property_set(e, f, box_text(buf[:]))
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
	heading(x, y, w, "Preview")
	// As large as fits, up to Level Select's own size.
	k := clamp((bottom - y^ - 4) / terrain.PREVIEW_HEIGHT, 0.25, 1)
	pw, ph := terrain.PREVIEW_WIDTH * k, terrain.PREVIEW_HEIGHT * k
	if lp.preview.id != 0 {
		rl.DrawTexturePro(lp.preview, {0, 0, f32(lp.preview.width), f32(lp.preview.height)}, {x, y^, pw, ph}, {}, 0, rl.WHITE)
	}
	rl.DrawRectangleLinesEx({x - 1, y^ - 1, pw + 2, ph + 2}, 1, {90, 92, 98, 255})
	bx, bw := x + pw + 8, w - pw - 8
	if rl.GuiButton({bx, y^, bw, 20}, "Where the view is") {
		preview_centre(e, {e.view.left + view_cols(&e.view, view) / 2, e.view.row + view_rows(&e.view, view) / 2})
	}
	if rl.GuiButton({bx, y^ + ROW, bw, 20}, "The level's start") {
		e.project.preview = terrain.preview_crop_default(e.project.width, e.project.length)
	}
	if rl.GuiButton({bx, y^ + 2 * ROW, bw, 20}, "Play (F5)") {
		editor_play(e)
	}
	yy := y^ + 3 * ROW + 4
	help(bx, &yy, bw, {"Click or drag on the", "map to move it.  It is", "made as the originals'", "were: the crop shown", "on the map, a third", "the size, then their", "tone and vignette."})
	y^ += ph + 4
}

// The preview's crop centred on a map point, kept on the map.
preview_centre :: proc(e: ^Editor, at: [2]f32) {
	p := &e.project
	p.preview = terrain.preview_crop_clamp({int(at.x) - terrain.PREVIEW_CROP_WIDTH / 2, int(at.y) - terrain.PREVIEW_CROP_HEIGHT / 2}, p.width, p.length)
}

// The preview made again, when the tab is open and it is out of date:
// the crop's rows rendered lit, then given the originals' look.
level_preview_prepare :: proc(e: ^Editor) {
	lp, p := &e.level_panel, &e.project
	if Tab(e.tab) != .Level || (!lp.preview_stale && lp.preview_at == p.preview && lp.preview.id != 0) {
		return
	}
	at := terrain.preview_crop_clamp(p.preview, p.width, p.length)
	strip, ok := terrain.render(&e.renderer, p, {output = .Lit, from = at.y, to = at.y + terrain.PREVIEW_CROP_HEIGHT}, context.temp_allocator)
	if !ok {
		return
	}
	pic := terrain.preview_make(strip, {at.x, 0}, context.temp_allocator)
	if lp.preview.id != 0 {
		rl.UnloadTexture(lp.preview)
	}
	lp.preview = rl.LoadTextureFromImage({data = raw_data(pic.pixels), width = i32(pic.width), height = i32(pic.height), mipmaps = 1, format = .UNCOMPRESSED_R8G8B8})
	lp.preview_at, lp.preview_stale = p.preview, false
}

level_panel_destroy :: proc(lp: ^Level_Panel) {
	if lp.preview.id != 0 {
		rl.UnloadTexture(lp.preview)
	}
	lp.preview = {}
}

// Keeps what is being typed, if anything.
level_panel_leave :: proc(e: ^Editor) {
	lp := &e.level_panel
	if lp.editing >= 0 {
		f := Field(lp.editing)
		editor_property_set(e, f, box_text(lp.buffers[f][:]))
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
