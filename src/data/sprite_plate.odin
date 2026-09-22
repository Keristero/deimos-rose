package data

// Cutting a sprite plate into frames, as U_SpritePlate_GetBitmapRectListFromPlate
// (FUN_0040e3a0 and helpers) does it.
//
// A plate is a grid of boxes drawn in a marker colour: pixel 1 of the plate is
// that marker, and pixels 0, 1 and 2 must be three different values. Column 0
// has marker pixels on separator rows, so the unbroken runs in column 0 give
// each band of boxes its height; within a band, columns without a marker give
// each box its width. A box's own first pixel is its background, and the frame
// is the box trimmed of background on all four sides. Boxes that are entirely
// background are skipped.
//
// Frame geometry feeds collision (G_GameObject::CalculateDimensions), so this
// is simulation data, not just presentation.
//
// The original draws the GIF into an 8-bit QuickTime GWorld before scanning,
// which maps every colour into the default colour table -- so two GIF palette
// entries that are nearly the same colour become one. Comparing raw indices
// instead leaves stray near-background pixels in place and grows the frame:
// the GLOW plate has a line of RGB(0,0,255) inside a RGB(8,0,255) background,
// which made frame 3 49x92 instead of 49x49.
//
// Pixels are therefore compared by colour, quantised to the 6x6x6 cube that
// forms the bulk of the Mac 8-bit system palette. Verified against frame
// dimensions read from the running original: all 1,037 frames of the 55
// sprite groups a demo loads match exactly.

Plate_Frame :: struct {
	// Position of the trimmed frame within the plate.
	x, y:          int,
	width, height: int,
}

Plate_Error :: enum {
	None,
	Too_Small,
	Bad_Markers,
	No_Frames,
}

plate_frames :: proc(
	pixels: []u8,
	palette: [][3]u8,
	width, height: int,
	allocator := context.allocator,
) -> (
	frames: [dynamic]Plate_Frame,
	err: Plate_Error,
) {
	if width < 3 || height < 2 {
		return nil, .Too_Small
	}
	// Palette entries collapsed to the colour cube, so that near-identical
	// colours compare equal as they do in the original's 8-bit buffer.
	quantised := make([]u8, 256, context.temp_allocator)
	cube :: proc(c: u8) -> u8 { return u8((int(c) + 25) / 51) }
	for i in 0 ..< 256 {
		q: [3]u8
		if i < len(palette) {
			q = {cube(palette[i][0]), cube(palette[i][1]), cube(palette[i][2])}
		}
		quantised[i] = q.r * 36 + q.g * 6 + q.b
	}
	px := make([]u8, len(pixels), context.temp_allocator)
	for v, i in pixels {
		px[i] = quantised[v]
	}
	if px[0] == px[1] || px[1] == px[2] {
		return nil, .Bad_Markers
	}
	marker := px[1]
	at :: #force_inline proc(p: []u8, w, x, y: int) -> u8 { return p[y * w + x] }

	frames = make([dynamic]Plate_Frame, allocator)
	// Row 0 is the top border, so bands start at row 1.
	for row := 1; row < height; row += 1 {
		// Band height: non-marker pixels down column 0 (FUN_0040e6e0).
		band := 0
		for row + band < height && at(px, width, 0, row + band) != marker {
			band += 1
		}
		if band < 1 {
			continue
		}
		for col := 0; col < width; col += 1 {
			// Box width: columns with no marker in the band (FUN_0040e750).
			box := 0
			scan: for col + box < width {
				for y in 0 ..< band {
					if at(px, width, col + box, row + y) == marker {
						break scan
					}
				}
				box += 1
			}
			if box < 1 {
				continue
			}
			if f, ok := trim(px, width, col, row, box, band); ok {
				append(&frames, f)
			}
			col += box
		}
		row += band
	}
	if len(frames) == 0 {
		delete(frames)
		return nil, .No_Frames
	}
	return frames, .None
}

// FUN_0040e7d0: trim a box of its background, top, bottom, left, right.
@(private = "file")
trim :: proc(p: []u8, w, x0, y0, bw, bh: int) -> (f: Plate_Frame, ok: bool) {
	bg := p[y0 * w + x0]
	row_empty :: proc(p: []u8, w, x0, y, bw: int, bg: u8) -> bool {
		for x in 0 ..< bw {
			if p[y * w + x0 + x] != bg {
				return false
			}
		}
		return true
	}
	col_empty :: proc(p: []u8, w, x, y0, h: int, bg: u8) -> bool {
		for y in 0 ..< h {
			if p[(y0 + y) * w + x] != bg {
				return false
			}
		}
		return true
	}
	top := 0
	for top < bh && row_empty(p, w, x0, y0 + top, bw, bg) {
		top += 1
	}
	if top >= bh {
		return {}, false
	}
	bottom := 0
	for bottom < bh && row_empty(p, w, x0, y0 + bh - 1 - bottom, bw, bg) {
		bottom += 1
	}
	h := bh - top - bottom
	left := 0
	for left < bw && col_empty(p, w, x0 + left, y0 + top, h, bg) {
		left += 1
	}
	right := 0
	for right < bw && col_empty(p, w, x0 + bw - 1 - right, y0 + top, h, bg) {
		right += 1
	}
	return Plate_Frame{x = x0 + left, y = y0 + top, width = bw - left - right, height = h}, true
}
