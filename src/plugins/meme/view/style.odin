package meme_view

// The style grade, after Devil May Cry's: each player has a style gauge that
// the hits they land fill, by how much by how different the tool is from
// the ones just used (a weapon spammed is worth little, a new one is worth a
// lot), and that always drains, faster the higher it stands. Its height is
// the grade, D up to SSSXTricky2; a hit taken knocks it down. Drawn with the
// combo (combo.odin) as a letter, its name and a gauge for the grade in
// progress.

import "core:math"

import rl "vendor:raylib"

import "dr:render"

STYLE_HISTORY :: 6 // the last tools used that a new hit is compared with

// The grades, lowest first: the letters and the name they go by.
@(rodata)
GRADES := [8]struct {
	letter, name: string,
	from:         f32, // the gauge at which it begins
	colour:       rl.Color,
}{
	{"D", "DREARY", 0, {150, 150, 160, 255}},
	{"C", "CHEEKY", 0.12, {110, 190, 230, 255}},
	{"B", "BRASH", 0.25, {90, 220, 140, 255}},
	{"A", "AUDACIOUS", 0.4, {240, 220, 70, 255}},
	{"S", "SPECTACULAR", 0.55, {255, 160, 40, 255}},
	{"SS", "SCORCHING SWAGGER", 0.7, {255, 90, 40, 255}},
	{"SSS", "SINFULLY SLICK SHOWMAN", 0.85, {255, 50, 90, 255}},
	{"SSSXTRICKY2", "XTREME TRICKSTER DEUX", 0.97, {230, 90, 255, 255}},
}

Style :: struct {
	gauge:   f32, // 0 to 1
	history: [STYLE_HISTORY]i32,
	used:    int, // how many of the history are filled
	next:    int, // where the next goes
	rank:    int, // the grade it was last drawn at
	changed: f64, // the clock when it last changed grade
}

// The grade, 0 (D) to 7, of gauge `g`.
style_rank :: proc "contextless" (g: f32) -> int {
	rank := 0
	for grade, i in GRADES {
		if g >= grade.from {
			rank = i
		}
	}
	return rank
}

// How far through its own grade the gauge is, 0 to 1 (the top grade's is
// the rest of the gauge).
style_progress :: proc "contextless" (g: f32) -> f32 {
	i := style_rank(g)
	lo := GRADES[i].from
	hi := i + 1 < len(GRADES) ? GRADES[i + 1].from : f32(1)
	return clamp((g - lo) / (hi - lo), 0, 1)
}

// What a hit with `source` adds, when the last `used` tools were `history`:
// 0.05 for one not used lately, a quarter less for each time it was, and
// never less than a tenth of that.
style_gain :: proc "contextless" (history: [STYLE_HISTORY]i32, used: int, source: i32) -> f32 {
	repeats := 0
	for i in 0 ..< used {
		if history[i] == source {
			repeats += 1
		}
	}
	return 0.05 * max(0.1, 1 - f32(repeats) * 0.25)
}

// What the gauge loses each step, from 0.0008 at the bottom to 0.0048 at the top.
style_drain :: proc "contextless" (g: f32) -> f32 {
	return 0.0008 + 0.004 * g * g
}

// A player's hit on an enemy with `source` (a kill is worth a flat 0.04 more).
style_hit :: proc "contextless" (st: ^Style, source: i32, killed: bool, now: f64) {
	st.gauge = min(1, st.gauge + style_gain(st.history, st.used, source) + (killed ? 0.04 : 0))
	st.history[st.next] = source
	st.next = (st.next + 1) % STYLE_HISTORY
	st.used = min(st.used + 1, STYLE_HISTORY)
}

// One step's draining.
style_step :: proc "contextless" (st: ^Style) {
	st.gauge = max(0, st.gauge - style_drain(st.gauge))
}

// A hit taken: a third of the gauge gone.
style_struck :: proc "contextless" (st: ^Style) {
	st.gauge *= 0.65
}

// Whether any player has style to show.
style_any :: proc() -> bool {
	for st in shared.style {
		if st.gauge > 0.005 {
			return true
		}
	}
	return false
}

// The style block of `player`: the grade's letters large in its colour, the
// name under it and the gauge for the grade in progress, at the field's
// side `left` or right, `y` down.
style_draw :: proc(r: ^render.Renderer, field: [4]f32, scale: f32, player: int, y: f32) {
	st := &shared.style[player]
	if st.gauge <= 0.005 {
		return
	}
	rank := style_rank(st.gauge)
	now := rl.GetTime()
	if rank != st.rank {
		// Up a grade pops it large, down a grade drops it.
		st.changed = now
		st.rank = rank
	}
	grade := GRADES[rank]
	t := f32(now)
	since := f32(now - st.changed)
	pop := 1 + 0.5 * max(0, 1 - since * 5)
	k := scale * (rank >= 6 ? f32(4) : 5) * pop
	name := grade.letter
	k = min(k, field[2] * 0.6 / max(text_width(r, name), 1)) // the longest fits the field
	width := text_width(r, name) * k
	nk := scale * 1.6
	label_w := text_width(r, grade.name) * nk
	bar_w := max(min(field[2] * 0.4, max(width, label_w)), field[2] * 0.25)
	x := field[0] + field[2] * 0.03
	if player % 2 == 1 {
		x = field[0] + field[2] * 0.97 - bar_w
	}
	h := text_height(r) * k

	// The top grades burn, the lower do not.
	if rank >= 4 {
		rl.BeginBlendMode(.ALPHA)
		flames(x, y + h * 0.9, width, h * (0.8 + 0.3 * f32(rank - 4)), 6 + 4 * (rank - 4), t, scale, player + 21)
		rl.EndBlendMode()
	}
	shake := rank >= 5 ? math.sin(t * 61) * f32(rank - 4) * 0.4 * scale : 0
	draw_tinted_text(r, name, x + shake, y, k, grade.colour)
	draw_tinted_text(r, grade.name, x, y + h * 1.15, nk, grade.colour)
	by := y + h * 1.15 + text_height(r) * nk * 1.5
	bh := 5 * scale
	rl.DrawRectangleRec({x - scale, by - scale, bar_w + 2 * scale, bh + 2 * scale}, rl.Color{10, 10, 14, 210})
	fill := bar_w * style_progress(st.gauge)
	rl.DrawRectangleRec({x, by, fill, bh}, grade.colour)
	rl.DrawRectangleRec({x, by, fill, bh * 0.4}, rl.Color{255, 255, 255, 110})
}

// `text` in a single colour over a black shadow.
@(private = "file")
draw_tinted_text :: proc(r: ^render.Renderer, text: string, x, y, k: f32, colour: rl.Color) {
	for pass in 0 ..< 2 {
		pen := x
		off := pass == 0 ? 0.12 * k : f32(0)
		tint := pass == 0 ? rl.Color{0, 0, 0, 255} : colour
		for c in transmute([]u8)text {
			tex, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(c))
			if !ok {
				continue
			}
			rl.SetTextureFilter(tex, .POINT)
			rl.DrawTexturePro(tex, src, {pen + off, y + off, src.width * k, src.height * k}, {}, 0, tint)
			pen += src.width * k
		}
	}
}
