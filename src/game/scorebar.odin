package game

// The score bar: the panel to the right of the play field, showing each
// player's score, extra lives, shields and weapon-power bars
// (G_ScoreBar_Draw). Rect positions come from assets/data/reli/inre.json
// (G_Res_GetPermRect 0-15 in the original -- see data.Score_Bar_Layout).
//
// G_ScoreBar_Draw itself is a maze of raw offsets into a packed C struct;
// rather than transliterate it, this reads the same backdrop image (im16
// "scor", which already has the shields/power bars' "empty" colour and the
// score/lives slots baked in as cutouts) and draws the same values
// (G_Player::score/lives/shields, Weapon_Handler.air_powerup.percent) the
// modern way, checked against a real screenshot of the running original
// (work/wine/cmp/orig-00900.png).
//
// Not yet drawn: the life icon and the three weapon icons -- which sprite
// each names is data-driven per player/weapon definition and not yet traced.
// The panel shows their backdrop cutouts empty until that is done.

import "core:fmt"

import rl "vendor:raylib"

import "dr:sim"

scorebar_draw :: proc(r: ^Renderer, s: ^sim.State, scale: f32) {
	if r.scorebar_panel.id == 0 {
		return
	}
	tex := r.scorebar_panel
	dst := rl.Rectangle{SCOREBAR_X * scale, 0, f32(tex.width) * scale, f32(tex.height) * scale}
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, rl.WHITE)

	// G_ScoreBar_Init enables both halves of the panel unconditionally: a
	// single-player game still shows "player 2, 0 lives, 0 score" in the
	// lower half, not a blank one -- confirmed against orig-00900.png.
	for &p in s.players {
		l := &r.textures.assets.scorebar.players[p.number]
		text_panel(r, fmt.tprintf("%07d", p.score), l.score, scale)
		text_panel(r, fmt.tprintf("%d", max(p.lives - 1, 0)), l.life_count, scale)
		bar_panel(r, l.shields, clamp(p.shields, 0, 100), {115, 150, 156, 255}, scale)
		bar_panel(r, l.power, clamp(p.weapons.air_powerup.percent, 0, 100), {156, 130, 90, 255}, scale)
	}
}

// A rect from data.Score_Bar_Layout is local to the panel image; the panel
// itself sits at SCOREBAR_X on screen.
@(private = "file")
panel_rect :: proc(rc: sim.Rect, scale: f32) -> rl.Rectangle {
	return {
		(SCOREBAR_X + f32(rc.left)) * scale, f32(rc.top) * scale,
		f32(rc.right - rc.left) * scale, f32(rc.bottom - rc.top) * scale,
	}
}

@(private = "file")
text_panel :: proc(r: ^Renderer, str: string, rc: sim.Rect, scale: f32) {
	x := (SCOREBAR_X + f32(rc.left)) * scale
	y := f32(rc.top) * scale
	for i in 0 ..< len(str) {
		tex, src, ok := frame_rect(&r.textures, FONT, glyph_of(str[i]))
		if !ok {
			continue
		}
		dst := rl.Rectangle{x, y, src.width * scale, src.height * scale}
		rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
		x += src.width * scale
	}
}

// The fill sprite the original draws over the backdrop's empty bar, clipped
// to `percent` of the rect's width -- here, a plain rounded-rectangle fill.
@(private = "file")
bar_panel :: proc(r: ^Renderer, rc: sim.Rect, percent: f32, color: rl.Color, scale: f32) {
	if percent <= 0 {
		return
	}
	full := panel_rect(rc, scale)
	fill := full
	fill.width *= percent / 100
	rl.DrawRectangleRounded(fill, 1, 8, color)
}
