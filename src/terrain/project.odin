package terrain

// A level project: what the level editor saves, and what the renderer
// draws. `<name>.drproj.json` beside its side files: the heightmap as a
// 16-bit PNG, and optionally the unlit colour, the material weights, the
// canopy, the occlusion and the water, each one PNG pixel per map pixel. The level's own record (its
// placements, lighting, water and wind, D54) is inside, as the game reads
// it. Maps, masks and previews are exports of a project, not part of it.

import "core:encoding/json"
import "core:image"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:strings"

import "dr:data"

PROJECT_FORMAT :: "deimos-rising.level-project"
PROJECT_VERSION :: 1
PROJECT_SUFFIX :: ".drproj.json"
// Heights are stored in 1/32 of a map pixel: up to 2048 pixels high.
HEIGHT_UNIT :: f32(1) / 32
// The highest a height can be stored.
HEIGHT_MAX :: 65535 * HEIGHT_UNIT
MAX_MATERIALS :: 4

// A material: a colour, or a tiling image tinted by it.
Material :: struct {
	name:   string   `json:"name"`,
	colour: [3]u8    `json:"colour"`,
	image:  string   `json:"image"`, // beside the project; empty for flat colour
	tile:   f32      `json:"tile"`,  // map pixels the image covers
	tags:   []string `json:"tags"`,  // "original-derived" for one taken from the originals
}

// A material laid automatically where the ground is steep (slope in height
// per map pixel), or near water (height above the water, in map pixels):
// none below `from`, all of it past `to`. -1 for no material.
Rule :: struct {
	material: int `json:"material"`,
	from:     f32 `json:"from"`,
	to:       f32 `json:"to"`,
}

Project :: struct {
	width:     int,
	length:    int,
	// Terrain height per map pixel, in map pixels, rows from the map's top.
	heights:   []f32,
	// The unlit colour per map pixel (RGB), or nil: materials only.
	albedo:    []u8,
	// Each material's weight per map pixel (RGBA for materials 0-3), or nil.
	splat:     []u8,
	// Tree cover per map pixel, 0-255, or nil: raises the surface by up to
	// canopy_height and blends in canopy_material.
	canopy:          []u8,
	canopy_height:   f32,
	canopy_material: int,
	// How open to the sky each map pixel is, 0-255 (255 fully), or nil: all
	// open. It darkens only the ambient light. Baked, as the originals had
	// none of it: tools/terrain_occlusion infers it from the colour.
	occlusion:       []u8,
	// The water over the bed, where the surface is under the water level
	// (RGBA: the water's own unlit colour, and how opaque it is), or nil:
	// opaque, the level's water colour. tools/terrain_recover bakes it from
	// the originals, whose shallows show the sand through.
	water:           []u8,
	materials:       [dynamic]Material,
	material_images: [MAX_MATERIALS]Picture,
	cliff, shore:    Rule,
	level:           data.Json_Level,
}

// A new project: flat ground, the originals' light, no water.
project_make :: proc(width, length: int, allocator := context.allocator) -> (p: Project) {
	p.width, p.length = width, length
	p.heights = make([]f32, width * length, allocator)
	p.canopy_material = -1
	p.cliff.material, p.shore.material = -1, -1
	p.materials = make([dynamic]Material, allocator)
	p.level.background = {0, 0, width, length}
	p.level.lighting = data.LIGHTING_MEASURED
	return
}

// The file as JSON: Project's settings, with the side files by name.
@(private = "file")
Json_Project :: struct {
	format:          string          `json:"format"`,
	version:         int             `json:"version"`,
	width:           int             `json:"width"`,
	length:          int             `json:"length"`,
	height:          string          `json:"height"`,
	height_unit:     f32             `json:"height_unit"`,
	albedo:          string          `json:"albedo"`,
	splat:           string          `json:"splat"`,
	canopy:          string          `json:"canopy"`,
	canopy_height:   f32             `json:"canopy_height"`,
	canopy_material: int             `json:"canopy_material"`,
	occlusion:       string          `json:"occlusion"`,
	water:           string          `json:"water"`,
	materials:       []Material      `json:"materials"`,
	cliff:           Rule            `json:"cliff"`,
	shore:           Rule            `json:"shore"`,
	level:           data.Json_Level `json:"level"`,
}

// Saves to `path` (…/<name>.drproj.json) and its side files beside it,
// <name>.height.png and so on.
project_save :: proc(p: ^Project, path: string) -> bool {
	dir, stem := project_names(path)
	side :: proc(dir, stem, what: string) -> (name, full: string) {
		name = strings.concatenate({stem, ".", what, ".png"}, context.temp_allocator)
		return name, side_path(dir, name)
	}
	j := Json_Project {
		format          = PROJECT_FORMAT,
		version         = PROJECT_VERSION,
		width           = p.width,
		length          = p.length,
		height_unit     = HEIGHT_UNIT,
		canopy_height   = p.canopy_height,
		canopy_material = p.canopy_material,
		materials       = p.materials[:],
		cliff           = p.cliff,
		shore           = p.shore,
		level           = p.level,
	}
	full: string
	j.height, full = side(dir, stem, "height")
	h := picture_make(p.width, p.length, 1, 16, context.temp_allocator)
	h16 := slice.reinterpret([]u16, h.pixels)
	for v, i in p.heights {
		h16[i] = height_quantise(v)
	}
	if !png_write(full, h) {
		return false
	}
	layers := [?]struct {
		name:     string,
		pixels:   []u8,
		channels: int,
		out:      ^string,
	}{{"albedo", p.albedo, 3, &j.albedo}, {"splat", p.splat, 4, &j.splat}, {"canopy", p.canopy, 1, &j.canopy}, {"occlusion", p.occlusion, 1, &j.occlusion}, {"water", p.water, 4, &j.water}}
	for l in layers {
		if l.pixels == nil {
			continue
		}
		l.out^, full = side(dir, stem, l.name)
		if !png_write(full, {p.width, p.length, l.channels, 8, l.pixels}) {
			return false
		}
	}
	blob, err := json.marshal(j, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		return false
	}
	return os.write_entire_file(path, blob) == nil
}

// Loads a project and its side files, and each material's image.
project_load :: proc(path: string, allocator := context.allocator) -> (p: Project, ok: bool) {
	blob, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	j: Json_Project
	if json.unmarshal(blob, &j, allocator = allocator) != nil || j.format != PROJECT_FORMAT || j.version > PROJECT_VERSION {
		return
	}
	dir, _ := project_names(path)
	p = project_make(j.width, j.length, allocator)
	h := picture_load(side_path(dir, j.height), 1, context.temp_allocator) or_return
	if h.width != p.width || h.height != p.length || h.channels != 1 || h.depth != 16 {
		return
	}
	unit := j.height_unit > 0 ? j.height_unit : HEIGHT_UNIT
	for v, i in slice.reinterpret([]u16, h.pixels) {
		if i < len(p.heights) {
			p.heights[i] = f32(v) * unit
		}
	}
	side :: proc(dir, name: string, p: ^Project, channels: int, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
		if name == "" {
			return nil, true
		}
		pic := picture_load(side_path(dir, name), channels, allocator) or_return
		if pic.width != p.width || pic.height != p.length || pic.depth != 8 || pic.channels != channels {
			return nil, false
		}
		return pic.pixels, true
	}
	p.albedo = side(dir, j.albedo, &p, 3, allocator) or_return
	p.splat = side(dir, j.splat, &p, 4, allocator) or_return
	p.canopy = side(dir, j.canopy, &p, 1, allocator) or_return
	p.occlusion = side(dir, j.occlusion, &p, 1, allocator) or_return
	p.water = side(dir, j.water, &p, 4, allocator) or_return
	p.canopy_height, p.canopy_material = j.canopy_height, j.canopy_material
	append(&p.materials, ..j.materials)
	for m, i in p.materials[:min(len(p.materials), MAX_MATERIALS)] {
		if m.image != "" {
			p.material_images[i] = picture_load(side_path(dir, m.image), 0, allocator) or_return
		}
	}
	p.cliff, p.shore, p.level = j.cliff, j.shore, j.level
	return p, true
}

// A height as the heightmap stores it.
height_quantise :: proc "contextless" (v: f32) -> u16 {
	return u16(clamp(v / HEIGHT_UNIT + 0.5, 0, 65535))
}

// The directory and the name before .drproj.json.
@(private = "file")
project_names :: proc(path: string) -> (dir, stem: string) {
	i := strings.last_index_any(path, "/\\")
	dir, stem = i < 0 ? "." : path[:i], path[i + 1:]
	return dir, strings.trim_suffix(stem, PROJECT_SUFFIX)
}

@(private = "file")
side_path :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

// A PNG as a Picture with `channels` samples a pixel (0 for the file's
// own): grey from the first, colour without alpha or with it opaque.
// core:image hands grey back as RGB, so grey is asked for, not found.
picture_load :: proc(path: string, channels := 0, allocator := context.allocator) -> (p: Picture, ok: bool) {
	img, err := png.load_from_file(path, {}, context.temp_allocator)
	if err != nil {
		return
	}
	defer image.destroy(img, context.temp_allocator)
	want := channels > 0 ? channels : img.channels
	p = picture_make(img.width, img.height, want, img.depth, allocator)
	src := img.pixels.buf[:]
	if want == img.channels {
		copy(p.pixels, src)
		return p, true
	}
	sample := img.depth / 8
	for i in 0 ..< img.width * img.height {
		for c in 0 ..< want {
			d := p.pixels[(i * want + c) * sample:][:sample]
			if c < img.channels {
				copy(d, src[(i * img.channels + c) * sample:][:sample])
			} else {
				for &b in d {
					b = 255
				}
			}
		}
	}
	return p, true
}
