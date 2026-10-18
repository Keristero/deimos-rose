package bases_tool

// Which units' bases the original maps have baked in (Stage 8 of
// notes/level-editor-plan.md), and what those bases look like:
//
//   bases <out dir>
//
// The original drew a structure's base into the map's render and the
// runtime sprite on top of it (making-of; findings). For every ground
// placement of the twelve levels this crops the map under the unit, and
// groups the crops by unit type. Where a type's crops correlate with one
// another far more than crops of the ground beside them, the map has its
// base baked in; the crops' median, where they agree, is that base.
//
// What it found (docs/level-editor.md, Stage 8, has the table):
// - A ground placement's x is the map's column, as spawn.odin reads it:
//   crops at x - 32 (sim.GROUND_PLACEMENT_SHIFT) correlate less for 11 of
//   the 12 types with one base; the hospital's pad is so wide that a crop
//   32 along still holds most of it. A few score higher there because a
//   crop half on a pad's edge and shadow, or on the same kind of slope
//   (the bonus stations sit on dune edges), lines up; by eye, the pads
//   are centred on x.
// - A base does not turn with its unit's heading: the hospital's two
//   agree unturned at different headings, and turning the crops back by
//   their headings makes every type agree less. The laser base's, the
//   laser platform's and the twin gun's pads are baked but at angles of
//   their own, so no one image is theirs; they are left out.
//
// `mise run levels:bases` writes assets/bases, where the editor looks, and
// prints the table.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:editor"
import "dr:sim"
import "dr:terrain"

// A crop is the unit's frame and this much ground on every side: a base
// may reach past its sprite (a pad, a shadow).
MARGIN :: 8
// Two crops agree at a pixel within this share of their brightness's
// spread.
Z_TOLERANCE :: 0.5
// A pixel is the base's where this share of the pairs of crops agree
// around it (SMOOTH either way), or it is inside such pixels.
KEEP :: 0.5
SMOOTH :: 2
// A type's base is baked where its crops agree this much, and by this
// much more than the ground beside them. Provisional: set from the table
// this tool prints (docs/level-editor.md), where the two groups are far
// apart.
BAKED_AGREEMENT :: 0.5
BAKED_OVER_BESIDE :: 0.25

Site :: struct {
	level:   int, // in maps
	x, y:    int, // the record's
	heading: int,
}

Base :: struct {
	unit:       string,
	image:      string,
	size:       [2]int, // the image's; centred on the placement's point
	placements: int,
	agreement:  f32,
	beside:     f32,
}

Index :: struct {
	format: string,
	bases:  []Base,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: bases <out dir>")
		os.exit(2)
	}
	out := os.args[1]
	declared, _ := data.plugins_discover(data.plugins_roots())
	sim.plugins_declare(declared)
	sim.register_all()
	root := os.get_env("DR_ASSETS", context.temp_allocator)
	if root == "" {
		root = "assets"
	}
	units: editor.Catalogue
	editor.catalogue_load(&units, root)
	classic, found := data.classic_levels_dir()
	if !found || len(units.defs.units) == 0 {
		fmt.eprintfln("bases: needs the assets tree (%s) and the Classic Levels plugin", root)
		os.exit(1)
	}
	rl.SetTraceLogLevel(.WARNING) // png_write deflates through raylib

	records, _ := filepath.glob(strings.concatenate({classic, "/data/levels/le*.json"}))
	slice.sort(records)
	maps := make([dynamic]terrain.Picture)
	names := make([dynamic]string)
	sites := make(map[string][dynamic]Site)
	for path in records {
		blob, err := os.read_entire_file(path, context.allocator)
		level: data.Json_Level
		if err != nil || json.unmarshal(blob, &level) != nil {
			fmt.eprintfln("bases: cannot read %s", path)
			os.exit(1)
		}
		pic, ok := terrain.picture_load(fmt.tprintf("%s/images/im16/%s.png", classic, level.background_image), 3)
		if !ok {
			fmt.eprintfln("bases: %s: no map %s", level.id, level.background_image)
			os.exit(1)
		}
		append(&maps, pic)
		append(&names, level.id)
		for pl in level.placements {
			if !editor.placement_ground(&units, pl) {
				continue
			}
			if pl.unit not_in sites {
				sites[pl.unit] = make([dynamic]Site)
			}
			append(&sites[pl.unit], Site{len(maps) - 1, pl.x, pl.y, pl.heading_degrees})
		}
	}

	ids := make([dynamic]string)
	for id in sites {
		append(&ids, id)
	}
	slice.sort(ids[:])
	os.make_directory_all(out)
	bases := make([dynamic]Base)
	fmt.println("| Unit | Name | Placed | At x | At x - 32 | Beside | |")
	fmt.println("|---|---|---|---|---|---|---|")
	for id in ids {
		list := sites[id][:]
		u := editor.catalogue_unit(&units, id)
		if u == nil {
			continue
		}
		sprite, frame := editor.unit_look(u, list[0].heading)
		frame_size, ok := editor.catalogue_frame_size(&units, sprite, frame)
		if !ok {
			continue
		}
		size := [2]int{int(frame_size.x) + 2 * MARGIN, int(frame_size.y) + 2 * MARGIN}
		if len(list) < 2 {
			continue // one crop agrees with nothing: undecided
		}
		at, _, _ := agreement(maps[:], list, size, 0, 0)
		shifted, _, _ := agreement(maps[:], list, size, -sim.GROUND_PLACEMENT_SHIFT, 0)
		// The ground beside, a crop's width to the right, or the left at
		// the map's edge: the same kind of ground, without the unit.
		beside, _, _ := agreement(maps[:], list, size, 0, size.x)
		baked := at >= BAKED_AGREEMENT && at - beside >= BAKED_OVER_BESIDE
		fmt.printfln("| `%s` | %s | %d | %.2f | %.2f | %.2f | %s |", id, u.name, len(list), at, shifted, beside, baked ? "**baked**" : "")
		if !baked {
			continue
		}
		_, share, median := agreement(maps[:], list, size, 0, 0)
		keep := footprint(share, size)
		pic := terrain.picture_make(size.x, size.y, 4, 8)
		for k in 0 ..< size.x * size.y {
			copy(pic.pixels[k * 4:][:3], median[k * 3:][:3])
			pic.pixels[k * 4 + 3] = keep[k] ? 255 : 0
		}
		image := strings.concatenate({strings.to_lower(id), ".png"})
		if !terrain.png_write(strings.concatenate({out, "/", image}, context.temp_allocator), pic) {
			fmt.eprintfln("bases: cannot write %s/%s", out, image)
			os.exit(1)
		}
		append(&bases, Base{id, image, size, len(list), at, beside})
	}
	index, merr := json.marshal(Index{"deimos-rising.bases", bases[:]}, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil || os.write_entire_file(strings.concatenate({out, "/index.json"}), index) != nil {
		fmt.eprintfln("bases: cannot write %s/index.json", out)
		os.exit(1)
	}
	fmt.printfln("%d of %d ground types baked; wrote %s", len(bases), len(ids), out)
}

// How alike the crops of `sites` are, centred dx right of each. Each crop's
// brightness is taken relative to its own mean and spread: the base is
// drawn in each map's light and tint, on desert as on grass, so its
// colours differ where its shapes do not. The score is the mean, over the
// pairs of crops, of their correlation over the unit's frame (inside the
// margin): 1 alike, 0 unrelated. Each pixel's share is of the pairs that
// agree there within Z_TOLERANCE of the spread. With the crops' median
// colour. A crop over the map's edge is left out, and moved to the other
// side when `beside` asks for the ground a crop along.
agreement :: proc(maps: []terrain.Picture, sites: []Site, size: [2]int, dx, beside: int) -> (score: f32, share: []f32, median: []u8) {
	crops := make([dynamic][]u8, context.temp_allocator)
	for s in sites {
		m := maps[s.level]
		centre := [2]int{s.x + dx, s.y}
		if beside != 0 {
			centre.x += centre.x + beside + size.x / 2 <= m.width ? beside : -beside
		}
		if c, ok := crop(m, centre, size); ok {
			append(&crops, c)
		}
	}
	n, count := len(crops), size.x * size.y
	share = make([]f32, count, context.temp_allocator)
	median = make([]u8, count * 3, context.temp_allocator)
	if n < 2 {
		return
	}
	inside :: proc(k: int, size: [2]int) -> bool {
		x, y := k % size.x, k / size.x
		return x >= MARGIN && x < size.x - MARGIN && y >= MARGIN && y < size.y - MARGIN
	}
	// Each crop's brightness in its own spreads from its mean.
	z := make([][]f32, n, context.temp_allocator)
	for c, i in crops {
		z[i] = make([]f32, count, context.temp_allocator)
		mean := f32(0)
		for k in 0 ..< count {
			z[i][k] = 0.299 * f32(c[k * 3]) + 0.587 * f32(c[k * 3 + 1]) + 0.114 * f32(c[k * 3 + 2])
			mean += z[i][k]
		}
		mean /= f32(count)
		spread := f32(0)
		for &v in z[i] {
			v -= mean
			spread += v * v
		}
		spread = max(math.sqrt(spread / f32(count)), 1)
		for &v in z[i] {
			v /= spread
		}
	}
	pairs := 0
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			ab, aa, bb := f32(0), f32(0), f32(0)
			for k in 0 ..< count {
				if inside(k, size) {
					ab += z[i][k] * z[j][k]
					aa += z[i][k] * z[i][k]
					bb += z[j][k] * z[j][k]
				}
			}
			score += ab / max(math.sqrt(aa * bb), 1e-6)
			pairs += 1
		}
	}
	values := make([]u8, n, context.temp_allocator)
	for k in 0 ..< count {
		for ch in 0 ..< 3 {
			for c, i in crops {
				values[i] = c[k * 3 + ch]
			}
			slice.sort(values)
			median[k * 3 + ch] = values[n / 2]
		}
		agree := 0
		for i in 0 ..< n {
			for j in i + 1 ..< n {
				if abs(z[i][k] - z[j][k]) <= Z_TOLERANCE {
					agree += 1
				}
			}
		}
		share[k] = f32(agree) / f32(pairs)
	}
	return score / f32(pairs), share, median
}

// The size window of `m` centred on `centre`; ok false where it reaches
// past the map.
crop :: proc(m: terrain.Picture, centre: [2]int, size: [2]int) -> (pixels: []u8, ok: bool) {
	x0, y0 := centre.x - size.x / 2, centre.y - size.y / 2
	if x0 < 0 || y0 < 0 || x0 + size.x > m.width || y0 + size.y > m.height {
		return
	}
	return terrain.picture_crop(m, x0, y0, size.x, size.y, context.temp_allocator).pixels, true
}

// Which pixels are the base's: where the pairs agree, over a box SMOOTH
// either way, since an edge or a dark hole agrees less pixel by pixel;
// and whatever those enclose, which the ground beyond cannot reach
// without crossing them.
footprint :: proc(share: []f32, size: [2]int) -> []bool {
	keep := make([]bool, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			sum, n := f32(0), 0
			for v in max(y - SMOOTH, 0) ..= min(y + SMOOTH, size.y - 1) {
				for u in max(x - SMOOTH, 0) ..= min(x + SMOOTH, size.x - 1) {
					sum += share[v * size.x + u]
					n += 1
				}
			}
			keep[y * size.x + x] = sum / f32(n) >= KEEP
		}
	}
	// The ground: every pixel not kept that the crop's border reaches.
	ground := make([]bool, size.x * size.y, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			if x == 0 || y == 0 || x == size.x - 1 || y == size.y - 1 {
				append(&stack, y * size.x + x)
			}
		}
	}
	for len(stack) > 0 {
		k := pop(&stack)
		if ground[k] || keep[k] {
			continue
		}
		ground[k] = true
		x, y := k % size.x, k / size.x
		if x > 0 do append(&stack, k - 1)
		if x < size.x - 1 do append(&stack, k + 1)
		if y > 0 do append(&stack, k - size.x)
		if y < size.y - 1 do append(&stack, k + size.x)
	}
	for &k, i in keep {
		k = !ground[i]
	}
	return keep
}
