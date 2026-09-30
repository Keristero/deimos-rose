package tests

import "core:os"
import "core:strings"
import "core:testing"

import "dr:data"
import "dr:plugins/accent"
import "dr:plugins/chaingun"
import "dr:sim"

// A plugin's content sits beside its code (D51): plugins/chaingun/data and
// sprites/, while Accent, all code, has none. Tests run from src/, where
// the plugins root falls back to plugins/.
@(test)
plugin_content_is_in_the_plugins_folder :: proc(t: ^testing.T) {
	dir, found := data.plugin_content_dir(chaingun.ID)
	testing.expect(t, found)
	testing.expect(t, strings.has_suffix(dir, "/chaingun"), dir)
	_, found = data.plugin_content_dir(accent.ID)
	testing.expect(t, !found, "Accent has a content folder")
}

// Every plate's image is a path that loads as it is: a plugin's relative to
// its own folder, the game's under the assets root.
@(test)
plugin_plates_name_their_own_folder :: proc(t: ^testing.T) {
	if !os.exists("assets/sprites/index.json") {
		return
	}
	a := data.assets_open("assets", context.temp_allocator)
	seen := false
	for p in a.sprites {
		testing.expect(t, os.exists(p.image), p.image)
		if p.id == sim.res_id("pl1k") {
			seen = true
			testing.expect(t, strings.has_suffix(p.image, "chaingun/sprites/im08/PL1K.png"), p.image)
		}
	}
	testing.expect(t, seen, "no Chaingun plate")
}

// A plugin's im16 image or sound is found by id, and one the core tree has
// already is left to the core: plugins add media, never replace it.
@(test)
plugin_media_adds_and_never_replaces :: proc(t: ^testing.T) {
	core :: "build/plugin_media_test/core"
	plug :: "build/plugin_media_test/plug"
	for dir in ([]string{core + "/images/im16", plug + "/images/im16", plug + "/audio"}) {
		os.make_directory_all(dir)
	}
	for path in ([]string{core + "/images/im16/back.png", plug + "/images/im16/back.png", plug + "/images/im16/newm.png", plug + "/audio/newt.wav"}) {
		_ = os.write_entire_file(path, []u8{})
	}
	images := make(map[string]string, context.temp_allocator)
	audio := make(map[string]string, context.temp_allocator)
	data.plugin_media_add(&images, core, "/images/im16/", plug, ".png", context.temp_allocator)
	data.plugin_media_add(&audio, core, "/audio/", plug, ".wav", context.temp_allocator)
	testing.expect_value(t, len(images), 1)
	testing.expect_value(t, images["newm"], plug + "/images/im16/newm.png")
	testing.expect_value(t, audio["newt"], plug + "/audio/newt.wav")

	a := data.Assets{root = core, plugin_images = images, plugin_audio = audio}
	testing.expect_value(t, data.assets_image_path(&a, "back"), core + "/images/im16/back.png")
	testing.expect_value(t, data.assets_image_path(&a, "newm"), plug + "/images/im16/newm.png")
	testing.expect_value(t, data.assets_audio_path(&a, "mu03"), core + "/audio/mu03.wav")
}
