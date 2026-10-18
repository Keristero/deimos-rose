package terrain_tests

// Scenery models (Stage 8): a model read from a glTF, and its instances
// drawn into the map: where they cover, turned, lifted, cut out, their
// shadows with light under them, hidden by water, following the ground,
// and saved and opened again. The models are boxes and a leaf, written as
// glTF here.

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "dr:terrain"

@(private = "file")
Box :: struct {
	lo, hi: [3]f32, // metres, Y up
	colour: [4]f32,
}

// A glTF of a node for each list of boxes, its mesh their triangles,
// coloured by vertex, its buffer a data URI.
@(private = "file")
boxes_gltf :: proc(t: ^testing.T, path: string, roots: [][]Box) {
	floats := make([dynamic]f32, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	accessors := strings.builder_make(context.temp_allocator)
	views := strings.builder_make(context.temp_allocator)
	meshes := strings.builder_make(context.temp_allocator)
	nodes := strings.builder_make(context.temp_allocator)
	FACES :: [6][4][3]int {
		{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}},
		{{0, 0, 1}, {0, 1, 1}, {1, 1, 1}, {1, 0, 1}},
		{{0, 0, 0}, {0, 1, 0}, {0, 1, 1}, {0, 0, 1}},
		{{1, 0, 0}, {1, 0, 1}, {1, 1, 1}, {1, 1, 0}},
		{{0, 0, 0}, {0, 0, 1}, {1, 0, 1}, {1, 0, 0}},
		{{0, 1, 0}, {1, 1, 0}, {1, 1, 1}, {0, 1, 1}},
	}
	for boxes, r in roots {
		start := len(floats)
		count := 0
		for box in boxes {
			for face in FACES {
				for k in ([6]int{0, 1, 2, 0, 2, 3}) {
					c := face[k]
					for axis in 0 ..< 3 {
						append(&floats, c[axis] == 0 ? box.lo[axis] : box.hi[axis])
					}
					count += 1
				}
			}
		}
		colours := len(floats)
		for box in boxes {
			for _ in 0 ..< 36 {
				colour := box.colour
				append(&floats, ..colour[:])
			}
		}
		sep := r > 0 ? "," : ""
		fmt.sbprintf(&views, `%s{{"buffer":0,"byteOffset":%d,"byteLength":%d}},{{"buffer":0,"byteOffset":%d,"byteLength":%d}}`, sep, start * 4, count * 12, colours * 4, count * 16)
		fmt.sbprintf(&accessors, `%s{{"bufferView":%d,"componentType":5126,"count":%d,"type":"VEC3"}},{{"bufferView":%d,"componentType":5126,"count":%d,"type":"VEC4"}}`, sep, 2 * r, count, 2 * r + 1, count)
		fmt.sbprintf(&meshes, `%s{{"primitives":[{{"attributes":{{"POSITION":%d,"COLOR_0":%d}}}}]}}`, sep, 2 * r, 2 * r + 1)
		fmt.sbprintf(&nodes, `%s{{"name":"box %d","mesh":%d,"translation":[%d,0,0]}}`, sep, r, r, 10 * r)
	}
	bytes := slice.reinterpret([]u8, floats[:])
	encoded, _ := base64.encode(bytes, allocator = context.temp_allocator)
	scene := strings.builder_make(context.temp_allocator)
	for r in 0 ..< len(roots) {
		fmt.sbprintf(&scene, "%s%d", r > 0 ? "," : "", r)
	}
	fmt.sbprintf(&b, `{{"asset":{{"version":"2.0"}},"scene":0,"scenes":[{{"nodes":[%s]}}],"nodes":[%s],"meshes":[%s],"accessors":[%s],"bufferViews":[%s],"buffers":[{{"byteLength":%d,"uri":"data:application/octet-stream;base64,%s"}}]}}`, strings.to_string(scene), strings.to_string(nodes), strings.to_string(meshes), strings.to_string(accessors), strings.to_string(views), len(bytes), encoded)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil)
}

RED :: [4]f32{0.8, 0.1, 0.1, 1}

// A slab `wide` m across, 4 m down and 1 m thick: 12 x 12 x 3 map pixels
// at 4.
@(private = "file")
slab :: proc(t: ^testing.T, wide: f32 = 4) -> terrain.Model_File {
	path := fmt.tprintf("%s/slab-%v.gltf", OUT, wide)
	boxes_gltf(t, path, {{{lo = {-wide / 2, 0, -2}, hi = {wide / 2, 1, 2}, colour = RED}}})
	f, ok := terrain.model_file_read(path, context.temp_allocator)
	testing.expect(t, ok && len(f.variants) == 1)
	return f
}

// A leaf: a square 4 m across, flat 1 m up, its texture a PNG beside it,
// green and opaque on its left half and clear on its right, cut out at a
// half. Its URI is percent-encoded, as a name with a space is. `texture`
// is more of its baseColorTexture, as `,"extensions":{...}`, and `images`
// how many it is read with.
@(private = "file")
leaf :: proc(t: ^testing.T, texture := "", name := "leaf", images := 1) -> terrain.Model_File {
	pic := terrain.picture_make(2, 1, 4, 8, context.temp_allocator)
	copy(pic.pixels, []u8{30, 160, 40, 255, 30, 160, 40, 0})
	testing.expect(t, terrain.png_write(OUT + "/leaf image.png", pic))
	floats := []f32{-2, 1, -2, 2, 1, -2, 2, 1, 2, -2, 1, 2, 0, 0, 1, 0, 1, 1, 0, 1}
	indices := []u16{0, 2, 1, 0, 3, 2}
	bytes := slice.concatenate([][]u8{slice.to_bytes(floats), slice.to_bytes(indices)}, context.temp_allocator)
	encoded, _ := base64.encode(bytes, allocator = context.temp_allocator)
	doc := fmt.tprintf(`{{"asset":{{"version":"2.0"}},"scenes":[{{"nodes":[0]}}],"nodes":[{{"mesh":0}}],"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"TEXCOORD_0":1}},"indices":2,"material":0}}]}}],"materials":[{{"pbrMetallicRoughness":{{"baseColorTexture":{{"index":0%s}}}},"alphaMode":"MASK"}}],"textures":[{{"source":0}}],"images":[{{"uri":"leaf%%20image.png"}}],"accessors":[{{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"}},{{"bufferView":0,"byteOffset":48,"componentType":5126,"count":4,"type":"VEC2"}},{{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}}],"bufferViews":[{{"buffer":0,"byteLength":80}},{{"buffer":0,"byteOffset":80,"byteLength":12}}],"buffers":[{{"byteLength":%d,"uri":"data:application/octet-stream;base64,%s"}}]}}`, texture, len(bytes), encoded)
	path := fmt.tprintf("%s/%s.gltf", OUT, name)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)doc) == nil)
	f, ok := terrain.model_file_read(path, context.temp_allocator)
	testing.expect(t, ok && len(f.variants) == 1 && len(f.images) == images)
	return f
}

// Flat ground at height 10, grey, the sun east at `rise` per pixel, hard.
@(private = "file")
ground :: proc(w, l: int, rise: f32) -> terrain.Project {
	p := terrain.project_make(w, l, context.temp_allocator)
	p.albedo = make([]u8, w * l * 3, context.temp_allocator)
	for i in 0 ..< w * l {
		p.heights[i] = 10
		p.albedo[i * 3], p.albedo[i * 3 + 1], p.albedo[i * 3 + 2] = 200, 200, 200
	}
	p.level.lighting.sun_azimuth_degrees = 0
	p.level.lighting.sun_elevation_degrees = math.to_degrees(math.atan(rise))
	p.level.lighting.softness = 0
	return p
}

// Puts an instance of the file's first model, adding the file and the
// model if the project has neither.
@(private = "file")
put :: proc(p: ^terrain.Project, f: terrain.Model_File, i: terrain.Instance) {
	i := i
	i.model = -1
	for m, k in p.models {
		if m.file == f.name {
			i.model = k
		}
	}
	if i.model < 0 {
		append(&p.model_files, f)
		append(&p.models, terrain.Model{name = f.name, file = f.name})
		i.model = len(p.models) - 1
	}
	append(&p.instances, i)
}

@(private = "file")
rgb :: proc(pic: terrain.Picture, x, y: int) -> [3]u8 {
	px := pic.pixels[(y * pic.width + x) * 3:][:3]
	return {px[0], px[1], px[2]}
}

scenery_cases :: proc(t: ^testing.T) {
	a_model_reads(t)
	a_set_is_its_models(t)
	a_texture_transform_moves_the_uvs(t)
	a_lifted_slab_shades_with_light_under_it(t)
	a_turn_turns_the_footprint(t)
	a_lean_tips_it(t)
	a_cutout_has_holes(t)
	water_hides_a_model_under_it(t)
	models_follow_the_ground(t)
	models_save_and_reopen(t)
}

// A tree of boxes: a trunk a metre square, 3 m tall, under a crown 4 m
// across and 1 m deep, read centred on its foot; met from above at the
// crown's top, 12 map pixels up, as far out as the crown.
@(private = "file")
a_model_reads :: proc(t: ^testing.T) {
	path :: OUT + "/Tree.gltf"
	boxes_gltf(t, path, {{{lo = {-0.5, 0, -0.5}, hi = {0.5, 3, 0.5}, colour = {0.4, 0.3, 0.2, 1}}, {lo = {-2, 3, -2}, hi = {2, 4, 2}, colour = {0.1, 0.6, 0.1, 1}}}})
	f, ok := terrain.model_file_read(path, context.temp_allocator)
	if !testing.expect(t, ok && len(f.variants) == 1) {
		return
	}
	testing.expect_value(t, f.name, "tree")
	m := f.variants[0]
	testing.expect_value(t, m.lo, [3]f32{-2, 0, -2})
	testing.expect_value(t, m.hi, [3]f32{2, 4, 2})
	testing.expect(t, len(m.parts) == 1 && m.parts[0].tinted && m.parts[0].count == 72)
	testing.expect_value(t, m.colours[m.indices[71]], [4]u8{26, 153, 26, 255})
	p := ground(64, 64, 1)
	put(&p, f, {x = 32, y = 32, scale = 1})
	i := p.instances[0]
	for at in ([3][2]f32{{32, 32}, {37.5, 26.5}, {26.6, 32}}) {
		top, hit := terrain.instance_hit(&p, i, at)
		testing.expectf(t, hit && abs(top - 22) < 1e-3, "at %v: top %v, hit %v", at, top, hit)
	}
	_, hit := terrain.instance_hit(&p, i, {38.1, 32})
	testing.expect(t, !hit, "met beyond the crown")
	testing.expect_value(t, terrain.instance_pick(&p, {33, 33}), 0)
	testing.expect_value(t, terrain.instance_pick(&p, {50, 50}), -1)
	testing.expectf(t, abs(terrain.instance_reach(&p, i) - math.sqrt(f32(8)) * 3) < 1e-3, "the reach is %v", terrain.instance_reach(&p, i))
}

// Each node at the scene's root is a model of its own, centred on itself.
@(private = "file")
a_set_is_its_models :: proc(t: ^testing.T) {
	path :: OUT + "/Two Boxes.gltf"
	boxes_gltf(t, path, {{{lo = {-1, 0, -1}, hi = {1, 2, 1}, colour = RED}}, {{lo = {-2, 0, -2}, hi = {2, 1, 2}, colour = RED}}})
	f, ok := terrain.model_file_read(path, context.temp_allocator)
	if !testing.expect(t, ok && len(f.variants) == 2) {
		return
	}
	testing.expect_value(t, f.name, "two-boxes")
	testing.expect_value(t, f.variants[0].name, "box 0")
	testing.expect_value(t, f.variants[1].hi, [3]f32{2, 1, 2})
	testing.expect_value(t, f.variants[1].lo, [3]f32{-2, 0, -2})
	_, read := terrain.model_file_read(OUT + "/no such.gltf", context.temp_allocator)
	testing.expect(t, !read)
}

// KHR_texture_transform, as Poly Haven's atlases use: its offset, turn
// and scale are T * R * S, so with a turn of a quarter, (u, v) is
// (3v + 0.5, 0.25 - 2u). And a texCoord of 1 is a set not read: no image.
@(private = "file")
a_texture_transform_moves_the_uvs :: proc(t: ^testing.T) {
	f := leaf(t, `,"extensions":{"KHR_texture_transform":{"offset":[0.5,0.25],"rotation":1.5707964,"scale":[2,3]}}`, "turned leaf")
	m := f.variants[0]
	testing.expect_value(t, m.parts[0].image, 0)
	want := [4][2]f32{{0.5, 0.25}, {0.5, -1.75}, {3.5, -1.75}, {3.5, 0.25}}
	for w, k in want {
		testing.expectf(t, abs(m.uvs[k].x - w.x) < 1e-5 && abs(m.uvs[k].y - w.y) < 1e-5, "uv %d is %v, not %v", k, m.uvs[k], w)
	}
	other := leaf(t, `,"extensions":{"KHR_texture_transform":{"texCoord":1}}`, "second set leaf", images = 0)
	testing.expect_value(t, other.variants[0].parts[0].image, -1)
}

// A slab lifted 9 pixels shades the ground where the ray toward the sun
// passes between its underside and its top: at a rise of a half, from 18
// to 24 pixels west of the slab, so ground nearer it, under no slab, is
// lit. It is drawn its own colour, lit itself, and its sun reaches it.
@(private = "file")
a_lifted_slab_shades_with_light_under_it :: proc(t: ^testing.T) {
	W, L :: 96, 32
	p := ground(W, L, 0.5)
	put(&p, slab(t), {x = 60, y = 16, offset = 9, scale = 1})
	shadow := draw(t, &p, {output = .Shadow}, 0)
	row := shadow.pixels[16 * W:][:W]
	// The slab is x 54 to 66: in shadow from 54 - 24 to 66 - 18.
	testing.expectf(t, row[20] == 255 && row[40] == 0 && row[50] == 255 && row[60] == 255, "the shadow's row: %v", row[10:70])
	albedo := draw(t, &p, {output = .Albedo}, 0)
	testing.expect_value(t, rgb(albedo, 60, 16), [3]u8{204, 26, 26})
	testing.expect_value(t, rgb(albedo, 70, 16), [3]u8{200, 200, 200})
	lit := draw(t, &p, {output = .Lit}, 0)
	testing.expect_value(t, lit.pixels[(16 * W + 60) * 3], 204)
	shade := lit.pixels[(16 * W + 40) * 3]
	testing.expectf(t, abs(int(shade) - int(200 * 0.44)) <= 1, "the slab's shade is %d", shade)
	height := draw(t, &p, {output = .Height}, 0)
	plain := ground(W, L, 0.5)
	testing.expect(t, string(height.pixels) == string(draw(t, &plain, {output = .Height}, 0).pixels), "the height output has the models in it")
	testing.expect(t, terrain.png_write(OUT + "/lifted.png", lit))
}

// Turned a quarter, a slab long down the map is long across it; where an
// instance is met from above is where it is drawn.
@(private = "file")
a_turn_turns_the_footprint :: proc(t: ^testing.T) {
	W, L :: 64, 64
	f := slab(t, 1) // 1 m across, 4 m down: 3 x 12 pixels
	for turn in ([2]f32{0, 90}) {
		p := ground(W, L, 1)
		put(&p, f, {x = 32, y = 32, turn = turn, scale = 1})
		albedo := draw(t, &p, {output = .Albedo}, 0)
		red :: proc(pic: terrain.Picture, x, y: int) -> bool {
			return pic.pixels[(y * pic.width + x) * 3 + 1] < 100
		}
		down, across := red(albedo, 32, 37), red(albedo, 37, 32)
		testing.expectf(t, down == (turn == 0) && across == (turn != 0), "turned %v: down %v, across %v", turn, down, across)
		for at in ([4][2]int{{32, 37}, {37, 32}, {32, 26}, {26, 32}}) {
			drawn := red(albedo, at.x, at.y)
			_, hit := terrain.instance_hit(&p, p.instances[0], {f32(at.x) + 0.5, f32(at.y) + 0.5})
			testing.expectf(t, drawn == hit, "turned %v, at %v: drawn %v, met %v", turn, at, drawn, hit)
		}
	}
}

// A post 1 m square and 4 m tall, leant 90 degrees, lies toward the map's
// bottom: its top is then its side, 3 pixels up, and it reaches 12 down.
@(private = "file")
a_lean_tips_it :: proc(t: ^testing.T) {
	boxes_gltf(t, OUT + "/post.gltf", {{{lo = {-0.5, 0, -0.5}, hi = {0.5, 4, 0.5}, colour = RED}}})
	f, ok := terrain.model_file_read(OUT + "/post.gltf", context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	p := ground(64, 64, 1)
	put(&p, f, {x = 32, y = 20, lean = 90, scale = 1})
	top, hit := terrain.instance_hit(&p, p.instances[0], {32, 30})
	testing.expectf(t, hit && abs(top - 11.5) < 1e-3, "leant: top %v, hit %v", top, hit)
	_, hit = terrain.instance_hit(&p, p.instances[0], {32, 33})
	testing.expect(t, !hit, "met past the post's top")
	albedo := draw(t, &p, {output = .Albedo}, 0)
	testing.expect_value(t, rgb(albedo, 32, 30), [3]u8{204, 26, 26})
	testing.expect_value(t, rgb(albedo, 32, 34), [3]u8{200, 200, 200})
}

// A cut-out texture covers where it is opaque and not where it is clear.
@(private = "file")
a_cutout_has_holes :: proc(t: ^testing.T) {
	p := ground(32, 32, 1)
	put(&p, leaf(t), {x = 16, y = 16, scale = 1})
	albedo := draw(t, &p, {output = .Albedo}, 0)
	testing.expect_value(t, rgb(albedo, 12, 16), [3]u8{30, 160, 40})
	testing.expect_value(t, rgb(albedo, 20, 16), [3]u8{200, 200, 200})
	_, hit := terrain.instance_hit(&p, p.instances[0], {20, 16})
	// Provisional: the line meets the triangles, not their texture's
	// holes. Picking a leaf by its hole is picking it.
	testing.expect(t, hit)
}

// A model whose top is under the visible water is not seen.
@(private = "file")
water_hides_a_model_under_it :: proc(t: ^testing.T) {
	W, L :: 32, 32
	p := ground(W, L, 1)
	p.level.water = {height = 20, colour = {0, 0, 255}, visible = true}
	put(&p, slab(t), {x = 16, y = 16, scale = 1})
	testing.expect_value(t, rgb(draw(t, &p, {output = .Albedo}, 0), 16, 16), [3]u8{0, 0, 255})
	p.level.water.height = 11
	testing.expect_value(t, rgb(draw(t, &p, {output = .Albedo}, 0), 16, 16), [3]u8{204, 26, 26})
}

// Ground raised under a model lifts it, as a fresh upload draws it.
@(private = "file")
models_follow_the_ground :: proc(t: ^testing.T) {
	W, L :: 96, 32
	p := ground(W, L, 0.5)
	put(&p, slab(t), {x = 60, y = 16, offset = 9, scale = 1})
	r: terrain.Renderer
	testing.expect(t, terrain.renderer_init(&r, &p))
	defer terrain.renderer_destroy(&r)
	for y in 10 ..< 22 {
		for x in 56 ..< 64 {
			p.heights[y * W + x] = 16
		}
	}
	terrain.renderer_update(&r, &p, {56, 10, 64, 22})
	updated, _ := terrain.render(&r, &p, {output = .Shadow}, context.temp_allocator)
	testing.expect(t, string(updated.pixels) == string(draw(t, &p, {output = .Shadow}).pixels), "the update draws otherwise than a fresh upload")
	// Raised 6, the slab's shadow is 12 pixels further west.
	testing.expect_value(t, updated.pixels[16 * W + 24], 0)
	testing.expect_value(t, updated.pixels[16 * W + 40], 255)
}

// Models, their files and their instances are saved, the files as GLBs
// beside, the same bytes each time, and come back the same, drawn the
// same; a file no model uses is not kept.
@(private = "file")
models_save_and_reopen :: proc(t: ^testing.T) {
	p := ground(48, 32, 0.5)
	put(&p, slab(t), {x = 20, y = 16, offset = 2, turn = 30, lean = 10, scale = 1.5})
	put(&p, slab(t), {x = 34, y = 10, scale = 0.5})
	put(&p, leaf(t), {x = 30, y = 24, offset = 4, turn = 45, scale = 0.8})
	p.models[0].tags, p.models[0].source = {"test"}, "boxes"
	unused := slab(t, 2)
	append(&p.model_files, unused)
	path :: OUT + "/scenery.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	first, _ := os.read_entire_file(OUT + "/models/leaf.glb", context.temp_allocator)
	testing.expect(t, terrain.project_save(&p, path))
	second, _ := os.read_entire_file(OUT + "/models/leaf.glb", context.temp_allocator)
	testing.expect(t, len(first) > 0 && slice.equal(first, second), "the GLB is not the same bytes twice")
	testing.expect(t, !os.exists(OUT + "/models/slab-2.glb"), "a file no model uses is kept")
	q, ok := terrain.project_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, len(q.models), 2)
	testing.expect_value(t, len(q.model_files), 2)
	testing.expect_value(t, q.models[0].source, "boxes")
	testing.expect(t, slice.equal(q.instances[:], p.instances[:]))
	for f, k in q.model_files {
		a, b := f.variants[0], p.model_files[k].variants[0]
		testing.expect(t, slice.equal(a.positions, b.positions) && slice.equal(a.normals, b.normals) && slice.equal(a.uvs, b.uvs) && slice.equal(a.indices, b.indices) && slice.equal(a.colours, b.colours))
		testing.expect(t, slice.equal(a.parts, b.parts) && a.lo == b.lo && a.hi == b.hi)
		testing.expect_value(t, len(f.images), len(p.model_files[k].images))
	}
	lit := draw(t, &q, {output = .Lit})
	testing.expect(t, string(lit.pixels) == string(draw(t, &p, {output = .Lit}).pixels))
	testing.expect(t, terrain.png_write(OUT + "/scenery.png", lit))
}
