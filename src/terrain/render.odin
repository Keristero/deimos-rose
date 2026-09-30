package terrain

// The renderer: a project drawn from straight above, lit by its level's sun,
// as the originals' maps were (notes/headless-3d-to-2d-pipeline.md). One
// fragment shader does the colour, the light and the shadow; exports draw it
// over the whole target in strips, each output pixel from its own map
// position, so a map drawn in strips is the map drawn at once. Needs a GL
// context: the editor's window, or a hidden one (tools/terrain).

import "core:math"
import "core:strings"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import "dr:data"

Output :: enum {
	Lit,    // the map as the game shows it
	Albedo, // unlit colour
	Normal, // the surface's normal, n*0.5+0.5 with z up
	Height, // 16-bit grey, in HEIGHT_UNIT: the heightmap resampled
	Shadow, // how much of the sun reaches the ground, grey
}

// No strip is taller than this, in output pixels.
STRIP_MAX :: 4096
// The geometry is drawn smoothed by a Gaussian this wide (its sigma, in map
// pixels): faint, so a heightmap's per-pixel steps and facets shade as a
// smooth surface, as a mesh with smooth vertex normals would. The project's
// heights are left as they are, and the height output is theirs.
GEOMETRY_SMOOTHING :: 1.0
// The longest shadow walked, in map pixels.
MARCH_MAX :: 4096

// The textures, by the material slot DrawMesh binds each to. The height
// texture holds the surface (ground, then canopy) in R, the canopy's cover
// in G and the bare ground in B, those two smoothed, and the surface as it
// is in A.
@(private = "file")
Slot :: enum {
	Height,
	Albedo,
	Splat,
	Material_0,
	Material_1,
	Material_2,
	Material_3,
}

@(private = "file")
SAMPLERS := [Slot]cstring {
	.Height     = "heights",
	.Albedo     = "albedo",
	.Splat      = "splat",
	.Material_0 = "material0",
	.Material_1 = "material1",
	.Material_2 = "material2",
	.Material_3 = "material3",
}

Renderer :: struct {
	shader:     rl.Shader,
	quad:       rl.Mesh,
	maps:       [rl.MAX_MATERIAL_MAPS]rl.MaterialMap,
	textures:   [Slot]rl.Texture2D, // zero where the white one stands in
	white:      rl.Texture2D,
	width:      int,
	length:     int,
	max_height: f32,
}

// Uploads the project, its geometry smoothed by `smoothing` (a Gaussian's
// sigma in map pixels, 0 for none). Call again after changing its layers.
renderer_init :: proc(r: ^Renderer, p: ^Project, smoothing: f32 = GEOMETRY_SMOOTHING) -> bool {
	if r.shader.id == 0 {
		r.shader = rl.LoadShaderFromMemory(VERTEX_SHADER, TERRAIN_SHADER)
		if !rl.IsShaderValid(r.shader) {
			return false
		}
		for name, slot in SAMPLERS {
			r.shader.locs[int(rl.ShaderLocationIndex.MAP_ALBEDO) + int(slot)] = rl.GetShaderLocation(r.shader, name)
		}
		r.quad = quad_mesh()
		white := rl.GenImageColor(1, 1, rl.WHITE)
		r.white = rl.LoadTextureFromImage(white)
		rl.UnloadImage(white)
	}
	for &t in r.textures {
		if t.id != 0 {
			rl.UnloadTexture(t)
		}
		t = {}
	}
	r.width, r.length = p.width, p.length

	// Heights: the surface with the canopy on it, the cover, the ground,
	// the surface unsmoothed.
	n := p.width * p.length
	h := make([]f32, n * 4, context.temp_allocator)
	r.max_height = p.level.water.visible ? p.level.water.height : 0
	for i in 0 ..< n {
		cover := p.canopy != nil ? f32(p.canopy[i]) / 255 : 0
		h[i * 4 + 0] = p.heights[i] + cover * p.canopy_height
		h[i * 4 + 1] = cover
		h[i * 4 + 2] = p.heights[i]
		h[i * 4 + 3] = h[i * 4 + 0]
		r.max_height = max(r.max_height, h[i * 4])
	}
	smooth(h, p.width, p.length, 0, smoothing)
	smooth(h, p.width, p.length, 2, smoothing)
	r.textures[.Height] = upload(raw_data(h), p.width, p.length, .UNCOMPRESSED_R32G32B32A32, .CLAMP)
	if p.albedo != nil {
		r.textures[.Albedo] = upload(raw_data(p.albedo), p.width, p.length, .UNCOMPRESSED_R8G8B8, .CLAMP)
	}
	if p.splat != nil {
		r.textures[.Splat] = upload(raw_data(p.splat), p.width, p.length, .UNCOMPRESSED_R8G8B8A8, .CLAMP)
	}
	for img, i in p.material_images {
		if img.pixels == nil || img.depth != 8 {
			continue
		}
		FORMATS := [5]rl.PixelFormat{{}, .UNCOMPRESSED_GRAYSCALE, .UNCOMPRESSED_GRAY_ALPHA, .UNCOMPRESSED_R8G8B8, .UNCOMPRESSED_R8G8B8A8}
		r.textures[Slot(int(Slot.Material_0) + i)] = upload(raw_data(img.pixels), img.width, img.height, FORMATS[img.channels], .REPEAT)
	}
	for t, slot in r.textures {
		r.maps[slot].texture = t.id != 0 ? t : r.white
	}
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	for t in r.textures {
		if t.id != 0 {
			rl.UnloadTexture(t)
		}
	}
	if r.shader.id != 0 {
		rl.UnloadMesh(r.quad)
		rl.UnloadTexture(r.white)
		rl.UnloadShader(r.shader)
	}
	r^ = {}
}

Render_Options :: struct {
	output: Output,
	scale:  int, // output pixels per map pixel; 0 for 1
	// Map rows [from, to), to 0 for the map's end.
	from:   int,
	to:     int,
	// Rows drawn at a time, in output pixels; 0 for STRIP_MAX.
	strip:  int,
	// Through the originals' 15-bit colour, as their maps were stored.
	quantise_1555: bool,
}

// Draws the map, or its rows [from, to), into a new picture: RGB, or grey
// for Height (16-bit) and Shadow.
render :: proc(r: ^Renderer, p: ^Project, o: Render_Options, allocator := context.allocator) -> (pic: Picture, ok: bool) {
	scale := max(o.scale, 1)
	to := o.to > 0 ? min(o.to, p.length) : p.length
	from := clamp(o.from, 0, to)
	strip := clamp(o.strip > 0 ? o.strip : STRIP_MAX, scale, STRIP_MAX) / scale // in map rows
	w := p.width * scale
	if w > STRIP_MAX || w == 0 || from == to {
		return
	}
	channels := 3
	depth := 8
	#partial switch o.output {
	case .Height:
		channels, depth = 1, 16
	case .Shadow:
		channels = 1
	}
	pic = picture_make(w, (to - from) * scale, channels, depth, allocator)

	target := rl.LoadRenderTexture(i32(w), i32(strip * scale))
	defer rl.UnloadRenderTexture(target)
	if !rl.IsRenderTextureValid(target) {
		picture_destroy(&pic, allocator)
		return
	}
	uniforms(r, p, o.output, f32(scale))
	material := rl.Material {
		shader = r.shader,
		maps   = raw_data(r.maps[:]),
	}
	for y0 := from; y0 < to; y0 += strip {
		rows := min(strip, to - y0)
		origin := [2]f32{0, f32(y0)}
		rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "origin"), &origin, .VEC2)
		rl.BeginTextureMode(target)
		rl.ClearBackground(rl.BLACK)
		rlgl.DisableBackfaceCulling()
		rl.DrawMesh(r.quad, material, rl.Matrix(1))
		rlgl.EnableBackfaceCulling()
		rl.EndTextureMode()

		img := rl.LoadImageFromTexture(target.texture)
		defer rl.UnloadImage(img)
		// The target's first row is gl_FragCoord.y 0.5: the strip's top.
		src := ([^]u8)(img.data)
		for y in 0 ..< rows * scale {
			out_y := (y0 - from) * scale + y
			for x in 0 ..< w {
				s := src[(y * w + x) * 4:][:4]
				d := out_y * w + x
				switch o.output {
				case .Height:
					(transmute([]u16)pic.pixels)[d] = u16(s[0]) << 8 | u16(s[1])
				case .Shadow:
					pic.pixels[d] = s[0]
				case .Lit, .Albedo, .Normal:
					copy(pic.pixels[d * 3:][:3], s[:3])
				}
			}
		}
	}
	if o.quantise_1555 && channels == 3 {
		quantise_1555(pic)
	}
	return pic, true
}

// Each colour through 5 bits a channel and back, as the originals'
// 16-bit images were.
quantise_1555 :: proc(pic: Picture) {
	expand :: proc "contextless" (c: u16) -> u8 {
		return u8(c << 3 | c >> 2)
	}
	for i in 0 ..< pic.width * pic.height {
		px := pic.pixels[i * 3:][:3]
		v := data.rgb_to_1555(px[0], px[1], px[2])
		px[0], px[1], px[2] = expand(v >> 10 & 31), expand(v >> 5 & 31), expand(v & 31)
	}
}

// The unit vector toward the sun in map space: x right, y down, z up.
sun_direction :: proc(l: data.Level_Lighting) -> [3]f32 {
	a := math.to_radians(l.sun_azimuth_degrees)
	e := math.to_radians(l.sun_elevation_degrees)
	return {math.cos(a) * math.cos(e), -math.sin(a) * math.cos(e), math.sin(e)}
}

@(private = "file")
uniforms :: proc(r: ^Renderer, p: ^Project, output: Output, scale: f32) {
	set :: proc(r: ^Renderer, name: cstring, v: $T) {
		v := v
		loc := rl.GetShaderLocation(r.shader, name)
		when T == f32 {
			rl.SetShaderValue(r.shader, loc, &v, .FLOAT)
		} else when T == i32 {
			rl.SetShaderValue(r.shader, loc, &v, .INT)
		} else when T == [2]f32 {
			rl.SetShaderValue(r.shader, loc, &v, .VEC2)
		} else when T == [3]f32 {
			rl.SetShaderValue(r.shader, loc, &v, .VEC3)
		} else {
			#panic("uniform type")
		}
	}
	colour :: proc(c: [3]u8) -> [3]f32 {
		return {f32(c.r), f32(c.g), f32(c.b)} / 255
	}
	l := p.level.lighting
	set(r, "size", [2]f32{f32(p.width), f32(p.length)})
	set(r, "scale", scale)
	set(r, "mode", i32(output))
	set(r, "sun", sun_direction(l))
	set(r, "sunColour", colour(l.sun_colour))
	set(r, "ambientColour", colour(l.ambient_colour))
	set(r, "ambient", l.ambient)
	set(r, "softness", max(l.softness, 0))
	set(r, "maxHeight", r.max_height)
	set(r, "marchMax", i32(MARCH_MAX))
	set(r, "heightUnit", HEIGHT_UNIT)
	w := p.level.water
	set(r, "waterHeight", w.height)
	set(r, "waterVisible", i32(w.visible))
	set(r, "waterColour", colour(w.colour))
	set(r, "hasAlbedo", i32(p.albedo != nil))
	set(r, "hasSplat", i32(p.splat != nil))
	set(r, "materialCount", i32(min(len(p.materials), MAX_MATERIALS)))
	for m, i in p.materials[:min(len(p.materials), MAX_MATERIALS)] {
		name := strings.clone_to_cstring(fmt_index("materialColour", i), context.temp_allocator)
		set(r, name, colour(m.colour))
		name = strings.clone_to_cstring(fmt_index("materialTile", i), context.temp_allocator)
		set(r, name, m.tile > 0 ? m.tile : 64)
		name = strings.clone_to_cstring(fmt_index("materialImage", i), context.temp_allocator)
		set(r, name, i32(r.textures[Slot(int(Slot.Material_0) + i)].id != 0))
	}
	rule :: proc(r: ^Renderer, name: cstring, rule: Rule, count: int) {
		set(r, name, [3]f32{rule.material < count ? f32(rule.material) : -1, rule.from, rule.to})
	}
	count := min(len(p.materials), MAX_MATERIALS)
	rule(r, "cliff", p.cliff, count)
	rule(r, "shore", p.shore, count)
	set(r, "canopyMaterial", i32(p.canopy_material < count ? p.canopy_material : -1))
}

@(private = "file")
fmt_index :: proc(name: string, i: int) -> string {
	DIGITS := [4]string{"[0]", "[1]", "[2]", "[3]"}
	return strings.concatenate({name, DIGITS[i]}, context.temp_allocator)
}

// Channel `c` of the RGBA picture `px` (w x l) blurred by a Gaussian of
// `sigma` map pixels, edges repeated: across the rows, then down the columns.
@(private = "file")
smooth :: proc(px: []f32, w, l, c: int, sigma: f32) {
	if sigma <= 0 {
		return
	}
	radius := int(math.ceil(3 * sigma))
	kernel := make([]f32, 2 * radius + 1, context.temp_allocator)
	sum: f32
	for &k, i in kernel {
		x := f32(i - radius)
		k = math.exp(-x * x / (2 * sigma * sigma))
		sum += k
	}
	for &k in kernel {
		k /= sum
	}
	line := make([]f32, max(w, l), context.temp_allocator)
	for y in 0 ..< l {
		for x in 0 ..< w {
			line[x] = px[(y * w + x) * 4 + c]
		}
		for x in 0 ..< w {
			v: f32
			for k, i in kernel {
				v += k * line[clamp(x + i - radius, 0, w - 1)]
			}
			px[(y * w + x) * 4 + c] = v
		}
	}
	for x in 0 ..< w {
		for y in 0 ..< l {
			line[y] = px[(y * w + x) * 4 + c]
		}
		for y in 0 ..< l {
			v: f32
			for k, i in kernel {
				v += k * line[clamp(y + i - radius, 0, l - 1)]
			}
			px[(y * w + x) * 4 + c] = v
		}
	}
}

@(private = "file")
upload :: proc(pixels: rawptr, w, h: int, format: rl.PixelFormat, wrap: rl.TextureWrap) -> rl.Texture2D {
	img := rl.Image {
		data    = pixels,
		width   = i32(w),
		height  = i32(h),
		mipmaps = 1,
		format  = format,
	}
	t := rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(t, .BILINEAR)
	rl.SetTextureWrap(t, wrap)
	return t
}

// Two triangles over the whole target, in clip space.
@(private = "file")
quad_mesh :: proc() -> (m: rl.Mesh) {
	CORNERS := [6][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1}}
	m.vertexCount, m.triangleCount = 6, 2
	m.vertices = ([^]f32)(rl.MemAlloc(6 * 3 * size_of(f32)))
	for c, i in CORNERS {
		m.vertices[i * 3 + 0], m.vertices[i * 3 + 1], m.vertices[i * 3 + 2] = c.x, c.y, 0
	}
	rl.UploadMesh(&m, false)
	return
}

// Clip space in, as it is: the target's pixels are placed by gl_FragCoord.
VERTEX_SHADER :: `#version 330
in vec3 vertexPosition;
void main() {
	gl_Position = vec4(vertexPosition.xy, 0.0, 1.0);
}
`

// Light: ambient, plus the sun by how squarely it meets the ground, scaled
// so that flat ground in the sun is its albedo, times how much of the sun
// is not blocked. Blocked: walking toward the sun a map pixel at a time,
// how far the ray from this point passes under the surface (the penumbra
// `softness` map pixels wide), starting a whole pixel past the penumbra, so
// flat ground is never its own shadow and a ray along a row meets texel
// centres.
TERRAIN_SHADER :: `#version 330
out vec4 finalColor;

uniform sampler2D heights; // R surface, G canopy cover, B ground, smoothed; A surface
uniform sampler2D albedo;
uniform sampler2D splat;
uniform sampler2D material0;
uniform sampler2D material1;
uniform sampler2D material2;
uniform sampler2D material3;

uniform vec2 size;
uniform vec2 origin;
uniform float scale;
uniform int mode;

uniform vec3 sun;
uniform vec3 sunColour;
uniform vec3 ambientColour;
uniform float ambient;
uniform float softness;
uniform float maxHeight;
uniform int marchMax;
uniform float heightUnit;

uniform float waterHeight;
uniform int waterVisible;
uniform vec3 waterColour;

uniform int hasAlbedo;
uniform int hasSplat;
uniform int materialCount;
uniform vec3 materialColour[4];
uniform float materialTile[4];
uniform int materialImage[4];
uniform vec3 cliff; // material, from, to
uniform vec3 shore;
uniform int canopyMaterial;

vec3 at(vec2 map) {
	return texture(heights, map / size).rgb;
}

float unsmoothed(vec2 map) {
	return texture(heights, map / size).a;
}

float surface(vec2 map) {
	float h = at(map).r;
	return waterVisible != 0 ? max(h, waterHeight) : h;
}

vec3 materialAt(int i, vec2 map) {
	vec3 c = materialColour[i];
	if (materialImage[i] == 0) return c;
	vec2 uv = map / materialTile[i];
	vec3 t;
	switch (i) {
	case 0: t = texture(material0, uv).rgb; break;
	case 1: t = texture(material1, uv).rgb; break;
	case 2: t = texture(material2, uv).rgb; break;
	default: t = texture(material3, uv).rgb; break;
	}
	return t * c;
}

float ramp(vec3 rule, float x) {
	if (rule.x < 0.0) return 0.0;
	float t = rule.z == rule.y ? step(rule.y, x) : clamp((x - rule.y) / (rule.z - rule.y), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

vec3 colourAt(vec2 map, vec3 h, vec2 slope) {
	float w[4] = float[4](0.0, 0.0, 0.0, 0.0);
	vec3 base = vec3(0.5);
	float baseWeight = 1.0;
	if (hasSplat != 0) {
		vec4 s = texture(splat, map / size);
		w = float[4](s.r, s.g, s.b, s.a);
	}
	float sum = w[0] + w[1] + w[2] + w[3];
	if (hasAlbedo != 0) {
		base = texture(albedo, map / size).rgb;
		baseWeight = max(1.0 - sum, 0.0);
	} else if (materialCount > 0) {
		if (sum <= 0.0) { w[0] = 1.0; sum = 1.0; }
		for (int i = 0; i < 4; i++) w[i] /= sum;
		baseWeight = 0.0;
	}
	float c = ramp(cliff, length(slope));
	float s = ramp(shore, h.b - waterHeight);
	float g = canopyMaterial >= 0 ? h.g : 0.0;
	float rules[3] = float[3](c, s, g);
	int mats[3] = int[3](int(cliff.x), int(shore.x), canopyMaterial);
	for (int r = 0; r < 3; r++) {
		if (mats[r] < 0 || rules[r] <= 0.0) continue;
		baseWeight *= 1.0 - rules[r];
		for (int i = 0; i < 4; i++) w[i] *= 1.0 - rules[r];
		w[mats[r]] += rules[r];
	}
	vec3 col = base * baseWeight;
	for (int i = 0; i < materialCount; i++) {
		if (w[i] > 0.0) col += materialAt(i, map) * w[i];
	}
	return col;
}

void main() {
	vec2 map = origin + gl_FragCoord.xy / scale;
	vec3 h = at(map);
	bool water = waterVisible != 0 && h.r < waterHeight;
	float h0 = water ? waterHeight : h.r;

	vec2 slope = vec2(at(map + vec2(1.0, 0.0)).r - at(map - vec2(1.0, 0.0)).r,
	                  at(map + vec2(0.0, 1.0)).r - at(map - vec2(0.0, 1.0)).r) * 0.5;
	vec3 n = water ? vec3(0.0, 0.0, 1.0) : normalize(vec3(-slope, 1.0));

	if (mode == 3) {
		float v = clamp(floor((water ? waterHeight : unsmoothed(map)) / heightUnit + 0.5), 0.0, 65535.0);
		float hi = floor(v / 256.0);
		finalColor = vec4(hi / 255.0, (v - hi * 256.0) / 255.0, 0.0, 1.0);
		return;
	}
	if (mode == 2) {
		finalColor = vec4(n * 0.5 + 0.5, 1.0);
		return;
	}
	vec3 col = water ? waterColour : colourAt(map, h, slope);
	if (mode == 1) {
		finalColor = vec4(col, 1.0);
		return;
	}

	float vis = 1.0;
	if (sun.z > 0.0 && length(sun.xy) > 1e-4) {
		vec2 d = normalize(sun.xy);
		float rise = sun.z / length(sun.xy);
		float halfSoft = softness * 0.5;
		float pen = -1e9;
		float dist = floor(halfSoft) + 1.0;
		for (int k = 0; k < marchMax; k++, dist += 1.0) {
			float ray = h0 + rise * dist;
			if (ray - maxHeight > rise * halfSoft) break;
			pen = max(pen, (surface(map + d * dist) - ray) / rise);
		}
		vis = halfSoft > 0.0 ? 1.0 - smoothstep(-halfSoft, halfSoft, pen) : 1.0 - step(0.0, pen);
	}
	if (mode == 4) {
		finalColor = vec4(vec3(vis), 1.0);
		return;
	}
	float direct = sun.z > 0.0 ? max(dot(n, sun), 0.0) / sun.z : 0.0;
	vec3 light = ambient * ambientColour + (1.0 - ambient) * sunColour * direct * vis;
	finalColor = vec4(col * light, 1.0);
}
`
