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

// One of the original's text presets (a "tefo" record), as
// G_Text_GetPermTextSetting hands it to G_Text_Draw. Indexed in the order of
// the "gate" id list (Text_Preset): the index is what the original passes.
Text_Setting :: struct {
	x, y:          i32,
	format:        sim.Res_ID, // LEFT, RIGHT, CENT, or CEGA/CEBU (centre of the play field / screen)
	monospaced:    bool,       // every character as wide as the widest digit (G_Text_Draw)
	shadows:       bool,
	blend:         i32,        // 0..32, 32 fully transparent
	spacing:       i32,        // before each character
	colorise:      bool,
	colour:        [3]u8,
	strip:         bool,       // a colour box behind the text
	strip_blend:   i32,
	strip_colour:  [3]u8,
	strip_h:       i32,        // the strip's margin beyond the text, across
	strip_v:       i32,        // and down
}

// G_Text_GetPermTextSetting's indices, named after the "gate" list's keys.
Text_Preset :: enum {
	Player_MoneyCount                     = 0x1e,
	ScoreBar_ShieldMeter                  = 0x29,
	ScoreBar_PowerMeter                   = 0x2a,
	ScoreBar_Score_Player1                = 0x2b,
	ScoreBar_Score_Player2                = 0x2c,
	ScoreBar_LivesCounter_Player1         = 0x2d,
	ScoreBar_LivesCounter_Player2         = 0x2e,
	ScoreBar_LivesCounterLastLife_Player1 = 0x2f,
	ScoreBar_LivesCounterLastLife_Player2 = 0x30,
	Game_Notice                           = 0x31,
	GroundAccuracyCount                   = 0x35,
}

TEXT_SETTINGS :: 0x36

Assets :: struct {
	root:     string,
	sprites:  []Sprite_Plate,
	levels:   []Level_Media,
	scorebar: Score_Bar_Layout,
	text:     [TEXT_SETTINGS]Text_Setting,
	// G_Res_GetPermGameString's table (stli "pgsl"): "Ground Accuracy:",
	// "Bonus:", "Coin Bonus:", "REPLAY" and the rest, by index.
	game_strings: []string,
	// Every `audio/*.wav` id except the ones levels reference as `music`
	// (assets/audio/mu03.wav is a 196s stereo track, not a one-shot effect --
	// see Level_Media.music). The game loads each of these once as a short
	// sound effect; music streams from disk instead, via Level_Media.music.
	sounds: []string,
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

	// The game's plates, then the new content's (assets/extra): both
	// indexes give image paths relative to the assets root.
	plates := make([dynamic]Sprite_Plate, 0, 400, allocator)
	for index in ([2]string{"/sprites/index.json", "/extra/sprites/index.json"}) {
		idx: Json_Sprite_Index
		if !read_json(strings.concatenate({root, index}, context.temp_allocator), &idx, context.temp_allocator) {
			continue
		}
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
	}
	if len(plates) > 0 {
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

	exclude := make(map[string]bool, len(a.levels), context.temp_allocator)
	for lv in a.levels {
		if lv.music != "" && lv.music != "none" {
			exclude[lv.music] = true
		}
	}
	// The menus' "Interface Music Loop" streams as music too
	// (game/assets.odin's MENU_MUSIC); decoding its ~60s into memory as a
	// sound effect as well would only waste ~10 MB.
	exclude["inmu"] = true
	sounds := make([dynamic]string, 0, 99, allocator)
	if paths, err := filepath.glob(strings.concatenate({root, "/audio/*.wav"}, context.temp_allocator),
		context.temp_allocator); err == nil {
		for path in paths {
			base := filepath.base(path)
			id := base[:len(base) - len(".wav")]
			if !exclude[id] {
				append(&sounds, strings.clone(id, allocator))
			}
		}
	}
	a.sounds = sounds[:]

	// G_Res_GetPermGameString: stli "pgsl", one line per index.
	pgsl: Json_Definition
	if read_json(strings.concatenate({root, "/data/stli/pgsl.json"}, context.temp_allocator), &pgsl, context.temp_allocator) {
		lines := make([]string, len(pgsl.fields), allocator)
		for f, i in pgsl.fields {
			lines[i] = strings.clone(f.value, allocator)
		}
		a.game_strings = lines
	}

	// The text presets: "gate" names one tefo record per index.
	gate: Json_Definition
	if read_json(strings.concatenate({root, "/data/idli/gate.json"}, context.temp_allocator), &gate, context.temp_allocator) {
		for f, i in gate.fields {
			if i >= TEXT_SETTINGS {
				break
			}
			rec: Json_Definition
			path := strings.concatenate({root, "/data/tefo/", strings.trim_space(f.value), ".json"}, context.temp_allocator)
			if read_json(path, &rec, context.temp_allocator) {
				a.text[i] = text_setting_from(rec.fields)
			}
		}
	}

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

@(private = "file")
text_setting_from :: proc(fields: []Json_Field) -> (t: Text_Setting) {
	int_of :: proc(v: string) -> i32 {
		n, _ := strconv.parse_int(strings.trim_space(v))
		return i32(n)
	}
	rgb_of :: proc(v: string) -> [3]u8 {
		n, _ := strconv.parse_int(strings.trim_space(v), 16)
		return {u8(n >> 16), u8(n >> 8), u8(n)}
	}
	for f in fields {
		v := f.value
		yes := strings.trim_space(v) == "TRUE"
		switch f.key {
		case "Loc_X_INT":                         t.x = int_of(v)
		case "Loc_Y_INT":                         t.y = int_of(v)
		case "Format_ID":
			// The loader (FUN_0043f280) also takes a digit: 0 LEFT, 1 CENT,
			// 2 RIGH, 3 CEBU, 4 CEGA ("gare", the REPLAY label, says 4).
			// Anything else it does not know reads as LEFT.
			digits := [5]sim.Res_ID{{'L', 'E', 'F', 'T'}, {'C', 'E', 'N', 'T'}, {'R', 'I', 'G', 'H'}, {'C', 'E', 'B', 'U'}, {'C', 'E', 'G', 'A'}}
			f := strings.trim_space(v)
			t.format = sim.res_id(f)
			if len(f) == 1 && f[0] >= '0' && f[0] <= '4' {
				t.format = digits[f[0] - '0']
			}
		case "Monospaced_BOOL":                   t.monospaced = yes
		case "DrawShadows_BOOL":                  t.shadows = yes
		case "BlendAmount_0To32_INT":             t.blend = int_of(v)
		case "SpaceBetweenChars_INT":             t.spacing = int_of(v)
		case "Colorise_Do_BOOL":                  t.colorise = yes
		case "ColoriseColor_RGB":                 t.colour = rgb_of(v)
		case "ColorStrip_Do_BOOL":                t.strip = yes
		case "ColorStrip_BlendAmount_0To32_INT":  t.strip_blend = int_of(v)
		case "ColorStrip_Color_RGB":              t.strip_colour = rgb_of(v)
		case "ColorStrip_HOffset_INT":            t.strip_h = int_of(v)
		case "ColorStrip_VOffset_INT":            t.strip_v = int_of(v)
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
	units := make([dynamic]sim.Unit, 0, 400, allocator)
	units_append(&units, root, &report, allocator)
	defs.units = units[:]
	report.units = len(units)

	sprites := make([dynamic]sim.Sprite, 0, 400, allocator)
	sprites_append(&sprites, root, allocator)
	if len(sprites) > 0 {
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

	weapons := make([dynamic]sim.Weapon, 0, 8, allocator)
	weapons_append(&weapons, root, false, &report, allocator)
	defs.weapons = weapons[:]

	assets_defs_load_rest(root, &defs, &report, allocator)
	return
}

// Units, with their states, spawn sets and rules.
@(private = "file")
units_append :: proc(units: ^[dynamic]sim.Unit, root: string, report: ^Defs_Report, allocator := context.allocator) {
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
		append(units, unit_from_definition(&d, report, allocator))
	}
}

// Sprite groups: the baked frame index is the same cut `defs_load` makes
// from the plates, verified against the original by `assets:verify`.
@(private = "file")
sprites_append :: proc(sprites: ^[dynamic]sim.Sprite, root: string, allocator := context.allocator) {
	idx: Json_Sprite_Index
	if !read_json(strings.concatenate({root, "/sprites/index.json"}, context.temp_allocator), &idx, context.temp_allocator) {
		return
	}
	for s in idx.sprites {
		spr := sim.Sprite{id = sim.res_id_lower(sim.res_id(s.fourcc))}
		spr.frames = make([]sim.Sprite_Frame, len(s.frames), allocator)
		for f, i in s.frames {
			spr.frames[i] = {i32(f.w), i32(f.h)}
		}
		append(sprites, spr)
	}
}

// Weapon definitions, whose spawn records repeat the spawn_* keys. `extra`
// marks them as new content, whose own keys start `x_`.
@(private = "file")
weapons_append :: proc(weapons: ^[dynamic]sim.Weapon, root: string, extra: bool, report: ^Defs_Report, allocator := context.allocator) {
	for path in record_paths(root, "wede", context.temp_allocator) {
		jd: Json_Definition
		if !read_json(path, &jd, context.temp_allocator) {
			continue
		}
		header := tags_from(jd.header, context.temp_allocator)
		wp := sim.Weapon{id = sim.res_id(id_of(path)), extra = extra}
		def_fill(&wp.def, header, report, allocator)
		wp.spawns = weapon_spawns(header, report, allocator)
		if extra {
			if v, ok := def_find(header, "x_AimedRelease_BOOL"); ok {
				wp.aimed_release, _ = tag_bool(v)
			}
			beam_fill(&wp.beam, header)
		}
		append(weapons, wp)
	}
}

// A beam weapon's x_Beam* keys (sim/beam.odin); none leaves it off.
@(private = "file")
beam_fill :: proc(b: ^sim.Beam_Def, header: []Tag) {
	b^ = {}
	if v, ok := def_find(header, "x_Beam_BOOL"); ok {
		b.on, _ = tag_bool(v)
	}
	if !b.on {
		return
	}
	float :: proc(header: []Tag, key: string) -> f32 {
		v, _ := def_find(header, key)
		f, _ := tag_float(v)
		return f32(f)
	}
	b.damage = float(header, "x_BeamDamage_FLOAT")
	b.width = float(header, "x_BeamWidth_FLOAT")
	b.release_damage = float(header, "x_BeamReleaseDamage_FLOAT")
	b.release_width = float(header, "x_BeamReleaseWidth_FLOAT")
	b.shrapnel = sim.Res_ID(def_fourcc(header, "x_BeamShrapnel_ID"))
	if v, ok := def_find(header, "x_BeamShrapnelCount_INT"); ok {
		n, _ := tag_int(v)
		b.shrapnel_count = i32(n)
	}
}

// The new content (docs/new-weapons.md): units, weapons and sprites under
// `<root>/extra`, laid out as the game's own tree is, added to `defs` after
// the game's own so no original index moves. Kept out of assets_defs_load,
// which has to match the original exactly. Returns false when there is no
// extra tree; the game then plays without the new weapons.
extra_defs_load :: proc(root: string, defs: ^sim.Defs, allocator := context.allocator) -> (report: Defs_Report, ok: bool) {
	extra := strings.concatenate({root, "/extra"}, context.temp_allocator)
	if !os.exists(extra) {
		return
	}
	units := make([dynamic]sim.Unit, 0, len(defs.units) + 16, allocator)
	append(&units, ..defs.units)
	units_append(&units, extra, &report, allocator)
	report.units = len(units) - len(defs.units)
	defs.units = units[:]

	weapons := make([dynamic]sim.Weapon, 0, len(defs.weapons) + 4, allocator)
	append(&weapons, ..defs.weapons)
	weapons_append(&weapons, extra, true, &report, allocator)
	defs.weapons = weapons[:]

	sprites := make([dynamic]sim.Sprite, 0, len(defs.sprites) + 4, allocator)
	append(&sprites, ..defs.sprites)
	sprites_append(&sprites, extra, allocator)
	report.sprites = len(sprites) - len(defs.sprites)
	defs.sprites = sprites[:]
	return report, true
}

// Levels, the permanent tables: the rest of assets_defs_load.
@(private = "file")
assets_defs_load_rest :: proc(root: string, defs: ^sim.Defs, report: ^Defs_Report, allocator := context.allocator) {

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
