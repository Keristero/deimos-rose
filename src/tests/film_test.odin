package tests

import "core:fmt"
import "core:os"
import "core:testing"

import "dr:data"
import "dr:sim"

@(private = "file")
put_u32 :: proc(b: []byte, o: int, v: u32, big: bool) {
	if big {
		b[o + 0] = u8(v >> 24); b[o + 1] = u8(v >> 16)
		b[o + 2] = u8(v >> 8);  b[o + 3] = u8(v)
	} else {
		b[o + 0] = u8(v);       b[o + 1] = u8(v >> 8)
		b[o + 2] = u8(v >> 16); b[o + 3] = u8(v >> 24)
	}
}

@(private = "file")
make_film :: proc(big: bool, frames: u32, inputs: []u8) -> []byte {
	b := make([]byte, data.FILM_SIZE)
	put_u32(b, 0, data.FILM_VERSION, big)
	put_u32(b, 4, 0xDEADBEEF, big)
	copy(b[8:12], "le07")
	b[0x0c] = data.FILM_GAME_TYPE_SINGLE
	put_u32(b, data.FILM_HEADER_SIZE, frames, big)
	copy(b[data.FILM_HEADER_SIZE + 8:][:4], "le07")
	copy(b[data.FILM_HEADER_SIZE + 0x0c:], inputs)
	copy(b[data.FILM_HEADER_SIZE + data.FILM_PLAYER_STRIDE + 8:][:4], "none")
	return b
}

@(test)
film_parses_both_byte_orders :: proc(t: ^testing.T) {
	for big in ([]bool{true, false}) {
		raw := make_film(big, 3, []u8{0x01, 0x10, 0x00})
		defer delete(raw)
		f, err := data.film_parse(raw)
		defer data.film_destroy(&f)

		testing.expectf(t, err == .None, "big=%v: %v", big, err)
		testing.expect_value(t, f.big_endian, big)
		testing.expect_value(t, f.version, u32(data.FILM_VERSION))
		testing.expect_value(t, f.seed, u32(0xDEADBEEF))
		testing.expect_value(t, f.game_type, u8(data.FILM_GAME_TYPE_SINGLE))
		testing.expect_value(t, data.fourcc_string(&f.level_id), "le07")
		testing.expect_value(t, f.tracks[0].frame_count, u32(3))
		testing.expect_value(t, f.tracks[1].frame_count, u32(0))
		testing.expect_value(t, len(f.frames), 3)
	}
}

@(test)
film_rejects_bad_input :: proc(t: ^testing.T) {
	short := make([]byte, 64)
	defer delete(short)
	_, e1 := data.film_parse(short)
	testing.expect_value(t, e1, data.Film_Error.Truncated)

	bad := make([]byte, data.FILM_SIZE)
	defer delete(bad)
	_, e2 := data.film_parse(bad)
	testing.expect_value(t, e2, data.Film_Error.Bad_Version)

	over := make_film(true, data.FILM_MAX_FRAMES + 1, nil)
	defer delete(over)
	_, e3 := data.film_parse(over)
	testing.expect_value(t, e3, data.Film_Error.Frame_Count_Too_Large)
}

@(test)
film_input_byte_unpacks_seven_bits :: proc(t: ^testing.T) {
	// All seven bits set yields all seven buttons; the eighth bit is unused.
	all := data.film_buttons_from_byte(0x7f)
	testing.expect_value(t, card(all), 7)
	none := data.film_buttons_from_byte(0x80)
	testing.expect_value(t, card(none), 0)
	// Each bit maps to exactly one distinct button.
	seen: sim.Buttons
	for i in 0 ..< 7 {
		b := data.film_buttons_from_byte(u8(1 << u8(i)))
		testing.expect_value(t, card(b), 1)
		testing.expect(t, card(seen & b) == 0, "bit mapping must be injective")
		seen += b
	}
	testing.expect_value(t, card(seen), 7)
}

@(test)
film_converts_to_a_sim_replay :: proc(t: ^testing.T) {
	raw := make_film(true, 2, []u8{0x04, 0x01})
	defer delete(raw)
	f, err := data.film_parse(raw)
	defer data.film_destroy(&f)
	testing.expect_value(t, err, data.Film_Error.None)

	replay := data.film_to_sim(f)
	testing.expect_value(t, replay.session.seed, u32(0xDEADBEEF))
	testing.expect_value(t, replay.session.game_type, sim.Game_Type.Single)
	testing.expect_value(t, replay.session.level_id, sim.level_id("le07"))
	testing.expect_value(t, len(replay.frames), 2)

	// Replaying is deterministic and drives the simulation without I/O.
	a := sim.replay(replay)
	b := sim.replay(replay)
	testing.expect_value(t, sim.checksum(&a), sim.checksum(&b))
	testing.expect_value(t, a.frame, u32(2))
}

// --- integration: the shipped films ---------------------------------------

@(test)
shipped_films_parse :: proc(t: ^testing.T) {
	if !os.exists("assets/films") {
		return
	}
	expect := [][2]string {
		{"de01", "le07"}, {"de02", "le06"}, {"de03", "le02"}, {"de04", "le08"},
	}
	for e in expect {
		path := fmt.tprintf("assets/films/%s.film", e[0])
		raw, rerr := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, rerr == nil, "cannot read %v", path)
		if rerr != nil {
			continue
		}
		testing.expect_value(t, len(raw), data.FILM_SIZE)

		f, err := data.film_parse(raw)
		defer data.film_destroy(&f)
		testing.expectf(t, err == .None, "%v: %v", path, err)
		if err != .None {
			continue
		}
		// The four demos in Game.pak were authored on the Mac.
		testing.expectf(t, f.big_endian, "%v should be big-endian", e[0])
		testing.expect_value(t, data.fourcc_string(&f.level_id), e[1])
		testing.expect_value(t, f.game_type, u8(data.FILM_GAME_TYPE_SINGLE))
		// Single-player demos: track 1 is unused.
		testing.expect_value(t, f.tracks[1].frame_count, u32(0))
		testing.expect(t, f.tracks[0].frame_count > 1000, "demo should be substantial")
		testing.expect_value(t, data.fourcc_string(&f.tracks[1].level_id), "none")
	}
}

@(test)
film_input_bits_match_the_recovered_control_order :: proc(t: ^testing.T) {
	// Composed from G_Film::SetInputs, G_Input_CachePlayerInputs and the
	// "Edit Key Controls" dialog template. See data/film.odin for the chain.
	expect := [7]sim.Button {
		0 = .Down, 1 = .Left, 2 = .Up, 3 = .Right,
		4 = .Fire_Ground, 5 = .Fire_Air, 6 = .Change_Air,
	}
	for want, i in expect {
		got := data.film_buttons_from_byte(u8(1 << u8(i)))
		testing.expectf(t, got == {want}, "bit %d should be %v, got %v", i, want, got)
	}
}
