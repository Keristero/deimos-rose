package meme_view

// The combo: each player's kill streak, shown while it lives as flaming
// "N COMBO" text over a flaming meter that drains over STREAK_WINDOW steps
// and puts the combo out when it empties (the next kill then starts at 1).
// A post pass, so the lighting leaves it bright. Every flame is a pure
// function of the clock, so nothing is kept between frames.

import "core:fmt"
import "core:math"

import rl "vendor:raylib"

import "dr:render"
import "dr:sim"

COMBO_MIN :: 2 // the combo is shown from this streak on

@(rodata)
combo_after := [?]string{"lighting", "hitstop kill cam"}

// How much of its window a player's combo has left, 0 to 1, `t` of the way
// to the next step; 0 when there is no combo to show.
combo_left :: proc(count, last, now: int, t: f32) -> f32 {
	if count < COMBO_MIN {
		return 0
	}
	gone := f32(now - last) + t
	return clamp(1 - gone / f32(STREAK_WINDOW), 0, 1)
}

combo_enabled :: proc(r: ^render.Renderer) -> bool {
	for p in 0 ..< sim.MAX_PLAYERS {
		if combo_left(shared.streak[p], shared.last_kill[p], shared.steps, 0) > 0 {
			return true
		}
	}
	return style_any()
}

combo_apply :: proc(r: ^render.Renderer, f: ^render.Post_Frame, src: rl.Texture2D) {
	shared.flame_amount = intensity(r.setting, shared.flames)
	field := [4]f32{render.VIEW_X * f.scale, 0, render.PLAY_W * f.scale, render.PLAY_H * f.scale}
	rl.DrawTexturePro(src, {field[0], f32(src.height) - field[1] - field[3], field[2], -field[3]}, {field[0], field[1], field[2], field[3]}, {}, 0, rl.WHITE)
	for p in 0 ..< sim.MAX_PLAYERS {
		left := combo_left(shared.streak[p], shared.last_kill[p], shared.steps, f.t)
		if left <= 0 {
			continue
		}
		combo_draw(r, field, f.scale, p, shared.streak[p], left)
	}
	for p in 0 ..< sim.MAX_PLAYERS {
		style_draw(r, field, f.scale, p, field[3] * (0.32 + f32(p / 2) * 0.2))
	}
}

// One player's combo: player 1's at the field's top left, the others' from
// the right, each a little lower than the last.
@(private = "file")
combo_draw :: proc(r: ^render.Renderer, field: [4]f32, scale: f32, player, count: int, left: f32) {
	text := fmt.tprintf("%d COMBO", count)
	k := scale * 3
	width := text_width(r, text) * k
	bar_w := min(field[2] * 0.4, max(width, field[2] * 0.25))
	x := field[0] + field[2] * 0.03
	if player % 2 == 1 {
		x = field[0] + field[2] * 0.97 - max(width, bar_w)
	}
	y := field[1] + field[3] * 0.16 + f32(player / 2) * field[3] * 0.1
	heat := flame_heat(count) // the hotter, the more flame, on to 2000
	rise := flame_rise(heat)
	t := f32(rl.GetTime())
	// A sudden jolt the moment it grows, the text popping.
	pop := 1 + 0.25 * max(0, 1 - f32(shared.steps - shared.last_kill[player]) / 6)
	text_h := text_height(r) * k

	rl.BeginBlendMode(.ALPHA)
	flames(x, y + text_h * 0.9, width, text_h * (2 + 1.5 * rise), 18 + int(heat * 30), t, scale, player)
	rl.EndBlendMode()

	draw_flame_text(r, text, x, y, k * pop, t)

	// The meter: a trough, and the fire left in it.
	by := y + text_h * 1.25
	bh := max(text_h * 0.28, 4 * scale)
	rl.DrawRectangleRec({x - 2 * scale, by - 2 * scale, bar_w + 4 * scale, bh + 4 * scale}, rl.Color{20, 6, 2, 200})
	fill := bar_w * left
	rl.DrawRectangleGradientV(i32(x), i32(by), i32(fill), i32(bh), rl.Color{255, 230, 90, 255}, rl.Color{230, 50, 10, 255})
	rl.BeginBlendMode(.ALPHA)
	// The flame licks up from the fill's front, and the whole bar glows.
	flames(x + fill - bar_w * 0.06, by + bh, bar_w * 0.12, text_h * (1.6 + rise), 10 + int(heat * 14), t * 1.3, scale, player + 7)
	flames(x, by + bh * 0.5, fill, bh * 1.5, 6 + int(left * 12), t * 0.9, scale, player + 13)
	rl.EndBlendMode()
}

// Tongues of fire rising from the line `y` over `w` pixels from `x`, as tall
// as `rise` at most; `n` of them, each at its own phase of its rise.
flames :: proc(x, y, w, rise: f32, n: int, t, scale: f32, seed: int) {
	for i in 0 ..< int(f32(n) * shared.flame_amount) {
		h := f32(i * 7919 + seed * 104729) * 0.6180339
		h -= math.floor(h)
		g := f32(i * 6151 + seed * 15485863) * 0.7548776
		g -= math.floor(g)
		life := math.mod(t * (0.9 + 0.8 * g) + h * 3, 1)
		fx := x + w * h + math.sin(t * 9 + h * 40) * 3 * scale * life
		fy := y - rise * shared.flame_amount * life * (0.55 + 0.45 * g)
		radius := (10 + 14 * g) * scale * (1 - life * 0.8)
		alpha := u8(255 * min(1, (1 - life) * 1.6))
		inner := rl.Color{255, u8(220 - 150 * life), u8(70 * (1 - life)), alpha}
		rl.DrawCircleGradient({fx, fy}, radius, inner, rl.Color{190, 20, 0, 0})
	}
}

// The font's glyphs set from (`x`, `y`) at `k`, the colour of a flame from
// its base up: a dark red glow behind, orange, and a yellow core.
@(private = "file")
draw_flame_text :: proc(r: ^render.Renderer, text: string, x, y, k, t: f32) {
	layers := [4]struct {
		dx, dy: f32,
		tint:   rl.Color,
	} {
		{0.2, 0.2, {0, 0, 0, 255}},
		{0, -0.12, {200, 30, 10, 255}},
		{0, 0, {255, 130, 20, 255}},
		{0, 0.1, {255, 235, 120, 255}},
	}
	for layer, li in layers {
		pen := x
		for c in transmute([]u8)text {
			tex, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(c))
			if !ok {
				continue
			}
			flick := li > 0 ? math.sin(t * 17 + pen * 0.05) * 0.04 * k : 0
			rl.SetTextureFilter(tex, .POINT)
			// The yellow core is a little smaller, the fire around it larger.
			shrink := li == 3 ? f32(0.82) : 1
			w, h := src.width * k * shrink, src.height * k * shrink
			rl.DrawTexturePro(tex, src, {pen + layer.dx * k + (src.width * k - w) / 2, y + layer.dy * k + flick * 4 + (src.height * k - h) * 0.55, w, h}, {}, 0, layer.tint)
			pen += src.width * k
		}
	}
}

text_width :: proc(r: ^render.Renderer, text: string) -> f32 {
	width: f32
	for c in transmute([]u8)text {
		if _, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(c)); ok {
			width += src.width
		}
	}
	return width
}

text_height :: proc(r: ^render.Renderer) -> f32 {
	if _, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of('0')); ok {
		return src.height
	}
	return 8
}
