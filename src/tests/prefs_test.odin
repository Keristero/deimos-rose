package tests

import "core:testing"

import "dr:prefs"
import "dr:sim"

@(test)
prefs_round_trip_through_the_save_format :: proc(t: ^testing.T) {
	p := prefs.defaults()
	p.sfx_volume, p.music_volume = 30, 0
	p.fullscreen, p.classic = true, true
	prefs.bind(&p, 1, .Fire_Air, 1, prefs.KEY_SPACE) // moves Space off player 1
	text := prefs.format(&p, context.temp_allocator)
	got := prefs.parse(text)
	testing.expect_value(t, got, p)
}

@(test)
prefs_parse_keeps_defaults_for_what_it_does_not_understand :: proc(t: ^testing.T) {
	// A missing file, an older file, or a hand-edited typo each fall back
	// per setting rather than losing the lot.
	got := prefs.parse("music_volume=40\nsfx_volume=loud\np1.fire_air=1,2,3\np9.up=87,0\nbogus\np2.left=65,0\nclassic=yes\n")
	want := prefs.defaults()
	want.music_volume = 40
	want.bindings[1][.Left] = {prefs.KEY_A, prefs.KEY_NONE}
	testing.expect_value(t, got, want)

	testing.expect_value(t, prefs.parse(""), prefs.defaults())
	testing.expect_value(t, prefs.parse("sfx_volume=250").sfx_volume, 100) // clamped
}

@(test)
prefs_bind_takes_a_key_off_everything_else :: proc(t: ^testing.T) {
	p := prefs.defaults()
	// W is player 1's alternate Up; giving it to player 2's Fire Air must
	// leave it bound exactly once.
	prefs.bind(&p, 1, .Fire_Air, 0, prefs.KEY_W)
	testing.expect_value(t, p.bindings[1][.Fire_Air][0], i32(prefs.KEY_W))
	testing.expect_value(t, p.bindings[0][.Up], [prefs.BINDING_SLOTS]i32{prefs.KEY_UP, prefs.KEY_NONE})
	count := 0
	for b in p.bindings {
		for keys in b {
			for k in keys {
				if k == prefs.KEY_W {
					count += 1
				}
			}
		}
	}
	testing.expect_value(t, count, 1)

	// KEY_NONE clears one slot without touching any other.
	prefs.bind(&p, 0, .Down, 0, prefs.KEY_NONE)
	testing.expect_value(t, p.bindings[0][.Down], [prefs.BINDING_SLOTS]i32{prefs.KEY_NONE, prefs.KEY_S})
	testing.expect_value(t, p.bindings[0][.Left], [prefs.BINDING_SLOTS]i32{prefs.KEY_LEFT, prefs.KEY_A})
}

@(test)
prefs_defaults_give_each_player_distinct_keys :: proc(t: ^testing.T) {
	// Player 2 had no keys at all before bindings; theirs must not overlap
	// player 1's, or local co-op would move both ships with one key.
	p := prefs.defaults()
	seen: map[i32]int
	defer delete(seen)
	for b, player in p.bindings {
		for keys, button in b {
			testing.expectf(t, keys[0] != prefs.KEY_NONE, "player %d %v has no key", player + 1, button)
			for k in keys {
				if k == prefs.KEY_NONE {
					continue
				}
				if other, dup := seen[k]; dup {
					testing.expectf(t, false, "key %d bound for player %d and player %d", k, other + 1, player + 1)
				}
				seen[k] = player
			}
		}
	}
	testing.expect_value(t, len(p.bindings), sim.MAX_PLAYERS)
}

@(test)
prefs_volume_steps_stay_in_range :: proc(t: ^testing.T) {
	v := 95
	prefs.step_volume(&v, 1)
	testing.expect_value(t, v, 100)
	v = 5
	prefs.step_volume(&v, -1)
	testing.expect_value(t, v, 0)
	v = 50
	prefs.step_volume(&v, -1)
	testing.expect_value(t, v, 50 - prefs.VOLUME_STEP)
}
