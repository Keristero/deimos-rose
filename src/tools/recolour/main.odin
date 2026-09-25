// Recolours extracted sprite plates into new ones, for new content that
// wants the game's own art in another colour: the Chaingun's dark grey
// ships are the Bacta Gun's green ones (docs/new-weapons.md).
//
//   recolour <recipe.json> <assets root>
//
// A recipe lists plates to write. Each takes a plate of sprites/index.json,
// and every pixel whose hue lies in [hue_min, hue_max] (degrees) has its
// saturation and value scaled; everything else, and the alpha, is kept:
//
//   {"plates": [
//     {"from": "PL1G", "to": "PL1K", "hue_min": 70, "hue_max": 170,
//      "saturation": 0.1, "value": 0.6}]}
//
// Each plate is written to <assets root>/extra/sprites/im08/<to>.png, with
// the source's frames, and all of them are listed in
// <assets root>/extra/sprites/index.json, which data.assets_open and
// data.extra_defs_load read beside the game's own index.
//
// Only raylib's CPU-side image functions are used: no window, no audio
// device, so it is safe to run headless. The output is derived entirely from
// the extracted sprites, and regenerable from them.
package recolour

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"

Plate :: struct {
	from:       string,
	to:         string,
	hue_min:    f32,
	hue_max:    f32,
	saturation: f32,
	value:      f32,
}

Recipe :: struct {
	plates: []Plate,
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: recolour <recipe.json> <assets root>")
		os.exit(2)
	}
	recipe_path, root := os.args[1], os.args[2]
	rl.SetTraceLogLevel(.WARNING)

	text, read_err := os.read_entire_file(recipe_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("recolour: cannot read %s: %v", recipe_path, read_err)
		os.exit(1)
	}
	recipe: Recipe
	if err := json.unmarshal(text, &recipe); err != nil {
		fmt.eprintfln("recolour: %s: %v", recipe_path, err)
		os.exit(1)
	}
	index_text, index_err := os.read_entire_file(fmt.tprintf("%s/sprites/index.json", root), context.allocator)
	index: data.Json_Sprite_Index
	if index_err != nil || json.unmarshal(index_text, &index) != nil {
		fmt.eprintfln("recolour: no sprites under %s (run mise run assets:all first)", root)
		os.exit(1)
	}
	out_dir := fmt.tprintf("%s/extra/sprites/im08", root)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		fmt.eprintfln("recolour: cannot create %s: %v", out_dir, err)
		os.exit(1)
	}

	written := make([dynamic]data.Json_Sprite)
	for &p in recipe.plates {
		src: ^data.Json_Sprite
		for &s in index.sprites {
			if strings.equal_fold(s.fourcc, p.from) {
				src = &s
			}
		}
		if src == nil {
			fmt.eprintfln("recolour: no plate %q", p.from)
			os.exit(1)
		}
		im := rl.LoadImage(fmt.ctprintf("%s/%s", root, src.image))
		if im.data == nil {
			fmt.eprintfln("recolour: cannot load %s", src.image)
			os.exit(1)
		}
		defer rl.UnloadImage(im)
		rl.ImageFormat(&im, .UNCOMPRESSED_R8G8B8A8)
		px := ([^]rl.Color)(im.data)[:im.width * im.height]
		for &c in px {
			c = recolour(c, &p)
		}
		image := fmt.aprintf("extra/sprites/im08/%s.png", p.to)
		if !rl.ExportImage(im, fmt.ctprintf("%s/%s", root, image)) {
			fmt.eprintfln("recolour: cannot write %s", image)
			os.exit(1)
		}
		fmt.println("wrote", image)
		out := src^
		out.fourcc = p.to
		out.image = image
		append(&written, out)
	}

	listing := data.Json_Sprite_Index{sprites = written[:]}
	blob, err := json.marshal(listing, {pretty = true, use_spaces = true, spaces = 4})
	if err != nil {
		fmt.eprintfln("recolour: %v", err)
		os.exit(1)
	}
	path := fmt.tprintf("%s/extra/sprites/index.json", root)
	if write_err := os.write_entire_file(path, blob); write_err != nil {
		fmt.eprintfln("recolour: cannot write %s: %v", path, write_err)
		os.exit(1)
	}
	fmt.println("wrote", path)
}

// A pixel in the plate's hue band, faded towards grey and darkened.
recolour :: proc(c: rl.Color, p: ^Plate) -> rl.Color {
	if c.a == 0 {
		return c
	}
	hsv := rl.ColorToHSV(c)
	if hsv.y < 0.05 || hsv.x < p.hue_min || hsv.x > p.hue_max {
		return c // grey already, or not in the band
	}
	out := rl.ColorFromHSV(hsv.x, clamp(hsv.y * p.saturation, 0, 1), clamp(hsv.z * p.value, 0, 1))
	out.a = c.a
	return out
}
