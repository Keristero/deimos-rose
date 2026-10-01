package terrain

// Scenery models (Stage 8): trees, grass and rocks put on the ground as 3D
// models, not painted into its colour. The originals' trees were rendered
// into their maps (le11's palms, a whole jungle), and colour like that is
// far harder to paint than models are to scatter.
//
// A model comes from a glTF, GLB or OBJ file, read into memory here as its
// triangles and the base colour of each material, and is kept beside the
// project as a GLB of just that, written by this file: one file however
// the original was laid out, and the same bytes for the same model. Each
// instance is the model drawn turned, leant, scaled and lifted over the
// ground (scenery.odin). Its foot follows the ground as it is sculpted.

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Map pixels a metre, for a model made in metres, as glTF's are. le11's
// palm crowns are about 30 map pixels across, and a palm's crown is 8 to
// 10 m.
MODEL_PIXELS_PER_METRE :: 3

// A model the project uses: one of a file's models, by its place there.
Model :: struct {
	name:    string   `json:"name"`,
	// Its file's name, model_file_path's beside the project, and which of
	// the models in it.
	file:    string   `json:"file"`,
	variant: int      `json:"variant"`,
	tags:    []string `json:"tags"`,
	// Where it came from, and its licence, for the reader.
	source:  string   `json:"source"`,
}

// A model put on the map.
Instance :: struct {
	model:  int `json:"model"`,
	// The map point its foot is centred on.
	x:      f32 `json:"x"`,
	y:      f32 `json:"y"`,
	// Map pixels its foot is above the ground there (below, negative).
	offset: f32 `json:"offset"`,
	// Degrees clockwise, as the map is seen.
	turn:   f32 `json:"turn"`,
	// Degrees its top leans toward the map's bottom, before the turn: so
	// with the turn, any way.
	lean:   f32 `json:"lean"`,
	scale:  f32 `json:"scale"`,
}

// A file's models, as read: what a project keeps of each file.
Model_File :: struct {
	name:     string, // its name beside the project, models/<name>.glb
	variants: []Model_Mesh,
	images:   []Model_Image,
}

// One model's triangles, in metres with Y up, its foot's centre at the
// origin: the middle of its extent across, and its lowest point.
Model_Mesh :: struct {
	name:      string,
	positions: [][3]f32,
	normals:   [][3]f32,
	uvs:       [][2]f32,
	// Per vertex, for parts tinted by them; nil when none is.
	colours:   [][4]u8,
	indices:   []u32,
	parts:     []Model_Part,
	// Its extent: lo.y is 0, lo.xz is -hi.xz.
	lo, hi:    [3]f32,
}

// A run of a mesh's triangles under one material.
Model_Part :: struct {
	first, count: int, // in indices
	image:        int, // into the file's images, or -1
	colour:       [4]f32,
	// Discarded where the colour's alpha is below this: glTF's MASK, and
	// its BLEND as a mask at a half, as the map is covered or not.
	cutoff:       f32,
	// The vertex colours tint it. Only without an image: rock_07's are not
	// its colour, and multiply its texture to nonsense.
	tinted:       bool,
}

// An image as its file held it, PNG or JPEG: kept so, not decoded and
// encoded again.
Model_Image :: struct {
	data: []u8,
	mime: string,
}

// The model's mesh, or nil if the project has no such.
model_mesh :: proc(p: ^Project, m: int) -> ^Model_Mesh {
	if m < 0 || m >= len(p.models) {
		return nil
	}
	k := model_file_find(p, p.models[m].file)
	v := p.models[m].variant
	if k < 0 || v < 0 || v >= len(p.model_files[k].variants) {
		return nil
	}
	return &p.model_files[k].variants[v]
}

// The place in p.model_files of the file named `name`, or -1.
model_file_find :: proc(p: ^Project, name: string) -> int {
	for f, k in p.model_files {
		if f.name == name {
			return k
		}
	}
	return -1
}

// Where a model file is kept, from the project's directory.
model_file_path :: proc(name: string) -> string {
	return strings.concatenate({"models/", name, ".glb"}, context.temp_allocator)
}

// The ground's height at a map point, between the pixels' centres.
ground_at :: proc(p: ^Project, at: [2]f32) -> f32 {
	if p.width == 0 || p.length == 0 {
		return 0
	}
	fx := clamp(at.x - 0.5, 0, f32(p.width - 1))
	fy := clamp(at.y - 0.5, 0, f32(p.length - 1))
	x0, y0 := int(fx), int(fy)
	x1, y1 := min(x0 + 1, p.width - 1), min(y0 + 1, p.length - 1)
	tx, ty := fx - f32(x0), fy - f32(y0)
	h :: proc(p: ^Project, x, y: int) -> f32 {
		return p.heights[y * p.width + x]
	}
	top := math.lerp(h(p, x0, y0), h(p, x1, y0), tx)
	bottom := math.lerp(h(p, x0, y1), h(p, x1, y1), tx)
	return math.lerp(top, bottom, ty)
}

instance_foot :: proc(p: ^Project, i: Instance) -> f32 {
	return ground_at(p, {i.x, i.y}) + i.offset
}

// From the model's metres, Y up, to the map's pixels, x across, y down and
// height up. glTF's space is right-handed and the map's left-handed, so
// taking its Z down the map is no mirror: seen from above with X to the
// right, a right-handed Y-up model has Z toward the viewer's feet.
instance_matrix :: proc(p: ^Project, i: Instance) -> matrix[4, 4]f32 {
	t, l := math.to_radians(i.turn), math.to_radians(i.lean)
	ct, st := math.cos(t), math.sin(t)
	cl, sl := math.cos(l), math.sin(l)
	turn := matrix[4, 4]f32{
		ct, -st, 0, 0,
		st, ct, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	// The top, +height, toward +y.
	lean := matrix[4, 4]f32{
		1, 0, 0, 0,
		0, cl, sl, 0,
		0, -sl, cl, 0,
		0, 0, 0, 1,
	}
	s := i.scale * MODEL_PIXELS_PER_METRE
	axes := matrix[4, 4]f32{
		s, 0, 0, 0,
		0, 0, s, 0,
		0, s, 0, 0,
		0, 0, 0, 1,
	}
	at := matrix[4, 4]f32{
		1, 0, 0, i.x,
		0, 1, 0, i.y,
		0, 0, 1, instance_foot(p, i),
		0, 0, 0, 1,
	}
	return at * turn * lean * axes
}

// How far an instance reaches from its point across the map, any way.
instance_reach :: proc(p: ^Project, i: Instance) -> f32 {
	m := model_mesh(p, i.model)
	if m == nil {
		return 0
	}
	r := math.sqrt(m.hi.x * m.hi.x + m.hi.z * m.hi.z)
	// Leant, its top reaches out by as much as its height leans.
	r += m.hi.y * abs(math.sin(math.to_radians(i.lean)))
	return r * i.scale * MODEL_PIXELS_PER_METRE
}

// The highest point of the instance over map point `at`, if it covers it:
// a vertical line through the point met with its triangles, as it is drawn.
instance_hit :: proc(p: ^Project, i: Instance, at: [2]f32) -> (top: f32, hit: bool) {
	m := model_mesh(p, i.model)
	if m == nil || i.scale <= 0 {
		return
	}
	d := at - {i.x, i.y}
	if r := instance_reach(p, i); d.x * d.x + d.y * d.y > r * r {
		return
	}
	mat := instance_matrix(p, i)
	inv := linalg.inverse(mat)
	o := (inv * [4]f32{at.x, at.y, 0, 1}).xyz
	dir := (inv * [4]f32{0, 0, 1, 0}).xyz
	best := f32(-math.F32_MAX)
	for part in m.parts {
		for k := part.first; k + 2 < part.first + part.count; k += 3 {
			a, b, c := m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]]
			// Möller and Trumbore: t is the map height, as dir is a map pixel up.
			e1, e2 := b - a, c - a
			pv := linalg.cross(dir, e2)
			det := linalg.dot(e1, pv)
			if abs(det) < 1e-12 {
				continue
			}
			tv := o - a
			u := linalg.dot(tv, pv) / det
			if u < 0 || u > 1 {
				continue
			}
			qv := linalg.cross(tv, e1)
			v := linalg.dot(dir, qv) / det
			if v < 0 || u + v > 1 {
				continue
			}
			best = max(best, linalg.dot(e2, qv) / det)
		}
	}
	return best, best > -math.F32_MAX
}

// The instance seen at map point `at`: the highest there, or -1.
instance_pick :: proc(p: ^Project, at: [2]f32) -> int {
	best, pick := f32(-math.F32_MAX), -1
	for i, k in p.instances {
		if top, hit := instance_hit(p, i, at); hit && top > best {
			best, pick = top, k
		}
	}
	return pick
}

// Reads `path`, a glTF, GLB or OBJ, into a file of models named for it,
// lowercase and dashed. OBJ goes through raylib's LoadModel, and so needs
// a GL context; glTF does not, and is read by gltf.odin, not LoadModel:
// raylib 6 reads no JPEG texture ("Data format not supported" on Poly
// Haven's), and truncates 32-bit indices to its 16-bit ones, which
// scrambles any mesh of more than 65535 vertices.
model_file_read :: proc(path: string, allocator := context.allocator) -> (f: Model_File, ok: bool) {
	stem := path[max(strings.last_index_any(path, "/\\"), -1) + 1:]
	if k := strings.last_index_byte(stem, '.'); k > 0 {
		stem = stem[:k]
	}
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".gltf"), strings.has_suffix(lower, ".glb"):
		f = gltf_read(path, allocator) or_return
	case strings.has_suffix(lower, ".obj"):
		f = obj_read(path, allocator) or_return
	case:
		return
	}
	f.name = model_name(stem, allocator)
	for &v in f.variants {
		mesh_centre(&v)
	}
	return f, len(f.variants) > 0
}

// A copy of `f`, all in `allocator`: a library's model put in a project.
model_file_clone :: proc(f: Model_File, allocator := context.allocator) -> (c: Model_File) {
	context.allocator = allocator
	c.name = strings.clone(f.name)
	c.variants = make([]Model_Mesh, len(f.variants))
	for v, k in f.variants {
		c.variants[k] = v
		c.variants[k].name = strings.clone(v.name)
		c.variants[k].positions = slice.clone(v.positions)
		c.variants[k].normals = slice.clone(v.normals)
		c.variants[k].uvs = slice.clone(v.uvs)
		c.variants[k].colours = slice.clone(v.colours)
		c.variants[k].indices = slice.clone(v.indices)
		c.variants[k].parts = slice.clone(v.parts)
	}
	c.images = make([]Model_Image, len(f.images))
	for img, k in f.images {
		c.images[k] = {slice.clone(img.data), strings.clone(img.mime)}
	}
	return
}

model_file_destroy :: proc(f: ^Model_File, allocator := context.allocator) {
	context.allocator = allocator
	for v in f.variants {
		delete(v.name)
		delete(v.positions)
		delete(v.normals)
		delete(v.uvs)
		delete(v.colours)
		delete(v.indices)
		delete(v.parts)
	}
	for img in f.images {
		delete(img.data)
		delete(img.mime)
	}
	delete(f.variants)
	delete(f.images)
	delete(f.name)
	f^ = {}
}

// The model moved so its foot's centre is at the origin.
@(private = "file")
mesh_centre :: proc(m: ^Model_Mesh) {
	lo, hi := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}, [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
	for v in m.positions {
		lo, hi = linalg.min(lo, v), linalg.max(hi, v)
	}
	if len(m.positions) == 0 {
		return
	}
	shift := [3]f32{(lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2}
	for &v in m.positions {
		v -= shift
	}
	m.lo, m.hi = lo - shift, hi - shift
}

// A name as a file name: lowercase, words joined by dashes.
model_name :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	dash := false
	for r in s {
		switch r {
		case 'a' ..= 'z', '0' ..= '9', 'A' ..= 'Z':
		case:
			dash = strings.builder_len(b) > 0
			continue
		}
		if dash {
			strings.write_byte(&b, '-')
			dash = false
		}
		strings.write_rune(&b, r >= 'A' && r <= 'Z' ? r + 32 : r)
	}
	if strings.builder_len(b) == 0 {
		strings.write_string(&b, "model")
	}
	return strings.to_string(b)
}

// An OBJ through raylib: one model, its meshes' materials' textures read
// back from the GPU and kept as PNG.
@(private = "file")
obj_read :: proc(path: string, allocator := context.allocator) -> (f: Model_File, ok: bool) {
	if !os.exists(path) {
		return
	}
	model := rl.LoadModel(strings.clone_to_cstring(path, context.temp_allocator))
	defer rl.UnloadModel(model)
	if model.meshCount == 0 {
		return
	}
	context.allocator = allocator
	positions, normals := make([dynamic][3]f32), make([dynamic][3]f32)
	uvs := make([dynamic][2]f32)
	indices := make([dynamic]u32)
	parts := make([dynamic]Model_Part)
	images := make([dynamic]Model_Image)
	textures := make(map[u32]int, context.temp_allocator)
	for k in 0 ..< int(model.meshCount) {
		mesh := model.meshes[k]
		base := u32(len(positions))
		for i in 0 ..< int(mesh.vertexCount) {
			append(&positions, [3]f32{mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2]})
			append(&normals, mesh.normals != nil ? [3]f32{mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2]} : {0, 1, 0})
			append(&uvs, mesh.texcoords != nil ? [2]f32{mesh.texcoords[i * 2], mesh.texcoords[i * 2 + 1]} : {})
		}
		first := len(indices)
		n := mesh.indices != nil ? int(mesh.triangleCount) * 3 : int(mesh.vertexCount)
		for i in 0 ..< n {
			append(&indices, base + (mesh.indices != nil ? u32(mesh.indices[i]) : u32(i)))
		}
		mat := model.materials[model.meshMaterial[k]]
		albedo := mat.maps[rl.MaterialMapIndex.ALBEDO]
		c := albedo.color
		part := Model_Part{first = first, count = n, image = -1, colour = {f32(c.r), f32(c.g), f32(c.b), f32(c.a)} / 255, cutoff = 0.5}
		if t := albedo.texture; t.id != 0 && t.id != rlgl.GetTextureIdDefault() {
			if found, seen := textures[t.id]; seen {
				part.image = found
			} else {
				img := rl.LoadImageFromTexture(t)
				rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
				pic := Picture{int(img.width), int(img.height), 4, 8, ([^]u8)(img.data)[:img.width * img.height * 4]}
				append(&images, Model_Image{data = png_encode(pic), mime = strings.clone("image/png")})
				rl.UnloadImage(img)
				part.image = len(images) - 1
				textures[t.id] = part.image
			}
		}
		append(&parts, part)
	}
	variants := make([]Model_Mesh, 1)
	variants[0] = {
		name      = strings.clone(""),
		positions = positions[:],
		normals   = normals[:],
		uvs       = uvs[:],
		indices   = indices[:],
		parts     = parts[:],
	}
	return {variants = variants, images = images[:]}, true
}

// Writes the file as a GLB: each model a node at the scene's root, with a
// mesh of a primitive for each part, and the images as they were read.
model_file_write :: proc(path: string, f: Model_File) -> bool {
	bin := make([dynamic]u8, context.temp_allocator)
	views := make([dynamic]Gltf_View, context.temp_allocator)
	accessors := make([dynamic]Gltf_Accessor, context.temp_allocator)
	view :: proc(bin: ^[dynamic]u8, views: ^[dynamic]Gltf_View, data: []u8) -> int {
		for len(bin) % 4 != 0 {
			append(bin, 0)
		}
		append(views, Gltf_View{buffer = 0, byteOffset = len(bin), byteLength = len(data)})
		append(bin, ..data)
		return len(views) - 1
	}
	meshes := make([dynamic]Gltf_Mesh, context.temp_allocator)
	materials := make([dynamic]Gltf_Material, context.temp_allocator)
	nodes := make([dynamic]Gltf_Node, context.temp_allocator)
	for &v, k in f.variants {
		attributes := make(map[string]int, context.temp_allocator)
		attributes["POSITION"] = len(accessors)
		append(&accessors, Gltf_Accessor{bufferView = view(&bin, &views, slice.to_bytes(v.positions)), componentType = 5126, count = len(v.positions), type = "VEC3", min = v.lo[:], max = v.hi[:]})
		if len(v.normals) == len(v.positions) {
			attributes["NORMAL"] = len(accessors)
			append(&accessors, Gltf_Accessor{bufferView = view(&bin, &views, slice.to_bytes(v.normals)), componentType = 5126, count = len(v.normals), type = "VEC3"})
		}
		if len(v.uvs) == len(v.positions) {
			attributes["TEXCOORD_0"] = len(accessors)
			append(&accessors, Gltf_Accessor{bufferView = view(&bin, &views, slice.to_bytes(v.uvs)), componentType = 5126, count = len(v.uvs), type = "VEC2"})
		}
		if len(v.colours) == len(v.positions) {
			attributes["COLOR_0"] = len(accessors)
			append(&accessors, Gltf_Accessor{bufferView = view(&bin, &views, slice.to_bytes(v.colours)), componentType = 5121, normalized = true, count = len(v.colours), type = "VEC4"})
		}
		indices := view(&bin, &views, slice.to_bytes(v.indices))
		prims := make([]Gltf_Primitive, len(v.parts), context.temp_allocator)
		for part, n in v.parts {
			append(&accessors, Gltf_Accessor{bufferView = indices, byteOffset = part.first * 4, componentType = 5125, count = part.count, type = "SCALAR"})
			mat := Gltf_Material{pbrMetallicRoughness = {baseColorFactor = part.colour, metallicFactor = 0}, doubleSided = true, alphaMode = "OPAQUE"}
			if part.cutoff > 0 {
				mat.alphaMode, mat.alphaCutoff = "MASK", part.cutoff
			}
			if part.image >= 0 {
				mat.pbrMetallicRoughness.baseColorTexture = Gltf_Texture_Ref{index = part.image}
			}
			// Untinted parts of a tinted mesh are told so by having none.
			attrs := attributes
			if !part.tinted && "COLOR_0" in attributes {
				attrs = make(map[string]int, context.temp_allocator)
				for name, a in attributes {
					if name != "COLOR_0" {
						attrs[name] = a
					}
				}
			}
			prims[n] = {attributes = attrs, indices = len(accessors) - 1, material = len(materials)}
			append(&materials, mat)
		}
		append(&meshes, Gltf_Mesh{primitives = prims})
		append(&nodes, Gltf_Node{name = v.name, mesh = k})
	}
	images := make([]Gltf_Image, len(f.images), context.temp_allocator)
	textures := make([]Gltf_Texture, len(f.images), context.temp_allocator)
	for img, k in f.images {
		images[k] = {bufferView = view(&bin, &views, img.data), mimeType = img.mime}
		textures[k] = {source = k}
	}
	for len(bin) % 4 != 0 {
		append(&bin, 0)
	}
	scene := make([]int, len(nodes), context.temp_allocator)
	for &n, k in scene {
		n = k
	}
	doc := Gltf_Document {
		asset       = {version = "2.0", generator = "deimos-rising level editor"},
		scenes      = {{nodes = scene}},
		nodes       = nodes[:],
		meshes      = meshes[:],
		materials   = materials[:],
		textures    = textures,
		images      = images,
		accessors   = accessors[:],
		bufferViews = views[:],
		buffers     = {{byteLength = len(bin)}},
	}
	text, err := json.marshal(doc, {sort_maps_by_key = true}, context.temp_allocator)
	if err != nil {
		return false
	}
	padded := make([dynamic]u8, context.temp_allocator)
	append(&padded, ..text)
	for len(padded) % 4 != 0 {
		append(&padded, ' ')
	}
	out := make([dynamic]u8, context.temp_allocator)
	le32 :: proc(out: ^[dynamic]u8, v: int) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	append(&out, 'g', 'l', 'T', 'F')
	le32(&out, 2)
	le32(&out, 12 + 8 + len(padded) + 8 + len(bin))
	le32(&out, len(padded))
	append(&out, 'J', 'S', 'O', 'N')
	append(&out, ..padded[:])
	le32(&out, len(bin))
	append(&out, 'B', 'I', 'N', 0)
	append(&out, ..bin[:])
	if k := strings.last_index_any(path, "/\\"); k > 0 {
		os.make_directory_all(path[:k])
	}
	return os.write_entire_file(path, out[:]) == nil
}

// What model_file_write writes, as glTF names it. Map keys are marshalled
// in order, so the same file gives the same bytes.
@(private = "file")
Gltf_Document :: struct {
	asset:       struct {
		version:   string,
		generator: string,
	},
	scene:       int,
	scenes:      []struct {
		nodes: []int,
	},
	nodes:       []Gltf_Node,
	meshes:      []Gltf_Mesh,
	materials:   []Gltf_Material,
	textures:    []Gltf_Texture,
	images:      []Gltf_Image,
	accessors:   []Gltf_Accessor,
	bufferViews: []Gltf_View,
	buffers:     []struct {
		byteLength: int,
	},
}

@(private = "file")
Gltf_Node :: struct {
	name: string,
	mesh: int,
}

@(private = "file")
Gltf_Mesh :: struct {
	primitives: []Gltf_Primitive,
}

@(private = "file")
Gltf_Primitive :: struct {
	attributes: map[string]int,
	indices:    int,
	material:   int,
}

@(private = "file")
Gltf_Texture_Ref :: struct {
	index: int,
}

@(private = "file")
Gltf_Material :: struct {
	pbrMetallicRoughness: struct {
		baseColorFactor:  [4]f32,
		baseColorTexture: Maybe(Gltf_Texture_Ref) `json:",omitempty"`,
		metallicFactor:   f32,
	},
	alphaMode:            string,
	alphaCutoff:          f32 `json:",omitempty"`,
	doubleSided:          bool,
}

@(private = "file")
Gltf_Texture :: struct {
	source: int,
}

@(private = "file")
Gltf_Image :: struct {
	bufferView: int,
	mimeType:   string,
}

@(private = "file")
Gltf_Accessor :: struct {
	bufferView:    int,
	byteOffset:    int `json:",omitempty"`,
	componentType: int,
	normalized:    bool `json:",omitempty"`,
	count:         int,
	type:          string,
	min:           []f32 `json:",omitempty"`,
	max:           []f32 `json:",omitempty"`,
}

@(private = "file")
Gltf_View :: struct {
	buffer:     int,
	byteOffset: int,
	byteLength: int,
}
