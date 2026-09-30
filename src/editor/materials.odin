package editor

// Materials (Stage 8): the project's up to four, each a colour or an image
// tinted by it, the brush that paints their weights, and the library a
// level starts its own from. An image dropped on the window, or taken from
// the library, is kept in memory and written beside the project, under
// materials/, when it is saved (terrain.project_save): the project stands
// alone, and exports carry it.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode"

import rl "vendor:raylib"

import "dr:terrain"

// A dropped image larger than this, either way, is scaled down to it: a
// material tiles every `tile` map pixels, rarely more than 256.
MATERIAL_IMAGE_MAX :: 1024
// Map pixels a dropped image covers, at most: its own width when smaller.
MATERIAL_TILE_DEFAULT :: 256
// Where a project keeps its materials' images, and the library its own.
MATERIALS_DIR :: "materials"
LIBRARY_INDEX :: "index.json"
LIBRARY_FORMAT :: "deimos-rising.material-library"

// The materials as a value: what an edit that adds or takes one away keeps.
// The names and images are the project's memory, which outlives the
// history.
Materials :: struct {
	list:            [terrain.MAX_MATERIALS]terrain.Material,
	images:          [terrain.MAX_MATERIALS]terrain.Picture,
	count:           int,
	// Which the rules lay, renumbered when one is taken away.
	cliff, shore:    terrain.Rule,
	canopy_material: int,
}

materials_of :: proc(p: ^terrain.Project) -> (m: Materials) {
	m.count = min(len(p.materials), terrain.MAX_MATERIALS)
	copy(m.list[:], p.materials[:m.count])
	m.images = p.material_images
	m.cliff, m.shore, m.canopy_material = p.cliff, p.shore, p.canopy_material
	return
}

materials_set :: proc(p: ^terrain.Project, m: Materials) {
	m := m
	clear(&p.materials)
	append(&p.materials, ..m.list[:m.count])
	p.material_images = m.images
	p.cliff, p.shore, p.canopy_material = m.cliff, m.shore, m.canopy_material
}

Paint_Mode :: enum c.int {
	Paint,
	Erase,
}

Paint :: struct {
	mode:           c.int, // Paint_Mode
	material:       int,   // in project.materials, or -1
	list_scroll:    c.int,
	library_scroll: c.int,
	library_pick:   c.int, // in library.entries, or -1
}

// A dab of the material weights: Paint moves every weight toward all of
// `material`, Erase takes that one away, by the brush's strength and edge
// as brush_dab's. Where the weights sum under full, the unlit colour shows
// through, or without one the first material. Returns the region it
// changed.
paint_dab :: proc(p: ^terrain.Project, b: Brush, mode: Paint_Mode, material: int, centre: [2]f32, amount: f32, h: ^History) -> (area: terrain.Rect) {
	if p.splat == nil || material < 0 || material >= min(len(p.materials), terrain.MAX_MATERIALS) {
		return {}
	}
	r := max(b.radius, 0.5)
	area = terrain.rect_clip({int(math.floor(centre.x - r)), int(math.floor(centre.y - r)), int(math.ceil(centre.x + r)) + 1, int(math.ceil(centre.y + r)) + 1}, p.width, p.length)
	if area.x1 <= area.x0 || area.y1 <= area.y0 || amount <= 0 {
		return {}
	}
	history_touch(h, p, area)
	strength := clamp(b.strength, 0, 1)
	for y in area.y0 ..< area.y1 {
		for x in area.x0 ..< area.x1 {
			t := min(strength * brush_weight(b, {f32(x) + 0.5 - centre.x, f32(y) + 0.5 - centre.y}, x, y) * amount, 1)
			// Under half a step a dab would round to nothing; over it,
			// each weight moves at least a step, so a held brush arrives.
			if t * 255 < 0.5 {
				continue
			}
			px := p.splat[(y * p.width + x) * 4:][:4]
			switch mode {
			case .Paint:
				sum := 0
				for &v, k in px {
					old := f32(v)
					v = k == material ? u8(min(math.ceil(old + (255 - old) * t), 255)) : u8(math.floor(old * (1 - t)))
					sum += int(v)
				}
				// Rounding up may leave them over full.
				px[material] -= u8(max(sum - 255, 0))
			case .Erase:
				px[material] = u8(math.floor(f32(px[material]) * (1 - t)))
			}
		}
	}
	return
}

// Adds `m`, with `image` when it has one (copied), as the last material,
// and selects it. -1 when there are already four.
editor_material_add :: proc(e: ^Editor, m: terrain.Material, image: terrain.Picture = {}) -> int {
	p := &e.project
	if len(p.materials) >= terrain.MAX_MATERIALS {
		return -1
	}
	editor_stroke_end(e)
	before := materials_of(p)
	a := virtual.arena_allocator(e.arena)
	kept := m
	kept.name = strings.clone(m.name, a)
	kept.image = strings.clone(m.image, a)
	kept.tags = make([]string, len(m.tags), a)
	for tag, i in m.tags {
		kept.tags[i] = strings.clone(tag, a)
	}
	append(&p.materials, kept)
	i := len(p.materials) - 1
	p.material_images[i] = {}
	if image.pixels != nil {
		p.material_images[i] = image
		p.material_images[i].pixels = slice.clone(image.pixels, a)
	}
	history_materials(&e.history, before)
	materials_changed(e)
	e.paint.material = i
	return i
}

// Takes material `i` away: its weights with it, the later ones' moved
// down, and the rules that laid it laying none. Undoes as one edit.
editor_material_remove :: proc(e: ^Editor, i: int) {
	p := &e.project
	if i < 0 || i >= len(p.materials) {
		return
	}
	editor_stroke_end(e)
	before := materials_of(p)
	full := terrain.Rect{0, 0, p.width, p.length}
	if p.splat != nil {
		history_begin(&e.history)
		history_touch(&e.history, p, full)
		for k in 0 ..< p.width * p.length {
			px := p.splat[k * 4:][:4]
			for ch in i ..< 3 {
				px[ch] = px[ch + 1]
			}
			px[3] = 0
		}
	}
	ordered_remove(&p.materials, i)
	for k in i ..< terrain.MAX_MATERIALS - 1 {
		p.material_images[k] = p.material_images[k + 1]
	}
	p.material_images[terrain.MAX_MATERIALS - 1] = {}
	renumber :: proc(m: ^int, gone: int) {
		if m^ == gone {
			m^ = -1
		} else if m^ > gone {
			m^ -= 1
		}
	}
	renumber(&p.cliff.material, i)
	renumber(&p.shore.material, i)
	renumber(&p.canopy_material, i)
	history_materials(&e.history, before)
	history_end(&e.history)
	if p.splat != nil {
		terrain.renderer_update(&e.renderer, p, full)
	}
	materials_changed(e)
	e.paint.material = min(i, len(p.materials) - 1)
}

// After the materials change: drawn again, their looks the settings'.
materials_changed :: proc(e: ^Editor) {
	terrain.renderer_materials(&e.renderer, &e.project)
	e.settings = settings_of(&e.project)
	e.dirty = true
	e.view_stale, e.overview_stale = true, true
	if e.paint.material >= len(e.project.materials) {
		e.paint.material = len(e.project.materials) - 1
	}
}

// Adds the image at `path` (anything raylib reads) as a material, named
// after the file. False when it cannot be read, or there are four.
editor_material_add_file :: proc(e: ^Editor, path: string) -> bool {
	if len(e.project.materials) >= terrain.MAX_MATERIALS {
		return false
	}
	img := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
	if img.data == nil {
		return false
	}
	defer rl.UnloadImage(img)
	if big := max(img.width, img.height); big > MATERIAL_IMAGE_MAX {
		rl.ImageResize(&img, img.width * MATERIAL_IMAGE_MAX / big, img.height * MATERIAL_IMAGE_MAX / big)
	}
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
	w, h := int(img.width), int(img.height)
	pic := terrain.Picture{w, h, 3, 8, ([^]u8)(img.data)[:w * h * 3]}
	name := material_name(e, path)
	m := terrain.Material {
		name   = name,
		colour = {255, 255, 255},
		image  = strings.concatenate({MATERIALS_DIR, "/", name, ".png"}, context.temp_allocator),
		tile   = f32(min(w, MATERIAL_TILE_DEFAULT)),
	}
	return editor_material_add(e, m, pic) >= 0
}

// A file's name as a material's, lower case and dashed, and not one a
// material of the project's image already has.
@(private = "file")
material_name :: proc(e: ^Editor, path: string) -> string {
	base := path
	if i := strings.last_index_any(base, "/\\"); i >= 0 {
		base = base[i + 1:]
	}
	if i := strings.last_index_byte(base, '.'); i > 0 {
		base = base[:i]
	}
	sb := strings.builder_make(context.temp_allocator)
	for r in base {
		switch {
		case unicode.is_letter(r) || unicode.is_digit(r):
			strings.write_rune(&sb, unicode.to_lower(r))
		case strings.builder_len(sb) > 0 && !strings.has_suffix(strings.to_string(sb), "-"):
			strings.write_byte(&sb, '-')
		}
	}
	stem := strings.trim_right(strings.to_string(sb), "-")
	if stem == "" {
		stem = "material"
	}
	name := stem
	for n := 2; material_image_taken(e, name); n += 1 {
		name = fmt.tprintf("%s-%d", stem, n)
	}
	return name
}

@(private = "file")
material_image_taken :: proc(e: ^Editor, name: string) -> bool {
	image := strings.concatenate({MATERIALS_DIR, "/", name, ".png"}, context.temp_allocator)
	for m in e.project.materials {
		if m.image == image {
			return true
		}
	}
	return false
}

// The materials a level can start from: tools/materials' exemplars from
// the originals' unlit colour, and whatever else is put beside them.
Library :: struct {
	dir:     string,
	entries: []Library_Entry,
	arena:   virtual.Arena,
}

Library_Entry :: struct {
	name:   string   `json:"name"`,
	image:  string   `json:"image"`, // in the library's directory
	colour: [3]u8    `json:"colour"`,
	tile:   f32      `json:"tile"`,
	tags:   []string `json:"tags"`,
	// Where it came from, for the reader: "le07 312,1880 96x96".
	source: string   `json:"source"`,
}

@(private = "file")
Json_Library :: struct {
	format:    string          `json:"format"`,
	materials: []Library_Entry `json:"materials"`,
}

// The library in `root`/materials, if there is one there.
library_load :: proc(l: ^Library, root: string) -> bool {
	library_destroy(l)
	dir := strings.concatenate({root, "/", MATERIALS_DIR}, context.temp_allocator)
	blob, err := os.read_entire_file(strings.concatenate({dir, "/", LIBRARY_INDEX}, context.temp_allocator), context.temp_allocator)
	if err != nil || virtual.arena_init_growing(&l.arena) != nil {
		return false
	}
	a := virtual.arena_allocator(&l.arena)
	j: Json_Library
	if json.unmarshal(blob, &j, allocator = a) != nil || j.format != LIBRARY_FORMAT {
		library_destroy(l)
		return false
	}
	l.dir = strings.clone(dir, a)
	l.entries = j.materials
	return true
}

library_destroy :: proc(l: ^Library) {
	virtual.arena_destroy(&l.arena)
	l^ = {}
}

// Adds the library's entry `i` to the project, its image copied in.
editor_material_add_library :: proc(e: ^Editor, l: ^Library, i: int) -> bool {
	if i < 0 || i >= len(l.entries) || len(e.project.materials) >= terrain.MAX_MATERIALS {
		return false
	}
	en := l.entries[i]
	pic, ok := terrain.picture_load(strings.concatenate({l.dir, "/", en.image}, context.temp_allocator), 3, context.temp_allocator)
	if !ok || pic.depth != 8 {
		return false
	}
	m := terrain.Material {
		name   = en.name,
		colour = en.colour,
		image  = strings.concatenate({MATERIALS_DIR, "/", en.image}, context.temp_allocator),
		tile   = en.tile,
		tags   = en.tags,
	}
	return editor_material_add(e, m, pic) >= 0
}
