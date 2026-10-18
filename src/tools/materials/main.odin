package materials_tool

// The level editor's material library (Stage 8 of
// notes/level-editor-plan.md), quilted from the recovered levels' unlit
// colour:
//
//   materials <recipe.json> <recovered dir> <out dir>
//
// For each of the recipe's materials, the most uniform exemplar-sized
// window inside its box of its level's albedo layer
// (<recovered>/<level>/<level>.albedo.png) is quilted into a tiling image,
// <out>/<image>, and listed in <out>/index.json with where it came from,
// tagged original-derived. `mise run materials:library` writes
// assets/materials, where the editor looks.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

Recipe :: struct {
	exemplar:  int `json:"exemplar"`, // the window quilted from, square
	cell:      int `json:"cell"`,     // uniform_window's blocks
	size:      int `json:"size"`,
	block:     int `json:"block"`,
	overlap:   int `json:"overlap"`,
	materials: []Recipe_Material `json:"materials"`,
}

Recipe_Material :: struct {
	name:  string `json:"name"`,
	image: string `json:"image"`,
	level: string `json:"level"`,
	box:   [4]int `json:"box"`, // x0, y0, x1, y1 in map pixels: where to look
	tile:  f32    `json:"tile"`,
	// Its own exemplar's size, when the recipe's is too small to hold
	// enough of it: the jungle's trees repeat in 128.
	exemplar: int `json:"exemplar"`,
}

// As the editor reads it (editor/materials.odin's Library_Entry).
Entry :: struct {
	name:   string   `json:"name"`,
	image:  string   `json:"image"`,
	colour: [3]u8    `json:"colour"`,
	tile:   f32      `json:"tile"`,
	tags:   []string `json:"tags"`,
	source: string   `json:"source"`,
}

Index :: struct {
	format:    string  `json:"format"`,
	materials: []Entry `json:"materials"`,
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: materials <recipe.json> <recovered dir> <out dir>")
		os.exit(2)
	}
	recipe_path, recovered, out := os.args[1], os.args[2], os.args[3]
	blob, err := os.read_entire_file(recipe_path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("materials: cannot read %s", recipe_path)
		os.exit(1)
	}
	r: Recipe
	if json.unmarshal(blob, &r) != nil {
		fmt.eprintfln("materials: %s is not a recipe", recipe_path)
		os.exit(1)
	}
	rl.SetTraceLogLevel(.WARNING) // png_write deflates through raylib
	os.make_directory_all(out)
	opts := terrain.QUILT_DEFAULT
	opts.size, opts.block, opts.overlap = r.size, r.block, r.overlap
	entries := make([dynamic]Entry)
	albedos := make(map[string]terrain.Picture)
	for m, i in r.materials {
		albedo, have := albedos[m.level]
		if !have {
			path := fmt.tprintf("%s/%s/%s.albedo.png", recovered, m.level, m.level)
			ok: bool
			if albedo, ok = terrain.picture_load(path, 3); !ok {
				fmt.eprintfln("materials: cannot read %s (terrain:recover-all makes it)", path)
				os.exit(1)
			}
			albedos[m.level] = albedo
		}
		size := m.exemplar > 0 ? m.exemplar : r.exemplar
		x, y, spread, found := terrain.uniform_window(albedo, {m.box[0], m.box[1], m.box[2], m.box[3]}, size, r.cell)
		if !found {
			fmt.eprintfln("materials: %s: its box is smaller than the exemplar", m.name)
			os.exit(1)
		}
		exemplar := terrain.picture_crop(albedo, x, y, size, size, context.temp_allocator)
		opts.seed = u64(i + 1)
		img, ok := terrain.quilt(exemplar, opts, context.temp_allocator)
		if !ok {
			fmt.eprintfln("materials: the recipe's size, block and overlap do not fit")
			os.exit(1)
		}
		full := strings.concatenate({out, "/", m.image}, context.temp_allocator)
		if !terrain.png_write(full, img) {
			fmt.eprintfln("materials: cannot write %s", full)
			os.exit(1)
		}
		source := fmt.aprintf("%s %d,%d %dx%d", m.level, x, y, size, size)
		append(&entries, Entry{m.name, m.image, {255, 255, 255}, m.tile, {"original-derived"}, source})
		fmt.printfln("%-12s %s  spread %.1f", m.name, source, spread)
		free_all(context.temp_allocator)
	}
	index, merr := json.marshal(Index{"deimos-rising.material-library", entries[:]}, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil || os.write_entire_file(strings.concatenate({out, "/index.json"}), index) != nil {
		fmt.eprintfln("materials: cannot write %s/index.json", out)
		os.exit(1)
	}
	fmt.printfln("wrote %d materials to %s", len(entries), out)
}
