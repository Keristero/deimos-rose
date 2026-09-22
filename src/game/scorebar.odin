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

// Every rect in inre.json is a generously oversized bounding box, not a
// tight fit around its text -- the life count's is 46x44 for one digit that
// belongs inside a round ~30px badge cutout in the panel backdrop. Checked
// pixel-for-pixel against orig-00900.png: drawing straight at (rc.left,
// rc.top), as the score's tight rect happened to get away with, put life
// count's digit in the empty margin above the badge instead of inside it.
// Centering horizontally and sitting the text on the rect's bottom edge (its
// height less the glyph height) lands both the score digits and the life
// count digit exactly where the original draws them.
//
// The score readout also needs a gap between digits: measured per-digit ink
// columns in orig-00900.png's "0001250" (a column-brightness scan, since the
// digits and the badge glow are both light on dark) put each digit's left
// edge 3px past the previous digit's frame width -- e.g. the '0'->'0' and
// '5'->'0' gaps both land exactly on width+3, matching G_Text_Draw's own
// look elsewhere (game/text.odin's draw_text already takes a spacing param;
// text_panel just never added the gap).
@(private = "file")
SPACING :: 3

@(private = "file")
text_panel :: proc(r: ^Renderer, str: string, rc: sim.Rect, scale: f32) {
	w, h: f32
	for i in 0 ..< len(str) {
		_, src, ok := frame_rect(&r.textures, FONT, glyph_of(str[i]))
		if !ok {
			continue
		}
		w += src.width
		if i > 0 {
			w += SPACING
		}
		h = max(h, src.height)
	}
	x := (SCOREBAR_X + f32(rc.left) + (f32(rc.right - rc.left) - w) / 2) * scale
	y := (f32(rc.bottom) - h) * scale
	for i in 0 ..< len(str) {
		tex, src, ok := frame_rect(&r.textures, FONT, glyph_of(str[i]))
		if !ok {
			continue
		}
		dst := rl.Rectangle{x, y, src.width * scale, src.height * scale}
		rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
		x += (src.width + SPACING) * scale
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
