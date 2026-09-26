package render

// Textures, loaded from the assets tree the extractor writes.
//
// One texture per sprite plate (the game has 125) and one per level's terrain
// map. Frames are sub-rectangles of a plate, from the index baked at extract
// time, so nothing is cut or re-packed at runtime.

import "core:fmt"
import "core:math"
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

	// Classic mode: im16 images as the original showed them, through
	// QuickTime's gamma (im16_load). main.odin copies it in every frame.
	quicktime_gamma: bool,
	sounds:  map[sim.Res_ID]Sound_Clip,
	music:   map[string]rl.Music, // by the level's own music id, e.g. "mu03"

	// Preferences' volumes as 0..1, applied at each play (sounds_step,
	// menu_play_sound) and each music_track lookup -- main.odin copies them
	// in every frame, so a change takes effect at once.
	sfx_volume:   f32,
	music_volume: f32,
}

// `audio` is false for a headless run (DR_SHOT): main.odin skips
// InitAudioDevice there, and rl.LoadSound/LoadMusicStream against a
// non-existent device would just fail per call (harmless, but noisy in the
// log and pointless work for frames nothing will ever hear) -- see
// sounds_step and music_track, which no-op cleanly when these maps stay empty.
textures_load :: proc(t: ^Textures, root: string, audio: bool = true) {
	t.root = strings.clone(root)
	t.sfx_volume, t.music_volume = 1, 1
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
	return music_load(t, media.music)
}

// "Interface Music Loop" (inmu, Music.pak -- the name is the one
// assets/manifest.json records for it): the menus' music, ~60s, looped.
MENU_MUSIC :: "inmu"

// Any track by its audio id, loaded on first use; volume follows
// Preferences' music setting on every call.
music_load :: proc(t: ^Textures, id: string) -> (rl.Music, bool) {
	if m, ok := t.music[id]; ok {
		rl.SetMusicVolume(m, t.music_volume)
		return m, true
	}
	m := rl.LoadMusicStream(fmt.ctprintf("%s/audio/%s.wav", t.root, id))
	if m.frameCount == 0 {
		return {}, false
	}
	t.music[id] = m
	rl.SetMusicVolume(m, t.music_volume)
	return m, true
}

// The terrain map for a level, loaded on first use: one 480-wide image as tall
// as the level is long.
terrain_texture :: proc(t: ^Textures, level: sim.Res_ID) -> (rl.Texture2D, bool) {
	media := data.assets_level_media(&t.assets, level)
	if media == nil || media.background == "" || media.background == "none" {
		return {}, false
	}
	return im16_texture(t, &t.terrain, media.background)
}

// The original decodes every TGA (the im16 images: terrain, menu and
// loading backdrops, the score bar) through QuickTime's GraphicsImporter
// (U_Image_LoadInBuffer, 0x44cba0), which gamma-corrects it on the way into
// the 16-bit buffer; its sprites are GIFs (U_Sprite_Load asks for 'GIF '),
// which come through unchanged. Fitted against Wine captures of demo 1 at
// steps 300/900/1500/2100 (oracle:shot), ~1.4M pixel channels of terrain and
// score-bar panel: each 5-bit channel v shows as round(31 * (v/31)^0.75),
// exactly, for every v from 1 to 24 with enough samples to call (1->2, 2->4,
// 4->7, 8->11, 12->15, 17->20, 22->24); sprite pixels (the shield meter)
// match with no curve. It is why the original looks lighter and less
// saturated. QuickTime runs the same code under Wine as on Windows, so this
// is the original's look, not the emulator's -- though that is inferred, not
// checked on a Windows machine.
@(private = "file") QUICKTIME_GAMMA :: 0.75

@(private = "file")
quicktime_gamma_table :: proc() -> (tab: [32]u8) {
	for v in 0 ..< 32 {
		g := u8(math.round(31 * math.pow(f32(v) / 31, QUICKTIME_GAMMA)))
		tab[v] = (g << 3) | (g >> 2) // expanded as data/tga.odin expands
	}
	return
}

// An im16 image, cached in `cache` by id -- with QuickTime's gamma applied
// in classic mode, cached beside the plain one as "<id>@qt".
im16_texture :: proc(t: ^Textures, cache: ^map[string]rl.Texture2D, id: string) -> (rl.Texture2D, bool) {
	key := t.quicktime_gamma ? fmt.tprintf("%s@qt", id) : id
	if tex, ok := cache[key]; ok {
		return tex, tex.id != 0
	}
	img := rl.LoadImage(fmt.ctprintf("%s/images/im16/%s.png", t.root, id))
	if img.data == nil {
		return {}, false
	}
	defer rl.UnloadImage(img)
	if t.quicktime_gamma {
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
		tab := quicktime_gamma_table()
		for &c in ([^]rl.Color)(img.data)[:img.width * img.height] {
			c.r, c.g, c.b = tab[c.r >> 3], tab[c.g >> 3], tab[c.b >> 3]
		}
	}
	tex := rl.LoadTextureFromImage(img)
	if tex.id == 0 {
		return {}, false
	}
	cache[t.quicktime_gamma ? strings.clone(key) : id] = tex
	return tex, true
}

// A full-screen im16 image not tied to any level (menu backgrounds: "back",
// "lese", …), loaded once and cached by name -- the same lazy-load pattern
// terrain_texture uses, minus the per-level media indirection.
// This port's own look for the menu backgrounds (outside classic mode): the
// original's teal recoloured to rose -- each pixel's luminance carried onto
// a rose hue, so the art's detail and brightness survive. ROSE is scaled so
// its own luminance is 1 (0.299*1.40 + 0.587*0.78 + 0.114*1.0 = 1.0).
@(private = "file") ROSE :: [3]f32{1.40, 0.78, 1.0}

// A menu background tinted rose, built from the im16 image the first time
// it is asked for and cached beside the original under "<id>@rose".
menu_image_rose :: proc(t: ^Textures, id: string) -> (rl.Texture2D, bool) {
	key := fmt.tprintf("%s@rose", id)
	if tex, ok := t.images[key]; ok {
		return tex, true
	}
	img := rl.LoadImage(fmt.ctprintf("%s/images/im16/%s.png", t.root, id))
	if img.data == nil {
		return {}, false
	}
	defer rl.UnloadImage(img)
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	pixels := ([^]rl.Color)(img.data)[:img.width * img.height]
	for &c in pixels {
		l := 0.299 * f32(c.r) + 0.587 * f32(c.g) + 0.114 * f32(c.b)
		c.r = u8(min(l * ROSE[0], 255))
		c.g = u8(min(l * ROSE[1], 255))
		c.b = u8(min(l * ROSE[2], 255))
	}
	tex := rl.LoadTextureFromImage(img)
	if tex.id == 0 {
		return {}, false
	}
	t.images[strings.clone(key)] = tex
	return tex, true
}

menu_image :: proc(t: ^Textures, id: string) -> (rl.Texture2D, bool) {
	return im16_texture(t, &t.images, id)
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

// A ship's trim, for the accent hues: the metal that is silver on player
// 1's ship ("pl1?") and gold on player 2's ("pl2?"). A pixel is trim when
// player 1's is grey and player 2's is yellower than it. The weapon's
// colour on the wings and canopy is also different between the pair
// (blue on PL1B, teal on PL2B), but it is not grey, so it stays out.
// Both tests use absolute channel differences, not saturation or summed
// distance: the engines at the back are dark, and there a faint blue cast
// reads as high saturation while gold and silver differ by only a few
// levels, which left them a patchwork of accent and original colour.
// Checked by rendering the mask for all 7 frames (level and banked) of
// all four pairs (B, C, G, O). Each trim pixel keeps player 1's silver
// shading as a grey the accent shader can colour. The mask is soft: its
// alpha ramps with both tests, then is feathered one pixel, so the accent
// blends into the shared shading instead of stopping on a hard, aliased
// edge. Both plates share one layout (394x48 for every pair), so the
// ship's own frame rectangles address it. Built on first use, cached as
// "<id>@trim".
//
// The score bar's ship icon ("play") is the same pair as frames 0 (silver)
// and 1 (gold) of one plate; its trim covers frame 0, for either frame to
// draw over.
SCOREBAR_ICON :: sim.Res_ID{'p', 'l', 'a', 'y'}

ship_trim :: proc(t: ^Textures, sprite: sim.Res_ID) -> (rl.Texture2D, bool) {
	icon := sprite == SCOREBAR_ICON
	if !icon && (sprite[0] != 'p' || sprite[1] != 'l' || (sprite[2] != '1' && sprite[2] != '2')) {
		return {}, false
	}
	name := sprite
	key := fmt.tprintf("%s@trim", string(name[:]))
	if tex, ok := t.images[key]; ok {
		return tex, tex.id != 0
	}
	silver, gold := sprite, sprite
	if !icon {
		silver[2], gold[2] = '1', '2'
	}
	tex := ship_trim_build(t, silver, gold, icon)
	t.images[strings.clone(key)] = tex // cached even when it failed, so it is tried once
	return tex, tex.id != 0
}

// Player 1's chroma (largest channel minus smallest): grey metal below
// TRIM_GREY, weapon colour above TRIM_COLOUR, a ramp between.
@(private = "file") TRIM_GREY :: 40
@(private = "file") TRIM_COLOUR :: 70
// How much yellower player 2's pixel is than player 1's, in yellowness
// min(r, g) - b: none below TRIM_SOFT, certainly gold above TRIM_HARD.
@(private = "file") TRIM_SOFT :: 2
@(private = "file") TRIM_HARD :: 14

@(private = "file")
smooth :: proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private = "file")
ship_trim_build :: proc(t: ^Textures, silver, gold: sim.Res_ID, icon: bool) -> rl.Texture2D {
	path :: proc(t: ^Textures, id: sim.Res_ID) -> cstring {
		for &p in t.assets.sprites {
			if p.id == id {
				return fmt.ctprintf("%s/%s", t.root, p.image)
			}
		}
		return ""
	}
	a := rl.LoadImage(path(t, silver))
	defer rl.UnloadImage(a)
	b := rl.LoadImage(path(t, gold))
	defer rl.UnloadImage(b)
	if a.data == nil || b.data == nil || a.width != b.width || a.height != b.height {
		return {}
	}
	rl.ImageFormat(&a, .UNCOMPRESSED_R8G8B8A8)
	rl.ImageFormat(&b, .UNCOMPRESSED_R8G8B8A8)
	if icon {
		// Gold's frame laid over silver's, so the two line up.
		_, f0, ok0 := frame_rect(t, silver, 0)
		_, f1, ok1 := frame_rect(t, silver, 1)
		if !ok0 || !ok1 {
			return {}
		}
		rl.ImageDrawRectangleRec(&b, f0, {}) // cleared: ImageDraw blends
		rl.ImageDraw(&b, a, f1, f0, rl.WHITE)
	}
	w, h := int(a.width), int(a.height)
	pa := ([^]rl.Color)(a.data)[:w * h]
	pb := ([^]rl.Color)(b.data)[:w * h]

	// How much of each pixel is trim, 0..1.
	mask := make([]f32, w * h)
	defer delete(mask)
	yellow :: proc(c: rl.Color) -> f32 {return f32(min(c.r, c.g)) - f32(c.b)}
	for c, i in pa {
		chroma := f32(max(c.r, c.g, c.b) - min(c.r, c.g, c.b))
		mask[i] = (1 - smooth(TRIM_GREY, TRIM_COLOUR, chroma)) * smooth(TRIM_SOFT, TRIM_HARD, yellow(pb[i]) - yellow(c))
	}
	// Feathered with a 3x3 tent, but never below the pixel's own value, so
	// the trim itself stays solid and only its edge softens outwards.
	// Frames sit side by side on the plate; a ship's alpha is 0 between
	// them, so the feather never carries colour onto a visible neighbour.
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			c := pa[i]
			if c.a == 0 {
				c = {}
				pa[i] = c
				continue
			}
			sum, wsum: f32
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					nx, ny := x + dx, y + dy
					if nx < 0 || ny < 0 || nx >= w || ny >= h {
						continue
					}
					k := f32((2 - abs(dx)) * (2 - abs(dy)))
					sum += mask[ny * w + nx] * k
					wsum += k
				}
			}
			m := max(mask[i], sum / wsum)
			l := u8(0.299 * f32(c.r) + 0.587 * f32(c.g) + 0.114 * f32(c.b))
			pa[i] = {l, l, l, u8(m * f32(c.a))}
		}
	}
	return rl.LoadTextureFromImage(a)
}
