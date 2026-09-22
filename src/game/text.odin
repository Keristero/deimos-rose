package game

// Text is sprites. G_Text_Draw maps each character to a frame of one sprite
// group and blits it like anything else, so there is no font file: the glyphs
// live in the "tesm" plate, named by the first entry of the "tesp" id list
// (G_Text_Init).

import rl "vendor:raylib"

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
