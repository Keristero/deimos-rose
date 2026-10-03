package lighting_view

// The lighting post pass (render/post.odin), in three parts, each using
// what raylib has: render textures for the buffers, additive blending for
// the lights, and fragment shaders for the blur and the composite.
//
//   lights  A half-resolution light map. Every item that shines
//           (render.Item.emit) and every bright spark adds a soft round
//           light in the colour of its sprite, drawn with raylib's additive
//           blend mode, so overlapping lights sum.
//   glow    A quarter-resolution map of the shining sprites themselves,
//           blurred by a separable Gaussian, twice, so a shot has a halo.
//   apply   One shader over the finished scene: the scene's colour times
//           (1 + light), so a light brings out the colour of the ground and
//           units it falls on, plus a little of its own; then the glow
//           added on. Shadowed ground has its own colour in the map, so a
//           light reveals it.
//   falling A shot falling to the ground (render.Item.falling) is drawn
//           into the light map's alpha channel as well, which says how far
//           its light reaches into shadow. A shot in the air lights the
//           ground faintly and leaves its shadows dark; as it comes down
//           its light grows and then fills the shadows, so the ground seems
//           to rise to meet it: a depth cue, since the shot is drawn flat.
//
// Cost per frame: a light is one quad into a 640x480 target, the glow a few
// full-screen draws into 320x240 targets, and the composite one draw. Both
// buffers are at lower resolution because both are soft; the composite
// samples them with bilinear filtering, so they do not show as blocks.
//
// Provisional: no sprite has albedo or a normal yet, so a light brightens
// by the scene's own colour and does not shade by direction; every
// radius and gain here was picked by eye. See
// notes/realtime-lighting-and-effects.md for what recovers them.

import "core:math"
import "core:strings"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import "dr:data"
import "dr:plugins/lighting"
import "dr:render"
import "dr:sim"

@(private = "file") LIGHT_DIV :: 2 // the light map's size is the canvas's over this
@(private = "file") GLOW_DIV :: 4
@(private = "file") MAX_LIGHTS :: 96
// A light reaches this many times its sprite's size, and this much more.
@(private = "file") LIGHT_REACH :: 1.0
@(private = "file") LIGHT_MIN_RADIUS :: 14
@(private = "file") FALLOFF_SIZE :: 128
// How glossy ground is in a level with no specular mask (terrain.MATERIAL_GLOSS_DEFAULT).
@(private = "file") SPECULAR_DEFAULT :: 0.2
// How bright a highlight is on the glossiest ground under a full light.
@(private = "file") SPECULAR_GAIN :: 1.6
@(private = "file") SPARK_MIN_LUMA :: 0.55 // a spark casts light when it is at least this bright
// A shot falling to the ground lights it at this share of its full light
// when let go, and the rest as the square of how far down it is.
@(private = "file") FALL_AIR_LIGHT :: 0.2

@(private = "file")
Colour_Key :: [5]i32 // texture id, then the frame's rectangle

@(private = "file")
State :: struct {
	ready:      bool,
	w, h:       i32, // the canvas the targets were made for
	light:      rl.RenderTexture2D,
	emit:       rl.RenderTexture2D,
	blur_a:     rl.RenderTexture2D,
	blur_b:     rl.RenderTexture2D,
	falloff:    rl.Texture2D,
	blur:       rl.Shader,
	blur_dir:   i32,
	composite:  rl.Shader,
	lights_loc: i32,
	glow_loc:   i32,
	spec_loc:   i32,
	normal_loc: i32,
	texel_loc:  i32,
	spec_gain:  i32,
	canvas_loc: i32,
	field_loc:  i32,
	map_loc:    i32,
	// The ground's gloss where a level has no specular mask: one pixel.
	plain:      rl.Texture2D,
	flat:       rl.Texture2D, // and its normal where it has none: facing straight up
	// The level's specular and shadow masks in one texture (gloss in red,
	// light in alpha), made once a level, where it has a shadow mask.
	ground:     rl.Texture2D,
	ground_key: string,
	shadow_loc: i32,
	// The specular textures given their filter (they are cached by the renderer).
	filtered:   map[u32]bool,
	light_k:    i32,
	glow_k:     i32,
	// Each shining frame's colour, found once from its plate.
	colours:    map[Colour_Key]rl.Color,
	plates:     map[u32]rl.Image,
}

@(private = "file")
st: State

register_lights :: proc() {
	render.post_pass_register({
		name    = "lighting",
		plugin  = lighting.ID,
		enabled = enabled,
		prepare = prepare,
		apply   = apply,
		destroy = destroy,
	})
}

@(init)
register_lights_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/lighting/view register_lights", register_lights)
}

@(private = "file")
enabled :: proc(r: ^render.Renderer) -> bool {
	return r.setting[LIGHT_STRENGTH] > 0 || r.setting[GLOW_STRENGTH] > 0
}

// Eight-bit light maps clip at 1, which is where lights stop adding.
@(private = "file")
BLUR_SHADER :: `#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec2 dir; // the step between taps, in texture coordinates
out vec4 finalColor;
void main() {
	// Five taps' worth of a 9-tap Gaussian, using the bilinear filter to
	// take two texels with each.
	vec3 c = texture(texture0, fragTexCoord).rgb * 0.2270270270;
	c += (texture(texture0, fragTexCoord + dir * 1.3846153846).rgb +
	      texture(texture0, fragTexCoord - dir * 1.3846153846).rgb) * 0.3162162162;
	c += (texture(texture0, fragTexCoord + dir * 3.2307692308).rgb +
	      texture(texture0, fragTexCoord - dir * 3.2307692308).rgb) * 0.0702702703;
	finalColor = vec4(c, 1.0);
}
`

@(private = "file")
COMPOSITE_SHADER :: `#version 330
#define LIGHT_LEAN 6.0       // how far the light map's slope leans a light's direction
#define NORMAL_GAIN 4.0      // how strongly the ground's slope shades under a light
#define SPECULAR_POWER 14.0  // how tight a highlight is
#define TILT_REACH 24.0      // map pixels over which the ground's general tilt is taken out
#define SHADOW_FILL 0.6      // how much of its colour a shadow takes from a shot that is down
#define SHADOW_LUMA_LO 0.10  // brightness at and below which a pixel is all shadow
#define SHADOW_LUMA_HI 0.50  // and at and above which none
in vec2 fragTexCoord;
uniform sampler2D texture0; // the scene
uniform sampler2D lights;
uniform sampler2D glow;
uniform sampler2D specular; // how glossy the ground is, in the map's own pixels
uniform sampler2D normals;  // which way it faces, in the same pixels
uniform vec2 lightPx;       // a light map texel, in texture coordinates
uniform float lightGain;
uniform float glowGain;
uniform float specGain;
uniform vec2 canvas;        // the canvas's size, in pixels
uniform vec4 field;         // the play field in canvas pixels: left, top, width, height
uniform float hasShadow;    // 1 where the specular texture's alpha is the level's shadow mask
uniform vec4 mapRect;       // the map's pixels showing: left, top, width, height, over the map's size
out vec4 finalColor;
void main() {
	vec3 scene = texture(texture0, fragTexCoord).rgb;
	vec4 lightMap = texture(lights, fragTexCoord);
	vec3 light = lightMap.rgb * lightGain;
	vec3 halo = texture(glow, fragTexCoord).rgb * glowGain;
	// The light shows the colour it falls on, and a little of its own where
	// that is dark, so a spark over black ground still lights something.
	vec3 lit = scene * (1.0 + 0.9 * light) + 0.05 * light;

	// A shot that is nearly down lights shadow as well. The multiplication
	// above leaves a shadow as dark against the ground round it as before;
	// this is what a light that close adds on top, which a shadow does not
	// keep out: each shadowed pixel takes the light's colour, in its own
	// hue. How far it reaches is the light map's alpha, and its colour is
	// the map's own. Which pixels are in shadow is the level's shadow mask;
	// a level without one has the dark pixels stand in.
	float reach = lightMap.a * lightGain;
	vec3 reachColour = lightMap.rgb / max(max(lightMap.r, max(lightMap.g, lightMap.b)), 0.02);
	float luma = dot(scene, vec3(0.299, 0.587, 0.114));
	float darkByLuma = 1.0 - smoothstep(SHADOW_LUMA_LO, SHADOW_LUMA_HI, luma);
	vec3 hue = scene / max(max(scene.r, max(scene.g, scene.b)), 0.05);

	// The ground, where the play field is: its normal and gloss at the map's
	// pixel. Light maps do not keep where each light is, but the way they
	// brighten does: the gradient of their brightness points to the light,
	// and a light is this far above the ground, so the ground's slope
	// shades by how it faces that way (as much as it faces away from flat),
	// and a highlight is where it faces half way between the light and the
	// eye above.
	vec2 px = vec2(fragTexCoord.x * canvas.x, (1.0 - fragTexCoord.y) * canvas.y);
	vec2 f = (px - field.xy) / field.zw;
	if (f.x >= 0.0 && f.x <= 1.0 && f.y >= 0.0 && f.y <= 1.0) {
		vec2 uv = mapRect.xy + f * mapRect.zw;
		vec4 ground = texture(specular, uv);
		float gloss = ground.r;
		float dark = mix(darkByLuma, 1.0 - ground.a, hasShadow);
		lit += reach * reachColour * hue * dark * SHADOW_FILL;
		vec3 n = normalize(texture(normals, uv).rgb * 2.0 - 1.0);
		// The recovered ground tilts one way on the whole (the heights were
		// fitted to the sun's shading, so slopes face it): shade by the
		// slope against the ground around it, or every light would favour
		// the side that tilt faces.
		vec2 around = 1.0 / vec2(textureSize(normals, 0)) * TILT_REACH;
		vec2 tilt = n.xy;
		for (int i = 0; i < 8; i++) {
			float a = 0.785398 * float(i);
			tilt += (texture(normals, uv + vec2(cos(a), sin(a)) * around).rg * 2.0 - 1.0);
		}
		vec2 slope = n.xy - tilt / 9.0;
		float bright = dot(light, vec3(0.333));
		float gx = dot(texture(lights, fragTexCoord + vec2(lightPx.x, 0.0)).rgb - texture(lights, fragTexCoord - vec2(lightPx.x, 0.0)).rgb, vec3(0.333));
		float gy = dot(texture(lights, fragTexCoord + vec2(0.0, lightPx.y)).rgb - texture(lights, fragTexCoord - vec2(0.0, lightPx.y)).rgb, vec3(0.333));
		// Texture rows run up the screen, the map's down: the map's y is -gy.
		vec2 toward = vec2(gx, -gy);
		vec3 l = normalize(vec3(toward * LIGHT_LEAN / max(bright, 0.02), 1.0));
		float shade = dot(slope, l.xy) / max(l.z, 0.2); // 0 on ground like its surroundings
		lit += scene * light * clamp(shade * NORMAL_GAIN, -0.6, 0.9);
		float detail = 0.5 + 1.0 * dot(scene, vec3(0.299, 0.587, 0.114));
		vec3 facing = normalize(vec3(slope, sqrt(max(1.0 - dot(slope, slope), 0.05))));
		float glint = pow(max(dot(facing, normalize(l + vec3(0.0, 0.0, 1.0))), 0.0), SPECULAR_POWER);
		lit += gloss * specGain * light * light * detail * glint;
	}
	finalColor = vec4(lit + halo, 1.0);
}
`

@(private = "file")
ensure :: proc(f: ^render.Post_Frame) {
	if !st.ready {
		st.ready = true
		st.blur = rl.LoadShaderFromMemory(nil, BLUR_SHADER)
		st.blur_dir = rl.GetShaderLocation(st.blur, "dir")
		st.composite = rl.LoadShaderFromMemory(nil, COMPOSITE_SHADER)
		st.lights_loc = rl.GetShaderLocation(st.composite, "lights")
		st.glow_loc = rl.GetShaderLocation(st.composite, "glow")
		st.spec_loc = rl.GetShaderLocation(st.composite, "specular")
		st.normal_loc = rl.GetShaderLocation(st.composite, "normals")
		st.texel_loc = rl.GetShaderLocation(st.composite, "lightPx")
		st.spec_gain = rl.GetShaderLocation(st.composite, "specGain")
		st.canvas_loc = rl.GetShaderLocation(st.composite, "canvas")
		st.field_loc = rl.GetShaderLocation(st.composite, "field")
		st.map_loc = rl.GetShaderLocation(st.composite, "mapRect")
		st.shadow_loc = rl.GetShaderLocation(st.composite, "hasShadow")
		st.filtered = make(map[u32]bool)
		gloss := rl.GenImageColor(1, 1, {u8(SPECULAR_DEFAULT * 255), 0, 0, 255})
		rl.ImageFormat(&gloss, .UNCOMPRESSED_GRAYSCALE)
		st.plain = rl.LoadTextureFromImage(gloss)
		rl.UnloadImage(gloss)
		up := rl.GenImageColor(1, 1, {128, 128, 255, 255})
		st.flat = rl.LoadTextureFromImage(up)
		rl.UnloadImage(up)
		st.light_k = rl.GetShaderLocation(st.composite, "lightGain")
		st.glow_k = rl.GetShaderLocation(st.composite, "glowGain")
		st.colours = make(map[Colour_Key]rl.Color)
		st.plates = make(map[u32]rl.Image)
		// A light's falloff: bright at the middle, smoothly to nothing at
		// the edge, in white, tinted when drawn.
		img := rl.GenImageColor(FALLOFF_SIZE, FALLOFF_SIZE, rl.BLACK)
		px := ([^]rl.Color)(img.data)[:FALLOFF_SIZE * FALLOFF_SIZE]
		for y in 0 ..< FALLOFF_SIZE {
			for x in 0 ..< FALLOFF_SIZE {
				dx := (f32(x) + 0.5) / FALLOFF_SIZE * 2 - 1
				dy := (f32(y) + 0.5) / FALLOFF_SIZE * 2 - 1
				d := clamp(1 - math.sqrt(dx * dx + dy * dy), 0, 1)
				v := u8(255 * d * d)
				px[y * FALLOFF_SIZE + x] = {v, v, v, v}
			}
		}
		st.falloff = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(st.falloff, .BILINEAR)
		rl.UnloadImage(img)
	}
	if st.w != f.width || st.h != f.height {
		unload_targets()
		st.w, st.h = f.width, f.height
		st.light = target(f.width / LIGHT_DIV, f.height / LIGHT_DIV)
		st.emit = target(f.width / GLOW_DIV, f.height / GLOW_DIV)
		st.blur_a = target(f.width / GLOW_DIV, f.height / GLOW_DIV)
		st.blur_b = target(f.width / GLOW_DIV, f.height / GLOW_DIV)
	}
}

@(private = "file")
target :: proc(w, h: i32) -> rl.RenderTexture2D {
	t := rl.LoadRenderTexture(w, h)
	rl.SetTextureFilter(t.texture, .BILINEAR)
	rl.SetTextureWrap(t.texture, .CLAMP)
	return t
}

@(private = "file")
unload_targets :: proc() {
	for t in ([4]rl.RenderTexture2D{st.light, st.emit, st.blur_a, st.blur_b}) {
		if t.id != 0 {
			rl.UnloadRenderTexture(t)
		}
	}
	st.light, st.emit, st.blur_a, st.blur_b = {}, {}, {}, {}
}

@(private = "file")
destroy :: proc() {
	if !st.ready {
		return
	}
	unload_targets()
	rl.UnloadTexture(st.falloff)
	rl.UnloadTexture(st.plain)
	rl.UnloadTexture(st.flat)
	rl.UnloadTexture(st.ground)
	delete(st.ground_key)
	delete(st.filtered)
	rl.UnloadShader(st.blur)
	rl.UnloadShader(st.composite)
	for _, img in st.plates {
		rl.UnloadImage(img)
	}
	delete(st.colours)
	delete(st.plates)
	st = {}
}

// The colour a frame shines in: its pixels' mean, weighted by alpha, with
// its brightest channel lifted to full and a quarter taken to white, so a
// dim sprite still makes a bright light of its hue. Read from the plate
// once, and kept.
@(private = "file")
shine_colour :: proc(r: ^render.Renderer, it: render.Item) -> rl.Color {
	key := Colour_Key{i32(it.texture.id), i32(it.src.x), i32(it.src.y), i32(it.src.width), i32(it.src.height)}
	if c, ok := st.colours[key]; ok {
		return c
	}
	img, have := st.plates[it.texture.id]
	if !have {
		// A texture pack's redrawn plate carries the original's size.
		whole := it.texture
		size := render.texture_pixels(&r.textures, it.texture)
		whole.width, whole.height = size.x, size.y
		img = rl.LoadImageFromTexture(whole)
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
		st.plates[it.texture.id] = img
	}
	sum: [3]f32
	weight: f32
	px := ([^]rl.Color)(img.data)[:img.width * img.height]
	k := f32(img.width) / f32(max(it.texture.width, 1)) // redrawn plates: more pixels per frame pixel
	x0, y0 := int(it.src.x * k), int(it.src.y * k)
	for y in y0 ..< min(y0 + int(it.src.height * k), int(img.height)) {
		for x in x0 ..< min(x0 + int(it.src.width * k), int(img.width)) {
			c := px[y * int(img.width) + x]
			a := f32(c.a)
			sum += {f32(c.r), f32(c.g), f32(c.b)} * a
			weight += a
		}
	}
	col := rl.Color{255, 255, 255, 255}
	if weight > 0 {
		mean := sum / weight
		top := max(mean.r, mean.g, mean.b, 1)
		mean = mean / top
		mean = mean + (1 - mean) * 0.1
		col = {u8(mean.r * 255), u8(mean.g * 255), u8(mean.b * 255), 255}
	}
	st.colours[key] = col
	return col
}

@(private = "file")
Light :: struct {
	at:     rl.Vector2, // canvas pixels
	radius: f32,
	colour: rl.Color,
	gain:   f32, // 0..1
	// 0..1: how far into shadow it reaches (the light map's alpha); only a
	// shot that is nearly down does.
	reach:  f32,
}

// What shines this frame: the shining items, and bright sparks.
@(private = "file")
gather :: proc(r: ^render.Renderer, f: ^render.Post_Frame, out: ^[MAX_LIGHTS]Light) -> int {
	n := 0
	for &layer in r.layers {
		for it in layer {
			if it.emit <= 0 || it.tint.a == 0 || n >= MAX_LIGHTS {
				continue
			}
			size := max(it.dst.width, it.dst.height)
			gain := it.emit * f32(it.tint.a) / 255
			l := Light {
				at     = {(it.dst.x + it.dst.width / 2 + render.VIEW_X) * f.scale, (it.dst.y + it.dst.height / 2) * f.scale},
				radius = (size * LIGHT_REACH + LIGHT_MIN_RADIUS) * f.scale,
				colour = shine_colour(r, it),
				gain   = gain,
			}
			if it.falling {
				// The light grows as the square of the fall and the reach
				// into shadow as its cube, so shadows stay dark until the
				// shot is close.
				d := it.descent
				l.gain = gain * (FALL_AIR_LIGHT + (1 - FALL_AIR_LIGHT) * d * d)
				l.reach = gain * d * d * d
			}
			out[n] = l
			n += 1
		}
	}
	// A spark's stamp is 7 pixels across; its shade is five bits a channel.
	for pt in f.particles.live {
		if n >= MAX_LIGHTS || pt.fade >= 32 {
			continue
		}
		c := [3]f32{f32(pt.shade[0]), f32(pt.shade[1]), f32(pt.shade[2])} / 31
		luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
		if luma < SPARK_MIN_LUMA {
			continue
		}
		top := max(c.r, c.g, c.b, 0.01)
		c = c / top
		out[n] = {
			at     = {(f32(sim.trunc_i32(pt.loc.x - f.side)) + 3.5 + render.VIEW_X) * f.scale, (f32(sim.trunc_i32(pt.loc.y)) + 3.5) * f.scale},
			radius = 26 * f.scale,
			colour = {u8(c.r * 255), u8(c.g * 255), u8(c.b * 255), 255},
			gain   = 0.5 * (1 - f32(pt.fade) / 32),
		}
		n += 1
	}
	return n
}

@(private = "file")
tinted :: proc(c: rl.Color, k: f32) -> rl.Color {
	return {c.r, c.g, c.b, u8(clamp(k, 0, 1) * 255)}
}

// A colour already scaled by `gain`, with `reach` as its alpha, for the
// light map's blend (prepare).
@(private = "file")
premultiplied :: proc(c: rl.Color, gain, reach: f32) -> rl.Color {
	k := clamp(gain, 0, 1)
	return {u8(f32(c.r) * k), u8(f32(c.g) * k), u8(f32(c.b) * k), u8(clamp(reach, 0, 1) * 255)}
}

@(private = "file")
prepare :: proc(r: ^render.Renderer, f: ^render.Post_Frame) {
	ensure(f)
	lights: [MAX_LIGHTS]Light
	n := gather(r, f, &lights)

	if r.setting[LIGHT_STRENGTH] > 0 {
		inv := 1 / f32(LIGHT_DIV)
		rl.BeginTextureMode(st.light)
		// Cleared clear, not black: the alpha is the reach into shadow.
		rl.ClearBackground({})
		// Added as they are, colour and reach both already scaled (the
		// falloff has its shape in its alpha too), so the colour takes the
		// gain and the alpha takes the reach, apart.
		rlgl.SetBlendFactorsSeparate(rlgl.ONE, rlgl.ONE, rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD, rlgl.FUNC_ADD)
		rl.BeginBlendMode(.CUSTOM_SEPARATE)
		src := rl.Rectangle{0, 0, FALLOFF_SIZE, FALLOFF_SIZE}
		for l in lights[:n] {
			rad := l.radius * inv
			rl.DrawTexturePro(st.falloff, src, {l.at.x * inv - rad, l.at.y * inv - rad, rad * 2, rad * 2}, {}, 0, premultiplied(l.colour, l.gain, l.reach))
		}
		rl.EndBlendMode()
		rl.EndTextureMode()
	}

	if r.setting[GLOW_STRENGTH] > 0 {
		inv := 1 / f32(GLOW_DIV)
		rl.BeginTextureMode(st.emit)
		rl.ClearBackground(rl.BLACK)
		rl.BeginBlendMode(.ADDITIVE)
		for &layer in r.layers {
			for it in layer {
				if it.emit <= 0 || it.tint.a == 0 {
					continue
				}
				d := it.dst
				d.x, d.y = (d.x + render.VIEW_X) * f.scale * inv, d.y * f.scale * inv
				d.width, d.height = d.width * f.scale * inv, d.height * f.scale * inv
				rl.DrawTexturePro(it.texture, it.src, d, {}, 0, tinted(rl.WHITE, it.emit * f32(it.tint.a) / 255))
			}
		}
		// A spark is a point of light: a small bright square of its colour.
		for pt in f.particles.live {
			if pt.fade >= 32 {
				continue
			}
			c := [3]f32{f32(pt.shade[0]), f32(pt.shade[1]), f32(pt.shade[2])} / 31
			if 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < SPARK_MIN_LUMA {
				continue
			}
			x := (f32(sim.trunc_i32(pt.loc.x - f.side)) + render.VIEW_X) * f.scale * inv
			y := f32(sim.trunc_i32(pt.loc.y)) * f.scale * inv
			k := 7 * f.scale * inv
			rl.DrawRectangleRec({x, y, k, k}, tinted({u8(c.r * 255), u8(c.g * 255), u8(c.b * 255), 255}, 1 - f32(pt.fade) / 32))
		}
		rl.EndBlendMode()
		rl.EndTextureMode()

		// Two rounds of a separable blur, the second wider: across, down,
		// across, down. A render texture is bottom-up, so each hop draws it
		// flipped to land the right way up again.
		hops := [4]struct {
			from, to: ^rl.RenderTexture2D,
			dir:      [2]f32,
		}{
			{&st.emit, &st.blur_a, {1, 0}},
			{&st.blur_a, &st.blur_b, {0, 1}},
			{&st.blur_b, &st.blur_a, {2.5, 0}},
			{&st.blur_a, &st.blur_b, {0, 2.5}},
		}
		w, h := f32(st.blur_a.texture.width), f32(st.blur_a.texture.height)
		for hop in hops {
			rl.BeginTextureMode(hop.to^)
			rl.BeginShaderMode(st.blur)
			step := [2]f32{hop.dir.x / w, hop.dir.y / h}
			rl.SetShaderValue(st.blur, st.blur_dir, &step, .VEC2)
			rl.DrawTexturePro(hop.from.texture, {0, 0, w, -h}, {0, 0, w, h}, {}, 0, rl.WHITE)
			rl.EndShaderMode()
			rl.EndTextureMode()
		}
	}
}

// The level's specular and shadow masks as one texture: gloss in red, where
// the sun reaches in alpha (a grey-alpha texture reads as r, r, r, a). The
// composite has no sampler to spare for a second map-sized mask, so they
// share one, built once a level. Not ok where the level has no shadow mask
// (or one of another size than its specular).
@(private = "file")
ground_texture :: proc(r: ^render.Renderer, layers: data.Level_Layers) -> (tex: rl.Texture2D, ok: bool) {
	key := strings.concatenate({layers.specular, "|", layers.shadow_mask}, context.temp_allocator)
	if key != st.ground_key {
		rl.UnloadTexture(st.ground)
		st.ground = {}
		delete(st.ground_key)
		st.ground_key = strings.clone(key)
		st.ground = ground_make(r, layers)
	}
	return st.ground, st.ground.id != 0
}

@(private = "file")
ground_make :: proc(r: ^render.Renderer, layers: data.Level_Layers) -> (tex: rl.Texture2D) {
	if layers.shadow_mask == "" {
		return
	}
	load :: proc(r: ^render.Renderer, id: string) -> (img: rl.Image) {
		if id == "" {
			return
		}
		img = rl.LoadImage(strings.clone_to_cstring(data.assets_image_path(&r.textures.assets, id), context.temp_allocator))
		if img.data != nil {
			rl.ImageFormat(&img, .UNCOMPRESSED_GRAYSCALE)
		}
		return
	}
	shadow := load(r, layers.shadow_mask)
	if shadow.data == nil {
		return
	}
	defer rl.UnloadImage(shadow)
	spec := load(r, layers.specular)
	if spec.data != nil {
		defer rl.UnloadImage(spec)
		if spec.width != shadow.width || spec.height != shadow.height {
			return
		}
	}
	out := rl.GenImageColor(shadow.width, shadow.height, {})
	rl.ImageFormat(&out, .UNCOMPRESSED_GRAY_ALPHA)
	defer rl.UnloadImage(out)
	n := int(shadow.width * shadow.height)
	px := ([^]u8)(out.data)[:n * 2]
	lit := ([^]u8)(shadow.data)[:n]
	for i in 0 ..< n {
		px[i * 2] = spec.data != nil ? ([^]u8)(spec.data)[i] : u8(SPECULAR_DEFAULT * 255)
		px[i * 2 + 1] = lit[i]
	}
	tex = rl.LoadTextureFromImage(out)
	if tex.id != 0 {
		rl.SetTextureFilter(tex, .BILINEAR)
		rl.SetTextureWrap(tex, .CLAMP)
	}
	return
}

// A level's layer image, filtered smooth and clamped at its edge once.
@(private = "file")
layer_texture :: proc(r: ^render.Renderer, id: string) -> (tex: rl.Texture2D, ok: bool) {
	if id == "" {
		return
	}
	tex, ok = render.im16_texture(&r.textures, &r.textures.images, id)
	if ok && !st.filtered[tex.id] {
		st.filtered[tex.id] = true
		rl.SetTextureFilter(tex, .BILINEAR)
		rl.SetTextureWrap(tex, .CLAMP)
	}
	return
}

@(private = "file")
apply :: proc(r: ^render.Renderer, f: ^render.Post_Frame, src: rl.Texture2D) {
	// Gains: the sliders, scaled so full is strong but not blinding.
	light_gain := f32(r.setting[LIGHT_STRENGTH]) / 100 * 1.0
	glow_gain := f32(r.setting[GLOW_STRENGTH]) / 100 * 1.8
	// The ground's gloss: the level's specular mask, at the map's pixels.
	spec, normals, map_rect := st.plain, st.flat, [4]f32{0, 0, 1, 1}
	has_shadow := f32(0)
	if s := f.state; s != nil {
		level := sim.level_def(s)
		if media := data.assets_level_media(&r.textures.assets, level.campaign, level.id); media != nil {
			tex, ok := ground_texture(r, media.layers)
			if ok {
				has_shadow = 1
			} else {
				tex, ok = layer_texture(r, media.layers.specular)
			}
			if ok {
				spec = tex
				mw, mh := f32(tex.width), f32(tex.height)
				map_rect = {max(f.side + 32, 0) / mw, f.view_top / mh, f32(sim.view_width(s.defs)) / mw, f32(sim.view_height(s.defs)) / mh}
			}
			if n, found := layer_texture(r, media.layers.normal); found {
				normals = n
			}
		}
	}
	spec_gain := f32(r.setting[LIGHT_STRENGTH]) / 100 * SPECULAR_GAIN
	canvas := [2]f32{f32(f.width), f32(f.height)}
	field := [4]f32{render.VIEW_X * f.scale, 0, render.PLAY_W * f.scale, render.PLAY_H * f.scale}
	rl.BeginShaderMode(st.composite)
	rl.SetShaderValue(st.composite, st.spec_gain, &spec_gain, .FLOAT)
	rl.SetShaderValue(st.composite, st.canvas_loc, &canvas, .VEC2)
	rl.SetShaderValue(st.composite, st.field_loc, &field, .VEC4)
	rl.SetShaderValue(st.composite, st.map_loc, &map_rect, .VEC4)
	rl.SetShaderValue(st.composite, st.shadow_loc, &has_shadow, .FLOAT)
	rl.SetShaderValueTexture(st.composite, st.spec_loc, spec)
	rl.SetShaderValueTexture(st.composite, st.normal_loc, normals)
	texel := [2]f32{1 / f32(st.light.texture.width), 1 / f32(st.light.texture.height)}
	rl.SetShaderValue(st.composite, st.texel_loc, &texel, .VEC2)
	rl.SetShaderValue(st.composite, st.light_k, &light_gain, .FLOAT)
	rl.SetShaderValue(st.composite, st.glow_k, &glow_gain, .FLOAT)
	rl.SetShaderValueTexture(st.composite, st.lights_loc, st.light.texture)
	rl.SetShaderValueTexture(st.composite, st.glow_loc, st.blur_b.texture)
	w, h := f32(src.width), f32(src.height)
	rl.DrawTexturePro(src, {0, 0, w, -h}, {0, 0, w, h}, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}
