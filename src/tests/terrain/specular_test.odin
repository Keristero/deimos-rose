package terrain_tests

// The layers an export makes for realtime lighting (terrain/specular.odin):
// how glossy the ground is, and which way it faces.

import "core:testing"

import "dr:terrain"

@(test)
specular_mask_is_wet_under_the_water_and_dull_under_trees :: proc(t: ^testing.T) {
	p := terrain.project_make(8, 4, context.temp_allocator)
	p.level.water = {height = 1, visible = true}
	p.heights[0] = -2 // under the water
	p.heights[1] = 0.5 // under it, just
	p.heights[2] = 1 // at the edge: damp
	p.heights[3] = 9 // well clear: the default
	for i in 4 ..< len(p.heights) {
		p.heights[i] = 9
	}
	p.canopy = make([]u8, 8 * 4, context.temp_allocator)
	p.canopy[4] = 255
	m := terrain.specular_mask_make(&p, context.temp_allocator)
	testing.expect_value(t, [3]int{m.width, m.height, m.channels}, [3]int{8, 4, 1})
	testing.expect(t, m.pixels[0] > 230, "water is near mirror")
	testing.expect(t, m.pixels[2] > m.pixels[3], "the shore is damp")
	testing.expect_value(t, m.pixels[3], u8(51)) // MATERIAL_GLOSS_DEFAULT
	testing.expect(t, m.pixels[4] < m.pixels[3] / 2, "tree cover dulls the ground")

	p.level.water.visible = false
	m = terrain.specular_mask_make(&p, context.temp_allocator)
	testing.expect_value(t, m.pixels[0], u8(51))
}

@(test)
specular_mask_takes_a_materials_own_gloss :: proc(t: ^testing.T) {
	p := terrain.project_make(2, 1, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "wet sand", gloss = 0.8}, terrain.Material{name = "grass"})
	p.splat = make([]u8, 2 * 4, context.temp_allocator)
	p.splat[0] = 255 // the first pixel is all the first material
	p.splat[4 + 1] = 255 // the second all the second, which has set none
	m := terrain.specular_mask_make(&p, context.temp_allocator)
	testing.expect_value(t, m.pixels[0], u8(204))
	testing.expect_value(t, m.pixels[1], u8(51))
}

@(test)
normal_mask_faces_up_on_flat_ground_and_downhill_on_a_slope :: proc(t: ^testing.T) {
	p := terrain.project_make(5, 5, context.temp_allocator)
	for y in 0 ..< 5 {
		for x in 0 ..< 5 {
			p.heights[y * 5 + x] = f32(x) // rising to the right
		}
	}
	m := terrain.normal_mask_make(&p, context.temp_allocator)
	px := m.pixels[(2 * 5 + 2) * 3:][:3]
	testing.expect(t, px[0] < 128, "the slope leans to the left, away from the rise")
	testing.expect_value(t, px[1], u8(128))
	testing.expect(t, px[2] > 128)

	flat := terrain.project_make(3, 3, context.temp_allocator)
	m = terrain.normal_mask_make(&flat, context.temp_allocator)
	testing.expect_value(t, [3]u8{m.pixels[12], m.pixels[13], m.pixels[14]}, [3]u8{128, 128, 255})
}
