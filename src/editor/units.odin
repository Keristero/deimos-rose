package editor

// The units a level can place, and how the editor shows them. The palette
// is every unit with a preview face (editorPreviewSpriteFace_ID not
// "none"): 134 of the originals' 386, among them all 114 the twelve levels
// place. What the preview flags mean is ours to settle -- the original
// editor is not in the release -- so unit_look is a reading of them, not a
// recovered rule (docs/level-editor.md, Stage 8).

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

Catalogue :: struct {
	defs:    sim.Defs,
	assets:  data.Assets,
	// Indices into defs.units that can be placed, by name.
	palette: [dynamic]int,
	// Each sprite plate's texture, loaded when first drawn.
	plates:  map[sim.Res_ID]Plate,
	// The bases the original maps have baked under these units, by unit
	// id: `mise run levels:bases` measures them (docs/level-editor.md).
	bases:   map[string]Plate,
}

// assets/bases/index.json, as tools/bases writes it.
@(private = "file")
Json_Bases :: struct {
	format: string,
	bases:  []struct {
		unit:  string,
		image: string,
	},
}

BASES_DIR :: "bases"
BASES_FORMAT :: "deimos-rising.bases"

Plate :: struct {
	frames:  []data.Json_Frame, // nil: no such plate
	image:   string,
	texture: rl.Texture2D,      // id 0 until drawn, or when the image is missing
	loaded:  bool,
}

// The originals' units and every data plugin's, from the assets tree.
// sim.register_all must have run: extra_defs_load reads the plugins.
catalogue_load :: proc(c: ^Catalogue, root: string) {
	c.defs, _ = data.assets_defs_load(root)
	data.extra_defs_load(&c.defs)
	c.assets = data.assets_open(root)
	catalogue_index(c)
	bases_load(c, root)
}

// The baked bases, from root/bases; none when they have not been measured.
@(private = "file")
bases_load :: proc(c: ^Catalogue, root: string) {
	dir := strings.concatenate({root, "/", BASES_DIR}, context.temp_allocator)
	blob, err := os.read_entire_file(strings.concatenate({dir, "/index.json"}, context.temp_allocator), context.temp_allocator)
	index: Json_Bases
	if err != nil || json.unmarshal(blob, &index, allocator = context.temp_allocator) != nil || index.format != BASES_FORMAT {
		return
	}
	for b in index.bases {
		c.bases[strings.clone(b.unit)] = {image = strings.concatenate({dir, "/", b.image})}
	}
}

// The base baked under `unit`'s structures, when it has one.
catalogue_base :: proc(c: ^Catalogue, unit: string) -> (t: rl.Texture2D, ok: bool) {
	p, have := &c.bases[unit]
	if !have {
		return
	}
	if !p.loaded {
		p.loaded = true
		p.texture = rl.LoadTexture(strings.clone_to_cstring(p.image, context.temp_allocator))
	}
	return p.texture, p.texture.id != 0
}

// Fills the palette from defs.units.
catalogue_index :: proc(c: ^Catalogue) {
	Entry :: struct {
		name, id: string,
		index:    int,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	for &u, i in c.defs.units {
		if u.editor_preview_sprite_face != sim.NONE {
			append(&entries, Entry{u.name, string(u.id[:]), i})
		}
	}
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
		return a.name != b.name ? a.name < b.name : a.id < b.id
	})
	clear(&c.palette)
	for en in entries {
		append(&c.palette, en.index)
	}
}

// Frees the textures; the defs and assets live as long as the editor.
catalogue_destroy :: proc(c: ^Catalogue) {
	for _, p in c.plates {
		if p.texture.id != 0 {
			rl.UnloadTexture(p.texture)
		}
	}
	delete(c.plates)
	for id, b in c.bases {
		if b.texture.id != 0 {
			rl.UnloadTexture(b.texture)
		}
		delete(id)
		delete(b.image)
	}
	delete(c.bases)
	delete(c.palette)
}

catalogue_unit :: proc(c: ^Catalogue, id: string) -> ^sim.Unit {
	return sim.unit_find(&c.defs, sim.res_id(id))
}

// The sprite and frame a placement shows, facing `heading`: the unit's
// first state as it spawns -- turned, when the editor sets its heading --
// unless it asks for its preview, or its first state draws nothing (a
// pause marker, a trigger).
unit_look :: proc(u: ^sim.Unit, heading: int) -> (sprite: sim.Res_ID, frame: int) {
	if u.use_preview_appearance_in_placement_editor || len(u.states) == 0 || u.states[0].sprite_face == sim.NONE {
		return u.editor_preview_sprite_face, int(u.editor_preview_sprite_frame)
	}
	st := &u.states[0]
	if u.initial_heading_set_in_editor {
		return st.sprite_face, int(sim.state_frame_for_angle(st, i32(heading)))
	}
	return st.sprite_face, int(st.sprite_frame_min)
}

// A frame's size, without its texture: what tests and picking need.
catalogue_frame_size :: proc(c: ^Catalogue, sprite: sim.Res_ID, frame: int) -> (size: [2]f32, ok: bool) {
	p := catalogue_plate(c, sprite)
	if frame < 0 || frame >= len(p.frames) {
		return
	}
	f := p.frames[frame]
	return {f32(f.w), f32(f.h)}, true
}

// A frame's texture and where it is in it; ok false when the plate, its
// image or the frame is missing.
catalogue_frame :: proc(c: ^Catalogue, sprite: sim.Res_ID, frame: int) -> (t: rl.Texture2D, src: rl.Rectangle, ok: bool) {
	p := catalogue_plate(c, sprite)
	if !p.loaded {
		p.loaded = true
		if p.image != "" {
			p.texture = rl.LoadTexture(strings.clone_to_cstring(p.image, context.temp_allocator))
		}
	}
	if p.texture.id == 0 || frame < 0 || frame >= len(p.frames) {
		return
	}
	f := p.frames[frame]
	return p.texture, {f32(f.x), f32(f.y), f32(f.w), f32(f.h)}, true
}

@(private = "file")
catalogue_plate :: proc(c: ^Catalogue, sprite: sim.Res_ID) -> ^Plate {
	key := sim.res_id_lower(sprite)
	if key not_in c.plates {
		p: Plate
		for sp in c.assets.sprites {
			if sp.id == key {
				p.frames, p.image = sp.frames, sp.image
				break
			}
		}
		c.plates[key] = p
	}
	return &c.plates[key]
}
