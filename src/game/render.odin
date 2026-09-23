package game

// Compositing a frame the way the original does.
//
// Every drawable pushes sprites into one of sixteen layer lists, and the frame
// is then assembled in three groups with the terrain and the particles between
// them (G_GameInterface::Draw):
//
//     layers 0-1  ->  terrain  ->  layers 2-5  ->  particles  ->  layers 6-15
//
// Within a layer, insertion order. The layer comes from the object's
// drawLayer_ID, mapped in G_GameObject::Priv_Draw.
//
// What is reproduced is that ordering, not the 16-bit blitter: raylib draws
// the same frames, at the same places, in the same sequence.

import "core:fmt"

import rl "vendor:raylib"

import "dr:sim"

LAYERS :: 16

// U_Display::Init hardcodes the screen to 640x480 and centres a 576-wide
// front buffer (the 416-wide play field plus a 160-wide score bar panel,
// im16 "scor") inside it, leaving a 32px black margin on each side --
// confirmed against a real screenshot of the running original
// (work/wine/cmp/orig-00900.png: the panel is exactly scor.png's own 160x480,
// and 32+416+160+32 = 640), not derived from U_Display::Init's offset
// arithmetic, which is a maze of raw struct offsets not worth transliterating.
VIEW_X :: 32
SCOREBAR_W :: 160
SCOREBAR_X :: VIEW_X + PLAY_W

// G_GameObject::Priv_Draw's switch on drawLayer_ID. "defa" splits by whether
// the object is in the air; an empty or "none" layer is treated as "defa".
layer_of :: proc "contextless" (id: sim.Res_ID, is_air: bool) -> int {
	switch id {
	case sim.res_id("grou"):
		return 3
	case sim.res_id("grhi"):
		return 5
	case sim.res_id("ailo"):
		return 7
	case sim.res_id("aihi"):
		return 8
	case sim.res_id("plwe"):
		return 9
	case sim.res_id("play"):
		return 10
	case sim.res_id("plsh"):
		return 11
	case sim.res_id("plef"):
		return 12
	case sim.res_id("plui"):
		return 13
	case sim.res_id("atmo"):
		return 14
	case sim.res_id("hud "):
		return 15
	}
	return is_air ? 7 : 3 // "defa"
}

// G_GameObject::Priv_DrawShadow picks its own, lower layer.
shadow_layer_of :: proc "contextless" (id: sim.Res_ID, is_air: bool) -> int {
	switch id {
	case sim.res_id("grou"):
		return 2
	case sim.res_id("grhi"):
		return 4
	case sim.res_id("hud "), sim.res_id("plwe"), sim.res_id("plef"),
	     sim.res_id("plsh"), sim.res_id("aihi"):
		return 6
	}
	return is_air ? 6 : 2
}

Item :: struct {
	texture: rl.Texture2D,
	src:     rl.Rectangle,
	dst:     rl.Rectangle,
	tint:    rl.Color,
}

Renderer :: struct {
	textures: Textures,
	layers:   [LAYERS][dynamic]Item,
	shadows:  bool,
	// The level's map, with everything the simulation has burned into it.
	// The original keeps one scrolling buffer and draws craters, tank tracks
	// and wrecks straight into it; this is the same buffer.
	terrain:       rl.RenderTexture2D,
	terrain_level: sim.Res_ID,
	// The score bar's backdrop (im16 "scor", 160x480): the metal panel and
	// its cutouts for the score slot, life icon, weapon icons and the
	// shields/power bars. Loaded once; nothing ever changes it.
	scorebar_panel: rl.Texture2D,
	// Set by DR_DUMP: print every sprite of the next frame, which is how a
	// misplaced or mis-scaled draw gets identified.
	dump:     bool,
	// -classic / Preferences' Classic Mode, copied in each frame by
	// main.odin -- see settings.odin.
	classic:  bool,
	// The fixed 1280x960 frame the interactive loop draws into before
	// scaling it to the window (main.odin). Zero for the headless capture
	// paths, which draw straight to the window as before.
	canvas:   rl.RenderTexture2D,

	// High refresh rate interpolation, presentation only: the state as it
	// was before the latest step, and how far the render is between that
	// step and the next (0..1). main.odin sets both each frame; interp_prev
	// nil means off, and every position is drawn exactly as the state has
	// it. The simulation never sees any of this.
	interp_prev:  ^sim.State,
	interp_alpha: f32,
	// The scroll this frame is drawn at: build_frame's (possibly
	// interpolated) view_top and side_scroll, read by draw_object and
	// draw_terrain.
	view_top:    f32,
	side_scroll: f32,
}

// Past this many pixels in one step, something jumped (a respawn, a new
// level, a reused entity slot) rather than moved: draw it where it is.
@(private = "file") INTERP_MAX_JUMP :: 48

// Between the previous step's value and this one's, `alpha` of the way.
// alpha 1 (interpolation off, or caught up) returns `now` exactly, so the
// ordinary 30 FPS path draws the very same pixels it always has.
interp :: proc "contextless" (before, now, alpha: f32) -> f32 {
	if alpha >= 1 || abs(now - before) > INTERP_MAX_JUMP {
		return now
	}
	return before + (now - before) * alpha
}

renderer_init :: proc(r: ^Renderer, root: string, classic: bool = false, audio: bool = true) {
	textures_load(&r.textures, root, audio)
	for &l in r.layers {
		l = make([dynamic]Item, 0, 64)
	}
	r.shadows = true
	r.classic = classic
	r.scorebar_panel = rl.LoadTexture(fmt.ctprintf("%s/images/im16/scor.png", root))
}

renderer_destroy :: proc(r: ^Renderer) {
	if r.scorebar_panel.id != 0 {
		rl.UnloadTexture(r.scorebar_panel)
	}
	if r.terrain.id != 0 {
		rl.UnloadRenderTexture(r.terrain)
	}
	if r.canvas.id != 0 {
		rl.UnloadRenderTexture(r.canvas)
	}
	textures_unload(&r.textures)
	for &l in r.layers {
		delete(l)
	}
}

push_item :: proc(r: ^Renderer, layer: int, it: Item) {
	if layer < 0 || layer >= LAYERS {
		return
	}
	append(&r.layers[layer], it)
}

// A 1555 colour as raylib sees it, with `amount` out of 32 as its alpha --
// the blend units U_Pixel16 works in.
@(private = "file")
tint_color :: proc "contextless" (c: u16, amount: i32) -> rl.Color {
	expand :: proc "contextless" (v: u16) -> u8 {
		return u8((u32(v) * 255 + 15) / 31)
	}
	a := clamp(amount, 0, 32)
	return {
		expand(c >> 10 & 0x1f),
		expand(c >> 5 & 0x1f),
		expand(c & 0x1f),
		u8(a * 255 / 32),
	}
}

// G_GameObject::Priv_Draw: the sprite, then a tint pass while `tint` is above
// zero, then a glow pass while glowing. Nothing draws while the object is
// fully invisible.
//
// Terrain-drawn objects are placed in map space: shifted 32 right and down by
// the scroll. Everything else slides with the view's sideways scroll, which a
// player pushes by holding left or right.
//
// G_GameObject::Priv_Draw draws up to three passes -- the sprite, a tint while
// `tint` is above zero, and a glow while glowing -- and Priv_DrawShadow adds a
// silhouette underneath. Nothing draws while the object is fully invisible.
//
// `prev` is the same object as it was a step ago, when interpolating and it
// existed then; nil draws it exactly where it is.
draw_object :: proc(r: ^Renderer, s: ^sim.State, o: ^sim.Game_Object, casts_shadow: bool, prev: ^sim.Game_Object = nil) {
	tex, src, ok := frame_rect(&r.textures, o.sprite, o.frame)
	if r.dump && (!ok || o.visibility <= 0) {
		id := o.sprite
		fmt.printfln("  SKIPPED %v frame %v at %.1f,%.1f  vis %.0f  %s",
			string(id[:]), o.frame, o.loc.x, o.loc.y, o.visibility,
			o.sprite == sim.NONE ? "no sprite" : !ok ? "no such frame" : "invisible")
	}
	if o.visibility <= 0 || o.sprite == sim.NONE || !ok {
		return
	}
	// Whole pixels, as the original draws -- unless interpolating, where
	// the in-between position is the point, and the 2x canvas shows it.
	x, y: f32
	if prev != nil && r.interp_alpha < 1 {
		x = interp(f32(sim.trunc_i32(prev.loc.x)), f32(sim.trunc_i32(o.loc.x)), r.interp_alpha)
		y = interp(f32(sim.trunc_i32(prev.loc.y)), f32(sim.trunc_i32(o.loc.y)), r.interp_alpha)
	} else {
		x = f32(sim.trunc_i32(o.loc.x))
		y = f32(sim.trunc_i32(o.loc.y))
	}
	if o.draw_to_terrain {
		x += 32
		y += r.view_top
	} else if o.scrolls_sideways {
		x -= r.side_scroll
	}
	// U_Sprite_Draw centres the frame on the point, halving as the
	// simulation does.
	place :: proc(x, y: f32, src: rl.Rectangle, scale: f32) -> rl.Rectangle {
		w := i32(src.width * scale)
		h := i32(src.height * scale)
		return {x - f32(sim.halve(w)), y - f32(sim.halve(h)), f32(w), f32(h)}
	}
	dst := place(x, y, src, o.scale)
	// G_GameObject::Priv_Draw: draw_to_terrain objects skip the drawLayer_ID
	// switch entirely and always land in layer 1, ahead of the terrain --
	// live tank tracks and craters (stateDrawToTerrain), not the permanent
	// wrecks stamp_object burns into the map at destruction.
	layer := o.draw_to_terrain ? 1 : layer_of(o.draw_layer, o.is_air)

	if r.dump {
		id := o.sprite
		fmt.printfln("  layer %2d  %v frame %v  at %.1f,%.1f  %.0fx%.0f  scale %.3f  vis %.0f  tint %.0f/%04x  glow %v  terrain %v  shadow %v",
			layer, string(id[:]), o.frame, o.loc.x, o.loc.y, dst.width, dst.height,
			o.scale, o.visibility, o.tint, o.tint_color, o.glowing, o.draw_to_terrain, casts_shadow)
	}

	// The shadow: a silhouette of the same frame, offset and never less than
	// the blend floor of 20/32. Ground objects keep their size and shift a
	// little (perm floats 0x32, 0x33); air objects drop half-size, far down
	// and to the left (0x30, 0x31), as if lit from high behind.
	if casts_shadow && r.shadows {
		pf := s.defs.perm_floats
		sscale, ox, oy: f32
		if o.is_air {
			sscale = o.scale * 0.5
			k := o.shadow_scaled ? sscale : 0.5
			ox, oy = pf[0x30] * k, pf[0x31] * k
		} else {
			sscale = o.scale
			ox, oy = pf[0x32] * o.scale, pf[0x33] * o.scale
		}
		blend := max(i32(32 - o.visibility * 32 / 100), 20)
		sh := place(x + f32(sim.trunc_i32(ox)), y + f32(sim.trunc_i32(oy)), src, sscale)
		push_item(r, shadow_layer_of(o.draw_layer, o.is_air), Item {
			texture = tex,
			src     = src,
			dst     = sh,
			tint    = {0, 0, 0, u8((32 - blend) * 255 / 32)},
		})
	}

	alpha := u8(clamp(o.visibility, 0, 100) * 255 / 100)
	push_item(r, layer, Item{texture = tex, src = src, dst = dst, tint = {255, 255, 255, alpha}})

	if o.tint > 0 {
		push_item(r, layer, Item {
			texture = tex, src = src, dst = dst,
			tint = tint_color(o.tint_color, i32(o.tint * 32 / 100)),
		})
	}
	if o.glowing {
		push_item(r, layer, Item {
			texture = tex, src = src, dst = dst,
			tint = tint_color(o.glow_color, o.glow_amount),
		})
	}
}

// FUN_00420740: entities, both players, then motion blur ghosts, then the
// notice banner. The score bar is drawn separately, straight to the score
// bar panel rather than through a layer (see scorebar_draw). The original
// draws motion blur after the players (G_MotionBlur_BuildDrawList runs in
// Process, ahead of entities and players in the build order); the ordering
// doesn't matter here since every draw only ever appends to its own layer's
// list.
build_frame :: proc(r: ^Renderer, s: ^sim.State, blurs: ^Blurs, notices: ^Notices) {
	for &l in r.layers {
		clear(&l)
	}
	terrain_prepare(r, s)
	terrain_stamp(r, s)
	pv := r.interp_prev
	if pv != nil && pv.level != s.level {
		pv = nil // a different level: nothing on screen was there a step ago
	}
	r.view_top, r.side_scroll = f32(s.bgnd.view_top), f32(s.bgnd.side_scroll)
	if pv != nil {
		r.view_top = interp(f32(pv.bgnd.view_top), r.view_top, r.interp_alpha)
		r.side_scroll = interp(f32(pv.bgnd.side_scroll), r.side_scroll, r.interp_alpha)
	}
	w := &s.world
	for g := w.active.head; g != sim.NO_LINK; g = w.group_links[g].next {
		for i := w.groups[g].entities.head; i != sim.NO_LINK; i = w.entity_links[i].next {
			e := &w.entities[i]
			u := &s.defs.units[e.unit]
			// The same slot holding the same entity a step ago (numbers are
			// unique, so a reused slot does not match).
			before: ^sim.Game_Object
			if pv != nil && pv.world.entity_used[i] && pv.world.entities[i].number == e.number {
				before = &pv.world.entities[i].obj
			}
			draw_object(r, s, &e.obj, u.casts_shadows, before)
		}
	}
	for &p, k in s.players {
		if p.active && p.state == .Playing {
			before: ^sim.Game_Object
			if pv != nil && pv.players[k].active && pv.players[k].state == .Playing {
				before = &pv.players[k].obj
			}
			draw_object(r, s, &p.obj, true, before)
		}
	}
	for &o in blurs.live {
		draw_object(r, s, &o, false)
	}
	notices_draw(r, notices)
}

// Draws what build_frame collected, in the original's order.
present :: proc(r: ^Renderer, s: ^sim.State, particles: ^Particles, scale: f32) {
	run :: proc(r: ^Renderer, lo, hi: int, scale: f32) {
		for l in lo ..= hi {
			for it in r.layers[l] {
				dst := it.dst
				dst.x = (dst.x + VIEW_X) * scale
				dst.y *= scale
				dst.width *= scale
				dst.height *= scale
				rl.DrawTexturePro(it.texture, it.src, dst, {0, 0}, 0, it.tint)
			}
		}
	}
	run(r, 0, 1, scale)
	draw_terrain(r, s, scale)
	run(r, 2, 5, scale)
	particles_draw(particles, scale, r.interp_prev != nil ? r.interp_alpha : 1)
	run(r, 6, 15, scale)
	scorebar_draw(r, s, scale)
}

// The map buffer for a level: the image, plus every mark burned into it
// since the level started. Rebuilt when the level changes.
terrain_prepare :: proc(r: ^Renderer, s: ^sim.State) {
	if r.terrain_level == s.level.id && r.terrain.id != 0 {
		return
	}
	tex, ok := terrain_texture(&r.textures, s.level.id)
	if !ok {
		return
	}
	if r.terrain.id != 0 {
		rl.UnloadRenderTexture(r.terrain)
	}
	r.terrain = rl.LoadRenderTexture(tex.width, tex.height)
	r.terrain_level = s.level.id
	rl.BeginTextureMode(r.terrain)
	rl.ClearBackground(rl.BLACK)
	// A render texture is bottom-up, so the map goes in flipped and every
	// later read flips back.
	rl.DrawTextureRec(tex, {0, 0, f32(tex.width), -f32(tex.height)}, {0, 0}, rl.WHITE)
	rl.EndTextureMode()
	resume_canvas(r)
}

// raylib's render targets do not nest: EndTextureMode goes back to the
// window, not to whatever target was bound before. The terrain buffer is
// drawn into mid-frame (build_frame), so once it is done the frame's own
// target has to be bound again or the rest of the frame lands on the window.
resume_canvas :: proc(r: ^Renderer) {
	if r.canvas.id != 0 {
		rl.BeginTextureMode(r.canvas)
	}
}

// Applies this step's marks. `loc` is where the object was on screen, so the
// map position is that plus the scroll, and 32 across.
terrain_stamp :: proc(r: ^Renderer, s: ^sim.State) {
	if r.terrain.id == 0 || s.stamps.count == 0 {
		return
	}
	rl.BeginTextureMode(r.terrain)
	for st in s.stamps.events[:s.stamps.count] {
		tex, src, ok := frame_rect(&r.textures, st.sprite, st.frame)
		if !ok {
			continue
		}
		x := sim.trunc_i32(st.loc.x) + 32
		y := st.view_top + sim.trunc_i32(st.loc.y)
		w := i32(src.width * st.scale)
		h := i32(src.height * st.scale)
		flipped := src
		flipped.height = -flipped.height // the buffer is bottom-up
		top := f32(r.terrain.texture.height) - f32(y - sim.halve(h)) - f32(h)
		dst := rl.Rectangle{f32(x - sim.halve(w)), top, f32(w), f32(h)}
		alpha := u8(clamp(st.visibility, 0, 100) * 255 / 100)
		rl.DrawTexturePro(tex, flipped, dst, {0, 0}, 0, {255, 255, 255, alpha})
	}
	rl.EndTextureMode()
	resume_canvas(r)
}

// G_Bgnd_CopyToFrontBuffer: the visible window of the level's map, straight to
// the top-left of the play field. The source starts 32 pixels in, because the
// map is 480 wide and the play field 416, plus however far the view has slid
// sideways.
draw_terrain :: proc(r: ^Renderer, s: ^sim.State, scale: f32) {
	if r.terrain.id == 0 {
		return
	}
	w := f32(sim.view_width(s.defs))
	h := f32(sim.view_height(s.defs))
	left := max(r.side_scroll + 32, 0)
	// The map went into the buffer flipped, so it reads like any other
	// texture from here on. r.view_top is fractional when interpolating.
	src := rl.Rectangle{left, r.view_top, w, h}
	dst := rl.Rectangle{VIEW_X * scale, 0, w * scale, h * scale}
	rl.DrawTexturePro(r.terrain.texture, src, dst, {0, 0}, 0, rl.WHITE)
}
