package terrain_tests

// Level previews (Stage 9): where the crop goes, the 3x average, and the
// fitted look's shape.

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
