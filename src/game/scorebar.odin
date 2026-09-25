package game

// The score bar: the panel to the right of the play field (G_ScoreBar_*).
// Per player it draws, in G_ScoreBar_Draw's order, the score, the ship
// icon in the big circle, the lives count, the three air-weapon globes
// (current, then the next two in the cycle), and the shield and power
// meters. Everything is placed by the original's own data rather than
// measured: the text by its presets (tefo sbs1/sbl1/sll1..., via
// G_Text_GetPermTextSetting 0x29-0x30), the sprites by G_Res_GetPermFloat
// 0x70-0x8f ("ScoreBar_P1LivesSymbol_XLoc" and so on), and which sprites by
// the player definition (spriteScoreBar*) and each air weapon's
// scoreBarPreviewFace. Coordinates in both are the original's 576-wide
// front buffer, which starts at VIEW_X on screen.
//
// The meters do not jump: G_ScoreBar_Process moves each shown value towards
// the real one every step, up by ScoreBar_*IncreaseRate (only while the
// player is Playing) and down by *DecreaseRate. A player who has left the
// game (or never joined, as player 2 in a one-player game) keeps their
// last values, drawn half-faded: the text's blend moves halfway to 32 and
// the icon is drawn at blend 16 (FUN_00439df0, FUN_00439f10, FUN_0043a140).

import "core:fmt"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

// G_ScoreBar_Process's state, one per player (the 0x149-byte blocks at
// DAT_004f0a20).
Scorebar_View :: struct {
	time:    i32, // the step last processed
	level:   i32,
	primed:  bool,
	players: [2]Scorebar_Player,
}

Scorebar_Player :: struct {
	shields, power: f32, // as shown, easing towards the player's
	active:         bool, // +0x12f: drawn at full strength
	was_active:     bool, // +0x12e
}

@(private = "file") PF_ICON_X :: 0x70 // P1 x, y, then P2 x, y
@(private = "file") PF_SHIELD_X :: 0x74
@(private = "file") PF_SHIELD_UP :: 0x78
@(private = "file") PF_SHIELD_DOWN :: 0x79
@(private = "file") PF_POWER_X :: 0x7a
@(private = "file") PF_POWER_UP :: 0x7e
@(private = "file") PF_POWER_DOWN :: 0x7f
@(private = "file") PF_WEAPONS_X :: 0x80 // P1's three x, y pairs, then P2's
@(private = "file") PF_WEAPONS_BLEND_NEXT :: 0x8c
@(private = "file") PF_WEAPONS_BLEND_CURRENT :: 0x8d
@(private = "file") PF_WEAPONS_SCALE_NEXT :: 0x8e
@(private = "file") PF_LIVES_MAX :: 0x8f

// Blend 0..32 as alpha, 32 invisible.
@(private = "file")
blend_alpha :: proc(blend: i32) -> u8 {
	return u8(clamp(32 - blend, 0, 32) * 255 / 32)
}

// G_ScoreBar_ResetAtLevelStart and G_ScoreBar_Process, run once for each
// step the simulation has moved on since the last frame (from build_frame,
// so a shot that presents only some steps still eases every one).
scorebar_process :: proc(v: ^Scorebar_View, s: ^sim.State) {
	pf := &s.defs.perm_floats
	if !v.primed || sim.single(s, sim.Level_Info).number != v.level || sim.single(s, sim.Clock).time < v.time {
		v^ = {primed = true, level = sim.single(s, sim.Level_Info).number, time = sim.single(s, sim.Clock).time}
		for &p, i in s.players[:2] {
			v.players[i].active = p.active
			v.players[i].was_active = p.active
		}
		return
	}
	for v.time < sim.single(s, sim.Clock).time {
		v.time += 1
		for &p, i in s.players[:2] {
			sp := &v.players[i]
			if !p.active || p.state == .Gone {
				if sp.was_active {
					sp.active = false
					sp.was_active = false
				}
				continue
			}
			playing := p.state == .Playing
			sp.shields = ease(sp.shields, p.shields, playing, pf[PF_SHIELD_UP], pf[PF_SHIELD_DOWN])
			sp.power = ease(sp.power, p.weapons.air_powerup.percent, playing, pf[PF_POWER_UP], pf[PF_POWER_DOWN])
			if sp.power < 1 {
				sp.power = 0
			} else if sp.power > 100 {
				sp.power = 100
			}
		}
	}
}

@(private = "file")
ease :: proc(shown, real: f32, playing: bool, up, down: f32) -> f32 {
	if shown < real {
		return playing ? min(shown + up, real) : shown
	}
	if shown > real {
		return max(shown - down, real)
	}
	return shown
}

scorebar_draw :: proc(r: ^Renderer, s: ^sim.State, scale: f32) {
	tex, ok := menu_image(&r.textures, "scor")
	if !ok {
		return
	}
	dst := rl.Rectangle{SCOREBAR_X * scale, 0, f32(tex.width) * scale, f32(tex.height) * scale}
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, rl.WHITE)

	v := &r.scorebar
	pf := &s.defs.perm_floats
	text := &r.textures.assets.text
	for pn in 0 ..< 2 {
		p := &s.players[pn]
		sp := &v.players[pn]
		faded := i32(-1)
		if !sp.active {
			faded = 16 // halfway from the presets' 0 to 32
		}

		// Score.
		score := text[int(data.Text_Preset.ScoreBar_Score_Player1) + pn]
		text_preset_draw(r, score, fmt.tprintf("%07d", p.score), VIEW_X, scale, faded)

		// Ship icon, in the player's accent when they have one.
		def := &s.defs.players[p.def].def
		icon_at := sim.Vec{pf[PF_ICON_X + 2 * pn], pf[PF_ICON_X + 2 * pn + 1]}
		ac := r.accents[pn]
		scorebar_sprite(r, def.sprite_score_bar, def.sprite_score_bar_frame, icon_at, scale, sp.active ? 0 : 16, 1, ac.on ? ac.hue : -1)

		// Lives: the spares, capped at ScoreBar_Lives_MaxNumDisplayed, red
		// on the last one.
		lives := max(p.lives - 1, 0)
		if cap := i32(pf[PF_LIVES_MAX]); cap > 0 && cap < lives {
			lives = cap
		}
		preset := data.Text_Preset.ScoreBar_LivesCounter_Player1
		if sp.active && lives == 0 {
			preset = .ScoreBar_LivesCounterLastLife_Player1
		}
		text_preset_draw(r, text[int(preset) + pn], fmt.tprintf("%d", lives), VIEW_X, scale, faded)

		// Air weapons: current, next, the one after (AirWeapon_GetScoreBarInfo);
		// only an active player's are drawn.
		if sp.active {
			faces := air_weapon_faces(s, &p.weapons)
			for f, slot in faces {
				if f.sprite == sim.NONE {
					continue
				}
				at := sim.Vec{pf[PF_WEAPONS_X + 6 * pn + 2 * slot], pf[PF_WEAPONS_X + 6 * pn + 2 * slot + 1]}
				blend := i32(pf[PF_WEAPONS_BLEND_CURRENT])
				size: f32 = 1
				if slot > 0 {
					blend = i32(pf[PF_WEAPONS_BLEND_NEXT])
					size = pf[PF_WEAPONS_SCALE_NEXT]
				}
				scorebar_sprite(r, f.sprite, f.frame, at, scale, blend, size)
			}
		}

		// Meters: the full glass sprite, with what is missing covered by the
		// preset's colour strip (black at blend 8).
		layout := &r.textures.assets.scorebar.players[pn]
		meter(r, def.sprite_score_bar_shield, def.sprite_score_bar_shield_frame, {pf[PF_SHIELD_X + 2 * pn], pf[PF_SHIELD_X + 2 * pn + 1]},
			layout.shields, sp.shields, text[data.Text_Preset.ScoreBar_ShieldMeter], scale)
		meter(r, def.sprite_score_bar_power, def.sprite_score_bar_power_frame, {pf[PF_POWER_X + 2 * pn], pf[PF_POWER_X + 2 * pn + 1]},
			layout.power, sp.power, text[data.Text_Preset.ScoreBar_PowerMeter], scale)
	}
}

// A sprite centred on a front-buffer point (U_Sprite_Draw), faded by a
// 0..32 blend and scaled. hue >= 0 lays the accent over its trim.
@(private = "file")
scorebar_sprite :: proc(r: ^Renderer, id: sim.Res_ID, frame: i32, at: sim.Vec, scale: f32, blend: i32, size: f32, hue: f32 = -1) {
	tex, src, ok := frame_rect(&r.textures, id, frame)
	if !ok {
		return
	}
	w := i32(src.width * size)
	h := i32(src.height * size)
	x := VIEW_X + at.x - f32(sim.halve(w))
	y := at.y - f32(sim.halve(h))
	dst := rl.Rectangle{x * scale, y * scale, f32(w) * scale, f32(h) * scale}
	tint := rl.Color{255, 255, 255, blend_alpha(blend)}
	draw_item(r, {texture = tex, src = src, tint = tint}, dst)
	if hue < 0 {
		return
	}
	if trim, tok := ship_trim(&r.textures, id); tok {
		// The trim covers the silver frame; either frame shares its shape.
		_, f0, _ := frame_rect(&r.textures, id, 0)
		draw_item(r, {texture = trim, src = f0, tint = tint, effect = .Recolour, hue = hue, sat = TRIM_SATURATION, shine = TRIM_SHINE}, dst)
	}
}

// FUN_0043a3a0 / FUN_0043a740.
@(private = "file")
meter :: proc(r: ^Renderer, id: sim.Res_ID, frame: i32, at: sim.Vec, rc: sim.Rect, percent: f32, strip: data.Text_Setting, scale: f32) {
	scorebar_sprite(r, id, frame, at, scale, 0, 1)
	pct := percent
	if pct > 100 {
		pct = 100
	} else if pct < 0 {
		pct = 0
	}
	if pct >= 100 {
		return
	}
	width := rc.right - rc.left
	left := rc.left + sim.trunc_i32(f32(width) * (pct / 100))
	box := rl.Rectangle {
		(SCOREBAR_X + f32(left)) * scale, f32(rc.top) * scale,
		f32(rc.right - left) * scale, f32(rc.bottom - rc.top) * scale,
	}
	c := strip.strip_colour
	rl.DrawRectangleRec(box, {c[0], c[1], c[2], blend_alpha(strip.strip_blend)})
}

Weapon_Face :: struct {
	sprite: sim.Res_ID,
	frame:  i32,
}

// G_WeaponHandler::AirWeapon_GetScoreBarInfo: the current (or queued) air
// weapon's face, then the next two available on this level, each dropped
// ("none") when it repeats one already shown.
air_weapon_faces :: proc(s: ^sim.State, h: ^sim.Weapon_Handler) -> (out: [3]Weapon_Face) {
	out = {{sprite = sim.NONE}, {sprite = sim.NONE}, {sprite = sim.NONE}}
	cur := sim.air_weapon_shown(h)
	if cur == sim.NO_WEAPON {
		return
	}
	face :: proc(s: ^sim.State, w: i32) -> Weapon_Face {
		d := &s.defs.weapons[w]
		return {d.score_bar_preview_face, d.score_bar_preview_frame}
	}
	out[0] = face(s, cur)
	// In a New Weapons session, the loadout's next slots (sim.air_weapon_next).
	next := sim.air_weapon_next(s, h, cur)
	out[1] = next == sim.NO_WEAPON ? out[0] : face(s, next)
	if out[1] == out[0] {
		out[1] = {sprite = sim.NONE}
		return
	}
	after := sim.air_weapon_next(s, h, next)
	out[2] = after == sim.NO_WEAPON ? out[0] : face(s, after)
	if out[2] == out[0] || out[2] == out[1] {
		out[2] = {sprite = sim.NONE}
	}
	return
}
