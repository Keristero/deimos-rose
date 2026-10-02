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

import rl "vendor:raylib"

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
@(private = "file") SPARK_MIN_LUMA :: 0.55 // a spark casts light when it is at least this bright

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
in vec2 fragTexCoord;
uniform sampler2D texture0; // the scene
uniform sampler2D lights;
uniform sampler2D glow;
uniform float lightGain;
uniform float glowGain;
out vec4 finalColor;
void main() {
	vec3 scene = texture(texture0, fragTexCoord).rgb;
	vec3 light = texture(lights, fragTexCoord).rgb * lightGain;
	vec3 halo = texture(glow, fragTexCoord).rgb * glowGain;
	// The light shows the colour it falls on, and a little of its own where
	// that is dark, so a spark over black ground still lights something.
	vec3 lit = scene * (1.0 + 0.9 * light) + 0.05 * light;
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
				px[y * FALLOFF_SIZE + x] = {v, v, v, 255}
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
shine_colour :: proc(it: render.Item) -> rl.Color {
	key := Colour_Key{i32(it.texture.id), i32(it.src.x), i32(it.src.y), i32(it.src.width), i32(it.src.height)}
	if c, ok := st.colours[key]; ok {
		return c
	}
	img, have := st.plates[it.texture.id]
	if !have {
		img = rl.LoadImageFromTexture(it.texture)
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
		st.plates[it.texture.id] = img
	}
	sum: [3]f32
	weight: f32
	px := ([^]rl.Color)(img.data)[:img.width * img.height]
	x0, y0 := int(it.src.x), int(it.src.y)
	for y in y0 ..< min(y0 + int(it.src.height), int(img.height)) {
		for x in x0 ..< min(x0 + int(it.src.width), int(img.width)) {
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
			out[n] = {
				at     = {(it.dst.x + it.dst.width / 2 + render.VIEW_X) * f.scale, (it.dst.y + it.dst.height / 2) * f.scale},
				radius = (size * LIGHT_REACH + LIGHT_MIN_RADIUS) * f.scale,
				colour = shine_colour(it),
				gain   = it.emit * f32(it.tint.a) / 255,
			}
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

@(private = "file")
prepare :: proc(r: ^render.Renderer, f: ^render.Post_Frame) {
	ensure(f)
	lights: [MAX_LIGHTS]Light
	n := gather(r, f, &lights)

	if r.setting[LIGHT_STRENGTH] > 0 {
		inv := 1 / f32(LIGHT_DIV)
		rl.BeginTextureMode(st.light)
		rl.ClearBackground(rl.BLACK)
		rl.BeginBlendMode(.ADDITIVE)
		src := rl.Rectangle{0, 0, FALLOFF_SIZE, FALLOFF_SIZE}
		for l in lights[:n] {
			rad := l.radius * inv
			rl.DrawTexturePro(st.falloff, src, {l.at.x * inv - rad, l.at.y * inv - rad, rad * 2, rad * 2}, {}, 0, tinted(l.colour, l.gain))
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

@(private = "file")
apply :: proc(r: ^render.Renderer, f: ^render.Post_Frame, src: rl.Texture2D) {
	// Gains: the sliders, scaled so full is strong but not blinding.
	light_gain := f32(r.setting[LIGHT_STRENGTH]) / 100 * 1.0
	glow_gain := f32(r.setting[GLOW_STRENGTH]) / 100 * 1.8
	rl.BeginShaderMode(st.composite)
	rl.SetShaderValue(st.composite, st.light_k, &light_gain, .FLOAT)
	rl.SetShaderValue(st.composite, st.glow_k, &glow_gain, .FLOAT)
	rl.SetShaderValueTexture(st.composite, st.lights_loc, st.light.texture)
	rl.SetShaderValueTexture(st.composite, st.glow_loc, st.blur_b.texture)
	w, h := f32(src.width), f32(src.height)
	rl.DrawTexturePro(src, {0, 0, w, -h}, {0, 0, w, h}, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}
