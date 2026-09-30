package terrain

// The renderer: a project drawn from straight above, lit by its level's sun,
// as the originals' maps were (notes/headless-3d-to-2d-pipeline.md). One
// fragment shader does the colour, the light and the shadow; exports draw it
// over the whole target in strips, each output pixel from its own map
// position, so a map drawn in strips is the map drawn at once. Needs a GL
// context: the editor's window, or a hidden one (tools/terrain).

import "core:math"
import "core:slice"
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
	Occlusion, // how open to the sky the ground is, grey: the project's layer
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
// is in A. The albedo texture holds the occlusion in A. DrawMesh binds
// slots 7-9 as cubemaps, so the water, the eighth, is bound to slot 10
// (map_slot()).
@(private = "file")
Slot :: enum {
	Height,
	Albedo,
	Splat,
	Material_0,
	Material_1,
	Material_2,
	Material_3,
	Water,
}

@(private = "file")
map_slot :: proc(s: Slot) -> int {
	return s == .Water ? int(rl.MaterialMapIndex.BRDF) : int(s)
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
	.Water      = "waterLayer",
}

Renderer :: struct {
	shader:      rl.Shader,
	quad:        rl.Mesh,
	maps:        [rl.MAX_MATERIAL_MAPS]rl.MaterialMap,
	textures:    [Slot]rl.Texture2D, // zero where the white one stands in
	white:       rl.Texture2D,
	width:       int,
	length:      int,
	smoothing:   f32,
	// The highest the surface reaches, where a shadow's march may stop. It
	// only rises with renderer_update: one too high marches further and
	// finds nothing, so it never changes a pixel.
	surface_max: f32,
}

// Uploads the project, its geometry smoothed by `smoothing` (a Gaussian's
// sigma in map pixels, 0 for none). Call again after changing its layers,
// or renderer_update for a changed region.
renderer_init :: proc(r: ^Renderer, p: ^Project, smoothing: f32 = GEOMETRY_SMOOTHING) -> bool {
	if r.shader.id == 0 {
		r.shader = rl.LoadShaderFromMemory(VERTEX_SHADER, TERRAIN_SHADER)
		if !rl.IsShaderValid(r.shader) {
			return false
		}
		for name, slot in SAMPLERS {
			r.shader.locs[int(rl.ShaderLocationIndex.MAP_ALBEDO) + map_slot(slot)] = rl.GetShaderLocation(r.shader, name)
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
	r.width, r.length, r.smoothing = p.width, p.length, smoothing

	n := p.width * p.length
	h: []f32
	h, r.surface_max = height_texels(p, {0, 0, p.width, p.length}, smoothing)
	r.textures[.Height] = upload(raw_data(h), p.width, p.length, .UNCOMPRESSED_R32G32B32A32, .CLAMP)
	if p.albedo != nil || p.occlusion != nil {
		c := make([]u8, n * 4, context.temp_allocator)
		for i in 0 ..< n {
			if p.albedo != nil {
				copy(c[i * 4:][:3], p.albedo[i * 3:][:3])
			}
			c[i * 4 + 3] = p.occlusion != nil ? p.occlusion[i] : 255
		}
		r.textures[.Albedo] = upload(raw_data(c), p.width, p.length, .UNCOMPRESSED_R8G8B8A8, .CLAMP)
	}
	if p.splat != nil {
		r.textures[.Splat] = upload(raw_data(p.splat), p.width, p.length, .UNCOMPRESSED_R8G8B8A8, .CLAMP)
	}
	if p.water != nil {
		r.textures[.Water] = upload(raw_data(p.water), p.width, p.length, .UNCOMPRESSED_R8G8B8A8, .CLAMP)
	}
	renderer_materials(r, p)
	return true
}

// Uploads the materials' images again: after one is added, taken away or
// replaced. Mipmapped, as they are drawn smaller than they are.
renderer_materials :: proc(r: ^Renderer, p: ^Project) {
	for img, i in p.material_images {
		t := &r.textures[Slot(int(Slot.Material_0) + i)]
		if t.id != 0 {
			rl.UnloadTexture(t^)
		}
		t^ = {}
		if img.pixels == nil || img.depth != 8 || i >= len(p.materials) {
			continue
		}
		FORMATS := [5]rl.PixelFormat{{}, .UNCOMPRESSED_GRAYSCALE, .UNCOMPRESSED_GRAY_ALPHA, .UNCOMPRESSED_R8G8B8, .UNCOMPRESSED_R8G8B8A8}
		t^ = upload(raw_data(img.pixels), img.width, img.height, FORMATS[img.channels], .REPEAT)
		rl.GenTextureMipmaps(t)
		rl.SetTextureFilter(t^, .TRILINEAR)
	}
	renderer_bind(r)
}

@(private = "file")
renderer_bind :: proc(r: ^Renderer) {
	for t, slot in r.textures {
		r.maps[map_slot(slot)].texture = t.id != 0 ? t : r.white
	}
}

// A map region, x0 and y0 in it, x1 and y1 past it.
Rect :: struct {
	x0, y0, x1, y1: int,
}

// Uploads again what changed in `rect` of the heights, and of the water
// layer and the material weights when there are any: the same texels
// renderer_init would, and all of a weights layer made since. The
// smoothing spreads a change as far as its kernel reaches, so that much
// around `rect` is uploaded, smoothed over as much again. The editor calls
// it for each brush dab.
renderer_update :: proc(r: ^Renderer, p: ^Project, rect: Rect) {
	m := smoothing_radius(r.smoothing)
	inner := rect_clip({rect.x0 - m, rect.y0 - m, rect.x1 + m, rect.y1 + m}, p.width, p.length)
	if inner.x1 <= inner.x0 || inner.y1 <= inner.y0 {
		return
	}
	outer := rect_clip({inner.x0 - m, inner.y0 - m, inner.x1 + m, inner.y1 + m}, p.width, p.length)
	h, top := height_texels(p, outer, r.smoothing)
	r.surface_max = max(r.surface_max, top)
	ow := outer.x1 - outer.x0
	w, l := inner.x1 - inner.x0, inner.y1 - inner.y0
	block := make([]f32, w * l * 4, context.temp_allocator)
	for y in 0 ..< l {
		copy(block[y * w * 4:][:w * 4], h[((inner.y0 - outer.y0 + y) * ow + inner.x0 - outer.x0) * 4:][:w * 4])
	}
	area := rl.Rectangle{f32(inner.x0), f32(inner.y0), f32(w), f32(l)}
	rl.UpdateTextureRec(r.textures[.Height], area, raw_data(block))
	if p.water != nil && r.textures[.Water].id != 0 {
		wb := make([]u8, w * l * 4, context.temp_allocator)
		for y in 0 ..< l {
			copy(wb[y * w * 4:][:w * 4], p.water[((inner.y0 + y) * p.width + inner.x0) * 4:][:w * 4])
		}
		rl.UpdateTextureRec(r.textures[.Water], area, raw_data(wb))
	}
	if p.splat != nil && r.textures[.Splat].id == 0 {
		r.textures[.Splat] = upload(raw_data(p.splat), p.width, p.length, .UNCOMPRESSED_R8G8B8A8, .CLAMP)
		renderer_bind(r)
	} else if p.splat != nil {
		sb := make([]u8, w * l * 4, context.temp_allocator)
		for y in 0 ..< l {
			copy(sb[y * w * 4:][:w * 4], p.splat[((inner.y0 + y) * p.width + inner.x0) * 4:][:w * 4])
		}
		rl.UpdateTextureRec(r.textures[.Splat], area, raw_data(sb))
	}
}

rect_clip :: proc(r: Rect, width, length: int) -> Rect {
	return {clamp(r.x0, 0, width), clamp(r.y0, 0, length), clamp(r.x1, 0, width), clamp(r.y1, 0, length)}
}

// The height texture's texels for `rect`, RGBA: the surface with the
// canopy on it, the cover, the ground, the surface unsmoothed; the first
// three smoothed within the rect. And the surface's highest point.
@(private = "file")
height_texels :: proc(p: ^Project, rect: Rect, smoothing: f32) -> (h: []f32, top: f32) {
	w, l := rect.x1 - rect.x0, rect.y1 - rect.y0
	h = make([]f32, w * l * 4, context.temp_allocator)
	for y in 0 ..< l {
		for x in 0 ..< w {
			i := (rect.y0 + y) * p.width + rect.x0 + x
			o := (y * w + x) * 4
			cover := p.canopy != nil ? f32(p.canopy[i]) / 255 : 0
			h[o + 0] = p.heights[i] + cover * p.canopy_height
			h[o + 1] = cover
			h[o + 2] = p.heights[i]
			h[o + 3] = h[o + 0]
			top = max(top, h[o])
		}
	}
	smooth(h, w, l, 0, smoothing)
	smooth(h, w, l, 2, smoothing)
	return
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
	case .Shadow, .Occlusion:
		channels = 1
	}
	pic = picture_make(w, (to - from) * scale, channels, depth, allocator)

	target := rl.LoadRenderTexture(i32(w), i32(strip * scale))
	defer rl.UnloadRenderTexture(target)
	if !rl.IsRenderTextureValid(target) {
		picture_destroy(&pic, allocator)
		return
	}
	heights := slice.reinterpret([]u16, pic.pixels)
	for y0 := from; y0 < to; y0 += strip {
		rows := min(strip, to - y0)
		render_into(r, p, {output = o.output, scale = scale, from = y0}, target)

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
					heights[d] = u16(s[0]) << 8 | u16(s[1])
				case .Shadow, .Occlusion:
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

// Draws the map from row o.from into `target`, as many rows as it holds at
// o.scale, the map's first row in the texture's first: what render reads
// back, and the editor's live view. Output as render's, but always RGBA:
// Height in R and G (high byte first), Shadow and Occlusion in R.
render_into :: proc(r: ^Renderer, p: ^Project, o: Render_Options, target: rl.RenderTexture2D) {
	uniforms(r, p, o.output, f32(max(o.scale, 1)))
	origin := [2]f32{0, f32(o.from)}
	rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "origin"), &origin, .VEC2)
	material := rl.Material {
		shader = r.shader,
		maps   = raw_data(r.maps[:]),
	}
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLACK)
	rlgl.DisableBackfaceCulling()
	rl.DrawMesh(r.quad, material, rl.Matrix(1))
	rlgl.EnableBackfaceCulling()
	rl.EndTextureMode()
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
	set(r, "maxHeight", max(r.surface_max, p.level.water.visible ? p.level.water.height : 0))
	set(r, "marchMax", i32(MARCH_MAX))
	set(r, "heightUnit", HEIGHT_UNIT)
	w := p.level.water
	set(r, "waterHeight", w.height)
	set(r, "waterVisible", i32(w.visible))
	set(r, "waterColour", colour(w.colour))
	set(r, "hasWater", i32(p.water != nil))
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
	radius := smoothing_radius(sigma)
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

// How far the smoothing reaches, in map pixels.
@(private = "file")
smoothing_radius :: proc(sigma: f32) -> int {
	return sigma > 0 ? int(math.ceil(3 * sigma)) : 0
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

// Light: ambient, as open to the sky as the occlusion says, plus the sun by
// how squarely it meets the ground, scaled
// so that flat ground in the sun is its albedo, times how much of the sun
// is not blocked. Blocked: walking toward the sun a map pixel at a time,
// how far the ray from this point passes under the surface (the penumbra
// `softness` map pixels wide), starting a whole pixel past the penumbra, so
// flat ground is never its own shadow and a ray along a row meets texel
// centres.
TERRAIN_SHADER :: `#version 330
out vec4 finalColor;

uniform sampler2D heights; // R surface, G canopy cover, B ground, smoothed; A surface
uniform sampler2D albedo; // RGB the unlit colour, A the occlusion
uniform sampler2D splat;
uniform sampler2D material0;
uniform sampler2D material1;
uniform sampler2D material2;
uniform sampler2D material3;
uniform sampler2D waterLayer; // RGB the water's unlit colour, A how opaque it is

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
uniform int hasWater;

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

vec3 materialSample(int i, vec2 uv, vec2 dx, vec2 dy) {
	switch (i) {
	case 0: return textureGrad(material0, uv, dx, dy).rgb;
	case 1: return textureGrad(material1, uv, dx, dy).rgb;
	case 2: return textureGrad(material2, uv, dx, dy).rgb;
	default: return textureGrad(material3, uv, dx, dy).rgb;
	}
}

vec2 hexOffset(vec2 v) {
	return fract(sin(vec2(dot(v, vec2(127.1, 311.7)), dot(v, vec2(269.5, 183.3)))) * 43758.5453);
}

// A material's image, hex-tiled (Mikkelsen, "Practical Real-Time
// Hex-Tiling", JCGT 2022): a triangle grid over the image, each corner's
// copy of it moved by its own random offset, the three blended by how
// near each corner is, sharpened by the copies' brightness so they meet
// along their features rather than fading through each other. The
// originals' ground never repeats; a tiled image repeats every tile.
// Offsets only, no turns: a dropped photograph's light has a direction.
vec3 hexTiled(int i, vec2 uv, vec2 dx, vec2 dy) {
	vec2 st = uv * 3.46410162; // 2 sqrt 3: a few hexes a tile
	vec2 skewed = vec2(st.x - 0.57735027 * st.y, 1.15470054 * st.y);
	vec2 base = floor(skewed);
	vec3 f = vec3(fract(skewed), 0.0);
	f.z = 1.0 - f.x - f.y;
	float s = step(0.0, -f.z);
	float s2 = 2.0 * s - 1.0;
	vec3 w = vec3(-f.z * s2, s - f.y * s2, s - f.x * s2);
	vec2 v1 = base + vec2(s, s), v2 = base + vec2(s, 1.0 - s), v3 = base + vec2(1.0 - s, s);
	vec3 c1 = materialSample(i, uv + hexOffset(v1), dx, dy);
	vec3 c2 = materialSample(i, uv + hexOffset(v2), dx, dy);
	vec3 c3 = materialSample(i, uv + hexOffset(v3), dx, dy);
	vec3 lum = vec3(0.299, 0.587, 0.114);
	vec3 d = mix(vec3(1.0), vec3(dot(c1, lum), dot(c2, lum), dot(c3, lum)), 0.6);
	vec3 k = d * pow(w, vec3(7.0));
	k /= k.x + k.y + k.z;
	return k.x * c1 + k.y * c2 + k.z * c3;
}

vec3 materialAt(int i, vec2 map) {
	vec3 c = materialColour[i];
	if (materialImage[i] == 0) return c;
	// The map moves 1/scale a pixel, known here where dFdx, under the
	// caller's per-material test, is not.
	float px = 1.0 / (scale * materialTile[i]);
	return hexTiled(i, map / materialTile[i], vec2(px, 0.0), vec2(0.0, px)) * c;
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
		// Without an unlit colour the first material is the ground under
		// the rest: what the weights leave is its, so a half-painted one
		// shows half.
		w[0] += max(1.0 - sum, 0.0);
		sum = max(sum, 1.0);
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
	// Water where the ground itself is under it, not the smoothed ground:
	// smoothing pulls a bank beside a deep bed under the water line, and a
	// tall bank lifts the water beside it out (on le01, a third of the land
	// by the shore was drawn as water, and half the water as land, D59).
	bool water = waterVisible != 0 && unsmoothed(map) < waterHeight;
	float h0 = surface(map);

	vec2 slope = vec2(at(map + vec2(1.0, 0.0)).r - at(map - vec2(1.0, 0.0)).r,
	                  at(map + vec2(0.0, 1.0)).r - at(map - vec2(0.0, 1.0)).r) * 0.5;
	// The land's normal is its visible surface's: a bank stops at the water
	// line, not at the bed beside it that the water hides.
	vec2 rise = vec2(surface(map + vec2(1.0, 0.0)) - surface(map - vec2(1.0, 0.0)),
	                 surface(map + vec2(0.0, 1.0)) - surface(map - vec2(0.0, 1.0))) * 0.5;
	vec3 n = water ? vec3(0.0, 0.0, 1.0) : normalize(vec3(-rise, 1.0));

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
	float open = texture(albedo, map / size).a;
	if (mode == 5) {
		finalColor = vec4(vec3(open), 1.0);
		return;
	}
	// Under the water, the bed, and over it the water's own colour by how
	// opaque it is: the layer's, or the level's colour, opaque.
	vec3 col = colourAt(map, h, slope);
	vec4 over = vec4(0.0);
	if (water) over = hasWater != 0 ? texture(waterLayer, map / size) : vec4(waterColour, 1.0);
	if (mode == 1) {
		finalColor = vec4(mix(col, over.rgb, over.a), 1.0);
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
	vec3 sky = ambient * open * ambientColour;
	vec3 light = sky + (1.0 - ambient) * sunColour * direct * vis;
	// The water's surface takes no cast shadow, as in the originals, and
	// is open to the whole sky: only the bed seen through it is shaded and
	// occluded. The occlusion under open water is the ground's, which the
	// surface hides (le03's invented rocks, D59).
	vec3 surfaceLight = ambient * ambientColour + (1.0 - ambient) * sunColour * direct;
	finalColor = vec4(mix(col * light, over.rgb * surfaceLight, over.a), 1.0);
}
`
