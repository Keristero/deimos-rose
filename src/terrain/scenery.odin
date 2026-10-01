package terrain

// Scenery models drawn for the terrain shader (Stage 8). The map is seen
// from straight above, orthographically, so each instance's triangles are
// drawn so, turned, leant, scaled and lifted, into a layer over the whole
// map, MODEL_SCALE texels a map pixel: its colour and coverage, and the
// height and normal of its top. A second pass, the depth test reversed,
// keeps its underside's height. The terrain shader lights the layer as it
// lights the ground, and a model blocks the sun's march between its
// underside and its top, so a canopy's shadow has light under it and a
// model's shadow falls on the ground, on itself and on the others. The
// export is the shader's output, so the shadows are in the map.

import "core:c"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The models' layer's texels per map pixel: its edges are antialiased from
// the 2x2 texels about each map pixel at 1x. Provisional: the editor's 2x
// view shows each texel as a pixel, and a finer layer costs its square in
// memory (a 480 x 3600 map at 2 is 69 MB, its three textures and depth).
MODEL_SCALE :: 2
// Heights in the models' layer are ordered by depth over this range, from
// MODEL_DEPTH_FLOOR up: the higher surface wins where two meet, or the
// lower in the underside's pass.
MODEL_DEPTH_FLOOR :: -1024
MODEL_DEPTH_RANGE :: 8192

// What the renderer keeps of the models: each file's on the GPU, and the
// layer the instances are drawn into.
@(private)
Scenery :: struct {
	files:  [dynamic]Scenery_File,
	shader: rl.Shader,
	maps:   [rl.MAX_MATERIAL_MAPS]rl.MaterialMap,
	// Colour and coverage, and the top's height and normal; the underside's
	// height.
	top:    Target,
	bottom: Target,
	// Whether anything is drawn in the layer: the shader skips it if not.
	drawn:  bool,
}

@(private)
Scenery_File :: struct {
	name:     string, // the project's Model_File's, not a copy
	textures: []rl.Texture2D, // mipmapped; zero for an image unread
	variants: [][]Scenery_Part,
}

// A part's triangles, unindexed: raylib's indices are 16-bit, and Poly
// Haven's grass has 70,000 vertices.
@(private)
Scenery_Part :: struct {
	mesh:  rl.Mesh,
	using part: Model_Part,
}

// A framebuffer with colour textures and a depth buffer.
@(private)
Target :: struct {
	fbo:     u32,
	colours: [2]rl.Texture2D,
	count:   int,
	depth:   u32,
	width:   int,
	height:  int,
}

// A framebuffer of `formats`' colour textures, width x height, with a
// depth buffer: raylib's LoadRenderTexture makes one 8-bit texture only.
@(private)
target_make :: proc(width, height: int, formats: []rl.PixelFormat) -> (t: Target, ok: bool) {
	t.width, t.height, t.count = width, height, len(formats)
	t.fbo = rlgl.LoadFramebuffer()
	if t.fbo == 0 {
		return
	}
	for f, i in formats {
		id := rlgl.LoadTexture(nil, c.int(width), c.int(height), c.int(f), 1)
		t.colours[i] = {
			id      = id,
			width   = i32(width),
			height  = i32(height),
			mipmaps = 1,
			format  = f,
		}
		rlgl.FramebufferAttach(t.fbo, id, c.int(i), c.int(rlgl.FramebufferAttachTextureType.TEXTURE2D), 0)
	}
	t.depth = rlgl.LoadTextureDepth(c.int(width), c.int(height), true)
	rlgl.FramebufferAttach(t.fbo, t.depth, c.int(rlgl.FramebufferAttachType.DEPTH), c.int(rlgl.FramebufferAttachTextureType.RENDERBUFFER), 0)
	rlgl.EnableFramebuffer(t.fbo)
	rlgl.ActiveDrawBuffers(c.int(len(formats)))
	ok = rlgl.FramebufferComplete(t.fbo)
	rlgl.DisableFramebuffer()
	if !ok {
		target_destroy(&t)
	}
	return
}

@(private)
target_destroy :: proc(t: ^Target) {
	for tex in t.colours[:t.count] {
		if tex.id != 0 {
			rl.UnloadTexture(tex)
		}
	}
	if t.fbo != 0 {
		// Its depth buffer with it.
		rlgl.UnloadFramebuffer(t.fbo)
	}
	t^ = {}
}

// Starts drawing into `t`: every colour texture, cleared to nothing, the
// depth test on and no blending, which would mix the channels' values.
@(private)
target_begin :: proc(t: Target) {
	rl.BeginTextureMode({id = t.fbo, texture = t.colours[0], depth = {id = t.depth}})
	rlgl.ActiveDrawBuffers(c.int(t.count))
	rl.ClearBackground({0, 0, 0, 0})
	rlgl.DisableColorBlend()
	rlgl.EnableDepthTest()
	rlgl.DisableBackfaceCulling()
}

@(private)
target_end :: proc() {
	rlgl.EnableBackfaceCulling()
	rlgl.DisableDepthTest()
	rlgl.EnableColorBlend()
	rl.EndTextureMode()
}

// Uploads the models again: after one is added or taken away. Then draws
// the instances, as scenery_draw.
renderer_models :: proc(r: ^Renderer, p: ^Project) {
	s := &r.scenery
	files_unload(s)
	for f in p.model_files {
		sf := Scenery_File{name = f.name, textures = make([]rl.Texture2D, len(f.images)), variants = make([][]Scenery_Part, len(f.variants))}
		for img, k in f.images {
			pic, ok := model_image_rgba(img)
			if !ok {
				continue
			}
			t := upload(raw_data(pic.pixels), pic.width, pic.height, .UNCOMPRESSED_R8G8B8A8, .REPEAT)
			rl.GenTextureMipmaps(&t)
			rl.SetTextureFilter(t, .TRILINEAR)
			sf.textures[k] = t
		}
		for &v, k in f.variants {
			parts := make([]Scenery_Part, len(v.parts))
			for part, n in v.parts {
				parts[n] = {mesh = part_mesh(&v, part), part = part}
			}
			sf.variants[k] = parts
		}
		append(&s.files, sf)
	}
	scenery_draw(r, p)
}

// A part's triangles as a mesh on the GPU, its vertices one a corner.
@(private = "file")
part_mesh :: proc(m: ^Model_Mesh, part: Model_Part) -> (mesh: rl.Mesh) {
	n := part.count
	if n == 0 {
		return
	}
	mesh.vertexCount, mesh.triangleCount = i32(n), i32(n / 3)
	mesh.vertices = ([^]f32)(rl.MemAlloc(u32(n * 3 * size_of(f32))))
	mesh.normals = ([^]f32)(rl.MemAlloc(u32(n * 3 * size_of(f32))))
	mesh.texcoords = ([^]f32)(rl.MemAlloc(u32(n * 2 * size_of(f32))))
	if part.tinted && m.colours != nil {
		mesh.colors = ([^]u8)(rl.MemAlloc(u32(n * 4)))
	}
	for k in 0 ..< n {
		v := m.indices[part.first + k]
		for a in 0 ..< 3 {
			mesh.vertices[k * 3 + a] = m.positions[v][a]
			mesh.normals[k * 3 + a] = m.normals[v][a]
		}
		mesh.texcoords[k * 2], mesh.texcoords[k * 2 + 1] = m.uvs[v].x, m.uvs[v].y
		if mesh.colors != nil {
			for a in 0 ..< 4 {
				mesh.colors[k * 4 + a] = m.colours[v][a]
			}
		}
	}
	rl.UploadMesh(&mesh, false)
	return
}

@(private = "file")
files_unload :: proc(s: ^Scenery) {
	for f in s.files {
		for t in f.textures {
			unload_texture(t)
		}
		for parts in f.variants {
			for part in parts {
				if part.mesh.vertexCount > 0 {
					rl.UnloadMesh(part.mesh)
				}
			}
			delete(parts)
		}
		delete(f.textures)
		delete(f.variants)
	}
	clear(&s.files)
}

@(private)
unload_texture :: proc(t: rl.Texture2D) {
	if t.id != 0 {
		rl.UnloadTexture(t)
	}
}

// Draws every instance into the models' layer again: after they change,
// or the ground under them does. The layer is made when first needed.
scenery_draw :: proc(r: ^Renderer, p: ^Project) {
	s := &r.scenery
	s.drawn = false
	if len(p.instances) == 0 || !layer_ready(s, p) {
		return
	}
	size := [2]f32{f32(p.width), f32(p.length)}
	rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "size"), &size, .VEC2)
	floor, span := f32(MODEL_DEPTH_FLOOR), f32(MODEL_DEPTH_RANGE)
	rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "depthFloor"), &floor, .FLOAT)
	rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "depthRange"), &span, .FLOAT)

	// Each model's instances' transforms, and the highest top among them.
	transforms := make([][dynamic]rl.Matrix, len(p.models), context.temp_allocator)
	for i in p.instances {
		m := model_mesh(p, i.model)
		if m == nil || i.scale <= 0 {
			continue
		}
		if transforms[i.model] == nil {
			transforms[i.model] = make([dynamic]rl.Matrix, context.temp_allocator)
		}
		mat := instance_matrix(p, i)
		append(&transforms[i.model], rl.Matrix(mat))
		r.surface_max = max(r.surface_max, instance_top(m, mat))
		s.drawn = true
	}
	if !s.drawn {
		return
	}
	for pass in 0 ..< 2 {
		pass := i32(pass)
		rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "pass"), &pass, .INT)
		target_begin(pass == 0 ? s.top : s.bottom)
		for list, k in transforms {
			if len(list) == 0 {
				continue
			}
			for part in model_parts(s, p.models[k]) {
				if part.mesh.vertexCount == 0 {
					continue
				}
				colour, cutoff, tinted := part.colour, part.cutoff, i32(part.tinted)
				rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "baseColour"), &colour, .VEC4)
				rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "cutoff"), &cutoff, .FLOAT)
				rl.SetShaderValue(s.shader, rl.GetShaderLocation(s.shader, "tinted"), &tinted, .INT)
				s.maps[rl.MaterialMapIndex.ALBEDO].texture = r.white
				if f := model_file(s, p.models[k]); f != nil && part.image >= 0 && part.image < len(f.textures) && f.textures[part.image].id != 0 {
					s.maps[rl.MaterialMapIndex.ALBEDO].texture = f.textures[part.image]
				}
				rl.DrawMeshInstanced(part.mesh, {shader = s.shader, maps = raw_data(s.maps[:])}, raw_data(list), i32(len(list)))
			}
		}
		target_end()
	}
}

// The highest point of a model as an instance is placed: the top of its
// box's corners, which a turn and a lean move.
@(private = "file")
instance_top :: proc(m: ^Model_Mesh, mat: matrix[4, 4]f32) -> (top: f32) {
	top = mat[2, 3]
	for k in 0 ..< 8 {
		corner := [4]f32{k & 1 == 0 ? m.lo.x : m.hi.x, k & 2 == 0 ? m.lo.y : m.hi.y, k & 4 == 0 ? m.lo.z : m.hi.z, 1}
		top = max(top, (mat * corner).z)
	}
	return
}

@(private = "file")
model_file :: proc(s: ^Scenery, m: Model) -> ^Scenery_File {
	for &f in s.files {
		if f.name == m.file {
			return &f
		}
	}
	return nil
}

@(private = "file")
model_parts :: proc(s: ^Scenery, m: Model) -> []Scenery_Part {
	f := model_file(s, m)
	if f == nil || m.variant < 0 || m.variant >= len(f.variants) {
		return nil
	}
	return f.variants[m.variant]
}

// The layer, the map's size, and the shader that draws into it: false if
// either cannot be made.
@(private = "file")
layer_ready :: proc(s: ^Scenery, p: ^Project) -> bool {
	w, l := p.width * MODEL_SCALE, p.length * MODEL_SCALE
	if s.top.width != w || s.top.height != l {
		target_destroy(&s.top)
		target_destroy(&s.bottom)
		ok: bool
		// Half floats: a height of 512 is kept to a quarter of a map pixel.
		if s.top, ok = target_make(w, l, {.UNCOMPRESSED_R8G8B8A8, .UNCOMPRESSED_R16G16B16A16}); !ok {
			return false
		}
		if s.bottom, ok = target_make(w, l, {.UNCOMPRESSED_R16}); !ok {
			target_destroy(&s.top)
			return false
		}
		rl.SetTextureFilter(s.top.colours[0], .BILINEAR)
		for t in ([]rl.Texture2D{s.top.colours[0], s.top.colours[1], s.bottom.colours[0]}) {
			rl.SetTextureWrap(t, .CLAMP)
		}
	}
	if s.shader.id == 0 {
		s.shader = rl.LoadShaderFromMemory(LAYER_VERTEX_SHADER, LAYER_SHADER)
		if !rl.IsShaderValid(s.shader) {
			s.shader = {}
			return false
		}
		s.shader.locs[rl.ShaderLocationIndex.MAP_ALBEDO] = rl.GetShaderLocation(s.shader, "colourMap")
		s.shader.locs[rl.ShaderLocationIndex.VERTEX_INSTANCETRANSFORM] = rl.GetShaderLocationAttrib(s.shader, "instanceTransform")
	}
	return true
}

@(private)
scenery_destroy :: proc(s: ^Scenery) {
	files_unload(s)
	delete(s.files)
	target_destroy(&s.top)
	target_destroy(&s.bottom)
	if s.shader.id != 0 {
		rl.UnloadShader(s.shader)
	}
	s^ = {}
}

// An instance's transform takes its model's metres to map pixels and
// height; the layer's first row is the map's first, at clip y -1, as the
// terrain's textures hold it. Its depth orders by height: in the first
// pass the highest is kept, in the second the lowest.
@(private = "file")
LAYER_VERTEX_SHADER :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
in mat4 instanceTransform;
uniform vec2 size;
uniform float depthFloor;
uniform float depthRange;
uniform int pass;
out vec2 uv;
out vec3 normal;
out vec4 tint;
out float height;
void main() {
	vec4 m = instanceTransform * vec4(vertexPosition, 1.0);
	uv = vertexTexCoord;
	normal = mat3(instanceTransform) * vertexNormal;
	tint = vertexColor;
	height = m.z;
	float d = clamp((m.z - depthFloor) / depthRange, 0.0, 1.0) * 2.0 - 1.0;
	gl_Position = vec4(m.xy / size * 2.0 - 1.0, pass == 0 ? -d : d, 1.0);
}
`

// The colour, its cutout's holes discarded; the normal turned to the sky,
// as the model's top is what is seen (a leaf's either side).
@(private = "file")
LAYER_SHADER :: `#version 330
in vec2 uv;
in vec3 normal;
in vec4 tint;
in float height;
uniform sampler2D colourMap;
uniform vec4 baseColour;
uniform float cutoff;
uniform int tinted;
uniform int pass;
layout(location = 0) out vec4 out0;
layout(location = 1) out vec4 out1;
void main() {
	vec4 c = texture(colourMap, uv) * baseColour;
	if (tinted != 0) c *= tint;
	// The cut-out from the texture's own texels, not its mipmaps': a
	// mipmap averages a grass blade's alpha under the cutoff, and the
	// grass is gone (grass_medium_02 was). Taken from the full image the
	// samples alias, but they cover as much of the model as its texels do.
	float a = textureLod(colourMap, uv, 0.0).a * baseColour.a;
	if (tinted != 0) a *= tint.a;
	if (a < cutoff) discard;
	if (pass == 0) {
		vec3 n = normalize(normal);
		if (n.z < 0.0) n = -n;
		out0 = vec4(c.rgb, 1.0);
		out1 = vec4(height, 0.0, n.xy);
	} else {
		out0 = vec4(height, 0.0, 0.0, 1.0);
	}
}
`
