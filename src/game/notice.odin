package game

// G_Notice_BuildDrawList: the banner across the top of the play field for a
// unit's entry/destruct notice. No shipped unit sets either field (see
// sim/notice.odin), so this never draws in practice; kept for completeness
// and so a modded level that does use it shows something reasonable. The
// original reveals the text character by character, then holds and fades it
// using G_Text_GetPermTextSetting(0x31)'s position and
// G_Res_GetPermFloat(0x47-49)'s timing; neither is reproduced here since
// neither affects the RNG stream, so this just shows the whole string for a
// fixed span at a fixed spot instead.

import "dr:sim"

NOTICE_SHOW_FRAMES :: 90
NOTICE_FADE_FRAMES :: 20
NOTICE_LAYER :: 15

Notices :: struct {
	text:      string,
	remaining: i32,
}

// Call once per sim.step, alongside particles_step/blurs_step.
notices_step :: proc(n: ^Notices, s: ^sim.State) {
	for ev in s.notices.events[:s.notices.count] {
		n.text = ev.text
		n.remaining = NOTICE_SHOW_FRAMES
	}
	if n.remaining > 0 {
		n.remaining -= 1
	}
}

// Call from build_frame, so the banner is one more item in the HUD layer.
notices_draw :: proc(r: ^Renderer, n: ^Notices) {
	if n.remaining <= 0 {
		return
	}
	alpha: u8 = 255
	if n.remaining < NOTICE_FADE_FRAMES {
		alpha = u8(n.remaining * 255 / NOTICE_FADE_FRAMES)
	}
	draw_text(r, n.text, PLAY_W / 2, 20, NOTICE_LAYER, {255, 255, 255, alpha}, .Centre)
}
