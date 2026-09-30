package terrain_tool

// Level projects from the command line (Stage 5 of
// notes/level-editor-plan.md), through a hidden window:
//
//   terrain render  <project> <out> [-output=lit|albedo|normal|height|shadow|all] [-scale=N] [-quantise] [-from=ROW] [-to=ROW] [-smoothing=SIGMA]
//   terrain compare <project> [<original.png> <mask.png>] [-images=DIR] [-out=side.png] [-from=ROW] [-to=ROW] [-fit] [-smoothing=SIGMA]
//
// render writes <out>.png, or <out>.<output>.png for each with -output=all.
// compare finds the original map and mask by the level's image ids in
// -images when they are not named.
// compare draws the project lit and finds the shadows in it and in the
// original as the findings did; it prints how well they overlap, how dark
// each one's shadow is, and with -fit the sun azimuth whose shadows fit the
// original's best, and writes original | render | overlap side by side.
// -smoothing is the geometry's smoothing, a Gaussian's sigma in map pixels
// (terrain.GEOMETRY_SMOOTHING when not given; 0 for none).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

main :: proc() {
	args := os.args[1:]
	flags := make(map[string]string, context.temp_allocator)
	plain := make([dynamic]string, context.temp_allocator)
	for a in args {
		if strings.has_prefix(a, "-") {
			k, _, v := strings.partition(a[1:], "=")
			flags[k] = v
		} else {
			append(&plain, a)
		}
	}
	if len(plain) < 1 || (plain[0] == "render" && len(plain) != 3) || (plain[0] == "compare" && len(plain) != 2 && len(plain) != 4) {
		fmt.eprintln("usage: terrain render <project> <out> [-output=lit|albedo|normal|height|shadow|all] [-scale=N] [-quantise] [-from=ROW] [-to=ROW] [-smoothing=SIGMA]")
		fmt.eprintln("       terrain compare <project> [<original.png> <mask.png>] [-images=DIR] [-out=side.png] [-from=ROW] [-to=ROW] [-fit] [-smoothing=SIGMA]")
		os.exit(2)
	}
	p, ok := terrain.project_load(plain[1])
	if !ok {
		fmt.eprintfln("terrain: cannot load %s", plain[1])
		os.exit(1)
	}
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(64, 64, "terrain")
	if !rl.IsWindowReady() {
		fmt.eprintln("terrain: no GL context (run it under xvfb-run)")
		os.exit(1)
	}
	defer rl.CloseWindow()
	smoothing := f32(terrain.GEOMETRY_SMOOTHING)
	if v, given := flags["smoothing"]; given {
		f, parsed := strconv.parse_f32(v)
		if !parsed || f < 0 {
			fmt.eprintfln("terrain: -smoothing=%s is not a sigma", v)
			os.exit(2)
		}
		smoothing = f
	}
	r: terrain.Renderer
	if !terrain.renderer_init(&r, &p, smoothing) {
		fmt.eprintln("terrain: the shader did not compile")
		os.exit(1)
	}
	defer terrain.renderer_destroy(&r)
	number :: proc(flags: map[string]string, name: string) -> int {
		v, _ := strconv.parse_int(flags[name] or_else "0")
		return v
	}
	o := terrain.Render_Options {
		scale         = number(flags, "scale"),
		from          = number(flags, "from"),
		to            = number(flags, "to"),
		quantise_1555 = "quantise" in flags,
	}
	switch plain[0] {
	case "render":
		os.exit(render(&r, &p, o, plain[2], flags["output"] or_else "lit") ? 0 : 1)
	case "compare":
		original, mask: string
		if len(plain) == 4 {
			original, mask = plain[2], plain[3]
		} else {
			images := flags["images"] or_else "."
			original = fmt.tprintf("%s/%s.png", images, p.level.background_image)
			mask = fmt.tprintf("%s/%s.png", images, p.level.media_mask)
		}
		os.exit(compare(&r, &p, o, original, mask, flags["out"] or_else "", "fit" in flags) ? 0 : 1)
	case:
		fmt.eprintfln("terrain: no command %s", plain[0])
		os.exit(2)
	}
}

render :: proc(r: ^terrain.Renderer, p: ^terrain.Project, o: terrain.Render_Options, out, which: string) -> bool {
	o := o
	for output in terrain.Output {
		name := strings.to_lower(fmt.tprint(output), context.temp_allocator)
		if which != "all" && which != name {
			continue
		}
		o.output = output
		pic, ok := terrain.render(r, p, o)
		if !ok {
			fmt.eprintfln("terrain: cannot draw %s", name)
			return false
		}
		defer terrain.picture_destroy(&pic)
		path := which == "all" ? fmt.tprintf("%s.%s.png", out, name) : fmt.tprintf("%s.png", out)
		if !terrain.png_write(path, pic) {
			fmt.eprintfln("terrain: cannot write %s", path)
			return false
		}
		fmt.println("wrote", path)
	}
	return true
}

compare :: proc(r: ^terrain.Renderer, p: ^terrain.Project, o: terrain.Render_Options, original_path, mask_path, out: string, fit: bool) -> bool {
	o := o
	o.scale = 1
	original, ok := terrain.picture_load(original_path, 3)
	if !ok || original.width != p.width || original.height != p.length || original.depth != 8 {
		fmt.eprintfln("terrain: %s is not a %dx%d image", original_path, p.width, p.length)
		return false
	}
	mask, mok := terrain.picture_load(mask_path, 3)
	if !mok {
		fmt.eprintfln("terrain: cannot load %s", mask_path)
		return false
	}
	to := o.to > 0 ? min(o.to, p.length) : p.length
	from := clamp(o.from, 0, to)
	o.from, o.to = from, to
	cell := max(p.width / max(mask.width, 1), 1)
	water_all := terrain.water_from_mask(mask, p.width, p.length, cell)
	w, h := p.width, to - from
	water := water_all[from * w:][:w * h]
	orig := terrain.Picture{w, h, 3, 8, original.pixels[from * w * 3:][:w * h * 3]}

	o.output = .Lit
	lit, lok := terrain.render(r, p, o)
	if !lok {
		return false
	}
	theirs := terrain.detect_shadows(orig, water)
	ours := terrain.detect_shadows(lit, water)
	fmt.printfln("rows %d-%d, sun azimuth %.0f, elevation %.0f", from, to, p.level.lighting.sun_azimuth_degrees, p.level.lighting.sun_elevation_degrees)
	fmt.printfln("shadow IoU %.3f (original %.1f%% of the land, render %.1f%%)", terrain.iou(theirs.shadow, ours.shadow, water), share(theirs.shadow, water), share(ours.shadow, water))
	fmt.printfln("shadow light: original %.2f, render %.2f of the ground around", terrain.shadow_ratio(theirs), terrain.shadow_ratio(ours))

	if fit {
		lighting := p.level.lighting
		defer p.level.lighting = lighting
		best, best_iou := f32(0), f32(-1)
		o.output = .Shadow
		for az := f32(20); az <= 52; az += 2 {
			p.level.lighting.sun_azimuth_degrees = az
			vis, vok := terrain.render(r, p, o, context.temp_allocator)
			if !vok {
				return false
			}
			shaded := make([]bool, w * h, context.temp_allocator)
			for v, i in vis.pixels {
				shaded[i] = v < 128 && !water[i]
			}
			if u := terrain.iou(theirs.shadow, shaded, water); u > best_iou {
				best, best_iou = az, u
			}
		}
		fmt.printfln("fitted azimuth %.0f (cast-shadow IoU %.3f)", best, best_iou)
	}

	if out != "" {
		side := terrain.picture_make(w * 3, h, 3, 8, context.temp_allocator)
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := y * w + x
				copy(side.pixels[(y * w * 3 + x) * 3:][:3], orig.pixels[i * 3:][:3])
				copy(side.pixels[(y * w * 3 + w + x) * 3:][:3], lit.pixels[i * 3:][:3])
				// Both in shadow white, the original's only red, the render's only blue.
				c := [3]u8{40, 40, 40}
				switch {
				case water[i]:
					c = {20, 30, 70}
				case theirs.shadow[i] && ours.shadow[i]:
					c = {255, 255, 255}
				case theirs.shadow[i]:
					c = {230, 50, 40}
				case ours.shadow[i]:
					c = {60, 110, 255}
				}
				copy(side.pixels[(y * w * 3 + 2 * w + x) * 3:][:3], c[:])
			}
		}
		if !terrain.png_write(out, side) {
			fmt.eprintfln("terrain: cannot write %s", out)
			return false
		}
		fmt.println("wrote", out)
	}
	return true
}

share :: proc(m, water: []bool) -> f32 {
	n, land := 0, 0
	for s, i in m {
		if !water[i] {
			land += 1
			n += int(s)
		}
	}
	return land > 0 ? 100 * f32(n) / f32(land) : 0
}
