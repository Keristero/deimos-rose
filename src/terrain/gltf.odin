package terrain

// A glTF 2.0 reader, as much of it as a scenery model needs: its scene's
// nodes and their transforms, triangle meshes, and each material's base
// colour, texture and alpha. A .gltf with its buffers and images in files
// or data URIs, or a .glb. Not vendor:cgltf: raylib carries its own cgltf,
// whose symbols the vendor's collide with at link time ("multiple
// definition of `cgltf_load_buffers'"), and binding to raylib's would tie
// the struct layouts to whichever version raylib bundles. Sparse accessors
// and Draco or meshopt compression are not read. KHR_texture_transform
// is, on the base colour, into the UVs: island_tree_01's bark tiles 15 by
// 3.4 times round its branches with it. Only the base colour's image is
// kept: the map's light is its own (render.odin).
//
// A file can hold several models: Poly Haven's sets lay each out as its
// own node at the scene's root (grass_medium_01 has 17, fern_02 4). So
// each root node with a mesh under it is a model, and so is each child of
// a lone root that has no mesh itself and two or more children that do,
// the way an exporter wraps a set. Provisional: a file that groups its
// models otherwise imports as one.

import "base:runtime"

import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/json"
import "core:image"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"


@(private = "file")
Gltf :: struct {
	root:      json.Object,
	buffers:   [dynamic][]u8,
	dir:       string,
	// Each glTF image's place in `images`, read when first used; -1 for
	// one that cannot be.
	seen:      map[int]int,
	images:    [dynamic]Model_Image,
	allocator: runtime.Allocator,
}

// The glTF's models, in `allocator`.
@(private)
gltf_read :: proc(path: string, allocator := context.allocator) -> (f: Model_File, ok: bool) {
	blob, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	g := Gltf{allocator = allocator}
	g.seen.allocator = context.temp_allocator
	g.images.allocator = allocator
	g.buffers.allocator = context.temp_allocator
	g.dir = path[:max(strings.last_index_any(path, "/\\"), 0)]
	if g.dir == "" {
		g.dir = "."
	}
	text := blob
	bin: []u8
	// A GLB: a header, then a JSON chunk and a binary one, the first buffer.
	if len(blob) >= 20 && string(blob[:4]) == "glTF" {
		total := int(endian.unchecked_get_u32le(blob[8:]))
		at := 12
		for at + 8 <= min(total, len(blob)) {
			n := int(endian.unchecked_get_u32le(blob[at:]))
			kind := endian.unchecked_get_u32le(blob[at + 4:])
			if at + 8 + n > len(blob) {
				return
			}
			chunk := blob[at + 8:][:n]
			switch kind {
			case 0x4E4F534A:
				text = chunk
			case 0x004E4942:
				bin = chunk
			}
			at += 8 + (n + 3) / 4 * 4
		}
	}
	value, jerr := json.parse(text, allocator = context.temp_allocator)
	if jerr != nil {
		return
	}
	g.root = value.(json.Object) or_return
	for e in array(g.root, "extensionsRequired") {
		switch e.(json.String) or_else "" {
		case "KHR_draco_mesh_compression", "EXT_meshopt_compression":
			return
		}
	}
	for b in array(g.root, "buffers") {
		o := b.(json.Object) or_else nil
		uri := text_of(o, "uri")
		data: []u8
		switch {
		case uri == "":
			data = bin
		case strings.has_prefix(uri, "data:"):
			comma := strings.index_byte(uri, ',')
			if comma < 0 {
				return
			}
			data, _ = base64.decode(uri[comma + 1:], allocator = context.temp_allocator)
		case:
			data, err = os.read_entire_file(strings.concatenate({g.dir, "/", uri_decode(uri)}, context.temp_allocator), context.temp_allocator)
			if err != nil {
				return
			}
		}
		if int(number(o, "byteLength", 0)) > len(data) {
			return
		}
		append(&g.buffers, data)
	}

	nodes := array(g.root, "nodes")
	roots := make([dynamic]int, context.temp_allocator)
	scenes := array(g.root, "scenes")
	if s := int(number(g.root, "scene", 0)); s < len(scenes) {
		for n in array(scenes[s].(json.Object) or_else nil, "nodes") {
			append(&roots, int(n.(json.Float) or_else -1))
		}
	} else {
		child := make([]bool, len(nodes), context.temp_allocator)
		for n in nodes {
			for k in array(n.(json.Object) or_else nil, "children") {
				if i := int(k.(json.Float) or_else -1); i >= 0 && i < len(child) {
					child[i] = true
				}
			}
		}
		for is_child, i in child {
			if !is_child {
				append(&roots, i)
			}
		}
	}
	node :: proc(g: ^Gltf, i: int) -> json.Object {
		nodes := array(g.root, "nodes")
		return i >= 0 && i < len(nodes) ? nodes[i].(json.Object) or_else nil : nil
	}
	has_mesh :: proc(g: ^Gltf, i: int, depth := 0) -> bool {
		n := node(g, i)
		if n == nil || depth > 64 {
			return false
		}
		if "mesh" in n {
			return true
		}
		for k in array(n, "children") {
			if has_mesh(g, int(k.(json.Float) or_else -1), depth + 1) {
				return true
			}
		}
		return false
	}
	if len(roots) == 1 && "mesh" not_in node(&g, roots[0]) {
		wrapper := node(&g, roots[0])
		inner := 0
		for k in array(wrapper, "children") {
			inner += int(has_mesh(&g, int(k.(json.Float) or_else -1)))
		}
		if inner >= 2 {
			clear(&roots)
			for k in array(wrapper, "children") {
				append(&roots, int(k.(json.Float) or_else -1))
			}
		}
	}
	variants := make([dynamic]Model_Mesh, allocator)
	for r in roots {
		if !has_mesh(&g, r) {
			continue
		}
		b := Mesh_Builder{}
		builder_init(&b)
		// The root's own transform too: a set's members are placed apart by
		// it, and each is centred on itself after.
		node_parts(&g, r, 1, &b, 0)
		if len(b.parts) > 0 {
			append(&variants, builder_mesh(&b, text_of(node(&g, r), "name"), allocator))
		}
	}
	return {variants = variants[:], images = g.images[:]}, true
}

// A model's arrays as they are gathered, in the temporary allocator.
@(private = "file")
Mesh_Builder :: struct {
	positions, normals: [dynamic][3]f32,
	uvs:                [dynamic][2]f32,
	colours:            [dynamic][4]u8,
	indices:            [dynamic]u32,
	parts:              [dynamic]Model_Part,
	tinted:             bool,
}

@(private = "file")
builder_init :: proc(b: ^Mesh_Builder) {
	b.positions.allocator = context.temp_allocator
	b.normals.allocator = context.temp_allocator
	b.uvs.allocator = context.temp_allocator
	b.colours.allocator = context.temp_allocator
	b.indices.allocator = context.temp_allocator
	b.parts.allocator = context.temp_allocator
}

@(private = "file")
builder_mesh :: proc(b: ^Mesh_Builder, name: string, allocator: runtime.Allocator) -> Model_Mesh {
	context.allocator = allocator
	m := Model_Mesh {
		name      = strings.clone(name),
		positions = slice.clone(b.positions[:]),
		normals   = slice.clone(b.normals[:]),
		uvs       = slice.clone(b.uvs[:]),
		indices   = slice.clone(b.indices[:]),
		parts     = slice.clone(b.parts[:]),
	}
	if b.tinted {
		m.colours = slice.clone(b.colours[:])
	}
	return m
}

// The meshes under node `i`, in the scene's space.
@(private = "file")
node_parts :: proc(g: ^Gltf, i: int, parent: matrix[4, 4]f32, b: ^Mesh_Builder, depth: int) {
	nodes := array(g.root, "nodes")
	if i < 0 || i >= len(nodes) || depth > 64 {
		return
	}
	n := nodes[i].(json.Object) or_else nil
	world := parent * node_matrix(n)
	defer for k in array(n, "children") {
		node_parts(g, int(k.(json.Float) or_else -1), world, b, depth + 1)
	}
	meshes := array(g.root, "meshes")
	mi := int(number(n, "mesh", -1))
	if mi < 0 || mi >= len(meshes) {
		return
	}
	normal_matrix := linalg.inverse_transpose((matrix[3, 3]f32)(world))
	for prim_value in array(meshes[mi].(json.Object) or_else nil, "primitives") {
		prim := prim_value.(json.Object) or_else nil
		if number(prim, "mode", 4) != 4 {
			continue
		}
		attributes := object(prim, "attributes")
		positions, vertices := accessor_read(g, int(number(attributes, "POSITION", -1)), 3)
		if vertices == 0 {
			continue
		}
		normals, normal_count := accessor_read(g, int(number(attributes, "NORMAL", -1)), 3)
		uvs, uv_count := accessor_read(g, int(number(attributes, "TEXCOORD_0", -1)), 2)

		part := Model_Part{image = -1, colour = 1}
		// KHR_texture_transform's T * R * S: its top two rows, as u and v
		// of (u, v, 1).
		uv_rows := [2][3]f32{{1, 0, 0}, {0, 1, 0}}
		materials := array(g.root, "materials")
		if m := int(number(prim, "material", -1)); m >= 0 && m < len(materials) {
			mat := materials[m].(json.Object) or_else nil
			pbr := object(mat, "pbrMetallicRoughness")
			for f, k in array(pbr, "baseColorFactor") {
				if k < 4 {
					part.colour[k] = f32(f.(json.Float) or_else 1)
				}
			}
			if tex := object(pbr, "baseColorTexture"); tex != nil {
				turn := object(object(tex, "extensions"), "KHR_texture_transform")
				if number(turn, "texCoord", number(tex, "texCoord", 0)) == 0 {
					part.image = image_of(g, int(number(tex, "index", -1)))
				}
				o := pair(turn, "offset", 0)
				sc := pair(turn, "scale", 1)
				r := f32(number(turn, "rotation", 0))
				c, s := math.cos(r), math.sin(r)
				uv_rows = {{c * sc.x, s * sc.y, o.x}, {-s * sc.x, c * sc.y, o.y}}
			}
			switch text_of(mat, "alphaMode") {
			case "MASK":
				part.cutoff = f32(number(mat, "alphaCutoff", 0.5))
			case "BLEND":
				part.cutoff = 0.5
			}
		}
		colours: []f32
		colour_count: int
		if part.image < 0 {
			colours, colour_count = accessor_read(g, int(number(attributes, "COLOR_0", -1)), 4, 1)
			part.tinted = colour_count > 0
		}
		indices, index_count := accessor_read(g, int(number(prim, "indices", -1)), 1)
		count := ("indices" in prim ? index_count : vertices) / 3 * 3
		if count == 0 {
			continue
		}
		base := u32(len(b.positions))
		for k in 0 ..< vertices {
			p := world * [4]f32{positions[k * 3], positions[k * 3 + 1], positions[k * 3 + 2], 1}
			append(&b.positions, p.xyz)
			nv := [3]f32{0, 1, 0}
			if k < normal_count {
				nv = linalg.normalize0(normal_matrix * [3]f32{normals[k * 3], normals[k * 3 + 1], normals[k * 3 + 2]})
			}
			append(&b.normals, nv)
			uv: [2]f32
			if k < uv_count {
				at := [3]f32{uvs[k * 2], uvs[k * 2 + 1], 1}
				uv = {linalg.dot(uv_rows[0], at), linalg.dot(uv_rows[1], at)}
			}
			append(&b.uvs, uv)
			c := [4]u8{255, 255, 255, 255}
			if part.tinted {
				for ch in 0 ..< 4 {
					c[ch] = u8(clamp(colours[k * 4 + ch], 0, 1) * 255 + 0.5)
				}
			}
			append(&b.colours, c)
		}
		b.tinted ||= part.tinted
		part.first = len(b.indices)
		for k in 0 ..< count {
			vi := "indices" in prim ? int(indices[k]) : k
			append(&b.indices, base + u32(vi >= 0 && vi < vertices ? vi : 0))
		}
		part.count = count
		// Without normals, each triangle's own, shared vertices aside: it is
		// seen from above only.
		if normal_count == 0 {
			for t := part.first; t < part.first + count; t += 3 {
				ia, ib, ic := b.indices[t], b.indices[t + 1], b.indices[t + 2]
				nv := linalg.normalize0(linalg.cross(b.positions[ib] - b.positions[ia], b.positions[ic] - b.positions[ia]))
				b.normals[ia], b.normals[ib], b.normals[ic] = nv, nv, nv
			}
		}
		append(&b.parts, part)
	}
}

// A node's transform: its matrix, or its translation, rotation and scale.
@(private = "file")
node_matrix :: proc(n: json.Object) -> matrix[4, 4]f32 {
	if values := array(n, "matrix"); len(values) == 16 {
		m: [16]f32
		for x, k in values {
			m[k] = f32(x.(json.Float) or_else 0)
		}
		return transmute(matrix[4, 4]f32)m // both column-major
	}
	vec :: proc(n: json.Object, key: string, default: [4]f32) -> (out: [4]f32) {
		out = default
		for x, k in array(n, key) {
			if k < 4 {
				out[k] = f32(x.(json.Float) or_else f64(default[k]))
			}
		}
		return
	}
	t := vec(n, "translation", 0)
	r := vec(n, "rotation", {0, 0, 0, 1})
	s := vec(n, "scale", 1)
	q := quaternion(x = r.x, y = r.y, z = r.z, w = r.w)
	return linalg.matrix4_from_trs_f32(t.xyz, q, s.xyz)
}

// An accessor's elements as floats, `width` a vertex (`fill` past its
// own), and how many. None if it cannot be read.
@(private = "file")
accessor_read :: proc(g: ^Gltf, index: int, width: int, fill: f32 = 0) -> (out: []f32, count: int) {
	accessors := array(g.root, "accessors")
	if index < 0 || index >= len(accessors) {
		return
	}
	a := accessors[index].(json.Object) or_else nil
	if "sparse" in a {
		return
	}
	comps: int
	switch text_of(a, "type") {
	case "SCALAR":
		comps = 1
	case "VEC2":
		comps = 2
	case "VEC3":
		comps = 3
	case "VEC4":
		comps = 4
	}
	kind := int(number(a, "componentType", 0))
	size: int
	switch kind {
	case 5120, 5121:
		size = 1
	case 5122, 5123:
		size = 2
	case 5125, 5126:
		size = 4
	case:
		return
	}
	n := int(number(a, "count", 0))
	views := array(g.root, "bufferViews")
	vi := int(number(a, "bufferView", -1))
	if comps == 0 || n <= 0 || vi < 0 || vi >= len(views) {
		return
	}
	view := views[vi].(json.Object) or_else nil
	b := int(number(view, "buffer", -1))
	if b < 0 || b >= len(g.buffers) {
		return
	}
	stride := int(number(view, "byteStride", 0))
	if stride == 0 {
		stride = comps * size
	}
	start := int(number(view, "byteOffset", 0)) + int(number(a, "byteOffset", 0))
	buf := g.buffers[b]
	if start < 0 || start + (n - 1) * stride + comps * size > len(buf) {
		return
	}
	normalized := a["normalized"].(json.Boolean) or_else false
	out = make([]f32, n * width, context.temp_allocator)
	for i in 0 ..< n {
		for k in 0 ..< width {
			if k >= comps {
				out[i * width + k] = fill
				continue
			}
			at := buf[start + i * stride + k * size:]
			x: f32
			switch kind {
			case 5120:
				v := i8(at[0])
				x = normalized ? max(f32(v) / 127, -1) : f32(v)
			case 5121:
				x = normalized ? f32(at[0]) / 255 : f32(at[0])
			case 5122:
				v := i16(endian.unchecked_get_u16le(at))
				x = normalized ? max(f32(v) / 32767, -1) : f32(v)
			case 5123:
				v := endian.unchecked_get_u16le(at)
				x = normalized ? f32(v) / 65535 : f32(v)
			case 5125:
				// An index: exact in an f32 up to 2^24, and no mesh of a model
				// worth a sprite has more vertices.
				x = f32(endian.unchecked_get_u32le(at))
			case 5126:
				x = transmute(f32)endian.unchecked_get_u32le(at)
			}
			out[i * width + k] = x
		}
	}
	return out, n
}

// A texture's image, its bytes as they are, PNG or JPEG: its own file
// beside the glTF, in a buffer, or a data URI. Its place in g.images, or
// -1 if it cannot be read.
@(private = "file")
image_of :: proc(g: ^Gltf, texture: int) -> int {
	textures := array(g.root, "textures")
	if texture < 0 || texture >= len(textures) {
		return -1
	}
	index := int(number(textures[texture].(json.Object) or_else nil, "source", -1))
	if k, found := g.seen[index]; found {
		return k
	}
	g.seen[index] = -1
	images := array(g.root, "images")
	if index < 0 || index >= len(images) {
		return -1
	}
	img := images[index].(json.Object) or_else nil
	blob: []u8
	if uri := text_of(img, "uri"); uri != "" {
		if strings.has_prefix(uri, "data:") {
			if comma := strings.index_byte(uri, ','); comma >= 0 {
				blob, _ = base64.decode(uri[comma + 1:], allocator = context.temp_allocator)
			}
		} else {
			blob, _ = os.read_entire_file(strings.concatenate({g.dir, "/", uri_decode(uri)}, context.temp_allocator), context.temp_allocator)
		}
	} else {
		views := array(g.root, "bufferViews")
		vi := int(number(img, "bufferView", -1))
		if vi < 0 || vi >= len(views) {
			return -1
		}
		view := views[vi].(json.Object) or_else nil
		b := int(number(view, "buffer", -1))
		start, n := int(number(view, "byteOffset", 0)), int(number(view, "byteLength", 0))
		if b < 0 || b >= len(g.buffers) || start < 0 || start + n > len(g.buffers[b]) {
			return -1
		}
		blob = g.buffers[b][start:][:n]
	}
	mime: string
	switch {
	case len(blob) >= 8 && string(blob[:8]) == "\x89PNG\r\n\x1a\n":
		mime = "image/png"
	case len(blob) >= 3 && blob[0] == 0xFF && blob[1] == 0xD8 && blob[2] == 0xFF:
		mime = "image/jpeg"
	case:
		return -1
	}
	// The same bytes again, under an image of their own: searsia_lucida
	// names its colour texture three times, once a material.
	for have, k in g.images {
		if slice.equal(have.data, blob) {
			g.seen[index] = k
			return k
		}
	}
	append(&g.images, Model_Image{data = slice.clone(blob, g.allocator), mime = strings.clone(mime, g.allocator)})
	g.seen[index] = len(g.images) - 1
	return len(g.images) - 1
}

// An image decoded to RGBA, 8 bits a sample, in the temporary allocator.
model_image_rgba :: proc(img: Model_Image) -> (pic: Picture, ok: bool) {
	decoded, err := image.load_from_bytes(img.data, {}, context.temp_allocator)
	if err != nil {
		return
	}
	defer image.destroy(decoded, context.temp_allocator)
	n := decoded.width * decoded.height
	pic = picture_make(decoded.width, decoded.height, 4, 8, context.temp_allocator)
	src := decoded.pixels.buf[:]
	step := decoded.depth / 8
	for i in 0 ..< n {
		for ch in 0 ..< 4 {
			// Grey and alpha to RGBA; the high byte of a 16-bit sample.
			from := decoded.channels >= 3 ? ch : (ch < 3 ? 0 : 1)
			v: u8 = 255
			if from < decoded.channels {
				k := (i * decoded.channels + from) * step
				v = step == 2 ? src[k + 1] : src[k]
			}
			pic.pixels[i * 4 + ch] = v
		}
	}
	return pic, true
}

// %20 and the like, as a URI's path holds them.
@(private = "file")
uri_decode :: proc(s: string) -> string {
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9':
			return int(c - '0')
		case 'a' ..= 'f':
			return int(c - 'a' + 10)
		case 'A' ..= 'F':
			return int(c - 'A' + 10)
		}
		return -1
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 {
			strings.write_byte(&b, u8(hex(s[i + 1]) * 16 + hex(s[i + 2])))
			i += 2
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

@(private = "file")
array :: proc(o: json.Object, key: string) -> json.Array {
	return o == nil ? nil : o[key].(json.Array) or_else nil
}

@(private = "file")
object :: proc(o: json.Object, key: string) -> json.Object {
	return o == nil ? nil : o[key].(json.Object) or_else nil
}

@(private = "file")
number :: proc(o: json.Object, key: string, default: f64) -> f64 {
	if o == nil {
		return default
	}
	#partial switch v in o[key] {
	case json.Float:
		return v
	case json.Integer:
		return f64(v)
	}
	return default
}

// A two-number array, or both `default` where it has none.
@(private = "file")
pair :: proc(o: json.Object, key: string, default: f32) -> (v: [2]f32) {
	v = default
	for f, k in array(o, key) {
		if k < 2 {
			v[k] = f32(f.(json.Float) or_else f64(default))
		}
	}
	return
}

@(private = "file")
text_of :: proc(o: json.Object, key: string) -> string {
	return o == nil ? "" : o[key].(json.String) or_else ""
}
