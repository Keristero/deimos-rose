package hitstop_view

// What a hit holds the game for, and how the kill cam moves: plain
// functions of numbers, so the tests need no window.

import "core:math"

import "dr:sim"

STEP_HZ :: 30 // a step of the game, in seconds: 1 / STEP_HZ

MAX_HOLD :: 15 // steps, for an ordinary hit however hard
TAKEDOWN_STEPS :: 54 // steps the kill cam lasts

// Steps to hold for a hit of `damage`, scaled by the setting `strength`
// (percent, 0 turns it off): 1 + 3 * sqrt(damage). Damage in this game is
// small (a Photon Beam shot is 0.5, a Flipper has 0.8 shields), so a shot is
// 3 steps, a hit of 1 is 4 and a hit of 10 is 10.
hold_steps :: proc "contextless" (damage: f32, strength: int) -> int {
	if damage <= 0 || strength <= 0 {
		return 0
	}
	n := int(math.round((1 + 3 * math.sqrt(damage)) * f32(strength) / 100))
	return clamp(n, 1, MAX_HOLD)
}

// Any kill of an enemy by a player: not a player, scenery, a shot or a
// bonus, and not one that had nothing left to lose.
is_takedown :: proc "contextless" (ev: sim.Hit_Event) -> bool {
	return ev.killed && ev.enemy && !ev.player && ev.shields > 0
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

SHAKE_PX :: 46 // field pixels the picture throws at the worst of it

// How hard a blow of `damage` shakes the screen, 0..1: a small hit is
// still a heavy shake (0.5 damage is 0.43), and 9 or more is all of it.
shake_power :: proc "contextless" (damage: f32) -> f32 {
	return clamp(0.25 + 0.25 * math.sqrt(max(damage, 0)), 0.25, 1)
}

// How hard the screen shakes at `p` for a blow of `power` (shake_power):
// all of it as the blow lands, falling away over the first half, and a
// rumble under the text after.
shake_at :: proc "contextless" (p, power: f32) -> f32 {
	land := 1 - ramp(p, 0, 0.55)
	return clamp(land * land + 0.12 * (1 - ramp(p, 0.55, 0.9)), 0, 1) * power
}
