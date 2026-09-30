package terrain_tests

// Materials (Stage 8): their images saved beside a project, the weights
// drawn, the hex-tiled sampling, and the quilting that makes the library.

import "core:os"
import "core:testing"

import "dr:terrain"

// A pattern 8 pixels across and down: the channel says the phase.
@(private = "file")
checks :: proc(w, h: int, allocator := context.allocator) -> terrain.Picture {
	pic := terrain.picture_make(w, h, 3, 8, allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			px := pic.pixels[(y * w + x) * 3:][:3]
			px[0], px[1], px[2] = u8(x % 8 * 30), u8(y % 8 * 30), 128
		}
	}
	return pic
}

// A material's image is written where its name says, and comes back.
@(test)
material_images_save_beside :: proc(t: ^testing.T) {
	os.make_directory_all(OUT)
	p := terrain.project_make(16, 16, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "checks", colour = {255, 255, 255}, image = "materials/checks.png", tile = 32})
	p.material_images[0] = checks(24, 16, context.temp_allocator)
	path :: OUT + "/imaged.drproj.json"
	os.remove(OUT + "/materials/checks.png")
	testing.expect(t, terrain.project_save(&p, path))
	testing.expect(t, os.exists(OUT + "/materials/checks.png"), "the image was not written")
	q, ok := terrain.project_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	img := q.material_images[0]
	testing.expect_value(t, [3]int{img.width, img.height, img.channels}, [3]int{24, 16, 3})
	testing.expect(t, string(img.pixels) == string(p.material_images[0].pixels))
}

// A quilt of a pattern that repeats every 8 pixels is that pattern
// throughout, across its own edges too: every block that fits is taken,
// and the last in each row and column joins the first.
@(test)
quilt_tiles :: proc(t: ^testing.T) {
	ex := checks(64, 64, context.temp_allocator)
	o := terrain.QUILT_DEFAULT
	o.size = 128
	q, ok := terrain.quilt(ex, o, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, [2]int{q.width, q.height}, [2]int{128, 128})
	broken := 0
	for y in 0 ..< 128 {
		for x in 0 ..< 128 {
			here := q.pixels[(y * 128 + x) * 3:][:3]
			right := q.pixels[(y * 128 + (x + 1) % 128) * 3:][:3]
			below := q.pixels[((y + 1) % 128 * 128 + x) * 3:][:3]
			if int(right[0]) != (int(here[0]) + 30) % 240 || int(below[1]) != (int(here[1]) + 30) % 240 {
				broken += 1
			}
		}
	}
	testing.expectf(t, broken == 0, "the pattern breaks at %d pixels", broken)

	again, _ := terrain.quilt(ex, o, context.temp_allocator)
	testing.expect(t, string(again.pixels) == string(q.pixels), "the same seed quilted otherwise")
	_, bad := terrain.quilt(ex, {size = 100, block = 40, overlap = 8}, context.temp_allocator)
	testing.expect(t, !bad, "a size that is not a whole number of steps")
}

// In a picture half one flat colour and half a gradient, the most uniform
// window is in the flat half.
@(test)
uniform_window_finds_one_ground :: proc(t: ^testing.T) {
	pic := terrain.picture_make(128, 64, 3, 8, context.temp_allocator)
	for y in 0 ..< 64 {
		for x in 0 ..< 128 {
			v := x < 64 ? u8(100) : u8(x * 2)
			pic.pixels[(y * 128 + x) * 3], pic.pixels[(y * 128 + x) * 3 + 1], pic.pixels[(y * 128 + x) * 3 + 2] = v, v, v
		}
	}
	x, _, spread, ok := terrain.uniform_window(pic, {0, 0, 128, 64}, 32, 8)
	testing.expect(t, ok)
	testing.expectf(t, x + 32 <= 64, "the window is at %d, over the gradient", x)
	testing.expect_value(t, spread, f32(0))
	_, _, _, small := terrain.uniform_window(pic, {0, 0, 20, 20}, 32, 8)
	testing.expect(t, !small)
}

// The weights made after the upload, and a region of them changed, draw
// as a fresh upload does.
weights_update_is_a_new_upload :: proc(t: ^testing.T) {
	p := hills(60, 50, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "red", colour = {200, 40, 40}})
	r: terrain.Renderer
	testing.expect(t, terrain.renderer_init(&r, &p))
	defer terrain.renderer_destroy(&r)
	splat := terrain.project_splat(&p, context.temp_allocator)
	rect := terrain.Rect{10, 10, 30, 25}
	for y in rect.y0 ..< rect.y1 {
		for x in rect.x0 ..< rect.x1 {
			splat[(y * 60 + x) * 4] = u8(x * 8)
		}
	}
	terrain.renderer_update(&r, &p, rect)
	updated, _ := terrain.render(&r, &p, {output = .Albedo}, context.temp_allocator)
	testing.expect(t, string(updated.pixels) == string(draw(t, &p, {output = .Albedo}).pixels), "weights made after the upload")
	splat[(20 * 60 + 20) * 4] = 255
	terrain.renderer_update(&r, &p, {20, 20, 21, 21})
	updated, _ = terrain.render(&r, &p, {output = .Albedo}, context.temp_allocator)
	testing.expect(t, string(updated.pixels) == string(draw(t, &p, {output = .Albedo}).pixels), "weights changed in a region")
}

// Without an unlit colour, a weight at half shows the material over the
// first by half, not all of it.
half_weight_shows_half :: proc(t: ^testing.T) {
	p := terrain.project_make(8, 8, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "black", colour = {0, 0, 0}})
	append(&p.materials, terrain.Material{name = "white", colour = {255, 255, 255}})
	splat := terrain.project_splat(&p, context.temp_allocator)
	for i in 0 ..< 64 {
		splat[i * 4 + 1] = 128
	}
	pic := draw(t, &p, {output = .Albedo})
	v := int(pic.pixels[(4 * 8 + 4) * 3])
	testing.expectf(t, abs(v - 128) <= 2, "half white over black is %d", v)
}

// An image material, hex-tiled, does not repeat every tile: a map pixel
// and the one a tile to its right are drawn alike far less often than a
// plain tiling's every time.
materials_do_not_repeat :: proc(t: ^testing.T) {
	TILE :: 16
	p := terrain.project_make(96, 64, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "noise", colour = {255, 255, 255}, image = "noise.png", tile = TILE})
	img := terrain.picture_make(16, 16, 3, 8, context.temp_allocator)
	seed := u32(7)
	for &b in img.pixels {
		seed = seed * 1664525 + 1013904223
		b = u8(seed >> 24)
	}
	p.material_images[0] = img
	pic := draw(t, &p, {output = .Albedo})
	alike, total := 0, 0
	for y in 0 ..< 64 {
		for x in 0 ..< 96 - TILE {
			a := pic.pixels[(y * 96 + x) * 3:][:3]
			b := pic.pixels[(y * 96 + x + TILE) * 3:][:3]
			total += 1
			if abs(int(a[0]) - int(b[0])) <= 2 && abs(int(a[1]) - int(b[1])) <= 2 && abs(int(a[2]) - int(b[2])) <= 2 {
				alike += 1
			}
		}
	}
	testing.expectf(t, alike * 10 < total, "%d of %d pixels repeat a tile along", alike, total)
}
