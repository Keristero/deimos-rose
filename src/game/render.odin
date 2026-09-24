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
import "core:strings"

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
	effect:  Item_Effect,
	hue:     f32, // degrees, for effect != .None
	sat:     f32, // minimum saturation, for effect != .None
	lighten: f32, // 0..1 towards white after recolouring, for effect != .None
	shine:   f32, // 0..1 of the saturation lost on highlights, for effect != .None
	// Paint the tint's colour flat in the sprite's shape (the original's
	// colorised blit, U_PixelScale16_Colorised_Alpha) rather than multiply.
	colorise: bool,
}

// Accents (Extras, never in classic mode): drawn through
// ACCENT_SHADER rather than baked into textures, since the same sprite is
// shared by both players and, for the ground bomb's "bgbu", by an air
// weapon too.
Item_Effect :: enum u8 {
	None,
	Recolour,   // the sprite's own shading, in the accent hue
	Silhouette, // the sprite's shape, flat in the accent hue
}

// High enough that a white or grey sprite (the glow of the ground weapon's
// "pbhf", say) still reads clearly as the accent colour against the map.
ACCENT_SATURATION :: 0.85
// The ship's trim is shaded metal, recoloured from the silver of player 1's
// ship. Fitted to player 2's gold: over the 1,518 PL1B/PL2B pixels that are
// grey on one and yellow on the other, gold is hue ~63, saturation ~0.55,
// brightness equal to the silver's luminance, and paler on the highlights
// (0.29 at full brightness). With these two constants and the slider at 63
// the mean error is 16 per pixel (summed RGB), from 42 at the 0.8 used
// before -- the slider's yellow-orange reproduces the original gold.
TRIM_SATURATION :: 0.55
TRIM_SHINE :: 0.3 // share of the saturation the brightest highlights lose
// How far the unlocked crosshair is washed towards white: lighter and
// paler than the locked frame's pure red, whatever the accent.
CROSSHAIR_LIGHTEN :: 0.45

// One player's accent for this frame, set by flow_draw: their hue on their
// ship's trim, crosshair and air-to-ground shots, and optionally an outline
// (which Accent Colours does not turn off).
Accent :: struct {
	on:             bool, // Accent Colours: trim, crosshair and ground shots in the hue
	hue:            f32, // degrees; also the outline's colour
	outline:        bool, // Self Outline, the local player only
	hide_crosshair: bool, // the other player's, in netplay
}

// A player's accent as a plain colour, for menu text.
accent_color :: proc(hue: int) -> rl.Color {
	return rl.ColorFromHSV(f32(hue), ACCENT_SATURATION * 0.8, 1)
}

// Replaces each pixel's hue with the accent's and lifts its saturation to
// at least ACCENT_SATURATION, keeping its brightness and alpha (Recolour);
// or ignores the colour altogether for a flat silhouette (Silhouette).
// raylib's default vertex shader feeds it.
@(private = "file")
ACCENT_SHADER :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float hue;     // 0..1
uniform float minSat;
uniform float flatten; // 1 for a silhouette
uniform float lighten; // 0..1 towards white, after the hue is applied
uniform float shine;   // 0..1 of the saturation highlights lose, like metal
uniform float recolour; // 1: take the accent hue
uniform float colorise; // 1: the tint colour, flat, in the sprite's shape
out vec4 finalColor;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
	vec4 tx = texture(texture0, fragTexCoord);
	vec4 tint = colDiffuse * fragColor;
	// The original adds the sprite's alpha weight to the draw's blend
	// (U_SpriteBlit_DrawTranslucent, U_PixelScale16_*_Alpha: weight + blend,
	// capped at 32) rather than multiplying them, so a fading glow loses its
	// faint halo first.
	float a = clamp(tx.a - (1.0 - tint.a), 0.0, 1.0);
	vec3 rgb = colorise > 0.5 ? tint.rgb : tx.rgb * tint.rgb;
	if (recolour > 0.5) {
		vec3 hsv = rgb2hsv(rgb);
		hsv.x = hue;
		hsv.y = max(hsv.y, minSat);
		hsv.y *= 1.0 - shine * smoothstep(0.85, 1.0, hsv.z);
		if (flatten > 0.5) {
			hsv.z = 1.0;
		}
		rgb = mix(hsv2rgb(hsv), vec3(1.0), lighten);
	}
	finalColor = vec4(rgb, a);
}
`

Renderer :: struct {
	textures: Textures,
	layers:   [LAYERS][dynamic]Item,
	shadows:  bool,
	// The level's map, with everything the simulation has burned into it.
	// The original keeps one scrolling buffer and draws craters, tank tracks
	// and wrecks straight into it; this is the same buffer.
	terrain:       rl.RenderTexture2D,
	terrain_level: sim.Res_ID,
	terrain_qt:    bool, // built with QuickTime's gamma (classic mode)
	replay:        bool, // a film is playing: the original labels it "REPLAY"
	// Set by DR_DUMP: print every sprite of the next frame, which is how a
	// misplaced or mis-scaled draw gets identified.
	dump:     bool,
	// Set by DR_SHOT_FIND: count the draws whose DR_DUMP line contains this
	// text, without printing them (run_shots reports the steps).
	find:      string,
	find_hits: int,
	// -classic / Preferences' Classic Mode, copied in each frame by
	// main.odin -- see settings.odin.
	classic:  bool,
	// The fixed 1280x960 frame the interactive loop draws into before
	// scaling it to the window (main.odin). Zero for the headless capture
	// paths, which draw straight to the window as before.
	canvas:   rl.RenderTexture2D,

	// Netplay accents, per player slot (flow_draw sets them each frame;
	// all off otherwise), and what draws them.
	accents:          [sim.MAX_PLAYERS]Accent,
	scorebar:         Scorebar_View, // the meters as shown, easing (scorebar.odin)
	accent_shader:    rl.Shader,
	accent_hue_loc:   i32,
	accent_sat_loc:   i32,
	accent_flat_loc:  i32,
	accent_light_loc: i32,
	accent_shine_loc: i32,
	accent_recolour_loc: i32,
	accent_colorise_loc: i32,
	// The units the ground weapons spawn -- their shots, which take their
	// owner's accent. Found once from the definitions (build_frame).
	ground_units:     [dynamic]sim.Res_ID,
	ground_units_set: bool,

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
	r.textures.quicktime_gamma = classic
	r.accent_shader = rl.LoadShaderFromMemory(nil, ACCENT_SHADER)
	r.accent_hue_loc = rl.GetShaderLocation(r.accent_shader, "hue")
	r.accent_sat_loc = rl.GetShaderLocation(r.accent_shader, "minSat")
	r.accent_flat_loc = rl.GetShaderLocation(r.accent_shader, "flatten")
	r.accent_light_loc = rl.GetShaderLocation(r.accent_shader, "lighten")
	r.accent_shine_loc = rl.GetShaderLocation(r.accent_shader, "shine")
	r.accent_recolour_loc = rl.GetShaderLocation(r.accent_shader, "recolour")
	r.accent_colorise_loc = rl.GetShaderLocation(r.accent_shader, "colorise")
}

renderer_destroy :: proc(r: ^Renderer) {
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
	if r.accent_shader.id != 0 {
		rl.UnloadShader(r.accent_shader)
	}
	delete(r.ground_units)
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
//
// `accent` recolours the sprite (a player's crosshair or shots) or rings it
// with an outline (their ship); the zero value draws it as it is.
Draw_Accent :: struct {
	hue:      f32,
	recolour: bool,
	trim:     bool, // a ship: its silver/gold trim (ship_trim) in the accent
	outline:  bool,
	lighten:  f32, // with recolour: towards white (the unlocked crosshair)
}

draw_object :: proc(r: ^Renderer, s: ^sim.State, o: ^sim.Game_Object, casts_shadow: bool, prev: ^sim.Game_Object = nil, accent := Draw_Accent{}) {
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

	if r.dump || r.find != "" {
		id := o.sprite
		line := fmt.tprintf("  layer %2d  %v frame %v  at %.1f,%.1f  %.0fx%.0f  scale %.3f  vis %.0f  tint %.0f/%04x  glow %v  terrain %v  shadow %v",
			layer, string(id[:]), o.frame, o.loc.x, o.loc.y, dst.width, dst.height,
			o.scale, o.visibility, o.tint, o.tint_color, o.glowing, o.draw_to_terrain, casts_shadow)
		if r.dump {
			fmt.println(line)
		}
		if r.find != "" && strings.contains(line, r.find) {
			r.find_hits += 1
		}
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
	if accent.outline {
		// The ship's own shape in its accent, one pixel out in each of
		// the eight directions, underneath the ship itself.
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			o := dst
			o.x += d.x
			o.y += d.y
			push_item(r, layer, Item {
				texture = tex, src = src, dst = o, tint = {255, 255, 255, alpha},
				effect = .Silhouette, hue = accent.hue, sat = ACCENT_SATURATION,
			})
		}
	}
	push_item(r, layer, Item {
		texture = tex, src = src, dst = dst, tint = {255, 255, 255, alpha},
		effect = accent.recolour ? .Recolour : .None, hue = accent.hue, sat = ACCENT_SATURATION,
		lighten = accent.lighten,
	})
	if accent.trim {
		if trim, tok := ship_trim(&r.textures, o.sprite); tok {
			push_item(r, layer, Item {
				texture = trim, src = src, dst = dst, tint = {255, 255, 255, alpha},
				effect = .Recolour, hue = accent.hue, sat = TRIM_SATURATION, shine = TRIM_SHINE,
			})
		}
	}

	// A recoloured object's tint and glow take the accent too: the ground
	// weapon's glow trail "pbgl" is tinted 70% cyan, which would otherwise
	// wash its accent back out.
	over := accent.recolour ? Item_Effect.Recolour : .None
	// Both are flat colour in the sprite's shape (Priv_Draw sets the
	// colorised flag, 4). The tint's weight is tint% of 32, scaled by the
	// sprite's own visibility; the glow's amount is the blit's destination
	// weight, so 32 is invisible and 4 (its peak) nearly solid.
	if o.tint > 0 {
		push_item(r, layer, Item {
			texture = tex, src = src, dst = dst,
			tint = tint_color(o.tint_color, i32(o.tint * 32 / 100 * clamp(o.visibility, 0, 100) / 100)),
			effect = over, hue = accent.hue, sat = ACCENT_SATURATION, colorise = true,
		})
	}
	if o.glowing {
		push_item(r, layer, Item {
			texture = tex, src = src, dst = dst,
			tint = tint_color(o.glow_color, 32 - o.glow_amount),
			effect = over, hue = accent.hue, sat = ACCENT_SATURATION, colorise = true,
		})
	}
}

// A shot from a ground weapon takes its owner's accent: the units the
// weapon spawns, and everything those spawn in turn -- for "plbo" (the only
// ground weapon today) its bomb "plbo" with its glow trail "pbgl" and hit
// flash "pbhf", and the launch flash "pblf". Keyed by unit rather than
// sprite, since the bomb's sprite "bgbu" is shared with an air weapon's
// bullet. Marks drawn into the terrain (craters) keep their colours.
@(private = "file")
shot_accent :: proc(r: ^Renderer, s: ^sim.State, e: ^sim.Entity) -> Draw_Accent {
	if e.owner_player < 0 || int(e.owner_player) >= sim.MAX_PLAYERS || e.draw_to_terrain {
		return {}
	}
	ac := r.accents[e.owner_player]
	if !ac.on {
		return {}
	}
	if !r.ground_units_set {
		r.ground_units_set = true
		for &w in s.defs.weapons {
			if w.type == sim.WEP_GROUND {
				for sp in w.spawns {
					ground_units_add(r, s.defs, sp.unit)
				}
			}
		}
	}
	id := s.defs.units[e.unit].id
	for u in r.ground_units {
		if u == id {
			return {hue = ac.hue, recolour = true}
		}
	}
	return {}
}

@(private = "file")
ground_units_add :: proc(r: ^Renderer, defs: ^sim.Defs, id: sim.Res_ID) {
	if id == sim.NONE {
		return
	}
	for u in r.ground_units {
		if u == id {
			return // already in, which also stops a unit that spawns itself
		}
	}
	append(&r.ground_units, id)
	for &u in defs.units {
		if u.id != id {
			continue
		}
		ground_units_add(r, defs, u.destruct_spawn)
		ground_units_add(r, defs, u.deletion_spawn)
		for &st in u.states {
			for &set in st.spawn_sets {
				ground_units_add(r, defs, set.spawn)
			}
		}
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
	scorebar_process(&r.scorebar, s)
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
			draw_object(r, s, &e.obj, u.casts_shadows, before, shot_accent(r, s, e))
		}
	}
	for &p, k in s.players {
		if p.active && p.state == .Playing {
			before: ^sim.Game_Object
			if pv != nil && pv.players[k].active && pv.players[k].state == .Playing {
				before = &pv.players[k].obj
			}
			// G_Player::BuildDrawList draws the ground weapon's crosshair
			// first (G_WeaponHandler::BuildDrawList, 0x447ad0: only once
			// crosshair_shown, +0x117), then the ship. No shadow: the
			// handler's Process clears the crosshair's +0x38 every step.
			ac := r.accents[k]
			if p.weapons.crosshair_shown && !ac.hide_crosshair {
				cbefore: ^sim.Game_Object
				if before != nil && pv.players[k].weapons.crosshair_shown {
					cbefore = &pv.players[k].weapons.crosshair
				}
				// Locked keeps its own red, so a lock still shows. Unlocked
				// is the accent washed towards white, so that even a red
				// accent reads differently from the lock.
				recolour := ac.on && !p.weapons.crosshair_locked
				draw_object(r, s, &p.weapons.crosshair, false, cbefore, {hue = ac.hue, recolour = recolour, lighten = CROSSHAIR_LIGHTEN})
			}
			draw_object(r, s, &p.obj, true, before, {hue = ac.hue, trim = ac.on, outline = ac.outline})
		}
	}
	for &o in blurs.live {
		draw_object(r, s, &o, false)
	}
	notices_draw(r, notices)
}

// One item at its final screen rectangle, through ACCENT_SHADER when it
// carries an effect. Also used directly by the Extras previews.
draw_item :: proc(r: ^Renderer, it: Item, dst: rl.Rectangle) {
	// An opaque plain draw blends the same either way; everything else goes
	// through the shader for the original's alpha rule.
	if (it.effect == .None && !it.colorise && it.tint.a == 255) || r.accent_shader.id == 0 {
		rl.DrawTexturePro(it.texture, it.src, dst, {0, 0}, 0, it.tint)
		return
	}
	recolour := f32(it.effect != .None ? 1 : 0)
	colorise := f32(it.colorise ? 1 : 0)
	hue := it.hue / 360
	sat := it.sat
	flat := f32(it.effect == .Silhouette ? 1 : 0)
	rl.BeginShaderMode(r.accent_shader)
	rl.SetShaderValue(r.accent_shader, r.accent_hue_loc, &hue, .FLOAT)
	rl.SetShaderValue(r.accent_shader, r.accent_sat_loc, &sat, .FLOAT)
	rl.SetShaderValue(r.accent_shader, r.accent_flat_loc, &flat, .FLOAT)
	light := it.lighten
	rl.SetShaderValue(r.accent_shader, r.accent_light_loc, &light, .FLOAT)
	shine := it.shine
	rl.SetShaderValue(r.accent_shader, r.accent_shine_loc, &shine, .FLOAT)
	rl.SetShaderValue(r.accent_shader, r.accent_recolour_loc, &recolour, .FLOAT)
	rl.SetShaderValue(r.accent_shader, r.accent_colorise_loc, &colorise, .FLOAT)
	rl.DrawTexturePro(it.texture, it.src, dst, {0, 0}, 0, it.tint)
	rl.EndShaderMode()
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
				draw_item(r, it, dst)
			}
		}
	}
	run(r, 0, 1, scale)
	draw_terrain(r, s, scale)
	run(r, 2, 5, scale)
	particles_draw(particles, scale, r.side_scroll, r.interp_prev != nil ? r.interp_alpha : 1)
	run(r, 6, 15, scale)
	level_end_draw(r, s, scale) // layer 0xf text, over the sprites
	scorebar_draw(r, s, scale)
	if r.replay {
		// G_Game_Play, while a film plays: game string 9 through preset 0x26.
		text_preset_draw(r, r.textures.assets.text[0x26], game_string(r, 9), VIEW_X, scale)
	}
}

// The map buffer for a level: the image, plus every mark burned into it
// since the level started. Rebuilt when the level changes.
terrain_prepare :: proc(r: ^Renderer, s: ^sim.State) {
	if r.terrain_level == s.level.id && r.terrain.id != 0 && r.terrain_qt == r.textures.quicktime_gamma {
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
	r.terrain_qt = r.textures.quicktime_gamma
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
