package tests

import "core:os"
import "core:testing"
import "dr:sim"

@(test)
angles_follow_the_originals_convention :: proc(t: ^testing.T) {
	// 0 is +y, 90 is +x: a heading's vector is (sin, cos).
	testing.expect_value(t, sim.angle_from_vector({0, 1}), i32(0))
	testing.expect_value(t, sim.angle_from_vector({1, 0}), i32(90))
	testing.expect_value(t, sim.angle_from_vector({0, -1}), i32(180))
	testing.expect_value(t, sim.angle_from_vector({-1, 0}), i32(270))
	testing.expect_value(t, sim.angle_from_vector({1, 1}), i32(45))
	testing.expect_value(t, sim.angle_from_vector({1, -1}), i32(135))
	testing.expect_value(t, sim.angle_from_vector({-1, -1}), i32(225))
	testing.expect_value(t, sim.angle_from_vector({-1, 1}), i32(315))
	testing.expect_value(t, sim.vector_from_angle(90), sim.Vec{1, transmute(f32)u32(0xb33bbd2e)})
}

@(test)
angle_round_trips_within_a_degree :: proc(t: ^testing.T) {
	// Truncation means a table vector can read back one degree low.
	for deg in i32(0) ..< 360 {
		back := sim.angle_from_vector(sim.vector_from_angle_and_speed(deg, 50))
		diff := (deg - back + 360) % 360
		testing.expectf(t, diff <= 1, "deg %d read back as %d", deg, back)
	}
}

@(test)
invert_angle_reverses_headings :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.invert_angle(0), i32(180))
	testing.expect_value(t, sim.invert_angle(90), i32(90))
	testing.expect_value(t, sim.invert_angle(180), i32(0))
	testing.expect_value(t, sim.invert_angle(270), i32(270))
	testing.expect_value(t, sim.invert_angle(359), i32(181))
}

@(test)
intercept_angle_is_a_screen_heading :: proc(t: ^testing.T) {
	// intercept_angle(x1, y1, x2, y2) is the heading from point 1 towards
	// point 2 in screen convention (0 = up, -y; 90 = +x). Vector angles put 0
	// at +y, so the two differ by invert_angle -- which is why the original
	// inverts headings before U_Math_GetVectorFromAngleAndSpeed.
	testing.expect_value(t, sim.intercept_angle(0, 10, 0, 0), i32(0)) // up
	testing.expect_value(t, sim.intercept_angle(-10, 0, 0, 0), i32(90)) // right
	testing.expect_value(t, sim.intercept_angle(0, -10, 0, 0), i32(180)) // down
	testing.expect_value(t, sim.intercept_angle(10, 0, 0, 0), i32(270)) // left
	for p in ([][2]i32{{3, 7}, {-5, 2}, {-4, -9}, {8, -1}}) {
		heading := sim.intercept_angle(0, 0, p.x, p.y)
		along := sim.angle_from_vector({f32(p.x), f32(p.y)})
		diff := (sim.invert_angle(heading) - along + 360) % 360
		testing.expectf(t, diff <= 1 || diff >= 359, "towards %v: heading %d, vector angle %d", p, heading, along)
	}
}

@(test)
trig_tables_match_the_running_original :: proc(t: ^testing.T) {
	// Dumped by `mise run oracle:tables`; skipped without it.
	sin_raw, err1 := os.read_entire_file("../work/wine/tables/sin.bin", context.temp_allocator)
	cos_raw, err2 := os.read_entire_file("../work/wine/tables/cos.bin", context.temp_allocator)
	atan_raw, err3 := os.read_entire_file("../work/wine/tables/atan.bin", context.temp_allocator)
	if err1 != nil || err2 != nil || err3 != nil {
		return
	}
	s := transmute([]u32)sin_raw
	c := transmute([]u32)cos_raw
	a := transmute([]i32)atan_raw
	for i in 0 ..< 360 {
		testing.expect_value(t, s[i], sim.SIN_BITS[i])
		testing.expect_value(t, c[i], sim.COS_BITS[i])
	}
	for i in 0 ..< 1024 {
		testing.expect_value(t, a[i], sim.ATAN_DEG[i])
	}
}
