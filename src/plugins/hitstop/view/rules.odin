package hitstop_view

// What a hit holds the game for, and how the kill cam moves: plain
// functions of numbers, so the tests need no window.

import "core:math"

import "dr:sim"

STEP_HZ :: 30 // a step of the game, in seconds: 1 / STEP_HZ

MAX_HOLD :: 10 // steps, for an ordinary hit however hard
TAKEDOWN_STEPS :: 54 // steps the kill cam lasts
TAKEDOWN_RATIO :: 3.0 // damage over the target's shields that earns it

// Steps to hold for a hit of `damage`, scaled by the setting `strength`
// (percent, 0 turns it off). A square root, so a shot is a flicker and a
// bomb a beat: 4 damage is a step, 16 two, 100 five.
hold_steps :: proc "contextless" (damage: f32, strength: int) -> int {
	if damage <= 0 || strength <= 0 {
		return 0
	}
	n := int(math.round(math.sqrt(damage) * 0.5 * f32(strength) / 100))
	return clamp(n, 1, MAX_HOLD)
}

// A kill that dealt more than TAKEDOWN_RATIO times the unit's shields. Not
// a player, and not one that had nothing left to lose.
is_takedown :: proc "contextless" (ev: sim.Hit_Event) -> bool {
	return ev.killed && !ev.player && ev.shields > 0 && ev.damage > TAKEDOWN_RATIO * ev.shields
}

// A rise from 0 to 1 over p in [a, b].
@(private = "file")
ramp :: proc "contextless" (p, a, b: f32) -> f32 {
	x := clamp((p - a) / (b - a), 0, 1)
	return x * x * (3 - 2 * x)
}

// How far in the kill cam is at `p` (0 to 1 through it): 1 is the view as
// it was, ZOOM the closest. It dives in, creeps closer while the text is
// up, and eases back out at the end.
ZOOM :: 2.4
zoom_at :: proc "contextless" (p: f32) -> f32 {
	z := 1 + (ZOOM - 1) * ramp(p, 0, 0.18)
	z += 0.25 * ramp(p, 0.18, 0.9)
	return z - (z - 1) * ramp(p, 0.9, 1)
}

// How much of the bars and the dimming is up at `p`.
frame_at :: proc "contextless" (p: f32) -> f32 {
	return min(ramp(p, 0, 0.15), 1 - ramp(p, 0.92, 1))
}

// The size of TAKEDOWN at `p`, a multiple of its resting size: it slams in
// large and settles. 0 before it appears.
text_scale_at :: proc "contextless" (p: f32) -> f32 {
	if p < 0.2 {
		return 0
	}
	return 1 + 1.2 * (1 - ramp(p, 0.2, 0.32))
}

// The part of the field `field` to show at zoom `z` centred on `at`, kept
// inside the field.
zoom_rect :: proc "contextless" (field: [4]f32, at: [2]f32, z: f32) -> [4]f32 {
	w, h := field[2] / z, field[3] / z
	x := clamp(at.x - w / 2, field[0], field[0] + field[2] - w)
	y := clamp(at.y - h / 2, field[1], field[1] + field[3] - h)
	return {x, y, w, h}
}
