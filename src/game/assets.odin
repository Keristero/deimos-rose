package game

// Textures, loaded from the assets tree the extractor writes.
//
// One texture per sprite plate (the game has 125) and one per level's terrain
// map. Frames are sub-rectangles of a plate, from the index baked at extract
// time, so nothing is cut or re-packed at runtime.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

Plate :: struct {
	texture: rl.Texture2D,
	frames:  []data.Json_Frame,
}

// A handful of independent playback handles sharing one clip's sample data
// (rl.LoadSoundAlias), so a retrigger while the clip is already sounding
// layers instead of cutting the earlier instance off. The original instead
// caches one handle per playing sound and steals the lowest-priority one
// when its channel budget is full (FUN_0044fab0); raylib/miniaudio mixes far
// more simultaneous voices than that budget, so channel stealing by
// priority is not reproduced -- see sounds_step.
SOUND_VOICES :: 3

Sound_Clip :: struct {
	voices: [SOUND_VOICES]rl.Sound,
	next:   int,
}

Textures :: struct {
	root:    string,
	assets:  data.Assets,
	plates:  map[sim.Res_ID]Plate,
	terrain: map[string]rl.Texture2D, // by im16 image id
	images:  map[string]rl.Texture2D, // by im16 image id -- menu backgrounds, not level-tied
	sounds:  map[sim.Res_ID]Sound_Clip,
	music:   map[string]rl.Music, // by the level's own music id, e.g. "mu03"
}

// `audio` is false for a headless run (DR_SHOT): main.odin skips
// InitAudioDevice there, and rl.LoadSound/LoadMusicStream against a
// non-existent device would just fail per call (harmless, but noisy in the
// log and pointless work for frames nothing will ever hear) -- see
// sounds_step and music_track, which no-op cleanly when these maps stay empty.
textures_load :: proc(t: ^Textures, root: string, audio: bool = true) {
	t.root = strings.clone(root)
	t.assets = data.assets_open(root)
	t.plates = make(map[sim.Res_ID]Plate, len(t.assets.sprites))
	t.terrain = make(map[string]rl.Texture2D)
	t.images = make(map[string]rl.Texture2D)
	for &p in t.assets.sprites {
		path := fmt.ctprintf("%s/%s", root, p.image)
		tex := rl.LoadTexture(path)
		if tex.id == 0 {
			continue
		}
		t.plates[p.id] = Plate{texture = tex, frames = p.frames}
	}

	t.sounds = make(map[sim.Res_ID]Sound_Clip, audio ? len(t.assets.sounds) : 0)
	if audio {
		for id in t.assets.sounds {
			path := fmt.ctprintf("%s/audio/%s.wav", root, id)
			snd := rl.LoadSound(path)
			if snd.frameCount == 0 {
				continue
			}
			clip: Sound_Clip
			clip.voices[0] = snd
			for i in 1 ..< SOUND_VOICES {
				clip.voices[i] = rl.LoadSoundAlias(snd)
			}
			t.sounds[sim.res_id(id)] = clip
		}
	}
	t.music = make(map[string]rl.Music)
}

textures_unload :: proc(t: ^Textures) {
	for _, p in t.plates {
		rl.UnloadTexture(p.texture)
	}
	for _, tex in t.terrain {
		rl.UnloadTexture(tex)
	}
	for _, tex in t.images {
		rl.UnloadTexture(tex)
	}
	for _, clip in t.sounds {
		for i in 1 ..< SOUND_VOICES {
			rl.UnloadSoundAlias(clip.voices[i])
		}
		rl.UnloadSound(clip.voices[0])
	}
	for _, m in t.music {
		rl.UnloadMusicStream(m)
	}
	delete(t.plates)
	delete(t.terrain)
	delete(t.images)
	delete(t.sounds)
	delete(t.music)
}

// The level's music track (Level_Media.music), loaded on first use and
// looped -- raylib's LoadMusicStream defaults Music.looping to true, which
// matches a level's track outlasting the level (mu03 alone runs ~196s).
music_track :: proc(t: ^Textures, level: sim.Res_ID) -> (rl.Music, bool) {
	media := data.assets_level_media(&t.assets, level)
	if media == nil || media.music == "" || media.music == "none" {
		return {}, false
	}
	if m, ok := t.music[media.music]; ok {
		return m, true
	}
	path := fmt.ctprintf("%s/audio/%s.wav", t.root, media.music)
	m := rl.LoadMusicStream(path)
	if m.frameCount == 0 {
		return {}, false
	}
	t.music[media.music] = m
	return m, true
}

// The terrain map for a level, loaded on first use: one 480-wide image as tall
// as the level is long.
terrain_texture :: proc(t: ^Textures, level: sim.Res_ID) -> (rl.Texture2D, bool) {
	media := data.assets_level_media(&t.assets, level)
	if media == nil || media.background == "" || media.background == "none" {
		return {}, false
	}
	if tex, ok := t.terrain[media.background]; ok {
		return tex, true
	}
	path := fmt.ctprintf("%s/images/im16/%s.png", t.root, media.background)
	tex := rl.LoadTexture(path)
	if tex.id == 0 {
		return {}, false
	}
	t.terrain[media.background] = tex
	return tex, true
}

// A full-screen im16 image not tied to any level (menu backgrounds: "back",
// "lese", …), loaded once and cached by name -- the same lazy-load pattern
// terrain_texture uses, minus the per-level media indirection.
menu_image :: proc(t: ^Textures, id: string) -> (rl.Texture2D, bool) {
	if tex, ok := t.images[id]; ok {
		return tex, true
	}
	path := fmt.ctprintf("%s/images/im16/%s.png", t.root, id)
	tex := rl.LoadTexture(path)
	if tex.id == 0 {
		return {}, false
	}
	t.images[id] = tex
	return tex, true
}

// The frame rectangle within a plate, or nothing when the sprite or frame is
// missing. A state may name a frame the plate does not have; the original
// draws nothing in that case rather than failing.
frame_rect :: proc(t: ^Textures, sprite: sim.Res_ID, frame: i32) -> (rl.Texture2D, rl.Rectangle, bool) {
	p, ok := t.plates[sprite]
	if !ok || frame < 0 || int(frame) >= len(p.frames) {
		return {}, {}, false
	}
	f := p.frames[frame]
	return p.texture, {f32(f.x), f32(f.y), f32(f.w), f32(f.h)}, true
}
