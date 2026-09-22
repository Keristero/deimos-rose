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

Textures :: struct {
	root:    string,
	assets:  data.Assets,
	plates:  map[sim.Res_ID]Plate,
	terrain: map[string]rl.Texture2D, // by im16 image id
}

textures_load :: proc(t: ^Textures, root: string) {
	t.root = strings.clone(root)
	t.assets = data.assets_open(root)
	t.plates = make(map[sim.Res_ID]Plate, len(t.assets.sprites))
	t.terrain = make(map[string]rl.Texture2D)
	for &p in t.assets.sprites {
		path := fmt.ctprintf("%s/%s", root, p.image)
		tex := rl.LoadTexture(path)
		if tex.id == 0 {
			continue
		}
		t.plates[p.id] = Plate{texture = tex, frames = p.frames}
	}
}

textures_unload :: proc(t: ^Textures) {
	for _, p in t.plates {
		rl.UnloadTexture(p.texture)
	}
	for _, tex in t.terrain {
		rl.UnloadTexture(tex)
	}
	delete(t.plates)
	delete(t.terrain)
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
