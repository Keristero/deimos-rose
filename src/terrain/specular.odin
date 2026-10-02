package terrain

// The specular mask: how much each map pixel throws light back, 0-255, one
// per map pixel. The game's realtime lighting (plugins/lighting) adds a
// highlight where a light falls on ground the mask calls glossy, so wet
// sand and rock catch a shot's light and grass does not. Exported with the
// map as the level's `layers.specular`.
//
// Made from what the project knows:
//   - the ground: its materials' gloss, weighted by the splat; a project
//     with no splat (a recovered level, which has only its colour) gets a
//     guess from the colour, pale and grey ground (rock, sand) glossier
//     than saturated ground (grass, soil);
//   - trees: the canopy's cover dulls what it covers;
//   - water: ground under the water's surface is wet, near mirror where the
//     water is opaque, and the shore a little above it is damp.
//
// Provisional: every number here was picked by eye, not measured; the art
// has no specular to measure against. A project's materials can say their
// own with `gloss`.

import "core:math"

MATERIAL_GLOSS_DEFAULT :: f32(0.2)
@(private = "file") WET_GLOSS :: f32(0.95)
@(private = "file") DAMP_GLOSS :: f32(0.5)
@(private = "file") DAMP_BAND :: f32(3) // map pixels above the water that are damp
@(private = "file") CANOPY_DULL :: f32(0.75)

// A material's gloss, with the default for one that has not set it.
material_gloss :: proc(m: Material) -> f32 {
	return m.gloss > 0 ? clamp(m.gloss, 0, 1) : MATERIAL_GLOSS_DEFAULT
}

// The gloss of one pixel's ground, before trees and water.
@(private = "file")
ground_gloss :: proc(p: ^Project, i: int) -> f32 {
	if p.splat != nil && len(p.materials) > 0 {
		weight, sum := f32(0), f32(0)
		for k in 0 ..< min(len(p.materials), MAX_MATERIALS) {
			w := f32(p.splat[i * 4 + k])
			weight += w
			sum += w * material_gloss(p.materials[k])
		}
		if weight > 0 {
			return sum / weight
		}
	}
	if p.albedo != nil {
		c := [3]f32{f32(p.albedo[i * 3]), f32(p.albedo[i * 3 + 1]), f32(p.albedo[i * 3 + 2])} / 255
		top, low := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
		saturation := top > 0 ? (top - low) / top : 0
		return clamp(0.05 + 0.5 * (1 - saturation) * (0.4 + 0.6 * top), 0, 1)
	}
	return MATERIAL_GLOSS_DEFAULT
}

specular_mask_make :: proc(p: ^Project, allocator := context.allocator) -> Picture {
	mask := picture_make(p.width, p.length, 1, 8, allocator)
	water := p.level.water
	for i in 0 ..< p.width * p.length {
		g := ground_gloss(p, i)
		if p.canopy != nil {
			g *= 1 - CANOPY_DULL * f32(p.canopy[i]) / 255
		}
		if water.visible {
			depth := water.height - p.heights[i]
			if depth > 0 {
				opacity := p.water != nil ? f32(p.water[i * 4 + 3]) / 255 : 1
				g = g + (WET_GLOSS - g) * opacity
			} else if depth > -DAMP_BAND {
				damp := 1 + depth / DAMP_BAND // 1 at the water's edge, 0 at the band's
				g = max(g, g + (DAMP_GLOSS - g) * damp)
			}
		}
		mask.pixels[i] = u8(math.round(clamp(g, 0, 1) * 255))
	}
	return mask
}

// The normal mask: the ground's surface normal at each map pixel, as RGB,
// each channel 0-255 for -1..1 (x to the right, y down the map as its rows
// run, z up), flat ground (128, 128, 255). From the heights, with the
// canopy's raise, by central differences, unsmoothed: the recovered
// heights' grain shows in it. Provisional: if a light picks that out as
// noise, smooth the surface before differencing. The lighting uses it to
// shade the ground by where a light is, and to place a highlight with the
// specular mask. Exported with the map as the level's `layers.normal`.
normal_mask_make :: proc(p: ^Project, allocator := context.allocator) -> Picture {
	w, l := p.width, p.length
	mask := picture_make(w, l, 3, 8, allocator)
	surface := make([]f32, w * l, context.temp_allocator)
	for i in 0 ..< w * l {
		surface[i] = p.heights[i]
		if p.canopy != nil {
			surface[i] += p.canopy_height * f32(p.canopy[i]) / 255
		}
	}
	for y in 0 ..< l {
		for x in 0 ..< w {
			dx := (surface[y * w + min(x + 1, w - 1)] - surface[y * w + max(x - 1, 0)]) / 2
			dy := (surface[min(y + 1, l - 1) * w + x] - surface[max(y - 1, 0) * w + x]) / 2
			inv := 1 / math.sqrt(dx * dx + dy * dy + 1)
			n := [3]f32{-dx * inv, -dy * inv, inv}
			px := mask.pixels[(y * w + x) * 3:][:3]
			for k in 0 ..< 3 {
				px[k] = u8(math.round((n[k] * 0.5 + 0.5) * 255))
			}
		}
	}
	return mask
}
