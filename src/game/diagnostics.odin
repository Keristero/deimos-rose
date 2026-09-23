package game

// notes/netcode-enhancements.md: "-diagnostics will show a rolling average
// stats display in the bottom right corner: ping of highest-ping client
// [multiplayer only], rollbacks/sec [multiplayer only], updates/sec
// (excluding rollbacks), FPS." New content, no original equivalent.
//
// "Rolling average" here is a 1-second tumbling window (count an event every
// time it happens, divide by elapsed time once a second has passed, then
// reset) rather than a continuously-sliding average -- simple, and updates
// often enough to read live; refine to an actual sliding window if a real
// session ever shows this stepping visibly between windows.
//
// "Highest ping client" is written for a future >2-player session; today
// there is only ever one peer, so it's just that peer's own ping
// (Netplay.ping_ms, net/reliable.odin's Ping/Pong round trip).

import "core:fmt"
import rl "vendor:raylib"

DIAGNOSTICS_WINDOW :: 1.0 // seconds

Diagnostics :: struct {
	enabled: bool,

	window_timer: f32,
	updates_this_window: int,
	updates_per_sec: f32,

	rollback_base:     int, // Rollback_Session.rollback_count at the last window boundary
	rollbacks_per_sec: f32,
}

// Called once per real (non-rollback) simulation tick -- see main.odin's
// fixed-step loop, which only calls this while Flow is actually stepping a
// session (.Playing). A misprediction's *extra* resimulation steps inside
// net/session.odin's rollback_to never reach here, only the one call per
// tick that advances to a new frame -- exactly the "excluding rollbacks"
// the notes ask for.
diagnostics_note_update :: proc(d: ^Diagnostics) {
	if !d.enabled {
		return
	}
	d.updates_this_window += 1
}

// Called once per render frame regardless of mode, so the window still rolls
// over (and the overlay's numbers decay toward 0) even at the title screen
// or mid-lobby, not just while playing. `rollback_count` is
// Flow.netplay.rs.rollback_count when a netplay session is active, 0
// otherwise (rollbacks/sec has no meaning outside netplay).
diagnostics_tick :: proc(d: ^Diagnostics, dt: f32, rollback_count: int) {
	if !d.enabled {
		return
	}
	d.window_timer += dt
	if d.window_timer < DIAGNOSTICS_WINDOW {
		return
	}
	d.updates_per_sec = f32(d.updates_this_window) / d.window_timer
	d.rollbacks_per_sec = f32(rollback_count - d.rollback_base) / d.window_timer
	d.rollback_base = rollback_count
	d.updates_this_window = 0
	d.window_timer = 0
}

diagnostics_draw :: proc(d: ^Diagnostics, netplay_active: bool, ping_ms: f32) {
	if !d.enabled {
		return
	}
	lines := 1
	if netplay_active {
		lines = 3
	}
	w: i32 = 190
	h: i32 = i32(lines) * 16 + 8
	x := SCREEN_W * WINDOW_SCALE - w - 8
	y := SCREEN_H * WINDOW_SCALE - h - 8
	rl.DrawRectangle(x, y, w, h, rl.Color{0, 0, 0, 150})
	ty := y + 4
	rl.DrawText(fmt.ctprintf("FPS %d", rl.GetFPS()), x + 6, ty, 14, rl.Color{180, 255, 180, 255})
	if netplay_active {
		ty += 16
		rl.DrawText(fmt.ctprintf("PING %.0f MS", ping_ms), x + 6, ty, 14, rl.Color{180, 220, 255, 255})
		ty += 16
		rl.DrawText(
			fmt.ctprintf("UPD %.1f/S  RB %.1f/S", d.updates_per_sec, d.rollbacks_per_sec),
			x + 6, ty, 14, rl.Color{220, 220, 180, 255},
		)
	}
}
