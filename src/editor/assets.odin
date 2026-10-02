package editor

// Bringing files in (D77). One way in for every kind of file: dropped on
// the window, picked in a file dialog, or by a tab's Import button, a file
// goes where its kind says. A model goes into the library, an image
// becomes a material, and audio becomes the level's own, its music. What
// is imported then shows in the asset lists beside the game's own and the
// plugins', each saying where it is from (asset_list.odin).

import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

File_Kind :: enum {
	Unknown,
	Project,
	Campaign,
	Model,
	Image,
	Audio,
}

// Each kind's file names' endings, lower case. The file dialogs offer
// these (dialog_filter). An unknown file is tried as an image.
@(rodata)
MODEL_EXTENSIONS := [?]string{".glb", ".gltf", ".obj"}
@(rodata)
IMAGE_EXTENSIONS := [?]string{".png", ".jpg", ".jpeg", ".bmp", ".tga", ".qoi"}
@(rodata)
AUDIO_EXTENSIONS := data.AUDIO_EXTENSIONS
@(rodata)
PROJECT_EXTENSIONS := [?]string{terrain.PROJECT_SUFFIX}
@(rodata)
CAMPAIGN_EXTENSIONS := [?]string{CAMPAIGN_SUFFIX}

FILE_EXTENSIONS := [File_Kind][]string {
	.Unknown  = nil,
	.Project  = PROJECT_EXTENSIONS[:],
	.Campaign = CAMPAIGN_EXTENSIONS[:],
	.Model    = MODEL_EXTENSIONS[:],
	.Image    = IMAGE_EXTENSIONS[:],
	.Audio    = AUDIO_EXTENSIONS[:],
}

// What `path` is, by its name.
file_kind :: proc(path: string) -> File_Kind {
	lower := strings.to_lower(path, context.temp_allocator)
	for exts, kind in FILE_EXTENSIONS {
		for ext in exts {
			if strings.has_suffix(lower, ext) {
				return kind
			}
		}
	}
	return .Unknown
}

// Takes a file into the editor, by its kind: a project or campaign opens,
// the rest is imported, and the tab that shows it opens. Says what came
// of it. `guard` asks before a project replaces unsaved changes, unless
// that was done when the dialog was asked for.
editor_import :: proc(e: ^Editor, path: string, guard: bool) {
	switch file_kind(path) {
	case .Project:
		if !guard || guarded(e, .Open) {
			open_reporting(e, path)
		}
	case .Campaign:
		campaign_open_reporting(e, path)
		e.tab = c.int(Tab.Campaign)
	case .Model:
		if k := editor_model_import(e, path); k >= 0 {
			e.tab = c.int(Tab.Models)
			editor_message(e, "Model %s imported", e.scenery.library[k].file.name)
		} else {
			editor_message(e, "Cannot read %s as a model", path)
		}
	case .Audio:
		if id, ok := editor_audio_import(e, path); ok {
			e.tab = c.int(Tab.Level)
			editor_message(e, "Music %s imported: the level's music", id)
		} else {
			editor_message(e, "Cannot play %s", path)
		}
	case .Image, .Unknown:
		switch {
		case editor_material_add_file(e, path):
			e.tab = c.int(Tab.Paint)
			editor_message(e, "Material %s added", e.project.materials[len(e.project.materials) - 1].name)
		case len(e.project.materials) >= terrain.MAX_MATERIALS:
			editor_message(e, "A level has at most %d materials", terrain.MAX_MATERIALS)
		case:
			editor_message(e, "Cannot read %s as an image", path)
		}
	}
}

// Imports `path` as audio the level brings and makes it the level's
// music, as one edit. A file with the same name and bytes already
// imported is chosen again, not copied. False when it is not audio the
// game plays.
editor_audio_import :: proc(e: ^Editor, path: string) -> (id: string, ok: bool) {
	p := &e.project
	ext := terrain.audio_extension(path)
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if ext == "" || err != nil || !audio_plays(ext, bytes) {
		return
	}
	name := terrain.audio_name(path, context.temp_allocator)
	id = name
	for n := 2; audio_taken(e, id); n += 1 {
		if k := terrain.audio_find(p, id); k >= 0 && p.audio[k].ext == ext && string(p.audio[k].bytes) == string(bytes) {
			break
		}
		id = fmt.tprintf("%s-%d", name, n)
	}
	if k := terrain.audio_find(p, id); k >= 0 {
		// Only the music changes, as choosing it in the list does.
		p.level.music = p.audio[k].id
		return p.level.music, true
	}
	a := virtual.arena_allocator(e.arena)
	editor_audio_change(e)
	append(&p.audio, terrain.Audio_File{strings.clone(id, a), ext, slice.clone(bytes, a)})
	p.level.music = p.audio[len(p.audio) - 1].id
	e.settings = settings_of(p)
	return p.level.music, true
}

// Takes the level's own audio `id` away, and the level's music with it
// when it was that, as one edit.
editor_audio_remove :: proc(e: ^Editor, id: string) {
	p := &e.project
	k := terrain.audio_find(p, id)
	if k < 0 {
		return
	}
	editor_audio_change(e)
	if p.level.music == id {
		p.level.music = ""
	}
	ordered_remove(&p.audio, k)
	e.settings = settings_of(p)
}

// Before the level's audio changes: what it was, and the settings, kept
// to undo as one.
@(private = "file")
editor_audio_change :: proc(e: ^Editor) {
	level_panel_leave(e)
	editor_settings_settle(e, false)
	listen_stop(&e.level_panel)
	history_audio(&e.history, e.settings, e.project.audio[:])
	e.dirty = true
}

// Whether raylib, as the game is built, decodes it.
audio_plays :: proc(ext: string, bytes: []u8) -> bool {
	if len(bytes) == 0 {
		return false
	}
	w := rl.LoadWaveFromMemory(strings.clone_to_cstring(ext, context.temp_allocator), raw_data(bytes), c.int(len(bytes)))
	defer rl.UnloadWave(w)
	return w.frameCount > 0
}

// Whether `id` is an audio id already: the game's, a plugin's, or the
// level's own. The game finds the first of them.
@(private = "file")
audio_taken :: proc(e: ^Editor, id: string) -> bool {
	a := &e.units.assets
	return terrain.audio_find(&e.project, id) >= 0 || id in a.plugin_audio || (a.root != "" && os.exists(data.assets_audio_path(a, id)))
}
