package render

// Text is sprites. G_Text_Draw maps each character to a frame of one sprite
// group and blits it like anything else, so there is no font file: the glyphs
// live in the "tesm" plate, named by the first entry of the "tesp" id list
// (G_Text_Init).

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

FONT :: sim.Res_ID{'t', 'e', 's', 'm'}

// FUN_0043eb70, transcribed. Capitals come first in the plate, then lower
// case, then 1-9, 0, then punctuation; anything unmapped draws frame 90,
// which is the space.
@(rodata)
GLYPH := [128]i32 {
	'A' = 0,  'B' = 1,  'C' = 2,  'D' = 3,  'E' = 4,  'F' = 5,  'G' = 6,
	'H' = 7,  'I' = 8,  'J' = 9,  'K' = 10, 'L' = 11, 'M' = 12, 'N' = 13,
	'O' = 14, 'P' = 15, 'Q' = 16, 'R' = 17, 'S' = 18, 'T' = 19, 'U' = 20,
	'V' = 21, 'W' = 22, 'X' = 23, 'Y' = 24, 'Z' = 25,
	'a' = 26, 'b' = 27, 'c' = 28, 'd' = 29, 'e' = 30, 'f' = 31, 'g' = 32,
	'h' = 33, 'i' = 34, 'j' = 35, 'k' = 36, 'l' = 37, 'm' = 38, 'n' = 39,
	'o' = 40, 'p' = 41, 'q' = 42, 'r' = 43, 's' = 44, 't' = 45, 'u' = 46,
	'v' = 47, 'w' = 48, 'x' = 49, 'y' = 50, 'z' = 51,
	'1' = 52, '2' = 53, '3' = 54, '4' = 55, '5' = 56, '6' = 57, '7' = 58,
	'8' = 59, '9' = 60, '0' = 61,
	'!' = 62, '"' = 63, '#' = 64, '$' = 65, '%' = 66, '&' = 67, '\'' = 68,
	'(' = 69, ')' = 70, '*' = 71, '+' = 72, ',' = 73, '-' = 74, '.' = 75,
	'/' = 76, ':' = 77, ';' = 78, '<' = 79, '=' = 80, '>' = 81, '?' = 82,
	'@' = 83, '\\' = 84, '^' = 85, '_' = 86, '`' = 87, '|' = 88, '~' = 89,
	// The three bracket pairs share the round glyphs.
	'[' = 69, ']' = 70, '{' = 69, '}' = 70,
	' ' = 90,
}

SPACE_GLYPH :: 90

glyph_of :: proc "contextless" (c: byte) -> i32 {
	if c >= 128 {
		return SPACE_GLYPH
	}
	g := GLYPH[c]
	// Every unmapped code falls through to the space in the original's
	// switch, and A is the only character whose frame is legitimately 0.
	if g == 0 && c != 'A' {
		return SPACE_GLYPH
	}
	return g
}

Align :: enum {
	Left,
	Centre,
	Right,
}

text_width :: proc(r: ^Renderer, s: string, spacing: i32 = 0) -> i32 {
	w: i32
	for i in 0 ..< len(s) {
		_, src, ok := frame_rect(&r.textures, FONT, glyph_of(s[i]))
		if ok {
			w += i32(src.width) + spacing
		}
	}
	return w
}

// Draws a string into a layer, left-to-right on a shared baseline. Positions
// are the top-left of the first glyph, or the centre/right edge for the other
// alignments.
draw_text :: proc(
	r: ^Renderer,
	s: string,
	x, y: i32,
	layer: int,
	color := rl.Color{255, 255, 255, 255},
	align := Align.Left,
	spacing: i32 = 0,
) {
	x := x
	switch align {
	case .Centre:
		x -= text_width(r, s, spacing) / 2
	case .Right:
		x -= text_width(r, s, spacing)
	case .Left:
	}
	for i in 0 ..< len(s) {
		tex, src, ok := frame_rect(&r.textures, FONT, glyph_of(s[i]))
		if !ok {
			continue
		}
		dst := rl.Rectangle{f32(x), f32(y), src.width, src.height}
		push_item(r, layer, Item{texture = tex, src = src, dst = dst, tint = color})
		x += i32(src.width) + spacing
	}
}

// G_Text_Draw with one of the original's text presets (data.Text_Setting),
// laid out as FUN_0043e4e0 does: each character is preceded by the preset's
// spacing and advances by its own width -- or, monospaced, by the widest
// digit's (G_Text_Draw measures '1'..'0' once and keeps the widest).
// Glyphs sit top-aligned on the preset's y. CENT centres the whole run,
// spacing included, on x. Colorise tints the white glyphs; the preset's
// blend (0 opaque .. 32 invisible) and `fade` scale the alpha.
//
// Preset coordinates are the original's front buffer (the 576-wide play
// field plus score bar), so `origin_x` is where that buffer starts on
// screen: VIEW_X in the game. Drawn immediately, at `scale`.
text_preset_draw :: proc(r: ^Renderer, t: data.Text_Setting, s: string, origin_x: f32, scale: f32, blend := i32(-1), colour: Maybe(rl.Color) = nil) {
	cell: f32
	if t.monospaced {
		for g in i32(52) ..= 61 { // '1'..'9', '0'
			if _, src, ok := frame_rect(&r.textures, FONT, g); ok {
				cell = max(cell, src.width)
			}
		}
	}
	advance :: proc(r: ^Renderer, c: byte, cell: f32) -> f32 {
		if cell > 0 {
			return cell
		}
		_, src, ok := frame_rect(&r.textures, FONT, glyph_of(c))
		return ok ? src.width : 0
	}
	total: f32
	for i in 0 ..< len(s) {
		total += advance(r, s[i], cell) + f32(t.spacing)
	}
	x := f32(t.x)
	switch t.format {
	case sim.Res_ID{'C', 'E', 'N', 'T'}:
		x = f32(t.x) - f32(i32(total / 2))
	case sim.Res_ID{'R', 'I', 'G', 'H'}:
		x = f32(t.x) - total
	case sim.Res_ID{'C', 'E', 'G', 'A'}:
		// Centred on the play field: (perm float 0x36 VisibleGameWidth -
		// width) / 2, the x the preset gives ignored (FUN_0043e4e0).
		x = f32(i32((PLAY_W - total) / 2))
	case sim.Res_ID{'C', 'E', 'B', 'U'}:
		// Centred on the buffer, perm float 0x34 MinScreenWidth (640).
		// Provisional: taken as the whole screen, which puts its origin
		// VIEW_X left of the play field's; no CEBU text is drawn yet to
		// check it against.
		x = f32(i32((SCREEN_W - total) / 2)) - VIEW_X
	}
	if t.strip {
		// ColorStrip: a box behind the text, as tall as the tallest glyph
		// and wider by the H/V offsets each side (G_Text_Draw).
		h: f32
		for i in 0 ..< len(s) {
			if _, src, ok := frame_rect(&r.textures, FONT, glyph_of(s[i])); ok {
				h = max(h, src.height)
			}
		}
		c := t.strip_colour
		box := rl.Rectangle {
			(origin_x + x - f32(t.strip_h)) * scale, (f32(t.y) - f32(t.strip_v)) * scale,
			(total + 1 + 2 * f32(t.strip_h)) * scale, (h + 2 * f32(t.strip_v)) * scale,
		}
		rl.DrawRectangleRec(box, {c[0], c[1], c[2], u8(clamp(32 - t.strip_blend, 0, 32) * 255 / 32)})
	}
	b := blend >= 0 ? blend : t.blend
	tint := colour.? or_else (t.colorise ? rl.Color{t.colour[0], t.colour[1], t.colour[2], 255} : rl.WHITE)
	tint.a = u8(clamp(32 - b, 0, 32) * 255 / 32)
	for i in 0 ..< len(s) {
		x += f32(t.spacing)
		if tex, src, ok := frame_rect(&r.textures, FONT, glyph_of(s[i])); ok && s[i] != ' ' {
			dst := rl.Rectangle{(origin_x + x) * scale, f32(t.y) * scale, src.width * scale, src.height * scale}
			rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, tint)
		}
		x += advance(r, s[i], cell)
	}
}
