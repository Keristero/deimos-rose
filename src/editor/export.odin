package editor

// Export and play (Stage 9 of notes/level-editor-plan.md): a campaign of
// level projects written as a data plugin the game finds and plays (D52,
// D53), and the level open played straight from the editor.
//
// A campaign is a `<name>.drcampaign.json`: the plugin's name, its label
// and words, and its levels' projects in play order. Exporting it checks
// every level first and writes nothing when one is wrong; then, a level a
// step so the window can show how far it is, writes each level's map,
// preview, media mask and record into the plugin's folder, and last its
// plugin.json. The level open is exported as it is in the editor, unsaved
// changes and all.

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "dr:data"
import "dr:prefs"
import "dr:sim"
import "dr:terrain"

CAMPAIGN_FORMAT :: "deimos-rising.campaign"
CAMPAIGN_VERSION :: 1
CAMPAIGN_SUFFIX :: ".drcampaign.json"
// The campaign Play exports the level open as, alone, into a plugins
// folder of its own in the user's data (play_root).
PLAY_CAMPAIGN :: "editor_play"
// Written into the plugin.json the editor makes, so an export never
// writes over a plugin it did not make (classic_levels, say).
MADE_WITH :: "deimos-rising level editor"
// Levels are numbered le01 to le99 in play order.
CAMPAIGN_LEVELS_MAX :: 99

Campaign :: struct {
	name:           string, // the plugin's folder, and its name to the game
	label:          string,
	description:    string,
	plugin_version: string,
	default_on:     bool,
	// The maps through the originals' 15-bit colour, as theirs were stored.
	classic_colour: bool,
	// That no asset in the plugin comes from the originals (the plan's
	// decision 5): export refuses it when one does.
	original_free:  bool,
	// The levels' projects in play order, absolute; saved relative to the
	// campaign file.
	levels:         [dynamic]string,
}

@(private = "file")
Json_Campaign :: struct {
	format:         string   `json:"format"`,
	version:        int      `json:"version"`,
	name:           string   `json:"name"`,
	label:          string   `json:"label"`,
	description:    string   `json:"description"`,
	plugin_version: string   `json:"plugin_version"`,
	default_on:     bool     `json:"default_on"`,
	classic_colour: bool     `json:"classic_colour"`,
	original_free:  bool     `json:"original_free"`,
	levels:         []string `json:"levels"`,
}

// What the game reads of plugin.json (data.Json_Plugin), and what the
// editor adds.
@(private = "file")
Json_Exported :: struct {
	label:         string   `json:"label"`,
	description:   string   `json:"description"`,
	version:       string   `json:"version"`,
	deps:          []string `json:"deps"`,
	default_on:    bool     `json:"default_on"`,
	levels:        []string `json:"levels"`,
	original_free: bool     `json:"original_free"`,
	made_with:     string   `json:"made_with"`,
}

campaign_make :: proc(name: string, allocator := context.allocator) -> Campaign {
	return {name = strings.clone(name, allocator), plugin_version = "1", levels = make([dynamic]string, allocator)}
}

campaign_load :: proc(path: string, allocator := context.allocator) -> (c: Campaign, ok: bool) {
	blob, err := os.read_entire_file(path, context.temp_allocator)
	j: Json_Campaign
	if err != nil || json.unmarshal(blob, &j, allocator = allocator) != nil || j.format != CAMPAIGN_FORMAT || j.version > CAMPAIGN_VERSION {
		return
	}
	c = {j.name, j.label, j.description, j.plugin_version, j.default_on, j.classic_colour, j.original_free, make([dynamic]string, allocator)}
	dir := filepath.dir(absolute(path, context.temp_allocator))
	for l in j.levels {
		append(&c.levels, absolute(filepath.is_abs(l) ? l : strings.concatenate({dir, "/", l}, context.temp_allocator), allocator))
	}
	return c, true
}

// Saves the campaign, its levels relative to the file where they can be.
campaign_save :: proc(c: ^Campaign, path: string) -> bool {
	dir := filepath.dir(absolute(path, context.temp_allocator))
	levels := make([]string, len(c.levels), context.temp_allocator)
	for l, i in c.levels {
		rel, err := filepath.rel(dir, l, context.temp_allocator)
		levels[i] = err == nil ? slashed(rel) : l
	}
	j := Json_Campaign{CAMPAIGN_FORMAT, CAMPAIGN_VERSION, c.name, c.label, c.description, c.plugin_version, c.default_on, c.classic_colour, c.original_free, levels}
	blob, err := json.marshal(j, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	return err == nil && os.write_entire_file(path, blob) == nil
}

// A path with / between its parts, as the campaign file and the export's
// bookkeeping keep them on every system.
slashed :: proc(path: string) -> string {
	s, _ := filepath.replace_separators(path, '/', context.temp_allocator)
	return s
}

// A path made absolute and clean, so two names for one project compare
// equal. Lexical: filepath.abs resolves through the file system, and
// fails for a file not yet saved, as a new campaign's is.
absolute :: proc(path: string, allocator := context.allocator) -> string {
	full := path
	if !filepath.is_abs(path) {
		if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
			full = strings.concatenate({cwd, "/", path}, context.temp_allocator)
		}
	}
	clean, err := filepath.clean(full, context.temp_allocator)
	return strings.clone(err == nil ? clean : full, allocator)
}

// What the folder holds when the campaign is exported where it would be
// by default: the first plugins root, which the game searches.
campaign_default_dir :: proc(c: ^Campaign, allocator := context.allocator) -> string {
	return strings.concatenate({data.plugins_roots()[0], "/", c.name}, allocator)
}

Problem :: struct {
	level: int, // its place in the campaign, or -1 for the campaign's own
	fatal: bool, // nothing is written while there is one
	text:  string,
}

Export_Stage :: enum {
	Check,
	Write,
	Done,
}

// An export under way: Check each level, then Write each, then plugin.json.
Export :: struct {
	arena:       virtual.Arena,
	campaign:    Campaign,
	dir:         string,
	stage:       Export_Stage,
	at:          int, // the level being checked or written
	problems:    [dynamic]Problem,
	deps:        map[string]bool,
	// Each level's identifier, as checked.
	identifiers: []string,
	// The first original-derived asset found, for the provenance check.
	derived:     string,
	// The files written, so a re-export clears what it no longer makes.
	written:     map[string]bool,
}

// Starts exporting a copy of `c` into `dir`.
export_begin :: proc(x: ^Export, c: ^Campaign, dir: string) {
	x^ = {}
	_ = virtual.arena_init_growing(&x.arena)
	a := virtual.arena_allocator(&x.arena)
	x.campaign = c^
	x.campaign.levels = make([dynamic]string, a)
	append(&x.campaign.levels, ..c.levels[:])
	x.dir = strings.clone(dir, a)
	x.problems = make([dynamic]Problem, a)
	x.deps = make(map[string]bool, a)
	x.written = make(map[string]bool, a)
	x.identifiers = make([]string, len(c.levels), a)
	switch {
	case !data.plugin_name_valid(c.name):
		// The game's own rule: it passes over any other folder.
		problem(x, -1, true, "The campaign's name, %q, is its folder: lower case letters, digits and _ only", c.name)
	case c.name == data.CLASSIC_LEVELS:
		problem(x, -1, true, "%s is the original's campaign: name it something else", c.name)
	}
	if len(c.levels) == 0 {
		problem(x, -1, true, "The campaign has no levels")
	} else if len(c.levels) > CAMPAIGN_LEVELS_MAX {
		problem(x, -1, true, "A campaign has at most %d levels", CAMPAIGN_LEVELS_MAX)
	}
	if blob, err := os.read_entire_file(strings.concatenate({dir, "/", data.PLUGIN_MANIFEST}, context.temp_allocator), context.temp_allocator); err == nil {
		j: Json_Exported
		if json.unmarshal(blob, &j, allocator = context.temp_allocator) != nil || j.made_with != MADE_WITH {
			problem(x, -1, true, "%s holds a plugin the editor did not make: export somewhere else", dir)
		}
	}
	if c.label == "" {
		problem(x, -1, false, "No label: Level Select shows the name")
	}
	if len(x.problems) > 0 && export_failed(x) {
		x.stage = .Done
	}
}

export_destroy :: proc(x: ^Export) {
	virtual.arena_destroy(&x.arena)
	x^ = {}
}

export_failed :: proc(x: ^Export) -> bool {
	for p in x.problems {
		if p.fatal {
			return true
		}
	}
	return false
}

// How far it is, 0 to 1: each level checked and written.
export_progress :: proc(x: ^Export) -> f32 {
	n := max(len(x.campaign.levels), 1)
	switch x.stage {
	case .Check:
		return f32(x.at) / f32(2 * n)
	case .Write:
		return f32(n + x.at) / f32(2 * n)
	case .Done:
	}
	return 1
}

// One step: a level checked or written, or the plugin's manifest. False
// once it is done, written or not.
export_step :: proc(e: ^Editor, x: ^Export) -> bool {
	switch x.stage {
	case .Done:
		return false
	case .Check:
		if x.at < len(x.campaign.levels) {
			p, arena, ok := project_for(e, x.campaign.levels[x.at])
			if !ok {
				problem(x, x.at, true, "Cannot open %s", x.campaign.levels[x.at])
			} else {
				level_check(e, x, p)
				arena_free(arena)
			}
			x.at += 1
			return true
		}
		identifiers_check(x)
		if x.campaign.original_free && x.derived != "" {
			problem(x, -1, true, "Marked free of the originals, but %s comes from them", x.derived)
		}
		if export_failed(x) {
			x.stage = .Done
			return false
		}
		x.stage, x.at = .Write, 0
		return true
	case .Write:
		if x.at < len(x.campaign.levels) {
			p, arena, ok := project_for(e, x.campaign.levels[x.at])
			if !ok || !level_write(e, x, p) {
				problem(x, x.at, true, "Cannot write %s's files into %s", x.identifiers[x.at], x.dir)
				x.stage = .Done
				arena_free(arena)
				return false
			}
			arena_free(arena)
			x.at += 1
			return true
		}
		if !manifest_write(x) {
			problem(x, -1, true, "Cannot write %s/%s", x.dir, data.PLUGIN_MANIFEST)
		}
		stale_clear(x)
		x.stage = .Done
		return false
	}
	return false
}

// Records a problem with the level at `place`, or -1 for the campaign's
// own, its words kept in the export's memory.
@(private = "file")
problem :: proc(x: ^Export, place: int, fatal: bool, format: string, args: ..any) {
	append(&x.problems, Problem{place, fatal, fmt.aprintf(format, ..args, allocator = virtual.arena_allocator(&x.arena))})
}

// The whole export at once: for the command line and the tests.
export_run :: proc(e: ^Editor, x: ^Export, c: ^Campaign, dir: string) -> bool {
	export_begin(x, c, dir)
	for export_step(e, x) {
	}
	return !export_failed(x)
}

// A level's project: the one open when it is that file, as it is in the
// editor, else loaded into an arena of its own, which arena_free frees.
@(private = "file")
project_for :: proc(e: ^Editor, path: string) -> (p: ^terrain.Project, arena: ^virtual.Arena, ok: bool) {
	if e.has_project && absolute(editor_path(e), context.temp_allocator) == path {
		return &e.project, nil, true
	}
	arena = arena_new() or_return
	p = new(terrain.Project, virtual.arena_allocator(arena))
	if p^, ok = terrain.project_load(path, virtual.arena_allocator(arena)); !ok {
		arena_free(arena)
		return nil, nil, false
	}
	return p, arena, true
}

// What would keep a level from playing, and what it needs: its units and
// start weapons resolve, and the plugins they are from become the
// campaign's dependencies; its width is the game's; its words are there.
@(private = "file")
level_check :: proc(e: ^Editor, x: ^Export, p: ^terrain.Project) {
	a := virtual.arena_allocator(&x.arena)
	place := x.at
	l := &p.level
	x.identifiers[place] = strings.clone(l.identifier, a)
	if l.identifier == "" {
		problem(x, place, true, "Level %d has no identifier (the Level tab)", place + 1)
	}
	who := l.identifier != "" ? l.identifier : fmt.tprintf("Level %d", place + 1)
	if p.width != NEW_WIDTH {
		problem(x, place, true, "%s is %d wide: the game's maps are %d", who, p.width, NEW_WIDTH)
	}
	if l.name == "" {
		problem(x, place, false, "%s has no name: Level Select shows its identifier", who)
	}
	for pl in p.placements {
		u, found := unit_find(&e.units, pl.unit)
		if !found {
			problem(x, place, true, "%s: unit %s at %d, %d is in neither the game nor a plugin", who, pl.unit, pl.x, pl.y)
			continue
		}
		if dep := unit_plugin(&e.units, string(u.id[:])); dep != "" {
			x.deps[strings.clone(dep, a)] = true
		}
	}
	for id in ([2]string{l.start_weapons.air, l.start_weapons.ground}) {
		if id == "" {
			continue
		}
		found := false
		for &w in e.units.defs.weapons {
			if string(w.id[:]) == id {
				found = true
				if w.plugin != sim.CORE {
					x.deps[strings.clone(sim.registered_plugins()[w.plugin].name, a)] = true
				}
			}
		}
		if !found {
			problem(x, place, true, "%s starts with weapon %s, which is in neither the game nor a plugin", who, id)
		}
	}
	if l.music == "" {
		problem(x, place, false, "%s has no music", who)
	} else if e.units.assets.root != "" && !os.exists(data.assets_audio_path(&e.units.assets, l.music)) {
		problem(x, place, false, "%s's music, %s, is not in the game or a plugin", who, l.music)
	}
	if l.skybox != "" && e.units.assets.root != "" && !os.exists(data.assets_image_path(&e.units.assets, l.skybox)) {
		problem(x, place, false, "%s's sky, %s, is not in the game or a plugin", who, l.skybox)
	}
	if p.length < terrain.PREVIEW_CROP_HEIGHT {
		problem(x, place, false, "%s is shorter than its preview: the preview repeats its top row", who)
	}
	if x.derived == "" {
		if d := derived_asset(p); d != "" {
			x.derived = fmt.aprintf("%s's %s", who, d, allocator = a)
		}
	}
}

// An identifier is what -level and the manifest name a level by: each
// one once.
@(private = "file")
identifiers_check :: proc(x: ^Export) {
	for id, i in x.identifiers {
		for other in x.identifiers[:i] {
			if id != "" && id == other {
				problem(x, i, true, "Two levels are both %s: identifiers are unique in a campaign", id)
				break
			}
		}
	}
}

// Something in the project that comes from the originals, or "": a
// material or model tagged so, or a layer only the recovery tools bake
// from the original maps (tools/terrain_recover, terrain_occlusion): the
// editor makes no colour, water colour or occlusion layer of its own.
derived_asset :: proc(p: ^terrain.Project) -> string {
	tagged :: proc(tags: []string) -> bool {
		return slice.contains(tags, "original-derived")
	}
	for m in p.materials {
		if tagged(m.tags) {
			return fmt.tprintf("material %s", m.name)
		}
	}
	for m in p.models {
		if tagged(m.tags) {
			return fmt.tprintf("model %s", m.name)
		}
	}
	switch {
	case p.albedo != nil:
		return "colour layer"
	case p.water != nil:
		return "water layer"
	case p.occlusion != nil:
		return "occlusion layer"
	}
	return ""
}

unit_find :: proc(c: ^Catalogue, id: string) -> (u: ^sim.Unit, found: bool) {
	for &u in c.defs.units {
		if string(u.id[:]) == id {
			return &u, true
		}
	}
	return nil, false
}

// The data plugin a unit is from, or "" for the game's own: units do not
// record it, but each is a record in its plugin's content folder.
@(private = "file")
unit_plugin :: proc(c: ^Catalogue, id: string) -> string {
	file := strings.concatenate({"/data/unde/", id, ".json"}, context.temp_allocator)
	if c.assets.root != "" && os.exists(strings.concatenate({c.assets.root, file}, context.temp_allocator)) {
		return ""
	}
	for i in 1 ..< len(sim.registered_plugins()) {
		if dir, found := data.plugin_content_dir(sim.Plugin_ID(i)); found && os.exists(strings.concatenate({dir, file}, context.temp_allocator)) {
			return sim.registered_plugins()[i].name
		}
	}
	return ""
}

// A level's id in the campaign: le01 for the first.
level_id :: proc(place: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("le%02d", place + 1, allocator = allocator)
}

// Its images' ids. im16 ids are one namespace across every plugin, the
// first plugin's winning (data.plugin_media_add), so they carry the
// campaign's name.
level_image :: proc(campaign: string, place: int, what: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s_%s_%s", campaign, level_id(place), what, allocator = allocator)
}

// The level's map, preview and media mask as im16 images, and its record.
@(private = "file")
level_write :: proc(e: ^Editor, x: ^Export, p: ^terrain.Project) -> bool {
	c := &x.campaign
	place := x.at
	images := strings.concatenate({x.dir, "/images/im16"}, context.temp_allocator)
	levels := strings.concatenate({x.dir, "/data/levels"}, context.temp_allocator)
	os.make_directory_all(images)
	os.make_directory_all(levels)

	r: terrain.Renderer
	own := p != &e.project
	if own && !terrain.renderer_init(&r, p) {
		return false
	}
	defer if own {
		terrain.renderer_destroy(&r)
	}
	pic, ok := terrain.render(own ? &r : &e.renderer, p, {output = .Lit, quantise_1555 = c.classic_colour}, context.temp_allocator)
	if !ok {
		return false
	}
	preview := terrain.preview_make(pic, terrain.preview_crop_clamp(p.preview, p.width, p.length), context.temp_allocator)
	mask := terrain.media_mask_make(p, context.temp_allocator)
	l := p.level
	l.id = level_id(place)
	l.background = {0, 0, p.width, p.length}
	l.background_image = level_image(c.name, place, "map")
	l.preview_image = level_image(c.name, place, "preview")
	l.media_mask = level_image(c.name, place, "mask")
	l.placements = p.placements[:]
	if l.name == "" {
		l.name = l.identifier
	}
	for img in ([3]struct {
			id:  string,
			pic: terrain.Picture,
		}{{l.background_image, pic}, {l.preview_image, preview}, {l.media_mask, mask}}) {
		path := strings.concatenate({images, "/", img.id, ".png"}, context.temp_allocator)
		if !terrain.png_write(path, img.pic) {
			return false
		}
		x.written[strings.clone(slashed(path), virtual.arena_allocator(&x.arena))] = true
	}
	blob, err := json.marshal(l, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	path := strings.concatenate({levels, "/", l.id, ".json"}, context.temp_allocator)
	if err != nil || os.write_entire_file(path, blob) != nil {
		return false
	}
	x.written[strings.clone(slashed(path), virtual.arena_allocator(&x.arena))] = true
	return true
}

@(private = "file")
manifest_write :: proc(x: ^Export) -> bool {
	c := &x.campaign
	deps := make([dynamic]string, context.temp_allocator)
	for d in x.deps {
		if d != c.name {
			append(&deps, d)
		}
	}
	slice.sort(deps[:])
	j := Json_Exported {
		label         = c.label != "" ? c.label : c.name,
		description   = c.description,
		version       = c.plugin_version != "" ? c.plugin_version : "1",
		deps          = deps[:],
		default_on    = c.default_on,
		levels        = x.identifiers,
		original_free = c.original_free,
		made_with     = MADE_WITH,
	}
	blob, err := json.marshal(j, {pretty = true, use_spaces = true, spaces = 4}, context.temp_allocator)
	return err == nil && os.write_entire_file(strings.concatenate({x.dir, "/", data.PLUGIN_MANIFEST}, context.temp_allocator), blob) == nil
}

// What an earlier export wrote that this one did not: the records of
// levels since taken out, which would still be found by identifier, and
// their images. Only the editor's own files, in a folder it made.
@(private = "file")
stale_clear :: proc(x: ^Export) {
	sweep :: proc(x: ^Export, pattern: string) {
		paths, err := filepath.glob(pattern, context.temp_allocator)
		if err != nil {
			return
		}
		for path in paths {
			if !(slashed(path) in x.written) {
				os.remove(path)
			}
		}
	}
	sweep(x, strings.concatenate({x.dir, "/data/levels/le[0-9][0-9].json"}, context.temp_allocator))
	sweep(x, strings.concatenate({x.dir, "/images/im16/", x.campaign.name, "_le[0-9][0-9]_*.png"}, context.temp_allocator))
}

// Where Play exports to: a plugins folder of its own in the user's data,
// which the game is told of with -plugins.
play_root :: proc(allocator := context.allocator) -> string {
	dir := prefs.user_data_path("editor-play", allocator)
	return dir != "" ? dir : strings.clone("editor-play", allocator)
}

// The game, beside the editor: deimos-editor and deimos are built and
// shipped side by side.
game_path :: proc(allocator := context.allocator) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		dir = "."
	}
	return strings.concatenate({dir, "/deimos", ODIN_OS == .Windows ? ".exe" : ""}, allocator)
}

// Starts exporting the level open alone, as PLAY_CAMPAIGN, into
// play_root.
play_begin :: proc(e: ^Editor, x: ^Export) {
	c := campaign_make(PLAY_CAMPAIGN, context.temp_allocator)
	c.label = "Editor play"
	append(&c.levels, absolute(editor_path(e), context.temp_allocator))
	export_begin(x, &c, strings.concatenate({play_root(context.temp_allocator), "/", PLAY_CAMPAIGN}, context.temp_allocator))
}

// The same, all at once. False when the level cannot be played yet: the
// problems are in `x`.
play_export :: proc(e: ^Editor, x: ^Export) -> bool {
	play_begin(e, x)
	for export_step(e, x) {
	}
	return !export_failed(x)
}

// The game's command line to play the level just exported from map row
// `row`.
play_command :: proc(e: ^Editor, row: int, allocator := context.temp_allocator) -> []string {
	return slice.clone([]string{game_path(allocator), "-plugins", play_root(allocator), "-campaign", PLAY_CAMPAIGN, "-level", strings.clone(e.project.level.identifier, allocator), "-row", fmt.aprint(row, allocator = allocator)}, allocator)
}

// Where the game's view should start for the editor's: its bottom where
// the editor's is, so what the player meets first is what was in view.
play_row :: proc(e: ^Editor, view_rows: f32) -> int {
	h := sim.view_height(&e.units.defs)
	if h <= 0 {
		h = 480
	}
	return clamp(int(e.view.row + view_rows) - int(h), 0, max(e.project.length - int(h), 0))
}
