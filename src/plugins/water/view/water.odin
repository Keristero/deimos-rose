package water_view

// The water, drawn over the ground and what stands on it, under the air
// units' shadows and everything above (an effect system at layer 6, so a
// ship or a shot over the water is not tinted by its reflection). One quad
// over the play field, run by one fragment shader; the level's media mask
// (the simulation's own, 0x1f where the ground is water) is the shader's
// texture, so it costs nothing outside the water.
//
// The shader adds three things to the art, which already shows the water
// as a translucent layer over the bed: waves, summed sines whose slope
// bends the reflection; a reflection, a sky with clouds that drift with the
// wind; and the sun's glint on the wave faces.
//
// Where a ground shot lands in the water a ring goes out and bounces off the
// banks (ripples.odin), added to the same slope.
//
// Provisional: the sky and the glint are procedural, not the level's skybox; the wind's units (a
// strength of 1 drifts 48 pixels a second) and every gain were picked by
// eye. See docs/realtime-effects.md.

import "core:math"

import rl "vendor:raylib"

import "dr:data"
import "dr:plugins/water"
import "dr:prefs"
import "dr:render"
import "dr:sim"

STRENGTH: prefs.Setting_ID // how strong the water's reflection and glint are

@(private = "file") CALM_DRIFT :: 8 // pixels a second with no wind
@(private = "file") WIND_DRIFT :: 40 // more, for a wind of strength 1

@(private = "file")
State :: struct {
	ready:     bool,
	built:     bool,         // the mask is made for `keyed`, or the level has no water
	shader:    rl.Shader,
	mask:      rl.Texture2D, // 255 in the water; none when the level has none
	keyed:     rawptr,       // the media the mask was made from
	size:      [2]f32,       // the mask's size, in background pixels
	wind:      [2]f32,       // pixels a second
	roughness: f32,          // 0..1, from the wind's strength
	colour:    [3]f32,
	sun:       [3]f32,       // towards the sun
	loc:       struct {
		time, mask_size, strength, tint, wind, rough, sun, ripples, ripple_px: i32,
	},
}

@(private = "file")
st: State

register :: proc() {
	STRENGTH = prefs.setting_register({plugin = water.ID, key = "water_strength", label = "WATER STRENGTH", kind = .Percent, default = 60})
	render.effect_system_register({
		name   = "water",
		plugin = water.ID,
		step   = step,
		draw   = draw,
		layer  = 6,
		clear  = clear,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/water/view register", register)
}

@(private = "file")
clear :: proc() {
	if st.mask.id != 0 {
		rl.UnloadTexture(st.mask)
	}
	st.mask, st.keyed, st.built = {}, nil, false
	ripples_clear()
}

@(private = "file")
step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	build(r, s)
	if st.mask.id != 0 && r.setting[STRENGTH] > 0 {
		ripples_step(s)
	}
}

// Makes the mask, and what is read from the level's record, once a level.
@(private = "file")
build :: proc(r: ^render.Renderer, s: ^sim.State) {
	lv := sim.level_def(s)
	key := raw_data(lv.media)
	if st.built && key == st.keyed {
		return
	}
	clear()
	st.built, st.keyed = true, key
	if len(lv.media) == 0 || lv.media_scale < 1 {
		return
	}
	// The mask, one byte a pixel: 255 in the water, so the filter softens
	// the shore.
	any_water := false
	px := make([]u8, len(lv.media), context.temp_allocator)
	for v, i in lv.media {
		if v == 0x1f {
			px[i] = 255
			any_water = true
		}
	}
	if !any_water {
		return
	}
	img := rl.Image{data = raw_data(px), width = lv.media_w, height = lv.media_h, mipmaps = 1, format = .UNCOMPRESSED_GRAYSCALE}
	st.mask = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(st.mask, .BILINEAR)
	rl.SetTextureWrap(st.mask, .CLAMP)
	st.size = {f32(lv.media_w * lv.media_scale), f32(lv.media_h * lv.media_scale)}
	ripples_build(lv.media, int(lv.media_w), int(lv.media_scale), st.size)

	st.wind, st.roughness, st.colour = {}, 0.15, {0.35, 0.5, 0.6}
	st.sun = {0.4, 0.5, 0.77}
	if media := data.assets_level_media(&r.textures.assets, lv.campaign, lv.id); media != nil {
		a := math.to_radians(media.wind.direction_degrees)
		push := media.wind.strength
		speed := CALM_DRIFT + WIND_DRIFT * push
		dir := [2]f32{math.sin(a), -math.cos(a)}
		if push == 0 {
			dir = {0.6, 0.8}
		}
		st.wind = dir * speed
		st.roughness = clamp(0.15 + 0.85 * push, 0, 1)
		if media.water.visible || media.water.colour != {} {
			st.colour = {f32(media.water.colour[0]), f32(media.water.colour[1]), f32(media.water.colour[2])} / 255
		}
		l := media.lighting
		if l.sun_elevation_degrees != 0 {
			az, el := math.to_radians(l.sun_azimuth_degrees), math.to_radians(l.sun_elevation_degrees)
			st.sun = {math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)}
		}
	}
}

@(private = "file")
FRAGMENT :: `#version 330
#define RIPPLE_SLOPE 6.0     // how much a ripple's slope bends the reflection
in vec2 fragTexCoord;
uniform sampler2D texture0; // the water mask
uniform float time;
uniform vec2 maskSize;      // the mask's size, in background pixels
uniform float strength;
uniform vec3 tint;
uniform vec2 wind;          // pixels a second
uniform float rough;        // 0 glassy .. 1 stormy
uniform vec3 sun;
uniform sampler2D ripples;  // the height of the ripples, over the same area as the mask
uniform vec2 ripplePx;      // a ripple cell, in texture coordinates
out vec4 finalColor;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
	           mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * noise(p);
		p = p * 2.03 + 17.0;
		a *= 0.5;
	}
	return v;
}

void main() {
	float m = texture(texture0, fragTexCoord).r;
	if (m < 0.01) {
		discard;
	}
	vec2 p = fragTexCoord * maskSize; // the ground's pixel
	vec2 dir = normalize(wind);
	vec2 across = vec2(-dir.y, dir.x);

	// Waves: four sines, along the wind and a little to either side. The
	// slope n is each one's derivative.
	vec2 n = vec2(0.0);
	float amp = 0.25 + 0.75 * rough;
	vec2 k[4] = vec2[4](dir * 0.21, dir * 0.13 + across * 0.07, dir * 0.31 - across * 0.11, dir * 0.07 + across * 0.19);
	float w[4] = float[4](1.9, 1.3, 2.6, 0.9);
	float a[4] = float[4](1.0, 0.8, 0.45, 0.6);
	for (int i = 0; i < 4; i++) {
		float ph = dot(k[i], p) - w[i] * time * (0.5 + rough);
		n += k[i] * a[i] * cos(ph) * amp;
	}

	// Ripples from shots that landed: the slope of their height.
	n += RIPPLE_SLOPE * 0.5 * vec2(
		texture(ripples, fragTexCoord + vec2(ripplePx.x, 0.0)).r - texture(ripples, fragTexCoord - vec2(ripplePx.x, 0.0)).r,
		texture(ripples, fragTexCoord + vec2(0.0, ripplePx.y)).r - texture(ripples, fragTexCoord - vec2(0.0, ripplePx.y)).r);

	// The sky the water mirrors: bent by the slope, clouds drifting.
	vec2 q = p * 0.0045 + n * 0.5 + wind * time * 0.0004;
	float c = smoothstep(0.42, 0.78, fbm(q));
	vec3 sky = mix(vec3(0.46, 0.64, 0.86), vec3(0.95, 0.96, 0.98), c * 0.9);
	sky = mix(sky, tint, 0.25);

	// The sun's glint on the faces turned towards it.
	vec3 normal = normalize(vec3(-n * 0.6, 1.0));
	vec3 h = normalize(sun + vec3(0.0, 0.0, 1.0));
	float glint = pow(max(dot(normal, h), 0.0), 90.0);

	float reflectance = 0.22 + 0.2 * length(n) + 0.14 * c;
	float alpha = m * strength * clamp(reflectance + glint * 0.9, 0.0, 1.0);
	finalColor = vec4(mix(sky, vec3(1.0, 0.97, 0.88), clamp(glint * 2.0, 0.0, 1.0)), alpha);
}
`

@(private = "file")
draw :: proc(r: ^render.Renderer, scale, side, t: f32) {
	if st.mask.id == 0 || r.setting[STRENGTH] == 0 {
		return
	}
	if !st.ready {
		st.ready = true
		st.shader = rl.LoadShaderFromMemory(nil, FRAGMENT)
		st.loc.time = rl.GetShaderLocation(st.shader, "time")
		st.loc.mask_size = rl.GetShaderLocation(st.shader, "maskSize")
		st.loc.strength = rl.GetShaderLocation(st.shader, "strength")
		st.loc.tint = rl.GetShaderLocation(st.shader, "tint")
		st.loc.wind = rl.GetShaderLocation(st.shader, "wind")
		st.loc.rough = rl.GetShaderLocation(st.shader, "rough")
		st.loc.sun = rl.GetShaderLocation(st.shader, "sun")
		st.loc.ripples = rl.GetShaderLocation(st.shader, "ripples")
		st.loc.ripple_px = rl.GetShaderLocation(st.shader, "ripplePx")
	}
	// What draw_terrain shows, in the same place, taken from the mask.
	w, h := f32(render.PLAY_W), f32(render.PLAY_H)
	left := max(side + 32, 0)
	k := st.size.x / f32(st.mask.width) // background pixels a mask pixel
	src := rl.Rectangle{left / k, r.view_top / k, w / k, h / k}
	dst := rl.Rectangle{render.VIEW_X * scale, 0, w * scale, h * scale}

	time := f32(rl.GetTime())
	strength := f32(r.setting[STRENGTH]) / 100
	rl.BeginShaderMode(st.shader)
	rl.SetShaderValue(st.shader, st.loc.time, &time, .FLOAT)
	rl.SetShaderValue(st.shader, st.loc.mask_size, &st.size, .VEC2)
	rl.SetShaderValue(st.shader, st.loc.strength, &strength, .FLOAT)
	rl.SetShaderValue(st.shader, st.loc.tint, &st.colour, .VEC3)
	rl.SetShaderValue(st.shader, st.loc.wind, &st.wind, .VEC2)
	rl.SetShaderValue(st.shader, st.loc.rough, &st.roughness, .FLOAT)
	rl.SetShaderValue(st.shader, st.loc.sun, &st.sun, .VEC3)
	rl.SetShaderValueTexture(st.shader, st.loc.ripples, ripple_texture())
	cell := ripple_cell()
	rl.SetShaderValue(st.shader, st.loc.ripple_px, &cell, .VEC2)
	rl.DrawTexturePro(st.mask, src, dst, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}
