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

// U_Math_GetSpeedFromVector: sqrtf of the float sum.
speed_from_vector :: proc "contextless" (v: Vec) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// U_Math_GetUnitVector: note the squared length is truncated to an integer
// before the square root, so short vectors normalise coarsely -- faithfully.
unit_vector :: proc "contextless" (x, y: f32) -> Vec {
	len := m_sqrt(trunc_i32(x * x + y * y))
	return {x / len, y / len}
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

// U_Math_GetAngleFromVector.
//
// PROVISIONAL: MSL's atanf returns its result on the x87 stack, and the
// product with 57.29... is only rounded when stored; modelled as an unrounded
// f64 atan. Only matters if the product lands within an ulp of an integer.
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
		a = f32(math.atan(f64(f32(f64(x) / f64(y)))) * DEG)
	case x > 0 && y < 0:
		a = f32(180 - math.atan(f64(f32(f64(x) / f64(abs(y))))) * DEG)
	case x < 0 && y > 0:
		a = f32(360 - math.atan(f64(f32(f64(abs(x)) / f64(y)))) * DEG)
	case x < 0 && y < 0:
		a = f32(270 - math.atan(f64(f32(f64(abs(y)) / f64(abs(x))))) * DEG)
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
