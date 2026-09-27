package sim

import "core:math"

// U_Math, reproduced exactly.
//
// Angles are integer degrees 0 ..< 360 with 0 pointing along +y (down the
// screen) and 90 along +x: a heading's vector is (sin, cos). Trig comes from
// the original's lookup tables (math_tables.odin, bit-exact).
//
// FLOAT NOTE: the original is x87 code. Windows runs the x87 at 53-bit
// precision by default, so `float10` intermediates in the decompilation
// behave as f64 here, and values the original stores to a `float` are rounded
// to f32 at the same points.

Vec :: [2]f32

m_sin :: #force_inline proc "contextless" (deg: i32) -> f32 {
	return transmute(f32)SIN_BITS[deg == 360 ? 0 : deg]
}

m_cos :: #force_inline proc "contextless" (deg: i32) -> f32 {
	return transmute(f32)COS_BITS[deg == 360 ? 0 : deg]
}

// C's (int) conversion: truncation toward zero. The decompilation spells it as
// ROUND() plus a sign-dependent correction, which is how CodeWarrior emits it
// on the x87.
trunc_i32 :: #force_inline proc "contextless" (f: f32) -> i32 {
	return i32(f)
}

// U_Math_Sqrt: table for small integers, sqrtf beyond. Both are correctly
// rounded f32 square roots, which is what the table holds (verified).
m_sqrt :: proc "contextless" (n: i32) -> f32 {
	return math.sqrt(f32(n))
}

vector_from_angle :: proc "contextless" (deg: i32) -> Vec {
	return {m_sin(deg), m_cos(deg)}
}

vector_from_angle_and_speed :: proc "contextless" (deg: i32, speed: f32) -> Vec {
	return {m_sin(deg) * speed, m_cos(deg) * speed}
}

// U_Math_GetSpeedFromVector: sqrtf of the float sum. The squares and their
// sum stay on the x87 stack (0x40242e..0x402436) and are rounded to f32 once,
// when stored as sqrtf's argument; squaring in f32 rounds three times, and
// lands an ulp off often enough to matter. ChangeState re-derives a velocity
// from this speed and steps toward it by the difference, so an ulp here is a
// velocity that drifts an ulp per step: dl09's smoke puff smbl 1949 drifted
// 67 ulps in vel.y, which turned Contract and Steady's heading from 316 to
// 315 at read 607 (vel/target/delta bits from tools/oracle/trace.py's move).
speed_from_vector :: proc "contextless" (v: Vec) -> f32 {
	x, y := f64(v.x), f64(v.y)
	return math.sqrt(f32(x * x + y * y))
}

// U_Math_GetDistanceToTarget: integer-truncated squared distance, then sqrt.
distance_to :: proc "contextless" (a, b: Vec) -> f32 {
	dx, dy := b.x - a.x, b.y - a.y
	return m_sqrt(trunc_i32(dx * dx + dy * dy))
}

// U_Math_InvertAngle: the reverse heading, in the original's own formula.
invert_angle :: proc "contextless" (deg: i32) -> i32 {
	return deg < 181 ? abs(deg - 180) : 540 - deg
}

// MSL's atanf (0x457420): widen to double, fpatan (atan, 0x457390), and
// store the result to a float before returning it (0x457434), so it is
// rounded to f32.
atanf :: proc "contextless" (r: f32) -> f64 {
	return f64(f32(math.atan(f64(r))))
}

// U_Math_GetAngleFromVector. Each quadrant multiplies atanf's result by the
// double 57.29... on the x87 stack, adds or subtracts its constant there, and
// stores the angle to a float before truncating it. atanf's rounding decides
// a velocity on a diagonal: de04's entity 1451 entering "Flash On" at read
// 505 with vel (bf95d9d8, bf95d9da) turns to 224 in the original, 225 with
// an unrounded atan; the traced vel/target/delta bits match this.
angle_from_vector :: proc "contextless" (v: Vec) -> i32 {
	x, y := v.x, v.y
	DEG :: 57.29577951308232
	a: f32
	switch {
	case x == 0 && y == 0:
		a = 0
	case x == 0 && y > 0:
		a = 0
	case x == 0 && y < 0:
		a = 180
	case y == 0 && x > 0:
		a = 90
	case y == 0 && x < 0:
		a = 270
	case x > 0 && y > 0:
		a = f32(atanf(x / y) * DEG)
	case x > 0 && y < 0:
		a = f32(180 - atanf(x / abs(y)) * DEG)
	case x < 0 && y > 0:
		a = f32(360 - atanf(abs(x) / y) * DEG)
	case x < 0 && y < 0:
		a = f32(270 - atanf(abs(y) / abs(x)) * DEG)
	}
	deg := trunc_i32(a)
	return deg > 359 ? 0 : deg
}

// FUN_004028e0 (behind U_Math_GetInterceptAngle): heading from one point to
// another via the atan table, in f64 as the original's float10 arithmetic.
intercept_angle_d :: proc "contextless" (dx, dy: f64) -> i32 {
	ax, ay := abs(dx), abs(dy)
	t := ax < ay ? abs(dx / dy) : abs(dy / dx)
	i := i32(t * 100)
	i = clamp(i, 0, 1023)
	a := abs(ATAN_DEG[i])
	if ax < ay {
		a = 90 - a
	}
	if dx < 0 && dy >= 0 {
		a = 180 - a
	}
	if dx < 0 && dy < 0 {
		a += 180
	}
	if dx >= 0 && dy < 0 {
		a = -a
	}
	r := a - 90
	if r < 0 {
		r = a + 270
	}
	if r > 359 {
		r -= 360
	}
	return r
}

// U_Math_GetInterceptAngle(x1, y1, x2, y2).
intercept_angle :: proc "contextless" (x1, y1, x2, y2: i32) -> i32 {
	return intercept_angle_d(f64(x1 - x2), f64(y1 - y2))
}
