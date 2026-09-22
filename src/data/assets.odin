package data

// Loading the game's own `assets/` tree.
//
// `defs_load` reads the original install: encrypted tagged text out of the
// PAKs, GIF plates, 16-bit TGA masks. That path stays, because the oracle
// harness needs the original anyway. The shipped game reads this tree instead:
// JSON records, RGBA PNGs and WAVs, written by `mise run assets:all`.
//
// The records keep every `key = value` pair the original text had, so the same
// reflection fill builds the same structures. `assets_defs_load` must produce
// a `sim.Defs` equal to `defs_load`'s, field for field -- tests/assets_test.odin
// checks exactly that.

import "core:encoding/json"
import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "dr:sim"

// --- the JSON the records tool writes -------------------------------------

Json_Field :: struct {
	key:   string `json:"key"`,
	value: string `json:"value"`,
}

Json_Rule :: struct {
	name:      string `json:"name"`,
	unit:      string `json:"unit"`,
	range:     int    `json:"range"`,
	condition: string `json:"condition"`,
	action:    string `json:"action"`,
}

Json_Spawn_Set :: struct {
	fields: []Json_Field `json:"fields"`,
}

Json_State :: struct {
	name:       string           `json:"name"`,
	spawn_sets: []Json_Spawn_Set `json:"spawn_sets"`,
	rules:      []Json_Rule      `json:"rules"`,
	fields:     []Json_Field     `json:"fields"`,
}

Json_Definition :: struct {
	id:     string       `json:"id"`,
	type:   string       `json:"type"`,
	states: []Json_State `json:"states"`,
	header: []Json_Field `json:"header"`,
	// Flat records (idli, flli, plde, wede as written by tools/records) put
	// their pairs here instead.
	fields: []Json_Field `json:"fields"`,
}

Json_Placement :: struct {
	unit:            string `json:"unit"`,
	layer:           string `json:"layer"`,
	x:               int    `json:"x"`,
	y:               int    `json:"y"`,
	heading_degrees: int    `json:"heading_degrees"`,
	is_stationary:   bool   `json:"is_stationary"`,
	terrain_effects: bool   `json:"terrain_effects"`,
}

Json_Level :: struct {
	id:               string           `json:"id"`,
	name:             string           `json:"name"`,
	identifier:       string           `json:"identifier"`,
	background:       [4]int           `json:"background"`,
	background_image: string           `json:"background_image"`,
	preview_image:    string           `json:"preview_image"`,
	music:            string           `json:"music"`,
	media_mask:       string           `json:"media_mask"`,
	placements:       []Json_Placement `json:"placements"`,
}

Json_Frame :: struct {
	x, y, w, h: int,
}

Json_Sprite :: struct {
	fourcc: string       `json:"fourcc"`,
	dir:    string       `json:"dir"`,
	image:  string       `json:"image"`,
	width:  int          `json:"width"`,
	height: int          `json:"height"`,
	frames: []Json_Frame `json:"frames"`,
}

Json_Sprite_Index :: struct {
	sprites: []Json_Sprite `json:"sprites"`,
}

// --- what the presentation needs and the simulation does not --------------

// A plate and where each frame sits in it. The game uploads one texture per
// plate and draws sub-rectangles of it.
Sprite_Plate :: struct {
	id:     sim.Res_ID, // lower-case, as units name it
	image:  string,     // path relative to the assets root
	width:  int,
	height: int,
	frames: []Json_Frame,
}

// Per-level presentation: the scrolling terrain image, the map preview and
// the music track. The simulation knows none of this.
Level_Media :: struct {
	id:         sim.Res_ID,
	name:       string,
	background: string, // im16 image id
	preview:    string,
	music:      string,
}

// Where the score bar's widgets sit, per player (G_ScoreBar_Init's
// G_Res_GetPermRect(0..7) for player 1, (8..15) for player 2). Positions are
// local to the score bar panel, which the original places at the right edge
// of the 416-wide play field (U_Display::GetFrontScorebarRect = play field
// width + a fixed margin, on a screen that G_Display::Init hardcodes to
// 640x480): rect.left/top here are relative to that panel's own origin, not
// the window.
Score_Bar_Rects :: struct {
	score:       sim.Rect,
	life_symbol: sim.Rect,
	life_count:  sim.Rect,
	weapon:      [3]sim.Rect,
	shields:     sim.Rect,
	power:       sim.Rect,
}

Score_Bar_Layout :: struct {
	players: [2]Score_Bar_Rects,
}

Assets :: struct {
	root:     string,
	sprites:  []Sprite_Plate,
	levels:   []Level_Media,
	scorebar: Score_Bar_Layout,
}

// --- loading ---------------------------------------------------------------

@(private = "file")
read_json :: proc(path: string, out: ^$T, allocator := context.allocator) -> bool {
	blob, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return json.unmarshal(blob, out, allocator = allocator) == nil
}

@(private = "file")
tags_from :: proc(fields: []Json_Field, allocator := context.allocator) -> []Tag {
	out := make([]Tag, len(fields), allocator)
	for f, i in fields {
		out[i] = {key = f.key, value = f.value}
	}
	return out
}

// Every `<root>/data/<type>/*.json`, sorted by name so the order is stable.
@(private = "file")
record_paths :: proc(root, type: string, allocator := context.allocator) -> []string {
	pattern := strings.concatenate({root, "/data/", type, "/*.json"}, context.temp_allocator)
	matches, err := filepath.glob(pattern, allocator)
	if err != nil {
		return nil
	}
	return matches
}

@(private = "file")
id_of :: proc(path: string) -> string {
	base := filepath.base(path)
	return base[:len(base) - len(".json")]
}

assets_open :: proc(root: string, allocator := context.allocator) -> (a: Assets) {
	a.root = strings.clone(root, allocator)

	idx: Json_Sprite_Index
	if read_json(strings.concatenate({root, "/sprites/index.json"}, context.temp_allocator),
		&idx, context.temp_allocator) {
		plates := make([dynamic]Sprite_Plate, 0, len(idx.sprites), allocator)
		for s in idx.sprites {
			frames := make([]Json_Frame, len(s.frames), allocator)
			copy(frames, s.frames)
			append(&plates, Sprite_Plate {
				id     = sim.res_id_lower(sim.res_id(s.fourcc)),
				image  = strings.clone(s.image, allocator),
				width  = s.width,
				height = s.height,
				frames = frames,
			})
		}
		a.sprites = plates[:]
	}

	media := make([dynamic]Level_Media, 0, 12, allocator)
	for path in record_paths(root, "levels", context.temp_allocator) {
		lv: Json_Level
		if !read_json(path, &lv, context.temp_allocator) {
			continue
		}
		append(&media, Level_Media {
			id         = sim.res_id(lv.id),
			name       = strings.clone(lv.name, allocator),
			background = strings.clone(lv.background_image, allocator),
			preview    = strings.clone(lv.preview_image, allocator),
			music      = strings.clone(lv.music, allocator),
		})
	}
	a.levels = media[:]

	// inre "reli": 16 score bar rects (8 per player, in G_Res_GetPermRect
	// order -- verified against G_ScoreBar_Init/Draw), then 6 more for the
	// level-select and briefing screens that Stage 6 will use.
	if paths := record_paths(root, "reli", context.temp_allocator); len(paths) > 0 {
		jd: Json_Definition
		if read_json(paths[0], &jd, context.temp_allocator) && len(jd.fields) >= 16 {
			rect :: proc(f: Json_Field) -> sim.Rect {
				r, _ := tag_rect(f.value)
				return rect_from(r)
			}
			for pn in 0 ..< 2 {
				base := pn * 8
				p := &a.scorebar.players[pn]
				p.score = rect(jd.fields[base + 0])
				p.life_symbol = rect(jd.fields[base + 1])
				p.life_count = rect(jd.fields[base + 2])
				p.weapon[0] = rect(jd.fields[base + 3])
				p.weapon[1] = rect(jd.fields[base + 4])
				p.weapon[2] = rect(jd.fields[base + 5])
				p.shields = rect(jd.fields[base + 6])
				p.power = rect(jd.fields[base + 7])
			}
		}
	}
	return
}

assets_plate :: proc(a: ^Assets, id: sim.Res_ID) -> ^Sprite_Plate {
	for &p in a.sprites {
		if p.id == id {
			return &p
		}
	}
	return nil
}

assets_level_media :: proc(a: ^Assets, id: sim.Res_ID) -> ^Level_Media {
	for &l in a.levels {
		if l.id == id {
			return &l
		}
	}
	return nil
}

// Builds the same `sim.Defs` as `defs_load`, from the extracted tree.
assets_defs_load :: proc(root: string, allocator := context.allocator) -> (defs: sim.Defs, report: Defs_Report) {
	// Units, with their states, spawn sets and rules.
	units := make([dynamic]sim.Unit, 0, 400, allocator)
	for path in record_paths(root, "unde", context.temp_allocator) {
		jd: Json_Definition
		if !read_json(path, &jd, context.temp_allocator) {
			continue
		}
		d := Definition {
			id     = fourcc_from(id_of(path)),
			header = tags_from(jd.header, context.temp_allocator),
		}
		states := make([]Def_State, len(jd.states), context.temp_allocator)
		for js, i in jd.states {
			st := &states[i]
			st.name = js.name
			st.fields = tags_from(js.fields, context.temp_allocator)
			st.spawn_sets = make([]Def_Spawn_Set, len(js.spawn_sets), context.temp_allocator)
			for ss, j in js.spawn_sets {
				st.spawn_sets[j] = {fields = tags_from(ss.fields, context.temp_allocator)}
			}
			st.rules = make([]Def_Rule, len(js.rules), context.temp_allocator)
			for r, j in js.rules {
				cond, _ := rule_condition_from(r.condition)
				st.rules[j] = {
					name      = r.name,
					unit      = fourcc_from(r.unit),
					range     = r.range,
					condition = cond,
					action    = r.action,
				}
			}
		}
		d.states = states
		append(&units, unit_from_definition(&d, &report, allocator))
	}
	defs.units = units[:]
	report.units = len(units)

	// Sprite groups: the baked frame index is the same cut `defs_load` makes
	// from the plates, verified against the original by `assets:verify`.
	idx: Json_Sprite_Index
	if read_json(strings.concatenate({root, "/sprites/index.json"}, context.temp_allocator),
		&idx, context.temp_allocator) {
		sprites := make([dynamic]sim.Sprite, 0, len(idx.sprites), allocator)
		for s in idx.sprites {
			spr := sim.Sprite{id = sim.res_id_lower(sim.res_id(s.fourcc))}
			spr.frames = make([]sim.Sprite_Frame, len(s.frames), allocator)
			for f, i in s.frames {
				spr.frames[i] = {i32(f.w), i32(f.h)}
			}
			append(&sprites, spr)
		}
		defs.sprites = sprites[:]
		report.sprites = len(sprites)
	}

	// Player definitions.
	players := make([dynamic]sim.Player_Entry, 0, 2, allocator)
	for path in record_paths(root, "plde", context.temp_allocator) {
		jd: Json_Definition
		if !read_json(path, &jd, context.temp_allocator) {
			continue
		}
		pe := sim.Player_Entry{id = sim.res_id(id_of(path))}
		def_fill(&pe.def, tags_from(jd.header, context.temp_allocator), &report, allocator)
		append(&players, pe)
	}
	defs.players = players[:]

	// Weapon definitions, whose spawn records repeat the spawn_* keys.
	weapons := make([dynamic]sim.Weapon, 0, 8, allocator)
	for path in record_paths(root, "wede", context.temp_allocator) {
		jd: Json_Definition
		if !read_json(path, &jd, context.temp_allocator) {
			continue
		}
		header := tags_from(jd.header, context.temp_allocator)
		wp := sim.Weapon{id = sim.res_id(id_of(path))}
		def_fill(&wp.def, header, &report, allocator)
		wp.spawns = weapon_spawns(header, &report, allocator)
		append(&weapons, wp)
	}
	defs.weapons = weapons[:]

	// Levels, in play order.
	levels := make([dynamic]sim.Level_Def, 0, 12, allocator)
	paths := record_paths(root, "levels", context.temp_allocator)
	for name, i in LEVEL_ORDER {
		for path in paths {
			lv: Json_Level
			if !read_json(path, &lv, context.temp_allocator) {
				continue
			}
			if lv.identifier != name {
				continue
			}
			l := sim.Level_Def {
				id         = sim.res_id(lv.id),
				identifier = strings.clone(lv.identifier, allocator),
				number     = i32(i + 1),
				background = rect_from(Rect{
					left   = lv.background[0],
					top    = lv.background[1],
					right  = lv.background[2],
					bottom = lv.background[3],
				}),
				placements = make([]sim.Placement_Def, len(lv.placements), allocator),
			}
			for pl, k in lv.placements {
				l.placements[k] = {
					unit            = sim.res_id(pl.unit),
					x               = i32(pl.x),
					y               = i32(pl.y),
					heading         = i32(pl.heading_degrees),
					stationary      = pl.is_stationary,
					terrain_effects = pl.terrain_effects,
				}
			}
			mask := strings.concatenate({root, "/images/im16/", lv.media_mask, ".png"},
				context.temp_allocator)
			if px, mw, mh, ok := media_mask_from_png(mask, allocator); ok {
				l.media, l.media_w, l.media_h = px, i32(mw), i32(mh)
				l.media_scale = (l.background.right - l.background.left) / i32(mw)
			}
			append(&levels, l)
			break
		}
	}
	defs.levels = levels[:]
	report.levels = len(levels)

	// The permanent tables: 220 floats read positionally, then the sound and
	// object id lists.
	flat: Json_Definition
	if read_json(strings.concatenate({root, "/data/flli/gafl.json"}, context.temp_allocator),
		&flat, context.temp_allocator) {
		for f, i in flat.fields {
			if i >= sim.PERM_FLOATS {
				break
			}
			v, _ := strconv.parse_f64(strings.trim_space(f.value))
			defs.perm_floats[i] = f32(v)
			report.perm_floats += 1
		}
	}
	sounds: Json_Definition
	if read_json(strings.concatenate({root, "/data/idli/gaso.json"}, context.temp_allocator),
		&sounds, context.temp_allocator) {
		for f, i in sounds.fields {
			if i >= sim.PERM_SOUNDS {
				break
			}
			defs.perm_sounds[i] = sim.res_id(f.value)
		}
	}
	objects: Json_Definition
	if read_json(strings.concatenate({root, "/data/idli/gaob.json"}, context.temp_allocator),
		&objects, context.temp_allocator) {
		for f, i in objects.fields {
			if i >= sim.PERM_OBJECTS {
				break
			}
			defs.perm_objects[i] = sim.res_id(f.value)
		}
	}
	return
}

// The media mask as the simulation wants it: one 16-bit value per pixel, with
// 0x001f meaning water.
//
// The original reads a 16-bit TGA and compares the raw word. Extraction turns
// that into an RGBA PNG, where 0x001f is exactly (0, 0, 255): each 5-bit
// channel is expanded by *255/31, so only 0x001f and 0x801f produce it, and
// `assets:verify` checks that no shipped mask sets the top bit.
media_mask_from_png :: proc(path: string, allocator := context.allocator) -> (px: []u16, w, h: int, ok: bool) {
	// png.destroy frees through the context allocator, so the image is loaded
	// with it rather than from a temporary arena.
	img, err := png.load_from_file(path)
	if err != nil {
		return nil, 0, 0, false
	}
	defer png.destroy(img)
	if img.depth != 8 || img.channels < 3 {
		return nil, 0, 0, false
	}
	out := make([]u16, img.width * img.height, allocator)
	buf := img.pixels.buf[:]
	for i in 0 ..< img.width * img.height {
		p := buf[i * img.channels:]
		out[i] = rgb_to_1555(p[0], p[1], p[2])
	}
	return out, img.width, img.height, true
}

rgb_to_1555 :: proc "contextless" (r, g, b: u8) -> u16 {
	// The inverse of the expansion in tga_decode: v*255/31 rounded.
	q :: proc "contextless" (v: u8) -> u16 {
		return u16((int(v) * 31 + 127) / 255)
	}
	return q(r) << 10 | q(g) << 5 | q(b)
}
