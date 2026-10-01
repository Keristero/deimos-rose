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
import "core:slice"
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
	// The originals' too, which the game does not show yet: kept so the
	// level editor carries them through (tools/records writes them).
	description:      string           `json:"description"`,
	copyright:        string           `json:"copyright"`,
	briefing:         string           `json:"briefing"`,
	background:       [4]int           `json:"background"`,
	background_image: string           `json:"background_image"`,
	preview_image:    string           `json:"preview_image"`,
	music:            string           `json:"music"`,
	media_mask:       string           `json:"media_mask"`,
	placements:       []Json_Placement `json:"placements"`,
	// Not the original's, and all optional (D54): no original level has
	// any of them.
	start_weapons:    Json_Start_Weapons `json:"start_weapons"`,
	wind:             Level_Wind         `json:"wind"`,
	water:            Level_Water        `json:"water"`,
	lighting:         Level_Lighting     `json:"lighting"`,
	skybox:           string             `json:"skybox"`,
	layers:           Level_Layers       `json:"layers"`,
}

// Weapon ids ("aipb"): what a player starts the level with, in place of
// what its number brings.
Json_Start_Weapons :: struct {
	air:    string `json:"air"`,
	ground: string `json:"ground"`,
}

// The wind over a level, for the presentation: particles and water. A
// direction as placements' headings are.
Level_Wind :: struct {
	direction_degrees: f32 `json:"direction_degrees"`,
	strength:          f32 `json:"strength"`, // 0 for still air
}

// The water plane the level was rendered with, in the editor's height
// units. The simulation reads only the media mask exported from it.
Level_Water :: struct {
	height:  f32   `json:"height"`,
	colour:  [3]u8 `json:"colour"`,
	visible: bool  `json:"visible"`,
}

// The light the level was rendered with. A field left out keeps
// LIGHTING_MEASURED's value.
Level_Lighting :: struct {
	sun_azimuth_degrees:   f32   `json:"sun_azimuth_degrees"`,
	sun_elevation_degrees: f32   `json:"sun_elevation_degrees"`,
	sun_colour:            [3]u8 `json:"sun_colour"`,
	ambient_colour:        [3]u8 `json:"ambient_colour"`,
	ambient:               f32   `json:"ambient"`,  // the share of full light left in shadow
	softness:              f32   `json:"softness"`, // the penumbra's width, in map pixels
}

// The originals' light, measured on their maps
// (notes/headless-3d-to-2d-findings.md): a white sun at azimuth 36°,
// 40° up, and neutral shadow at 0.44 of full light, a few pixels soft.
// The silos' shadows alone said about 28° up; le07's recovered terrain
// matches the art's shadows as well at 40° and their darkness better (D55).
LIGHTING_MEASURED :: Level_Lighting {
	sun_azimuth_degrees   = 36,
	sun_elevation_degrees = 40,
	sun_colour            = {255, 255, 255},
	ambient_colour        = {255, 255, 255},
	ambient               = 0.44,
	softness              = 3,
}

// Optional exports beside the map, for presentation mods (Stage 10 of
// notes/level-editor-plan.md): im16 image ids, empty when not exported.
Level_Layers :: struct {
	albedo:      string `json:"albedo"`,
	normal:      string `json:"normal"`,
	height:      string `json:"height"`,
	shadow_mask: string `json:"shadow_mask"`,
	hd_map:      string `json:"hd_map"`,
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
	image:  string,     // the PNG's path: under the assets root, or a plugin's folder
	width:  int,
	height: int,
	frames: []Json_Frame,
}

// Per-level presentation: the scrolling terrain image, the map preview and
// the music track. The simulation knows none of this.
Level_Media :: struct {
	id:         sim.Res_ID,
	campaign:   sim.Plugin_ID, // as the level's sim.Level_Def
	name:       string,
	background: string, // im16 image id
	preview:    string,
	music:      string,
	// Not the original's (D54).
	wind:       Level_Wind,
	water:      Level_Water,
	lighting:   Level_Lighting,
	skybox:     string, // an im16 image id, empty for none
	layers:     Level_Layers,
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
	// A plugin's own sounds are listed too (assets_audio_path).
	sounds: []string,
	// The im16 images and sounds that plugins' content folders bring, by id:
	// where each file is. Ids the core tree already has are not taken, so a
	// plugin adds media and never replaces the original's (D51).
	plugin_images: map[string]string,
	plugin_audio:  map[string]string,
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

	// The game's plates, then each plugin's (extra_defs_load). The game's
	// index gives image paths relative to the assets root, a plugin's
	// relative to its own folder; the plates keep the joined path.
	Index :: struct {
		path, dir: string,
	}
	plates := make([dynamic]Sprite_Plate, 0, 400, allocator)
	indexes := make([dynamic]Index, 0, len(sim.registered_plugins()), context.temp_allocator)
	append(&indexes, Index{strings.concatenate({root, "/sprites/index.json"}, context.temp_allocator), root})
	a.plugin_images = make(map[string]string, allocator)
	a.plugin_audio = make(map[string]string, allocator)
	for i in 1 ..< len(sim.registered_plugins()) {
		if dir, found := plugin_content_dir(sim.Plugin_ID(i)); found {
			append(&indexes, Index{strings.concatenate({dir, "/sprites/index.json"}, context.temp_allocator), dir})
			plugin_media_add(&a.plugin_images, root, "/images/im16/", dir, ".png", allocator)
			plugin_media_add(&a.plugin_audio, root, "/audio/", dir, ".wav", allocator)
		}
	}
	for index in indexes {
		idx: Json_Sprite_Index
		if !read_json(index.path, &idx, context.temp_allocator) {
			continue
		}
		for s in idx.sprites {
			frames := make([]Json_Frame, len(s.frames), allocator)
			copy(frames, s.frames)
			append(&plates, Sprite_Plate {
				id     = sim.res_id_lower(sim.res_id(s.fourcc)),
				image  = strings.concatenate({index.dir, "/", s.image}, allocator),
				width  = s.width,
				height = s.height,
				frames = frames,
			})
		}
	}
	if len(plates) > 0 {
		a.sprites = plates[:]
	}

	// Each level's media: the original's, from Classic Levels, then each
	// campaign plugin's. Classic Levels' images are found as a plugin's are.
	media := make([dynamic]Level_Media, 0, 12, allocator)
	if dir, found := classic_levels_dir(); found {
		level_media_append(&media, dir, sim.CORE, allocator)
		plugin_media_add(&a.plugin_images, root, "/images/im16/", dir, ".png", allocator)
	}
	for i in 1 ..< len(sim.registered_plugins()) {
		if sim.registered_plugins()[i].name == CLASSIC_LEVELS {
			continue
		}
		if dir, found := plugin_content_dir(sim.Plugin_ID(i)); found {
			level_media_append(&media, dir, sim.Plugin_ID(i), allocator)
		}
	}
	a.levels = media[:]

	exclude := make(map[string]bool, len(a.levels), context.temp_allocator)
	for lv in a.levels {
		if lv.music != "" && lv.music != "none" {
			exclude[lv.music] = true
		}
	}
	// The menus' "Interface Music Loop" streams as music too
	// (render/assets.odin's MENU_MUSIC); decoding its ~60s into memory as a
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
	core_sounds := len(sounds)
	for id in a.plugin_audio {
		if !exclude[id] {
			append(&sounds, id)
		}
	}
	slice.sort(sounds[core_sounds:]) // map order is not stable
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

// A level's media, by its campaign and id.
assets_level_media :: proc(a: ^Assets, campaign: sim.Plugin_ID, id: sim.Res_ID) -> ^Level_Media {
	for &l in a.levels {
		if l.campaign == campaign && l.id == id {
			return &l
		}
	}
	return nil
}

@(private = "file")
level_media_append :: proc(media: ^[dynamic]Level_Media, dir: string, campaign: sim.Plugin_ID, allocator := context.allocator) {
	for path in record_paths(dir, "levels", context.temp_allocator) {
		lv := Json_Level{lighting = LIGHTING_MEASURED}
		if !read_json(path, &lv, context.temp_allocator) {
			continue
		}
		layers := lv.layers
		for &l in ([]^string{&layers.albedo, &layers.normal, &layers.height, &layers.shadow_mask, &layers.hd_map}) {
			l^ = strings.clone(l^, allocator)
		}
		append(media, Level_Media {
			id         = sim.res_id(lv.id),
			campaign   = campaign,
			name       = strings.clone(lv.name, allocator),
			background = strings.clone(lv.background_image, allocator),
			preview    = strings.clone(lv.preview_image, allocator),
			music      = strings.clone(lv.music, allocator),
			wind       = lv.wind,
			water      = lv.water,
			lighting   = lv.lighting,
			skybox     = strings.clone(lv.skybox, allocator),
			layers     = layers,
		})
	}
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
// marks them as new content, whose own keys start `x_` and are read for
// the plugins that registered them.
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
		weapon_keys_fill(&wp, header)
		append(weapons, wp)
	}
}

// The keys plugins registered (sim/def_keys.odin), each by its type; one
// the definition leaves out takes its type's default.
@(private = "file")
weapon_keys_fill :: proc(w: ^sim.Weapon, header: []Tag) {
	for k, i in sim.registered_weapon_keys() {
		w.keys[i] = sim.def_key_default(k.kind)
		v, ok := def_find(header, k.name)
		if !ok {
			continue
		}
		switch k.kind {
		case .Bool:
			b, _ := tag_bool(v)
			sim.weapon_key_set(w, sim.Weapon_Key(i), b)
		case .Int:
			n, _ := tag_int(v)
			sim.weapon_key_set(w, sim.Weapon_Key(i), i32(n))
		case .Float:
			f, _ := tag_float(v)
			sim.weapon_key_set(w, sim.Weapon_Key(i), f32(f))
		case .Id:
			sim.weapon_key_set(w, sim.Weapon_Key(i), sim.Res_ID(def_fourcc(header, k.name)))
		}
	}
}

// The plugins' own content (docs/new-weapons.md): units, weapons and
// sprites in each plugin's content folder (plugin_content_dir), laid out as
// the game's own tree is, for every plugin in the build. Added to `defs`
// after the game's own so no original index moves, and ordered by id rather
// than by plugin, so moving content from one plugin to another renumbers
// nothing. Each weapon records the plugin it came from (Weapon.plugin), and
// `defs.content` the plugins that brought any. Kept out of
// assets_defs_load, which has to match the original exactly. Returns false
// when no plugin has content; the game then plays without it.
extra_defs_load :: proc(defs: ^sim.Defs, allocator := context.allocator) -> (report: Defs_Report, ok: bool) {
	units := make([dynamic]sim.Unit, 0, len(defs.units) + 16, allocator)
	append(&units, ..defs.units)
	weapons := make([dynamic]sim.Weapon, 0, len(defs.weapons) + 4, allocator)
	append(&weapons, ..defs.weapons)
	sprites := make([dynamic]sim.Sprite, 0, len(defs.sprites) + 4, allocator)
	append(&sprites, ..defs.sprites)
	levels := make([dynamic]sim.Level_Def, 0, len(defs.levels), allocator)
	append(&levels, ..defs.levels)
	for i in 1 ..< len(sim.registered_plugins()) {
		dir, found := plugin_content_dir(sim.Plugin_ID(i))
		if !found {
			continue
		}
		// A campaign's levels follow the original's, each campaign's
		// together, as sim.campaign_levels needs (D53). Classic Levels'
		// are the original's, which assets_defs_load read as CORE's.
		if sim.registered_plugins()[i].name != CLASSIC_LEVELS {
			levels_append(&levels, dir, manifest_levels(dir), sim.Plugin_ID(i), allocator)
		}
		units_append(&units, dir, &report, allocator)
		first := len(weapons)
		weapons_append(&weapons, dir, true, &report, allocator)
		for &w in weapons[first:] {
			w.plugin = sim.Plugin_ID(i)
		}
		sprites_append(&sprites, dir, allocator)
		defs.content += {i}
	}
	slice.sort_by(units[len(defs.units):], proc(a, b: sim.Unit) -> bool {return res_id_less(a.id, b.id)})
	slice.sort_by(weapons[len(defs.weapons):], proc(a, b: sim.Weapon) -> bool {return res_id_less(a.id, b.id)})
	report.units = len(units) - len(defs.units)
	report.sprites = len(sprites) - len(defs.sprites)
	report.levels = len(levels) - len(defs.levels)
	defs.units, defs.weapons, defs.sprites, defs.levels = units[:], weapons[:], sprites[:], levels[:]
	return report, defs.content != {}
}

// Every `<dir><sub>*<ext>` whose id the core tree (`root`) has no file
// for, into `media` by id. The first plugin with an id keeps it.
plugin_media_add :: proc(media: ^map[string]string, root, sub, dir, ext: string, allocator := context.allocator) {
	paths, err := filepath.glob(strings.concatenate({dir, sub, "*", ext}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return
	}
	slice.sort(paths)
	for path in paths {
		base := filepath.base(path)
		id := base[:len(base) - len(ext)]
		if id in media || os.exists(strings.concatenate({root, sub, base}, context.temp_allocator)) {
			continue
		}
		// Joined as the core tree's paths are, not glob's: on Windows glob
		// gives back `\`, and a plugin's path would differ from a core one
		// in its separators alone (CI's Windows test caught it).
		media[strings.clone(id, allocator)] = strings.concatenate({dir, sub, base}, allocator)
	}
}

// Where an im16 image is: a plugin's, if one brought it, else the core
// tree's.
assets_image_path :: proc(a: ^Assets, id: string) -> string {
	if path, ok := a.plugin_images[id]; ok {
		return path
	}
	return strings.concatenate({a.root, "/images/im16/", id, ".png"}, context.temp_allocator)
}

// Where a sound or music track is, as assets_image_path.
assets_audio_path :: proc(a: ^Assets, id: string) -> string {
	if path, ok := a.plugin_audio[id]; ok {
		return path
	}
	return strings.concatenate({a.root, "/audio/", id, ".wav"}, context.temp_allocator)
}

@(private = "file")
res_id_less :: proc(a, b: sim.Res_ID) -> bool {
	for k in 0 ..< len(a) {
		if a[k] != b[k] {
			return a[k] < b[k]
		}
	}
	return false
}

// A campaign's levels, from `dir`/data/levels, numbered in the order
// `order` names their identifiers. An identifier with no level is skipped.
@(private = "file")
levels_append :: proc(levels: ^[dynamic]sim.Level_Def, dir: string, order: []string, campaign: sim.Plugin_ID, allocator := context.allocator) {
	paths := record_paths(dir, "levels", context.temp_allocator)
	number: i32
	for name in order {
		for path in paths {
			lv: Json_Level
			if !read_json(path, &lv, context.temp_allocator) {
				continue
			}
			if lv.identifier != name {
				continue
			}
			number += 1
			l := sim.Level_Def {
				id         = sim.res_id(lv.id),
				name       = strings.clone(lv.name, allocator),
				identifier = strings.clone(lv.identifier, allocator),
				number     = number,
				campaign   = campaign,
				background = rect_from(Rect{
					left   = lv.background[0],
					top    = lv.background[1],
					right  = lv.background[2],
					bottom = lv.background[3],
				}),
				placements = make([]sim.Placement_Def, len(lv.placements), allocator),
			}
			if lv.start_weapons.air != "" {
				l.start_air = sim.res_id(lv.start_weapons.air)
			}
			if lv.start_weapons.ground != "" {
				l.start_ground = sim.res_id(lv.start_weapons.ground)
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
			mask := strings.concatenate({dir, "/images/im16/", lv.media_mask, ".png"},
				context.temp_allocator)
			if px, mw, mh, ok := media_mask_from_png(mask, allocator); ok {
				l.media, l.media_w, l.media_h = px, i32(mw), i32(mh)
				l.media_scale = (l.background.right - l.background.left) / i32(mw)
			}
			append(levels, l)
			break
		}
	}
}

// Levels, the permanent tables: the rest of assets_defs_load.
@(private = "file")
assets_defs_load_rest :: proc(root: string, defs: ^sim.Defs, report: ^Defs_Report, allocator := context.allocator) {

	// Levels, in play order: the original's, from the Classic Levels plugin.
	levels := make([dynamic]sim.Level_Def, 0, 12, allocator)
	if dir, found := classic_levels_dir(); found {
		levels_append(&levels, dir, manifest_levels(dir), sim.CORE, allocator)
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
