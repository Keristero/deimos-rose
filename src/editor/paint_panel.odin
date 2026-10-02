package editor

// The Paint tab: the project's materials, the library, the brush that
// paints their weights, and the rules that lay them on steep ground and by
// the water.

import "core:c"
import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

paint_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	p, pt := &e.project, &e.paint
	heading(x, y, w, "Materials")
	rows := make([]Asset_Row, len(p.materials), context.temp_allocator)
	for m, i in p.materials {
		rows[i] = {fmt.tprintf("%s%s", m.name, m.image == "" ? "  (colour)" : ""), material_source(e, m)}
	}
	active := c.int(pt.material)
	list := rl.Rectangle{x, y^, w - 24, 4 * 18 + 8}
	asset_list(list, rows, &pt.list_scroll, &active)
	if int(active) < len(p.materials) {
		pt.material = int(active)
	}
	// Each one's colour beside its name.
	for m, i in p.materials {
		rl.DrawRectangleRec({x + w - 18, y^ + 4 + f32(i) * 18 + 2, 14, 14}, {m.colour.r, m.colour.g, m.colour.b, 255})
	}
	y^ += list.height + 4
	bw := (w - 4) / 2
	full := len(p.materials) >= terrain.MAX_MATERIALS
	if full {
		rl.GuiDisable()
	}
	if rl.GuiButton({x, y^, bw, 20}, "Add a colour") {
		editor_material_add(e, {name = fmt.tprintf("colour %d", len(p.materials) + 1), colour = {128, 128, 128}})
	}
	rl.GuiEnable()
	if pt.material < 0 {
		rl.GuiDisable()
	}
	if rl.GuiButton({x + bw + 4, y^, bw, 20}, "Remove") {
		editor_material_remove(e, pt.material)
	}
	rl.GuiEnable()
	y^ += ROW
	if i := pt.material; i >= 0 && i < len(p.materials) && i < terrain.MAX_MATERIALS {
		m := &p.materials[i]
		colour(x, y, w, "Tint", &m.colour)
		if m.image != "" {
			slider(x, y, w, "Tile", &m.tile, 8, 1024, "%.0f px")
			img := p.material_images[i]
			tags := strings.join(m.tags, ", ", context.temp_allocator)
			help(x, y, w, {fmt.ctprintf("%s, %d x %d%s%s", m.image, img.width, img.height, tags != "" ? ": " : "", tags)})
		}
	}
	y^ += 4

	heading(x, y, w, "Library")
	if len(e.library.entries) > 0 {
		lrows := make([]Asset_Row, len(e.library.entries), context.temp_allocator)
		for en, i in e.library.entries {
			lrows[i].name = en.name
		}
		lrect := rl.Rectangle{x, y^, w, 4 * 18 + 8}
		asset_list(lrect, lrows, &pt.library_scroll, &pt.library_pick)
		y^ += lrect.height + 4
		if full || pt.library_pick < 0 {
			rl.GuiDisable()
		}
		if rl.GuiButton({x, y^, w, 20}, "Add from the library") {
			if !editor_material_add_library(e, &e.library, int(pt.library_pick)) {
				editor_message(e, "Cannot read %s", e.library.entries[pt.library_pick].image)
			}
		}
		rl.GuiEnable()
		y^ += ROW
	} else {
		help(x, y, w, {"No library: `mise run materials:library`."})
	}
	if full {
		rl.GuiDisable()
	}
	if rl.GuiButton({x, y^, w, 20}, "Add an image...") && !editor_dialog(e, .Image) {
		editor_message(e, "No file dialog here: drop the image on the window")
	}
	rl.GuiEnable()
	y^ += ROW
	help(x, y, w, {"Or drop an image on the window."})

	brush_heading(e, x, y, w)
	rl.GuiToggleGroup({x, y^, (w - 2) / 2, 20}, "Paint;Erase", &pt.mode)
	y^ += ROW
	brush_settings(e, x, y, w)
	y^ += 4

	heading(x, y, w, "Laid by the ground")
	rule(e, x, y, w, "Steep", &p.cliff, 0, 4, "%.2f")
	rule(e, x, y, w, "By water", &p.shore, 0, 64, "%.0f px")
	if p.canopy != nil {
		material_combo(e, x, y, w, "Under trees", &p.canopy_material)
	}
	y^ += 4
	help(x, y, w, {"Drag on the map to paint the chosen", "material.  Steep lays one by the slope,", "By water by the height over the water."})
}

// Where a project's material is from: the library's are the game's, the
// images dropped on the window imported. A colour says so in its name.
@(private = "file")
material_source :: proc(e: ^Editor, m: terrain.Material) -> string {
	if m.image == "" {
		return ""
	}
	for en in e.library.entries {
		if m.image == strings.concatenate({MATERIALS_DIR, "/", en.image}, context.temp_allocator) {
			return ""
		}
	}
	return "imported"
}

// A rule: which material, and the range it comes in over.
@(private = "file")
rule :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, label: cstring, r: ^terrain.Rule, lo, hi: f32, format: string) {
	material_combo(e, x, y, w, label, &r.material)
	if r.material >= 0 {
		slider(x, y, w, "  from", &r.from, lo, hi, format)
		slider(x, y, w, "  to", &r.to, lo, hi, format)
	}
}

// Which material, or none (-1): a click takes the next.
@(private = "file")
material_combo :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, label: cstring, material: ^int) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "None")
	for m in e.project.materials[:min(len(e.project.materials), terrain.MAX_MATERIALS)] {
		strings.write_byte(&sb, ';')
		strings.write_string(&sb, m.name)
	}
	active := c.int(material^ + 1)
	rl.GuiLabel({x, y^, 96, 20}, label)
	rl.GuiComboBox({x + 96, y^, w - 96, 20}, strings.to_cstring(&sb), &active)
	material^ = int(active) - 1
	y^ += ROW
}
