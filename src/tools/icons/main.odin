// Composites icons out of the extracted sprites: easy mode's passive icons
// (docs/passive-upgrades.md), and any new icon a recipe describes.
//
//   icons <recipe.json> <assets root> <out dir>
//
// A recipe is a canvas size and a list of icons, each a stack of layers drawn
// bottom first. A layer is one frame of a sprite plate (sprites/index.json),
// scaled so its longer side is `fit` pixels (its own size when fit is left
// out), centred on (x, y) (the canvas centre when left out), optionally
// flipped, and faded to `alpha`:
//
//   {"size": 32, "icons": [
//     {"name": "shield_regen", "layers": [
//       {"sprite": "pish", "frame": 0, "fit": 28, "x": 15, "y": 15},
//       {"sprite": "edut", "frame": 1, "fit": 11, "x": 26, "y": 26}]}]}
//
// Each icon is written to <out dir>/<name>.png. The game finds a passive's
// icon by its sim.Passive name in lower case, so a new passive needs only a
// recipe entry of that name and `mise run assets:icons`.
//
// Only raylib's CPU-side image functions are used: no window, no audio
// device, so it is safe to run headless. The output is derived entirely from
// the extracted sprites, and regenerable from them.
package icons

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

Layer :: struct {
	sprite: string,
	frame:  int,
	fit:    Maybe(f32),
	x:      Maybe(f32),
	y:      Maybe(f32),
	alpha:  Maybe(f32),
	flip_x: bool,
	flip_y: bool,
}

Icon :: struct {
	name:   string,
	layers: []Layer,
}

Recipe :: struct {
	size:  int,
	icons: []Icon,
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: icons <recipe.json> <assets root> <out dir>")
		os.exit(2)
	}
	recipe_path, root, out_dir := os.args[1], os.args[2], os.args[3]
	rl.SetTraceLogLevel(.WARNING)

	text, read_err := os.read_entire_file(recipe_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("icons: cannot read %s: %v", recipe_path, read_err)
		os.exit(1)
	}
	recipe: Recipe
	if err := json.unmarshal(text, &recipe); err != nil {
		fmt.eprintfln("icons: %s: %v", recipe_path, err)
		os.exit(1)
	}
	if recipe.size <= 0 {
		fmt.eprintfln("icons: %s: size must be positive", recipe_path)
		os.exit(1)
	}
	assets := data.assets_open(root)
	if len(assets.sprites) == 0 {
		fmt.eprintfln("icons: no sprites under %s (run mise run assets:all first)", root)
		os.exit(1)
	}
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		fmt.eprintfln("icons: cannot create %s: %v", out_dir, err)
		os.exit(1)
	}

	// Each plate is loaded once, however many layers use it.
	plates := make(map[sim.Res_ID]rl.Image)
	defer for _, im in plates {
		rl.UnloadImage(im)
	}
	failed := false
	for &icon in recipe.icons {
		canvas := rl.GenImageColor(i32(recipe.size), i32(recipe.size), rl.BLANK)
		defer rl.UnloadImage(canvas)
		ok := true
		for &l in icon.layers {
			if !draw_layer(&canvas, &assets, &plates, root, &l, f32(recipe.size)) {
				fmt.eprintfln("icons: %s: no frame %d of sprite %q", icon.name, l.frame, l.sprite)
				ok = false
			}
		}
		path := fmt.ctprintf("%s/%s.png", out_dir, icon.name)
		if !ok || !rl.ExportImage(canvas, path) {
			failed = true
			continue
		}
		fmt.println("wrote", path)
	}
	if failed {
		os.exit(1)
	}
}

draw_layer :: proc(canvas: ^rl.Image, assets: ^data.Assets, plates: ^map[sim.Res_ID]rl.Image, root: string, l: ^Layer, size: f32) -> bool {
	id := sim.res_id(strings.to_lower(l.sprite, context.temp_allocator))
	plate: ^data.Sprite_Plate
	for &p in assets.sprites {
		if p.id == id {
			plate = &p
		}
	}
	if plate == nil || l.frame < 0 || l.frame >= len(plate.frames) {
		return false
	}
	sheet, loaded := plates[id]
	if !loaded {
		sheet = rl.LoadImage(fmt.ctprintf("%s/%s", root, plate.image))
		if sheet.data == nil {
			return false
		}
		rl.ImageFormat(&sheet, .UNCOMPRESSED_R8G8B8A8)
		plates[id] = sheet
	}
	f := plate.frames[l.frame]
	src := rl.ImageFromImage(sheet, {f32(f.x), f32(f.y), f32(f.w), f32(f.h)})
	defer rl.UnloadImage(src)
	if l.flip_x {
		rl.ImageFlipHorizontal(&src)
	}
	if l.flip_y {
		rl.ImageFlipVertical(&src)
	}
	w, h := f32(f.w), f32(f.h)
	if fit, ok := l.fit.?; ok {
		k := fit / max(w, h)
		w, h = max(math.round(w * k), 1), max(math.round(h * k), 1)
		rl.ImageResize(&src, i32(w), i32(h))
	}
	cx, cy := l.x.? or_else size / 2, l.y.? or_else size / 2
	alpha := clamp(l.alpha.? or_else 1, 0, 1)
	tint := rl.Color{255, 255, 255, u8(math.round(alpha * 255))}
	at := rl.Rectangle{math.round(cx - w / 2), math.round(cy - h / 2), w, h}
	rl.ImageDraw(canvas, src, {0, 0, w, h}, at, tint)
	return true
}
