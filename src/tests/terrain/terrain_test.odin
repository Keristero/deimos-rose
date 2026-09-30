package terrain_tests

// The terrain renderer and the project format (Stage 5 of
// notes/level-editor-plan.md). A package of its own: rendering needs a GL
// context, which the main suite never opens. The GL cases share one hidden
// window, and skip when there is no display (mise run test runs them under
// xvfb-run).

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:testing"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

OUT :: "build/terrain_test"

// Ground made of hills, with a colour of its own everywhere.
hills :: proc(w, l: int, allocator := context.allocator) -> terrain.Project {
	p := terrain.project_make(w, l, allocator)
	p.albedo = make([]u8, w * l * 3, allocator)
	for y in 0 ..< l {
		for x in 0 ..< w {
			fx, fy := f32(x), f32(y)
			p.heights[y * w + x] = 12 + 8 * math.sin(fx * 0.11) * math.cos(fy * 0.07) + 3 * math.sin((fx + fy) * 0.23)
			c := p.albedo[(y * w + x) * 3:][:3]
			c[0], c[1], c[2] = u8(80 + x % 50), u8(120 + y % 60), 90
		}
	}
	return p
}

// Saved, loaded and saved again, a project is the same bytes; heights
// come back as the 16-bit file holds them.
@(test)
project_round_trips :: proc(t: ^testing.T) {
	os.make_directory_all(OUT)
	p := hills(24, 16, context.temp_allocator)
	p.splat = make([]u8, 24 * 16 * 4, context.temp_allocator)
	p.canopy = make([]u8, 24 * 16, context.temp_allocator)
	p.occlusion = make([]u8, 24 * 16, context.temp_allocator)
	p.water = make([]u8, 24 * 16 * 4, context.temp_allocator)
	for i in 0 ..< 24 * 16 {
		p.splat[i * 4 + i % 4] = 255
		p.canopy[i] = u8(i * 7)
		p.occlusion[i] = u8(255 - i * 3)
		p.water[i * 4], p.water[i * 4 + 3] = u8(i * 5), u8(i * 11)
	}
	p.canopy_height, p.canopy_material = 4, 1
	append(&p.materials, terrain.Material{name = "grass", colour = {60, 140, 50}, tile = 32})
	append(&p.materials, terrain.Material{name = "trees", colour = {30, 80, 30}, tags = {"original-derived"}})
	p.cliff = {material = 0, from = 1, to = 2}
	p.level.id, p.level.name = "le99", "Test"
	p.level.water = {height = 9.5, colour = {20, 40, 90}, visible = true}
	p.level.lighting.sun_elevation_degrees = 35

	path :: OUT + "/round.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	first, _ := os.read_entire_file(path, context.temp_allocator)
	first_h, _ := os.read_entire_file(OUT + "/round.height.png", context.temp_allocator)
	q, ok := terrain.project_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, q.width, 24)
	testing.expect_value(t, len(q.materials), 2)
	testing.expect_value(t, q.materials[1].tags[0], "original-derived")
	testing.expect_value(t, q.level.water, p.level.water)
	testing.expect_value(t, q.level.lighting.sun_elevation_degrees, f32(35))
	testing.expect_value(t, q.level.lighting.ambient, data.LIGHTING_MEASURED.ambient)
	testing.expect_value(t, q.canopy_material, 1)
	for v, i in p.heights {
		if f32(terrain.height_quantise(v)) * terrain.HEIGHT_UNIT != q.heights[i] {
			testing.expectf(t, false, "height %d: %v then %v", i, v, q.heights[i])
			break
		}
	}
	testing.expect(t, string(q.albedo) == string(p.albedo))
	testing.expect(t, string(q.splat) == string(p.splat))
	testing.expect(t, string(q.canopy) == string(p.canopy))
	testing.expect(t, string(q.occlusion) == string(p.occlusion))
	testing.expect(t, string(q.water) == string(p.water))

	testing.expect(t, terrain.project_save(&q, path))
	second, _ := os.read_entire_file(path, context.temp_allocator)
	second_h, _ := os.read_entire_file(OUT + "/round.height.png", context.temp_allocator)
	testing.expect(t, string(first) == string(second), "the JSON changed")
	testing.expect(t, string(first_h) == string(second_h), "the heightmap changed")
}

// Through 15-bit colour and back, as the originals' images went: black
// and white stay, and doing it twice changes nothing.
@(test)
quantise_1555_is_the_originals :: proc(t: ^testing.T) {
	px := []u8{0, 0, 0, 255, 255, 255, 128, 7, 200}
	pic := terrain.Picture{3, 1, 3, 8, px}
	terrain.quantise_1555(pic)
	testing.expect_value(t, [9]u8{px[0], px[1], px[2], px[3], px[4], px[5], px[6], px[7], px[8]}, [9]u8{0, 0, 0, 255, 255, 255, 132, 8, 198})
	again := [9]u8{}
	copy(again[:], px)
	terrain.quantise_1555(pic)
	testing.expect(t, string(px) == string(again[:]))
}

@(test)
terrain_renders :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(64, 64, "terrain test")
	if !rl.IsWindowReady() {
		fmt.println("terrain_renders: no display, skipped")
		return
	}
	defer rl.CloseWindow()
	os.make_directory_all(OUT)
	flat_ground_is_lit(t)
	block_shadow_is_as_long_as_the_sun_says(t)
	smoothing_rounds_edges(t)
	occlusion_darkens_the_ambient(t)
	water_layer_over_the_bed(t)
	water_follows_the_ground(t)
	strips_are_the_whole(t)
	an_update_is_a_new_upload(t)
	scales_agree(t)
	heights_come_back(t)
	weights_update_is_a_new_upload(t)
	half_weight_shows_half(t)
	materials_do_not_repeat(t)
}

draw :: proc(t: ^testing.T, p: ^terrain.Project, o: terrain.Render_Options, smoothing: f32 = terrain.GEOMETRY_SMOOTHING) -> terrain.Picture {
	r: terrain.Renderer
	testing.expect(t, terrain.renderer_init(&r, p, smoothing))
	defer terrain.renderer_destroy(&r)
	pic, ok := terrain.render(&r, p, o, context.temp_allocator)
	testing.expect(t, ok)
	return pic
}

// Flat ground in the sun is its own colour, and nowhere its own shadow;
// the first row read back is the map's first.
@(private = "file")
flat_ground_is_lit :: proc(t: ^testing.T) {
	p := terrain.project_make(40, 30, context.temp_allocator)
	p.albedo = make([]u8, 40 * 30 * 3, context.temp_allocator)
	for &h in p.heights {
		h = 10
	}
	for i in 0 ..< 40 * 30 {
		p.albedo[i * 3 + 0], p.albedo[i * 3 + 1], p.albedo[i * 3 + 2] = 100, 150, 200
	}
	p.albedo[0], p.albedo[1], p.albedo[2] = 255, 0, 0
	shadow := draw(t, &p, {output = .Shadow})
	for v in shadow.pixels {
		if v != 255 {
			testing.expectf(t, false, "flat ground shadowed: %d", v)
			break
		}
	}
	lit := draw(t, &p, {output = .Lit})
	testing.expect_value(t, [3]u8{lit.pixels[0], lit.pixels[1], lit.pixels[2]}, [3]u8{255, 0, 0})
	for i in 1 ..< 40 * 30 {
		c := lit.pixels[i * 3:][:3]
		if abs(int(c[0]) - 100) > 1 || abs(int(c[1]) - 150) > 1 || abs(int(c[2]) - 200) > 1 {
			testing.expectf(t, false, "flat ground at %d is %v", i, c)
			break
		}
	}
}

// Occlusion takes away only the sky's light: fully occluded ground in
// the sun keeps the sun's share, in shadow it is black, and its layer
// comes back as the occlusion output.
@(private = "file")
occlusion_darkens_the_ambient :: proc(t: ^testing.T) {
	W, L :: 128, 16
	p := terrain.project_make(W, L, context.temp_allocator)
	p.albedo = make([]u8, W * L * 3, context.temp_allocator)
	p.occlusion = make([]u8, W * L, context.temp_allocator)
	for x in 0 ..< W {
		for y in 0 ..< L {
			i := y * W + x
			p.heights[i] = x >= 100 && x < 110 ? 20 : 0
			p.albedo[i * 3], p.albedo[i * 3 + 1], p.albedo[i * 3 + 2] = 200, 200, 200
			p.occlusion[i] = x < 50 ? 0 : 255
		}
	}
	p.level.lighting.sun_azimuth_degrees = 0
	p.level.lighting.sun_elevation_degrees = 45
	p.level.lighting.softness = 0
	a := p.level.lighting.ambient
	lit := draw(t, &p, {output = .Lit}, 0)
	open := draw(t, &p, {output = .Occlusion}, 0)
	grey :: proc(pic: terrain.Picture, x, y, channels: int) -> int {
		return int(pic.pixels[(y * pic.width + x) * channels])
	}
	// West of x 50, in the sun, occluded; at x 90, in the wall's shadow
	// (20 long), open; at x 20 the sun's share alone.
	testing.expect(t, abs(grey(lit, 20, 8, 3) - int(200 * (1 - a) + 0.5)) <= 1, "occluded in the sun")
	testing.expect(t, abs(grey(lit, 70, 8, 3) - 200) <= 1, "open in the sun")
	testing.expect(t, abs(grey(lit, 90, 8, 3) - int(200 * a + 0.5)) <= 1, "open in shadow")
	testing.expect_value(t, grey(open, 20, 8, 1), 0)
	testing.expect_value(t, grey(open, 70, 8, 1), 255)
}

// Under the water its layer is drawn over the bed by its opacity: clear
// shows the bed, opaque the layer's colour, half between; the bed takes
// the cast shadows, the water's surface none. Without the layer the water
// is the level's colour.
@(private = "file")
water_layer_over_the_bed :: proc(t: ^testing.T) {
	W, L :: 64, 16
	p := terrain.project_make(W, L, context.temp_allocator)
	p.albedo = make([]u8, W * L * 3, context.temp_allocator)
	p.water = make([]u8, W * L * 4, context.temp_allocator)
	for x in 0 ..< W {
		for y in 0 ..< L {
			i := y * W + x
			p.heights[i] = x < 48 ? 0 : 40
			p.albedo[i * 3] = 200
			p.water[i * 4 + 2] = 200
			p.water[i * 4 + 3] = x < 16 ? 0 : x < 32 ? 128 : 255
		}
	}
	p.level.water = {height = 10, colour = {0, 200, 0}, visible = true}
	albedo := draw(t, &p, {output = .Albedo}, 0)
	px :: proc(pic: terrain.Picture, x: int) -> [3]int {
		c := pic.pixels[(8 * pic.width + x) * 3:]
		return {int(c[0]), int(c[1]), int(c[2])}
	}
	near :: proc(a, b: [3]int) -> bool {
		return abs(a.r - b.r) <= 2 && abs(a.g - b.g) <= 2 && abs(a.b - b.b) <= 2
	}
	testing.expectf(t, near(px(albedo, 8), {200, 0, 0}), "clear water: %v", px(albedo, 8))
	testing.expectf(t, near(px(albedo, 24), {100, 0, 100}), "half: %v", px(albedo, 24))
	testing.expectf(t, near(px(albedo, 40), {0, 0, 200}), "opaque: %v", px(albedo, 40))
	testing.expectf(t, near(px(albedo, 56), {200, 0, 0}), "dry land: %v", px(albedo, 56))
	// The sun low in the east: the bank at x 48 shades all the water. The
	// clear water shows the bed in shadow, the opaque its colour lit.
	p.level.lighting.sun_azimuth_degrees = 0
	p.level.lighting.sun_elevation_degrees = 20
	p.level.lighting.softness = 0
	a := p.level.lighting.ambient
	lit := draw(t, &p, {output = .Lit}, 0)
	testing.expectf(t, near(px(lit, 8), {int(200 * a + 0.5), 0, 0}), "clear, in shadow: %v", px(lit, 8))
	testing.expectf(t, near(px(lit, 40), {0, 0, 200}), "opaque, unshadowed: %v", px(lit, 40))
	// Fully occluded: the bed seen through clear water is black in the
	// shadow, the opaque water's surface is lit as before.
	p.occlusion = make([]u8, W * L, context.temp_allocator)
	occluded := draw(t, &p, {output = .Lit}, 0)
	testing.expectf(t, near(px(occluded, 8), {0, 0, 0}), "clear, occluded: %v", px(occluded, 8))
	testing.expectf(t, near(px(occluded, 40), {0, 0, 200}), "opaque, occluded: %v", px(occluded, 40))
	p.occlusion = nil
	p.water = nil
	flat := draw(t, &p, {output = .Albedo}, 0)
	testing.expectf(t, near(px(flat, 24), {0, 200, 0}), "no layer: %v", px(flat, 24))
}

// Water is drawn where the ground itself is under it, the smoothed ground
// notwithstanding: a tall bank's smoothing lifts the bed beside it out of
// the water (row 3), and a low bank's pulls it under (row 12).
@(private = "file")
water_follows_the_ground :: proc(t: ^testing.T) {
	W, L :: 64, 16
	p := terrain.project_make(W, L, context.temp_allocator)
	p.albedo = make([]u8, W * L * 3, context.temp_allocator)
	p.water = make([]u8, W * L * 4, context.temp_allocator)
	for x in 0 ..< W {
		for y in 0 ..< L {
			i := y * W + x
			p.heights[i] = x < 48 ? 0 : y < 8 ? 40 : 11
			p.albedo[i * 3] = 200
			p.water[i * 4 + 2], p.water[i * 4 + 3] = 200, 255
		}
	}
	p.level.water = {height = 10, colour = {0, 200, 0}, visible = true}
	albedo := draw(t, &p, {output = .Albedo})
	px :: proc(pic: terrain.Picture, x, y: int) -> [3]u8 {
		c := pic.pixels[(y * pic.width + x) * 3:]
		return {c[0], c[1], c[2]}
	}
	for y in ([?]int{3, 12}) {
		testing.expectf(t, px(albedo, 47, y) == {0, 0, 200}, "row %d: the water's last pixel is %v", y, px(albedo, 47, y))
		testing.expectf(t, px(albedo, 48, y) == {200, 0, 0}, "row %d: the bank's first pixel is %v", y, px(albedo, 48, y))
	}
}

// A wall h high, with the sun due east at elevation e, shades h/tan(e)
// of the ground west of it; the shade is the ambient light. Unsmoothed:
// smoothing rounds the wall's edge, and its shadow is a little shorter.
@(private = "file")
block_shadow_is_as_long_as_the_sun_says :: proc(t: ^testing.T) {
	W, L :: 128, 16
	p := terrain.project_make(W, L, context.temp_allocator)
	p.albedo = make([]u8, W * L * 3, context.temp_allocator)
	for i in 0 ..< W * L {
		p.albedo[i * 3 + 0], p.albedo[i * 3 + 1], p.albedo[i * 3 + 2] = 200, 200, 200
		if x := i % W; x >= 96 && x < 112 {
			p.heights[i] = 16
		}
	}
	p.level.lighting.sun_azimuth_degrees = 0
	p.level.lighting.sun_elevation_degrees = 28
	shadow := draw(t, &p, {output = .Shadow}, 0)
	row := shadow.pixels[8 * W:][:W]
	edge := -1
	for x in 0 ..< 96 {
		if row[x] < 128 {
			edge = x
			break
		}
	}
	want := 96 - 16 / math.tan(math.to_radians(f32(28))) - 0.5
	testing.expectf(t, abs(f32(edge) - want) <= 1.5, "the shadow starts at %d, not %.1f", edge, want)
	testing.expect_value(t, row[90], 0)
	testing.expect_value(t, row[20], 255)
	testing.expect_value(t, row[100], 255)
	lit := draw(t, &p, {output = .Lit}, 0)
	shade := lit.pixels[(8 * W + 90) * 3]
	testing.expectf(t, abs(int(shade) - int(200 * 0.44)) <= 1, "shade is %d", shade)
}

// The geometry drawn smoothed: the wall's edge tilts over a few pixels, not
// the two a central difference sees, and its shadow is shorter than the
// sharp wall's by less than 3 sigma.
@(private = "file")
smoothing_rounds_edges :: proc(t: ^testing.T) {
	W, L :: 128, 16
	p := terrain.project_make(W, L, context.temp_allocator)
	for i in 0 ..< W * L {
		if x := i % W; x >= 96 && x < 112 {
			p.heights[i] = 16
		}
	}
	p.level.lighting.sun_azimuth_degrees = 0
	p.level.lighting.sun_elevation_degrees = 28
	tilted :: proc(pic: terrain.Picture, W: int) -> (n: int) {
		for x in 80 ..< 104 {
			if pic.pixels[(8 * W + x) * 3 + 2] < 250 {
				n += 1
			}
		}
		return
	}
	sharp, soft := tilted(draw(t, &p, {output = .Normal}, 0), W), tilted(draw(t, &p, {output = .Normal}), W)
	testing.expectf(t, sharp <= 2 && soft >= 4, "tilted pixels at the edge: %d sharp, %d smoothed", sharp, soft)
	edge :: proc(pic: terrain.Picture, W: int) -> int {
		for x in 0 ..< 96 {
			if pic.pixels[8 * W + x] < 128 {
				return x
			}
		}
		return -1
	}
	a, b := edge(draw(t, &p, {output = .Shadow}, 0), W), edge(draw(t, &p, {output = .Shadow}), W)
	testing.expectf(t, b >= a && f32(b - a) < 3 * terrain.GEOMETRY_SMOOTHING / math.tan(math.to_radians(f32(28))) + 1, "the smoothed shadow starts at %d, the sharp one at %d", b, a)
}

// Drawn a few rows at a time, the map is the map drawn at once.
@(private = "file")
strips_are_the_whole :: proc(t: ^testing.T) {
	p := hills(60, 50, context.temp_allocator)
	for output in terrain.Output {
		whole := draw(t, &p, {output = output, scale = 2})
		strips := draw(t, &p, {output = output, scale = 2, strip = 14})
		testing.expectf(t, string(whole.pixels) == string(strips.pixels), "%v differs in strips", output)
	}
	part := draw(t, &p, {output = .Lit, from = 10, to = 30})
	whole := draw(t, &p, {output = .Lit})
	testing.expect(t, string(part.pixels) == string(whole.pixels[10 * 60 * 3:][:20 * 60 * 3]), "rows 10-30 differ")
	terrain.png_write(OUT + "/hills.png", whole)
}

// A region uploaded again after an edit draws as the whole project
// uploaded afresh: the smoothing's margin is recomputed, and the water
// layer follows too.
@(private = "file")
an_update_is_a_new_upload :: proc(t: ^testing.T) {
	p := hills(60, 50, context.temp_allocator)
	p.level.water = {height = 9, colour = {20, 60, 110}, visible = true}
	p.water = make([]u8, 60 * 50 * 4, context.temp_allocator)
	r: terrain.Renderer
	testing.expect(t, terrain.renderer_init(&r, &p))
	defer terrain.renderer_destroy(&r)
	// A pit and a peak across one corner, and water filled into the pit.
	rect := terrain.Rect{40, 30, 60, 50}
	for y in rect.y0 ..< rect.y1 {
		for x in rect.x0 ..< rect.x1 {
			i := y * 60 + x
			p.heights[i] = x < 50 ? 2 : 40
			if p.heights[i] < p.level.water.height {
				copy(p.water[i * 4:][:4], []u8{30, 70, 120, 200})
			}
		}
	}
	terrain.renderer_update(&r, &p, rect)
	for output in ([?]terrain.Output{.Lit, .Albedo, .Normal, .Shadow}) {
		updated, ok := terrain.render(&r, &p, {output = output}, context.temp_allocator)
		testing.expect(t, ok)
		fresh := draw(t, &p, {output = output})
		testing.expectf(t, string(updated.pixels) == string(fresh.pixels), "%v after an update differs from a fresh upload", output)
	}
}

// Twice the size, averaged down, is close to the map at its size.
@(private = "file")
scales_agree :: proc(t: ^testing.T) {
	p := hills(60, 50, context.temp_allocator)
	one := draw(t, &p, {output = .Lit})
	two := draw(t, &p, {output = .Lit, scale = 2})
	total, worst := 0, 0
	for y in 0 ..< 50 {
		for x in 0 ..< 60 {
			for c in 0 ..< 3 {
				sum := 0
				for d in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
					sum += int(two.pixels[((y * 2 + d.y) * 120 + x * 2 + d.x) * 3 + c])
				}
				diff := abs((sum + 2) / 4 - int(one.pixels[(y * 60 + x) * 3 + c]))
				total += diff
				worst = max(worst, diff)
			}
		}
	}
	mean := f32(total) / (60 * 50 * 3)
	testing.expectf(t, mean < 2 && worst < 48, "2x shrunk differs from 1x: mean %.2f, worst %d", mean, worst)
}

// The height output at 1x is the heightmap.
@(private = "file")
heights_come_back :: proc(t: ^testing.T) {
	p := hills(60, 50, context.temp_allocator)
	h := draw(t, &p, {output = .Height})
	hs := slice.reinterpret([]u16, h.pixels)
	for v, i in p.heights {
		if hs[i] != terrain.height_quantise(v) {
			testing.expectf(t, false, "height %d: %d, not %d", i, hs[i], terrain.height_quantise(v))
			break
		}
	}
}
