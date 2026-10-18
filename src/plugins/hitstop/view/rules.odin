package hitstop_view

// What a hit holds the game for, and how the kill cam moves: plain
// functions of numbers, so the tests need no window.

import "core:fmt"
import "core:math"
import "core:strings"

import "dr:sim"

STEP_HZ :: 30 // a step of the game, in seconds: 1 / STEP_HZ

MAX_HOLD :: 15 // steps, for an ordinary hit however hard
TAKEDOWN_SECONDS :: 2.8 // the kill cam, on the clock
STREAK_WINDOW :: 420 // steps (14 s of the game) a kill streak is kept alive between kills
STREAK_HIT_COST :: 50 // steps a player's streak loses each time they are struck

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

// How much damage slows the game for the kill cam, 0..1: 9 or more is all.
slow_power :: proc "contextless" (damage: f32) -> f32 {
	return clamp(math.sqrt(max(damage, 0)) / 3, 0, 1)
}

// The speed the game runs at in the middle of the kill cam: 30% for a light
// blow down to 1% for a heavy one.
SLOW_LIGHTEST :: 0.30
SLOW_HEAVIEST :: 0.01
slow_speed :: proc "contextless" (power: f32) -> f32 {
	return SLOW_LIGHTEST + (SLOW_HEAVIEST - SLOW_LIGHTEST) * clamp(power, 0, 1)
}

// How far into the slow-motion the kill cam is at `p`: it drops into it in
// the first tenth, stays, and comes back out over the last quarter.
slow_at :: proc "contextless" (p: f32) -> f32 {
	return ramp(p, 0, 0.1) * (1 - ramp(p, 0.72, 1))
}

// The game's speed at `p` through a kill cam of `power` (slow_power).
speed_at :: proc "contextless" (p, power: f32) -> f32 {
	return 1 - slow_at(p) * (1 - slow_speed(power))
}

// How much slower the sound plays at `p`: a heavier blow drags it down
// further, to about half speed.
audio_slow_at :: proc "contextless" (p, power: f32) -> f32 {
	return slow_at(p) * (0.25 + 0.3 * power)
}

// How much reverb is on the sound at `p`, 0..1, growing with the damage.
reverb_at :: proc "contextless" (p, power: f32) -> f32 {
	return slow_at(p) * (0.3 + 0.7 * power)
}

// A kill streak's titles: line N of announcer/streaks.txt is streak N.
STREAK_TITLES :: #load("../announcer/streaks.txt", string)
STREAK_TITLE_COUNT :: 50

// Which of the 50 titles streak `n` (1 or more) is named by, 1 to 50: past
// 50 they come round again.
streak_index :: proc "contextless" (n: int) -> int {
	return (max(n, 1) - 1) % STREAK_TITLE_COUNT + 1
}

// A streak's modifiers: line N of announcer/modifiers.txt is the prefix of
// tier N, one tier for each 50 kills ("Super" from 51, "Super Duper" from 101,
// on to "Final" from 1951). Past 2000 the last one stays.
STREAK_MODIFIERS :: #load("../announcer/modifiers.txt", string)
STREAK_MAX_TIER :: 39

// 0 for none, then the tier of the modifier: 1 for Super (51 to 100), 2 for
// Super Duper (101 to 150), ..., STREAK_MAX_TIER from 1951.
streak_tier :: proc "contextless" (n: int) -> int {
	return min((max(n, 1) - 1) / STREAK_TITLE_COUNT, STREAK_MAX_TIER)
}

// The modifier of `tier` (1 or more), "" for none.
streak_modifier :: proc(tier: int) -> string {
	rest := STREAK_MODIFIERS
	for i := 1; rest != ""; i += 1 {
		line, _, more := strings.partition(rest, "\n")
		if i == tier {
			return strings.trim_space(line)
		}
		rest = more
	}
	return ""
}

// The clip a modifier is spoken from: "super", "super_duper", "mega", ...
streak_modifier_clip :: proc(tier: int, allocator := context.temp_allocator) -> string {
	low, _ := strings.to_lower(streak_modifier(tier), allocator)
	clip, _ := strings.replace_all(low, " ", "_", allocator)
	return clip
}

// The title line of streak `n`, as spoken ("Oh Baby, a Triple").
streak_title :: proc(n: int) -> string {
	want := streak_index(n)
	rest := STREAK_TITLES
	for i := 1; ; i += 1 {
		line, _, more := strings.partition(rest, "\n")
		if i == want {
			return strings.trim_space(line)
		}
		if more == "" {
			return ""
		}
		rest = more
	}
}

// What is spoken and shown for streak `n`: "Takedown", "Quad Kill", ...,
// "Super Takedown" past 50, "Super Duper Takedown" past 100, "Mega Takedown"
// past 150, and so on.
streak_phrase :: proc(n: int, allocator := context.temp_allocator) -> string {
	tier := streak_tier(n)
	if tier == 0 {
		return streak_title(n)
	}
	return strings.concatenate({streak_modifier(tier), " ", streak_title(n)}, allocator)
}

// What is drawn: the phrase, upper case, without its commas.
streak_text :: proc(n: int, allocator := context.temp_allocator) -> string {
	up, _ := strings.to_upper(streak_phrase(n, allocator), allocator)
	text, _ := strings.remove_all(up, ",", allocator)
	return text
}

// The step a streak counts its last kill from once its player is struck:
// earlier by STREAK_HIT_COST, so the meter drops a little (and a streak
// that was nearly out is out).
streak_struck :: proc "contextless" (count, last: int) -> int {
	return count > 0 ? last - STREAK_HIT_COST : last
}

// A player's streak after a kill at step `now`, from their `count` and the
// step of their last kill: it goes on within STREAK_WINDOW steps, else it
// starts again at 1.
streak_after :: proc "contextless" (count, last, now: int) -> int {
	if count > 0 && now - last <= STREAK_WINDOW {
		return count + 1
	}
	return 1
}

// How hot a combo of `count` burns, 1 up to 20 and then on, a hundredfold
// count (20 to 2000) taking it to 5: the flames' number and height follow.
flame_heat :: proc "contextless" (count: int) -> f32 {
	if count <= 20 {
		return clamp(f32(count) / 20, 0, 1)
	}
	return 1 + 2 * math.log10(f32(min(count, 2000)) / 20)
}

// How tall the flames rise at `heat`: all of it to 1, a quarter of the rest.
flame_rise :: proc "contextless" (heat: f32) -> f32 {
	return min(heat, 1) + max(heat - 1, 0) * 0.25
}

// Player 2's announcer gets angrier with the streak: the stage (0 calm to
// RAGE_STAGES - 1 furious) rises at these streaks.
RAGE_STAGES :: 5
RAGE_LINES :: 4 // lines for each stage in announcer/rage.txt
@(rodata)
RAGE_FROM := [RAGE_STAGES]int{1, 6, 16, 36, 101}

// From this stage he shouts the titles and modifiers (the "_mad" clips).
RAGE_SHOUTING :: 3

rage_stage :: proc "contextless" (n: int) -> int {
	stage := 0
	for from, i in RAGE_FROM {
		if n >= from {
			stage = i
		}
	}
	return stage
}

// The clip of the line he says after the title: one of the stage's lines,
// by the streak so that it varies kill to kill.
rage_clip :: proc(n: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("rage_%d_%d", rage_stage(n), max(n, 0) % RAGE_LINES, allocator = allocator)
}

// How fast and how loud he is at `n`: higher and louder as he loses it.
rage_pitch :: proc "contextless" (n: int) -> f32 {
	return 1 + 0.07 * f32(rage_stage(n))
}

rage_gain :: proc "contextless" (n: int) -> f32 {
	return 1 + 0.15 * f32(rage_stage(n))
}
