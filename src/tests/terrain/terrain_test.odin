package terrain_tests

// The terrain renderer and the project format (Stage 5 of
// notes/level-editor-plan.md). A package of its own: rendering needs a GL
// context, which the main suite never opens. The GL cases share one hidden
// window, and skip when there is no display (mise run test runs them under
// xvfb-run).

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

OUT :: "build/terrain_test"

// Ground made of hills, with a colour of its own everywhere.
@(private = "file")
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
	for i in 0 ..< 24 * 16 {
		p.splat[i * 4 + i % 4] = 255
		p.canopy[i] = u8(i * 7)
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
	strips_are_the_whole(t)
	scales_agree(t)
	heights_come_back(t)
}

@(private = "file")
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
	hs := transmute([]u16)h.pixels
	for v, i in p.heights {
		if hs[i] != terrain.height_quantise(v) {
			testing.expectf(t, false, "height %d: %d, not %d", i, hs[i], terrain.height_quantise(v))
			break
		}
	}
}
