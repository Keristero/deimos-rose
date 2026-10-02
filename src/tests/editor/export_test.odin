package editor_tests

// Export and play (Stage 9): a campaign of projects written as a plugin
// the game reads, and what keeps one from being written. The checks run
// anywhere; writing renders the maps, so those cases run in editor_draws's
// window.

import "core:encoding/json"
import "core:image/png"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "dr:data"
import "dr:editor"
import "dr:terrain"

@(private = "file")
EXPORT :: OUT + "/export"

// A level the game can play: its width, ground at 20, and a lake from row
// 200 to 400 under water at 10.
@(private = "file")
lake :: proc(identifier: string, length: int, allocator := context.allocator) -> terrain.Project {
	p := terrain.project_make(editor.NEW_WIDTH, length, allocator)
	for &h, i in p.heights {
		row := i / p.width
		h = row >= 200 && row < 400 ? 4 : 20
	}
	append(&p.materials, editor.NEW_MATERIAL)
	p.level.water = editor.NEW_WATER
	p.level.water.height = 10
	p.level.identifier, p.level.name = identifier, identifier
	return p
}

// Saves `p` as EXPORT/<dir>/<file>.drproj.json, and gives its absolute
// path, as a campaign holds it.
@(private = "file")
saved :: proc(t: ^testing.T, p: ^terrain.Project, dir, file: string) -> string {
	folder := strings.concatenate({EXPORT, "/", dir}, context.temp_allocator)
	dir_make(folder)
	path := strings.concatenate({folder, "/", file, terrain.PROJECT_SUFFIX}, context.temp_allocator)
	testing.expect(t, terrain.project_save(p, path))
	return editor.absolute(path, context.temp_allocator)
}

@(private = "file")
fatal_with :: proc(x: ^editor.Export, text: string) -> bool {
	for p in x.problems {
		if p.fatal && strings.contains(p.text, text) {
			return true
		}
	}
	return false
}

// Each thing that would keep a level from playing is reported, and with
// one, nothing is written.
@(test)
export_refuses_what_cannot_play :: proc(t: ^testing.T) {
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)

	good := lake("Good", 1000, context.temp_allocator)
	good_path := saved(t, &good, "refused", "good")
	nameless := lake("", 1000, context.temp_allocator)
	narrow := terrain.project_make(120, 1000, context.temp_allocator)
	narrow.level.identifier = "Narrow"
	stranger := lake("Stranger", 1000, context.temp_allocator)
	append(&stranger.placements, data.Json_Placement{unit = "zzzz", layer = "grnd", x = 100, y = 500})
	weaponed := lake("Weaponed", 1000, context.temp_allocator)
	weaponed.level.start_weapons.air = "zzzz"
	copied := hills(editor.NEW_WIDTH, 1000, context.temp_allocator)
	copied.level.identifier = "Copied"

	Case :: struct {
		levels: []string,
		name:   string,
		free:   bool,
		text:   string,
	}
	cases := []Case {
		{{good_path, saved(t, &good, "refused", "good_again")}, "fixture_export", false, "Two levels are both Good"},
		{{saved(t, &nameless, "refused", "nameless")}, "fixture_export", false, "has no identifier"},
		{{saved(t, &narrow, "refused", "narrow")}, "fixture_export", false, "120 wide"},
		{{saved(t, &stranger, "refused", "stranger")}, "fixture_export", false, "unit zzzz"},
		{{saved(t, &weaponed, "refused", "weaponed")}, "fixture_export", false, "weapon zzzz"},
		{{saved(t, &copied, "refused", "copied")}, "fixture_export", true, "colour layer comes from them"},
		{{good_path}, "Bad-Name", false, "lower case letters, digits and _ only"},
		{{good_path}, data.CLASSIC_LEVELS, false, "the original's campaign"},
		{{}, "fixture_export", false, "no levels"},
		{{EXPORT + "/refused/missing.drproj.json"}, "fixture_export", false, "Cannot open"},
	}
	dir :: EXPORT + "/refused/plugins/fixture_export"
	os.remove_all(EXPORT + "/refused/plugins")
	for k in cases {
		c := editor.campaign_make(k.name, context.temp_allocator)
		c.label, c.original_free = "Refused", k.free
		append(&c.levels, ..k.levels)
		x: editor.Export
		testing.expectf(t, !editor.export_run(&e, &x, &c, dir), "%v: exported", k.text)
		testing.expectf(t, fatal_with(&x, k.text), "%v: not reported in %v", k.text, x.problems)
		editor.export_destroy(&x)
		testing.expectf(t, !os.exists(dir), "%v: written", k.text)
	}

	// A folder holding a plugin the editor did not make is left alone.
	theirs :: EXPORT + "/refused/plugins/foreign"
	dir_make(theirs)
	manifest :: `{"label": "Someone else's"}`
	testing.expect(t, os.write_entire_file(theirs + "/plugin.json", transmute([]u8)string(manifest)) == nil)
	c := editor.campaign_make("foreign", context.temp_allocator)
	append(&c.levels, good_path)
	x: editor.Export
	testing.expect(t, !editor.export_run(&e, &x, &c, theirs))
	testing.expect(t, fatal_with(&x, "did not make"))
	editor.export_destroy(&x)
	after, _ := os.read_entire_file(theirs + "/plugin.json", context.temp_allocator)
	testing.expect_value(t, string(after), manifest)
	testing.expect(t, !os.exists(theirs + "/data"))
}

// A campaign file keeps its levels relative to itself, so it moves with
// them, and opens with them absolute again.
@(test)
campaign_file_round_trips :: proc(t: ^testing.T) {
	p := lake("Alpha", 1000, context.temp_allocator)
	a := saved(t, &p, "round/levels", "alpha")
	c := editor.campaign_make("fixture_round", context.temp_allocator)
	c.label, c.description, c.plugin_version = "Round", "Two of one", "3"
	c.default_on, c.classic_colour, c.original_free = true, true, true
	append(&c.levels, a, a)
	path :: EXPORT + "/round/round" + editor.CAMPAIGN_SUFFIX
	testing.expect(t, editor.campaign_save(&c, path))
	blob, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, strings.contains(string(blob), `"levels/alpha.drproj.json"`), "not relative: %s", blob)

	d, ok := editor.campaign_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, d.name, c.name)
	testing.expect_value(t, d.label, c.label)
	testing.expect_value(t, d.description, c.description)
	testing.expect_value(t, d.plugin_version, c.plugin_version)
	testing.expect(t, d.default_on && d.classic_colour && d.original_free)
	testing.expectf(t, slice.equal(d.levels[:], c.levels[:]), "the levels differ: %v, %v", d.levels, c.levels)

	_, ok = editor.campaign_load(EXPORT + "/round/levels/alpha.drproj.json", context.temp_allocator)
	testing.expect(t, !ok, "a project opened as a campaign")
}

// Play's command line names the level open, and its view starts where
// the editor's is, kept on the map.
@(test)
play_starts_where_the_view_is :: proc(t: ^testing.T) {
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	e.project = lake("Vista", 3600, context.temp_allocator)
	e.has_project = true
	defer e.has_project = false
	cmd := editor.play_command(&e, 1500)
	testing.expect_value(t, len(cmd), 9)
	testing.expect(t, strings.has_prefix(cmd[0], editor.game_path(context.temp_allocator)))
	testing.expect(t, slice.equal(cmd[1:], []string{"-plugins", editor.play_root(context.temp_allocator), "-campaign", editor.PLAY_CAMPAIGN, "-level", "Vista", "-row", "1500"}))
	// With no game data the view is the original's 480 rows.
	e.view.row = 2000
	testing.expect_value(t, editor.play_row(&e, 600), 2120)
	e.view.row = 3400
	testing.expect_value(t, editor.play_row(&e, 600), 3600 - 480)
	e.view.row = -100
	testing.expect_value(t, editor.play_row(&e, 300), 0)
}

// A campaign exported as the game reads it: plugin.json lists the levels
// in play order; each record names its images, which are the map, its
// preview and the water's mask; the level open goes as it is, unsaved
// changes and all. Exported again without a level, that level's files go.
// Draws: called from editor_draws.
export_writes_a_plugin :: proc(t: ^testing.T) {
	os.remove_all(EXPORT + "/written")
	alpha := lake("Alpha", 1000, context.temp_allocator)
	alpha.preview = {0, 0}
	a := saved(t, &alpha, "written", "alpha")
	beta := lake("Beta", 1200, context.temp_allocator)
	beta.level.name = "The Beta"
	b := saved(t, &beta, "written", "beta")

	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, b)) {
		return
	}
	// Unsaved: the open Beta's first 100 rows sunk under the water.
	for &h in e.project.heights[:100 * editor.NEW_WIDTH] {
		h = 0
	}
	terrain.renderer_update(&e.renderer, &e.project, {0, 0, editor.NEW_WIDTH, 100})

	c := editor.campaign_make("fixture_export", context.temp_allocator)
	c.label = "Fixture Export"
	append(&c.levels, a, b)
	dir :: EXPORT + "/written/plugins/fixture_export"
	x: editor.Export
	ok := editor.export_run(&e, &x, &c, dir)
	testing.expectf(t, ok, "not exported: %v", x.problems)
	for p in x.problems {
		testing.expectf(t, strings.contains(p.text, "no music"), "an unexpected problem: %v", p)
	}
	editor.export_destroy(&x)
	if !ok {
		return
	}

	testing.expect(t, data.plugin_name_valid(c.name))
	testing.expect(t, slice.equal(data.manifest_levels(dir), []string{"Alpha", "Beta"}), "plugin.json's levels")
	manifest: struct {
		label:     string,
		made_with: string,
	}
	text, _ := os.read_entire_file(dir + "/plugin.json", context.temp_allocator)
	testing.expect(t, json.unmarshal(text, &manifest, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, manifest.label, "Fixture Export")
	testing.expect_value(t, manifest.made_with, editor.MADE_WITH)

	Want :: struct {
		id, name:  string,
		length:    int,
		sunk_rows: int, // the rows from the top the mask shows water in
	}
	for want in ([]Want{{"le01", "Alpha", 1000, 0}, {"le02", "The Beta", 1200, 100}}) {
		blob, err := os.read_entire_file(strings.concatenate({dir, "/data/levels/", want.id, ".json"}, context.temp_allocator), context.temp_allocator)
		l: data.Json_Level
		if !testing.expectf(t, err == nil && json.unmarshal(blob, &l, allocator = context.temp_allocator) == nil, "%s: no record", want.id) {
			continue
		}
		testing.expect_value(t, l.id, want.id)
		testing.expect_value(t, l.name, want.name)
		testing.expect_value(t, l.background, [4]int{0, 0, editor.NEW_WIDTH, want.length})
		prefix := strings.concatenate({"fixture_export_", want.id, "_"}, context.temp_allocator)
		testing.expect_value(t, l.background_image, strings.concatenate({prefix, "map"}, context.temp_allocator))
		testing.expect_value(t, l.preview_image, strings.concatenate({prefix, "preview"}, context.temp_allocator))
		testing.expect_value(t, l.media_mask, strings.concatenate({prefix, "mask"}, context.temp_allocator))

		image := proc(dir, id: string) -> string {
			return strings.concatenate({dir, "/images/im16/", id, ".png"}, context.temp_allocator)
		}
		size :: proc(path: string) -> [2]int {
			img, err := png.load_from_file(path)
			if err != nil {
				return {}
			}
			defer png.destroy(img)
			return {img.width, img.height}
		}
		testing.expect_value(t, size(image(dir, l.background_image)), [2]int{editor.NEW_WIDTH, want.length})
		testing.expect_value(t, size(image(dir, l.preview_image)), [2]int{terrain.PREVIEW_WIDTH, terrain.PREVIEW_HEIGHT})

		// The mask as the game reads it: 0x001f where the lake is.
		mask, mw, mh, read := data.media_mask_from_png(image(dir, l.media_mask), context.temp_allocator)
		if !testing.expectf(t, read, "%s: no mask", want.id) {
			continue
		}
		C :: terrain.MEDIA_CELL
		testing.expect_value(t, [2]int{mw, mh}, [2]int{editor.NEW_WIDTH / C, want.length / C})
		wrong := 0
		for v, i in mask {
			row := (i / mw) * C
			wet := row < want.sunk_rows || row >= 200 && row < 400
			if (v == 0x001f) != wet {
				wrong += 1
			}
		}
		testing.expectf(t, wrong == 0, "%s: %d mask cells wrong", want.id, wrong)
	}

	// Again with Beta alone, first: its files are le01's, and le02's go.
	clear(&c.levels)
	append(&c.levels, b)
	testing.expect(t, editor.export_run(&e, &x, &c, dir))
	editor.export_destroy(&x)
	testing.expect(t, slice.equal(data.manifest_levels(dir), []string{"Beta"}), "plugin.json's levels")
	testing.expect(t, os.exists(dir + "/data/levels/le01.json"))
	testing.expect(t, os.exists(dir + "/images/im16/fixture_export_le01_mask.png"))
	testing.expect(t, !os.exists(dir + "/data/levels/le02.json"), "le02's record is left")

	// An export runs a step a frame, past the frame it began in, whose
	// temporary memory Play's campaign was made in: what it was begun from
	// is gone, here overwritten, before its first step.
	scratch: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, scratch[:])
	gone := mem.arena_allocator(&arena)
	g := editor.campaign_make("fixture_export", gone)
	g.label = strings.clone("Fixture Export", gone)
	append(&g.levels, strings.clone(a, gone))
	editor.export_begin(&x, &g, dir)
	slice.fill(scratch[:], 0xaa)
	for editor.export_step(&e, &x) {
	}
	testing.expectf(t, !editor.export_failed(&x), "the export held on to its campaign: %v", x.problems)
	editor.export_destroy(&x)
	testing.expect(t, slice.equal(data.manifest_levels(dir), []string{"Alpha"}), "plugin.json's levels")
	for what in ([]string{"map", "preview", "mask"}) {
		testing.expectf(t, !os.exists(strings.concatenate({dir, "/images/im16/fixture_export_le02_", what, ".png"}, context.temp_allocator)), "le02's %s is left", what)
	}
}

// The audio a level brings goes into the plugin with it, its id carrying
// the campaign's name, and the level's too where two levels bring one
// name and different files; and it goes when no level brings it. Draws:
// called from editor_draws.
audio_exports_with_the_level :: proc(t: ^testing.T) {
	os.remove_all(EXPORT + "/audio")
	ogg, _ := os.read_entire_file(TONE, context.temp_allocator)
	mp3, _ := os.read_entire_file(TONE_MP3, context.temp_allocator)
	brings :: proc(p: ^terrain.Project, ext: string, bytes: []u8) {
		append(&p.audio, terrain.Audio_File{"song", ext, bytes})
		p.level.music = "song"
	}
	alpha := lake("Alpha", 1000, context.temp_allocator)
	brings(&alpha, ".ogg", ogg)
	beta := lake("Beta", 1000, context.temp_allocator)
	brings(&beta, ".mp3", mp3)
	gamma := lake("Gamma", 1000, context.temp_allocator)
	brings(&gamma, ".ogg", ogg)
	a, b, g := saved(t, &alpha, "audio", "alpha"), saved(t, &beta, "audio", "beta"), saved(t, &gamma, "audio", "gamma")

	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	c := editor.campaign_make("fixture_audio", context.temp_allocator)
	c.label = "Fixture Audio"
	append(&c.levels, a, b, g)
	dir :: EXPORT + "/audio/plugins/fixture_audio"
	x: editor.Export
	ok := editor.export_run(&e, &x, &c, dir)
	testing.expectf(t, ok && len(x.problems) == 0, "not exported cleanly: %v", x.problems)
	editor.export_destroy(&x)
	if !ok {
		return
	}
	music :: proc(dir, id: string) -> string {
		blob, _ := os.read_entire_file(strings.concatenate({dir, "/data/levels/", id, ".json"}, context.temp_allocator), context.temp_allocator)
		l: data.Json_Level
		_ = json.unmarshal(blob, &l, allocator = context.temp_allocator)
		return l.music
	}
	testing.expect_value(t, music(dir, "le01"), "fixture_audio_song")
	testing.expect_value(t, music(dir, "le02"), "fixture_audio_le02_song")
	testing.expect_value(t, music(dir, "le03"), "fixture_audio_song")
	song, _ := os.read_entire_file(dir + "/audio/fixture_audio_song.ogg", context.temp_allocator)
	testing.expect(t, len(ogg) > 0 && string(song) == string(ogg), "Alpha's song")
	other, _ := os.read_entire_file(dir + "/audio/fixture_audio_le02_song.mp3", context.temp_allocator)
	testing.expect(t, len(mp3) > 0 && string(other) == string(mp3), "Beta's song")

	// The game finds them as a plugin's.
	media: map[string]string
	defer delete(media)
	for ext in data.AUDIO_EXTENSIONS {
		data.plugin_media_add(&media, EXPORT + "/audio/nothing", "/audio/", dir, ext, ".wav", context.temp_allocator)
	}
	testing.expect(t, "fixture_audio_song" in media && "fixture_audio_le02_song" in media, "not a plugin's audio")

	// Again without Beta: its song goes, Alpha's stays.
	clear(&c.levels)
	append(&c.levels, a, g)
	testing.expect(t, editor.export_run(&e, &x, &c, dir))
	editor.export_destroy(&x)
	testing.expect(t, os.exists(dir + "/audio/fixture_audio_song.ogg"))
	testing.expect(t, !os.exists(dir + "/audio/fixture_audio_le02_song.mp3"), "Beta's song is left")
}
