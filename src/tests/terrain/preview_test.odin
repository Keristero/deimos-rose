package terrain_tests

// Level previews (Stage 9): where the crop goes, the 3x average, the
// fitted look's shape, the crop kept in the project and found again from
// a preview; and the media mask an export makes beside it.

import "core:os"
import "core:strings"
import "core:testing"

import "dr:terrain"

// The look that changes nothing: what the crop gives is the preview.
@(private = "file")
IDENTITY :: terrain.Preview_Look {
	colour = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}},
	tone = {
		{0, 15.9375, 31.875, 47.8125, 63.75, 79.6875, 95.625, 111.5625, 127.5, 143.4375, 159.375, 175.3125, 191.25, 207.1875, 223.125, 239.0625, 255},
		{0, 15.9375, 31.875, 47.8125, 63.75, 79.6875, 95.625, 111.5625, 127.5, 143.4375, 159.375, 175.3125, 191.25, 207.1875, 223.125, 239.0625, 255},
		{0, 15.9375, 31.875, 47.8125, 63.75, 79.6875, 95.625, 111.5625, 127.5, 143.4375, 159.375, 175.3125, 191.25, 207.1875, 223.125, 239.0625, 255},
	},
	across = {1, 1, 1, 1, 1, 1, 1, 1, 1},
	down = {1, 1, 1, 1, 1, 1, 1, 1, 1},
}

// The crop starts where it is asked to, and each preview pixel is the
// mean of its 3x3 block: a map whose red is its column and green its row
// (mod 256) shows both offset by the crop and stepping by 3.
@(test)
preview_crops_and_averages :: proc(t: ^testing.T) {
	m := terrain.picture_make(480, 1200, 3, 8, context.temp_allocator)
	for y in 0 ..< m.height {
		for x in 0 ..< m.width {
			px := m.pixels[(y * m.width + x) * 3:][:3]
			px[0], px[1], px[2] = u8(x % 256), u8(y % 200), 77
		}
	}
	at := [2]int{20, 90}
	p := terrain.preview_make_with(m, at, IDENTITY, context.temp_allocator)
	testing.expect_value(t, p.width, terrain.PREVIEW_WIDTH)
	testing.expect_value(t, p.height, terrain.PREVIEW_HEIGHT)
	for q in ([][2]int{{0, 0}, {10, 7}, {60, 30}}) {
		px := p.pixels[(q.y * p.width + q.x) * 3:][:3]
		testing.expect_value(t, int(px[0]), (at.x + q.x * 3 + 1) % 256)
		testing.expect_value(t, int(px[1]), (at.y + q.y * 3 + 1) % 200)
		testing.expect_value(t, px[2], 77)
	}
}

// By default the crop is the level's start, its bottom, in the middle
// across; it stays on the map; and a map narrower than the crop starts
// at its edge.
@(test)
preview_crop_defaults_to_the_start :: proc(t: ^testing.T) {
	testing.expect_value(t, terrain.preview_crop_default(480, 3600), [2]int{21, 3600 - 918})
	testing.expect_value(t, terrain.preview_crop_clamp({-5, 9999}, 480, 3600), [2]int{0, 3600 - 918})
	testing.expect_value(t, terrain.preview_crop_default(200, 500), [2]int{0, 0})
}

// The fitted look keeps the middle as the tone makes it and darkens
// towards the edges, the ends more than the sides, as the originals do.
@(test)
preview_look_darkens_the_edges :: proc(t: ^testing.T) {
	look := terrain.PREVIEW_LOOK
	mid := terrain.preview_vignette(&look, terrain.PREVIEW_WIDTH / 2, terrain.PREVIEW_HEIGHT / 2)
	side := terrain.preview_vignette(&look, 0, terrain.PREVIEW_HEIGHT / 2)
	end := terrain.preview_vignette(&look, terrain.PREVIEW_WIDTH / 2, 0)
	testing.expect(t, abs(mid - 1) < 0.02)
	testing.expect(t, side < mid && end < side, "the vignette darkens the ends most")
	for c in 0 ..< 3 {
		testing.expect(t, look.tone[c][8] > look.tone[c][4] && look.tone[c][12] > look.tone[c][8], "the tone rises")
	}
}

// A preview made with the look is found where it was cut, to the pixel,
// though the crop is at no multiple of the 3x downscale: how
// `terrain preview` gives a recovered level its original's crop. The map
// is noise in blocks of 5, so only one place matches.
@(test)
preview_locate_finds_the_crop :: proc(t: ^testing.T) {
	m := terrain.picture_make(480, 1200, 3, 8, context.temp_allocator)
	for y in 0 ..< m.height {
		for x in 0 ..< m.width {
			h := u32(x / 5) * 0x9e3779b1 ~ u32(y / 5) * 0x85ebca77
			h = (h ~ h >> 15) * 0x2c1b3c6d
			h ~= h >> 13
			px := m.pixels[(y * m.width + x) * 3:][:3]
			px[0], px[1], px[2] = u8(h), u8(h >> 8), u8(h >> 16)
		}
	}
	at := [2]int{37, 211}
	shown := terrain.preview_make(m, at, context.temp_allocator)
	found, score := terrain.preview_locate(m, shown)
	testing.expect_value(t, found, at)
	testing.expectf(t, score > 0.9, "match %v", score)
}

// The crop is the project's: saved, opened again where it was, and kept
// on the map. A project from before it had one gets the default.
@(test)
preview_crop_saves_with_the_project :: proc(t: ^testing.T) {
	os.make_directory_all(OUT)
	p := terrain.project_make(480, 1200, context.temp_allocator)
	testing.expect_value(t, p.preview, terrain.preview_crop_default(480, 1200))
	p.preview = {17, 140}
	path :: OUT + "/preview.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	q, ok := terrain.project_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, q.preview, [2]int{17, 140})

	// Off the map, it is brought back on.
	p.preview = {400, 5000}
	testing.expect(t, terrain.project_save(&p, path))
	q, _ = terrain.project_load(path, context.temp_allocator)
	testing.expect_value(t, q.preview, [2]int{480 - terrain.PREVIEW_CROP_WIDTH, 1200 - terrain.PREVIEW_CROP_HEIGHT})

	// Version 2 had no crop: whatever the file holds, it is the default.
	blob, _ := os.read_entire_file(path, context.temp_allocator)
	old, replaced := strings.replace(string(blob), `"version": 3`, `"version": 2`, 1, context.temp_allocator)
	testing.expect(t, replaced, "the project's version is not where it was")
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	q, ok = terrain.project_load(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, q.preview, terrain.preview_crop_default(480, 1200))
}

// A mask cell is water where most of its ground is below the surface, and
// nowhere when the water is hidden; a part cell at the edge counts what
// it covers.
@(test)
media_mask_takes_the_majority :: proc(t: ^testing.T) {
	C :: terrain.MEDIA_CELL
	p := terrain.project_make(3 * C, C + 2, context.temp_allocator)
	for &h in p.heights {
		h = 20
	}
	p.level.water = {height = 10, visible = true}
	under :: proc(p: ^terrain.Project, cell, n: int) {
		for i in 0 ..< n {
			p.heights[(i / C) * p.width + cell * C + i % C] = 2
		}
	}
	under(&p, 0, C * C / 2 + 1) // most of the first cell: water
	under(&p, 1, C * C / 2) // not most of the second: ground
	for x in 0 ..< 3 * C {
		p.heights[C * p.width + x] = 2 // the part cells' first row of two
	}
	p.heights[(C + 1) * p.width + 2 * C] = 2 // and the third's second

	water :: [3]u8{0, 0, 255}
	ground :: [3]u8{255, 255, 255}
	at :: proc(m: terrain.Picture, x, y: int) -> [3]u8 {
		px := m.pixels[(y * m.width + x) * 3:]
		return {px[0], px[1], px[2]}
	}
	m := terrain.media_mask_make(&p, context.temp_allocator)
	if !testing.expect_value(t, [2]int{m.width, m.height}, [2]int{3, 2}) {
		return
	}
	testing.expect_value(t, at(m, 0, 0), water)
	testing.expect_value(t, at(m, 1, 0), ground)
	testing.expect_value(t, at(m, 2, 0), ground)
	// Half of a part cell is not most of it; all of it is.
	testing.expect_value(t, at(m, 0, 1), ground)
	testing.expect_value(t, at(m, 2, 1), water)

	p.level.water.visible = false
	m = terrain.media_mask_make(&p, context.temp_allocator)
	testing.expect_value(t, at(m, 0, 0), ground)
}
