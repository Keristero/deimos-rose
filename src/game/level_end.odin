package game

// The end-of-level readouts under "Sector Secured": the ground-accuracy
// tally (FUN_00421730 draws DAT_004e487a through preset 0x35 "gaco") and
// each player's coin bonus (G_Player::BuildDrawList draws this+0xe6
// through preset 0x1e "plmc", moved down by the counter's offset, only
// while the player is Playing). Both fade by their own blend, and are not
// drawn once it reaches 32.
//
// The original keeps each line as a string, re-sprintf'd as the state
// machines in sim/level_end.odin advance (FUN_00420d90,
// G_Player::MoneyCounter_Process). Everything those sprintfs read is in
// the state, so the line is rebuilt from it here: the formats are the
// exe's own ('%s%i%%' at 0x4e4dc1 and on, '%s%i' at 0x4ed078 and on).
// The one liberty is timing: the original rewrites the "bonus" line on
// the steps of state 5 rather than on entering it, so it shows here one
// step early.

import "core:fmt"

import "dr:data"
import "dr:sim"

@(private = "file") GS_PERFECT :: 0xa // "All Mission Targets Destroyed!!!"
@(private = "file") GS_ACCURACY :: 0xb // "Ground Accuracy:"
@(private = "file") GS_BONUS :: 0xc // "Bonus:"
@(private = "file") GS_NONE :: 0xd // "None!"
@(private = "file") GS_COIN_BONUS :: 0xe // "Coin Bonus:"
@(private = "file") GS_TIMES :: 0xf // "x"
@(private = "file") GS_EQUALS :: 0x10 // "="

game_string :: proc(r: ^Renderer, i: int) -> string {
	gs := r.textures.assets.game_strings
	return i < len(gs) ? gs[i] : ""
}

level_end_draw :: proc(r: ^Renderer, s: ^sim.State, scale: f32) {
	text := &r.textures.assets.text
	l := sim.single(s, sim.Level_End)
	if l.state != 0 && l.fade < 0x20 {
		acc := game_string(r, GS_ACCURACY)
		line: string
		switch l.state {
		case 1, 2:
			line = acc
		case 3:
			line = fmt.tprintf("%s%i%%", acc, l.percent)
		case 4:
			line = fmt.tprintf("%s%i%%%s", acc, l.percent, game_string(r, GS_BONUS))
		case 5 ..= 8:
			if l.bonus_total == 0 {
				line = fmt.tprintf("%s%i%%%s%s", acc, l.percent, game_string(r, GS_BONUS), game_string(r, GS_NONE))
			} else {
				line = fmt.tprintf("%s%i%%%s%i", acc, l.percent, game_string(r, GS_BONUS), l.bonus)
			}
		case 9:
			line = game_string(r, GS_PERFECT)
		}
		text_preset_draw(r, text[data.Text_Preset.GroundAccuracyCount], line, VIEW_X, scale, l.fade)
	}

	for &p in s.players {
		m := &p.counter
		if p.state != .Playing || m.state == 0 || m.fade >= 0x20 {
			continue
		}
		coin := game_string(r, GS_COIN_BONUS)
		line: string
		switch m.state {
		case 1, 2:
			line = coin
		case 3:
			line = fmt.tprintf("%s%i", coin, m.money)
		case 4:
			line = fmt.tprintf("%s%i%s%i", coin, m.money, game_string(r, GS_TIMES), m.multiplier)
		case:
			line = fmt.tprintf("%s%i%s%i%s%i", coin, m.money, game_string(r, GS_TIMES), m.multiplier, game_string(r, GS_EQUALS), m.value)
		}
		t := text[data.Text_Preset.Player_MoneyCount]
		t.y += m.offset
		text_preset_draw(r, t, line, VIEW_X, scale, m.fade)
	}
}
