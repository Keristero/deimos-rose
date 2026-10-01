package terrain_tests

// A model too heavy to keep, simplified (simplify.odin): under the budget,
// its parts and extent kept, its cover from above the same near enough,
// and a texture's seam still a seam.

import "core:math"
import "core:strings"
import "core:testing"

import "dr:terrain"

// A dome 4 m across and 1 m high, `n` by `n` quads a side, as two grids
// meeting at x = 0, where its texture's seam is: the left's u runs 0.55 to
// 1, the right's 0 to 0.45. And a second part, a flat cap 1.5 m up.
@(private = "file")
dome :: proc(n: int) -> terrain.Model_File {
	m: terrain.Model_Mesh
	positions := make([dynamic][3]f32)
	normals := make([dynamic][3]f32)
	uvs := make([dynamic][2]f32)
	indices := make([dynamic]u32)
	grid :: proc(positions: ^[dynamic][3]f32, normals: ^[dynamic][3]f32, uvs: ^[dynamic][2]f32, indices: ^[dynamic]u32, n: int, x0, x1, u0, u1, lift: f32) {
		base := u32(len(positions))
		for j in 0 ..= n {
			for i in 0 ..= n {
				x := x0 + (x1 - x0) * f32(i) / f32(n)
				z := -2 + 4 * f32(j) / f32(n)
				y := lift > 0 ? lift : max(1 - (x * x + z * z) / 4, 0)
				append(positions, [3]f32{x, y, z})
				append(normals, [3]f32{0, 1, 0})
				append(uvs, [2]f32{u0 + (u1 - u0) * f32(i) / f32(n), f32(j) / f32(n)})
			}
		}
		row := u32(n + 1)
		for j in 0 ..< u32(n) {
			for i in 0 ..< u32(n) {
				a := base + j * row + i
				append(indices, a, a + 1, a + row + 1, a, a + row + 1, a + row)
			}
		}
	}
	grid(&positions, &normals, &uvs, &indices, n, -2, 0, 0.55, 1, 0)
	grid(&positions, &normals, &uvs, &indices, n, 0, 2, 0, 0.45, 0)
	first := len(indices)
	grid(&positions, &normals, &uvs, &indices, n / 4, -0.5, 0.5, 0, 1, 1.5)
	m.positions, m.normals, m.uvs, m.indices = positions[:], normals[:], uvs[:], indices[:]
	m.parts = make([]terrain.Model_Part, 2)
	m.parts[0] = {first = 0, count = first, image = -1, colour = 1}
	m.parts[1] = {first = first, count = len(indices) - first, image = -1, colour = {1, 0, 0, 1}}
	m.lo, m.hi = {-2, 0, -2}, {2, 1.5, 2}
	m.name = strings.clone("dome")
	f := terrain.Model_File {
		name     = strings.clone("dome"),
		variants = make([]terrain.Model_Mesh, 1),
	}
	f.variants[0] = m
	return f
}

@(test)
a_heavy_model_is_simplified :: proc(t: ^testing.T) {
	f := dome(120)
	defer terrain.model_file_destroy(&f)
	before := terrain.file_triangles(f)
	testing.expect(t, !terrain.model_file_simplify(&f, budget = before), "a model at the budget was changed")
	testing.expect_value(t, terrain.file_triangles(f), before)

	// The heights the dome's top is met at from above.
	tops :: proc(f: terrain.Model_File) -> (out: [16 * 16]f32, hits: int) {
		p := terrain.project_make(64, 64, context.temp_allocator)
		append(&p.model_files, f)
		append(&p.models, terrain.Model{name = "dome", file = "dome"})
		defer delete(p.model_files)
		defer delete(p.models)
		defer delete(p.instances)
		append(&p.instances, terrain.Instance{x = 32, y = 32, scale = 4})
		for j in 0 ..< 16 {
			for i in 0 ..< 16 {
				// 0.25 m apart, none on an edge: the clustered outline is
				// in by up to half a cell (0.09 m here), where a cell's
				// mean is.
				at := [2]f32{32 + (f32(i) - 7.5) * 3, 32 + (f32(j) - 7.5) * 3}
				top, hit := terrain.instance_hit(&p, p.instances[0], at)
				out[j * 16 + i] = hit ? top : -1
				hits += int(hit)
			}
		}
		return
	}
	want, want_hits := tops(f)

	budget :: 2000
	testing.expect(t, terrain.model_file_simplify(&f, budget = budget))
	v := f.variants[0]
	n := terrain.file_triangles(f)
	testing.expectf(t, n > budget / 8 && n <= budget, "%d triangles from %d for a budget of %d", n, before, budget)
	testing.expect_value(t, len(v.parts), 2)
	testing.expect_value(t, v.parts[1].colour, [4]f32{1, 0, 0, 1})
	testing.expect_value(t, v.lo, [3]f32{-2, 0, -2})
	testing.expect_value(t, v.hi, [3]f32{2, 1.5, 2})
	testing.expect_value(t, len(v.positions), len(v.normals))
	testing.expect_value(t, len(v.positions), len(v.uvs))

	got, got_hits := tops(f)
	testing.expectf(t, got_hits == want_hits, "covered at %d points, not %d", got_hits, want_hits)
	worst: f32
	for k in 0 ..< len(want) {
		if want[k] >= 0 && got[k] >= 0 {
			worst = max(worst, abs(got[k] - want[k]))
		}
	}
	// Map pixels: 0.2 m at scale 4.
	testing.expectf(t, worst < 2.4, "the top moved %v map pixels", worst)

	for k := 0; k < len(v.indices); k += 3 {
		lo, hi := f32(math.F32_MAX), f32(-math.F32_MAX)
		for c in 0 ..< 3 {
			u := v.uvs[v.indices[k + c]].x
			lo, hi = min(lo, u), max(hi, u)
		}
		if hi - lo > 0.5 {
			testing.expectf(t, false, "triangle %d spans the seam: u %v to %v", k / 3, lo, hi)
			break
		}
	}
}
