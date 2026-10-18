package editor_tests

// Importing (D77): one way in for every kind of file, and the music a
// level brings, chosen, undone and taken away. None of it needs the
// original data or a window; exporting it is in export_test.odin.

import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"

import "dr:data"
import "dr:editor"
import "dr:terrain"

// A quarter second of 440 Hz, as Ogg Vorbis and as MP3.
TONE :: "tests/fixtures/audio/tone.ogg"
TONE_MP3 :: "tests/fixtures/audio/tone.mp3"

@(test)
files_go_by_their_kind :: proc(t: ^testing.T) {
	Case :: struct {
		path: string,
		kind: editor.File_Kind,
	}
	for k in ([]Case {
			{"a/b/rock.GLB", .Model},
			{"tree.obj", .Model},
			{"grass.Png", .Image},
			{"theme.ogg", .Audio},
			{"C:\\tunes\\BOSS.MP3", .Audio},
			{"loop.wav", .Audio},
			{"loop.flac", .Unknown},
			{"le07" + terrain.PROJECT_SUFFIX, .Project},
			{"mine" + editor.CAMPAIGN_SUFFIX, .Campaign},
		}) {
		testing.expectf(t, editor.file_kind(k.path) == k.kind, "%s: %v", k.path, editor.file_kind(k.path))
	}
	// The dialog offers what the kind takes.
	testing.expect(t, slice.equal(editor.dialog_filter(.Audio).globs, []string{"*.wav", "*.ogg", "*.mp3"}))
	testing.expect(t, slice.equal(editor.dialog_filter(.Project).globs, []string{"*" + terrain.PROJECT_SUFFIX}))
}

// Imported audio is the level's music, one edit with it: undone, the
// music is what it was and the file is gone; taken away, the music goes
// with it. A name the game or a plugin has already is not taken.
@(test)
music_imports_as_the_levels :: proc(t: ^testing.T) {
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	arena, made := editor.arena_new()
	if !testing.expect(t, made) {
		return
	}
	e.arena = arena
	e.project = terrain.project_make(480, 400, virtual.arena_allocator(arena))
	e.settings = editor.settings_of(&e.project)
	p := &e.project
	tone, _ := os.read_entire_file(TONE, context.temp_allocator)

	id, ok := editor.editor_audio_import(&e, TONE)
	testing.expect(t, ok)
	testing.expect_value(t, id, "tone")
	testing.expect_value(t, p.level.music, "tone")
	if !testing.expect_value(t, len(p.audio), 1) {
		return
	}
	testing.expect_value(t, p.audio[0].ext, ".ogg")
	testing.expect(t, len(tone) > 0 && string(p.audio[0].bytes) == string(tone), "the file is not what was imported")
	testing.expect(t, e.dirty)

	// The same file again is chosen again; another of its name is another.
	id, ok = editor.editor_audio_import(&e, TONE)
	testing.expect(t, ok && id == "tone" && len(p.audio) == 1, "imported twice")
	id, ok = editor.editor_audio_import(&e, TONE_MP3)
	testing.expect_value(t, id, "tone-2")
	testing.expect_value(t, len(p.audio), 2)

	// Not audio, whatever it is called.
	dir_make(OUT)
	junk :: OUT + "/junk.ogg"
	testing.expect(t, os.write_entire_file(junk, transmute([]u8)string("not audio")) == nil)
	_, ok = editor.editor_audio_import(&e, junk)
	testing.expect(t, !ok)
	testing.expect_value(t, len(p.audio), 2)

	// One the plugins have is left to them.
	e.units.assets.plugin_audio = make(map[string]string, context.temp_allocator)
	e.units.assets.plugin_audio["boom"] = "elsewhere/audio/boom.ogg"
	boom :: OUT + "/boom.ogg"
	testing.expect(t, os.write_entire_file(boom, tone) == nil)
	id, _ = editor.editor_audio_import(&e, boom)
	testing.expect_value(t, id, "boom-2")

	// Each import undoes as one, file and music.
	testing.expect(t, editor.editor_undo(&e))
	testing.expect(t, p.level.music == "tone-2" && len(p.audio) == 2, "the first undo")
	testing.expect(t, editor.editor_undo(&e))
	testing.expect(t, editor.editor_undo(&e))
	testing.expect(t, p.level.music == "" && len(p.audio) == 0, "undone to none")
	testing.expect(t, editor.editor_redo(&e))
	testing.expect(t, editor.editor_redo(&e))
	testing.expect(t, p.level.music == "tone-2" && len(p.audio) == 2, "redone")

	// Taken away, the music with it; undone, both back.
	editor.editor_audio_remove(&e, "tone-2")
	testing.expect(t, p.level.music == "" && len(p.audio) == 1, "removed")
	testing.expect(t, editor.editor_undo(&e))
	testing.expect(t, p.level.music == "tone-2" && len(p.audio) == 2, "the removal undone")
	testing.expect_value(t, p.audio[1].ext, ".mp3")
}

// The game's music is Music.pak's, by the names the extraction gave it.
@(test)
the_games_music_is_the_manifests :: proc(t: ^testing.T) {
	dir :: OUT + "/manifest"
	dir_make(dir)
	manifest :: `{"entries": [
		{"fourcc": "ammu", "name": "Ambient Music Loop", "kind": "audio", "source": "Music.pak"},
		{"fourcc": "boom", "name": "Explosion", "kind": "audio", "source": "Audio.pak"},
		{"fourcc": "mu03", "name": "Music 3", "kind": "audio", "source": "Music.pak"},
		{"fourcc": "pict", "name": "Picture", "kind": "image", "source": "Music.pak"}
	]}`
	testing.expect(t, os.write_entire_file(dir + "/manifest.json", transmute([]u8)string(manifest)) == nil)
	music := data.assets_music(dir, context.temp_allocator)
	testing.expect(t, slice.equal(music, []data.Music_Track{{"ammu", "Ambient Music Loop"}, {"mu03", "Music 3"}}), "the tracks")
	testing.expect_value(t, len(data.assets_music(OUT + "/nowhere", context.temp_allocator)), 0)
}
