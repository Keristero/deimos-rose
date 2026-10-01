package editor

// Scenery models (Stage 8): trees, grass and rocks put on the map as 3D
// models, which the terrain renderer draws into the level's light, so
// their shadows are in the exported map (terrain/scenery.odin). Models
// come from the library, assets/models (`mise run models:library`, Poly
// Haven's, CC0), and from files dropped on the window, which are kept in
// the user's data, editor/models/, for every level after. A model is
// copied into the project when it is first put down, and saved beside it.
//
// They are put down with a profile's brush: its models, each with a chance
// and ranges of scale and lift, and the spacing, density, turn, lean,
// slope and water it keeps to. "Jungle Trees", "Grasses" and the like come
// with the library (profiles.json); the author's own, and their changes to
// those, are kept in the user's data, editor/brush-profiles.json.

import "base:runtime"

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import "dr:prefs"
import "dr:terrain"

MODEL_LIBRARY_INDEX :: "index.json"
MODEL_LIBRARY_FORMAT :: "deimos-rising.model-library"
PROFILES_FILE :: "profiles.json"
PROFILES_FORMAT :: "deimos-rising.brush-profiles"
// Under the user's editor data.
USER_MODELS :: "models"
USER_PROFILES :: "brush-profiles.json"
// Random sequential packing of discs jams with 0.547 of the plane covered
// (Feder 1980): 0.697 points a spacing squared. A density of 1 is that.
JAMMED :: 0.697
// Tries for each instance a dab still wants, before it gives up: near the
// jam, most fail.
SCATTER_TRIES :: 30
// Scattering the same each run, so a test can count what it puts down.
SCATTER_SEED :: 0x5ce7e
// A model the mouse is over, in the Select mode, is picked by this much
// around it as well, in map pixels: grass is a pixel across.
INSTANCE_PICK_SLACK :: 2

Models_Mode :: enum c.int {
	Scatter,
	Erase,
	Select,
}

// A profile: the models a brush puts down, and how.
Profile :: struct {
	name:      string                  `json:"name"`,
	entries:   [dynamic]Profile_Entry  `json:"entries"`,
	// Map pixels between two instances' points, at least, of the
	// profile's own models: another profile's may be among them.
	spacing:   f32                     `json:"spacing"`,
	// 0-1 of as many as the spacing allows (JAMMED).
	density:   f32                     `json:"density"`,
	// Degrees, each instance's chosen evenly between.
	turn:      [2]f32                  `json:"turn"`,
	lean:      [2]f32                  `json:"lean"`,
	// Degrees: none is put on steeper ground.
	max_slope: f32                     `json:"max_slope"`,
	// None under the water.
	dry:       bool                    `json:"dry"`,
}

// One of a profile's models: a library file's, or each of them in turn.
Profile_Entry :: struct {
	model:   string `json:"model"`, // the library file's name
	variant: string `json:"variant"`, // its model's name, or "" for any
	// Weights against the profile's others.
	chance:  f32    `json:"chance"`,
	scale:   [2]f32 `json:"scale"`,
	// Map pixels over the ground.
	offset:  [2]f32 `json:"offset"`,
}

@(private = "file")
Json_Profiles :: struct {
	format:   string    `json:"format"`,
	profiles: []Profile `json:"profiles"`,
}

Library_Model :: struct {
	file:     terrain.Model_File,
	tags:     []string,
	source:   string,
	// Dropped on the window: kept in the user's data, not the library's.
	imported: bool,
}

@(private = "file")
Json_Model_Library :: struct {
	format: string               `json:"format"`,
	models: []Model_Library_Item `json:"models"`,
}

@(private = "file")
Model_Library_Item :: struct {
	file:   string   `json:"file"`, // <file>.glb beside the index
	tags:   []string `json:"tags"`,
	source: string   `json:"source"`,
}

// The editor's models: the library, the profiles, and what the Models tab
// is doing.
Scenery :: struct {
	// The user's editor data, where imports and profiles are kept: "" for
	// none, as prefs.user_data_path gives without a home.
	user_dir:        string,
	library:         [dynamic]Library_Model,
	profiles:        [dynamic]Profile,
	profiles_dirty:  bool,
	// The library's and the profiles' memory, freed together.
	arena:           virtual.Arena,
	rng:             rand.Default_Random_State,
	mode:            c.int, // Models_Mode
	profile:         int, // in profiles, or -1
	entry:           int, // in the profile's entries, or -1
	erase_any:       bool, // Erase takes every model, not the profile's
	library_pick:    c.int,
	library_scroll:  c.int,
	profile_scroll:  c.int,
	entry_scroll:    c.int,
	name:            [64]u8,
	name_edit:       bool,
	// In the Select mode.
	instance:        int, // in project.instances, or -1
	hovered:         int,
	dragging:        bool,
	drag_offset:     [2]f32,
	// The instances as last recorded, while a change is under way.
	before:          [dynamic]terrain.Instance,
	changing:        bool,
}

scenery_init :: proc(s: ^Scenery) {
	_ = virtual.arena_init_growing(&s.arena)
	s.library.allocator = virtual.arena_allocator(&s.arena)
	s.profiles.allocator = virtual.arena_allocator(&s.arena)
	s.rng = rand.create(SCATTER_SEED)
	s.profile, s.entry, s.instance, s.hovered = -1, -1, -1, -1
	s.library_pick = -1
	s.user_dir = prefs.user_data_path("editor", virtual.arena_allocator(&s.arena))
}

scenery_destroy :: proc(s: ^Scenery) {
	delete(s.before)
	virtual.arena_destroy(&s.arena)
	s^ = {}
}

// Where the library's and the profiles' strings are kept.
scenery_allocator :: proc(s: ^Scenery) -> runtime.Allocator {
	return virtual.arena_allocator(&s.arena)
}

// The library in `root`/models, if there is one there, and the models
// the user imported before. The number read.
model_library_load :: proc(s: ^Scenery, root: string) -> int {
	a := virtual.arena_allocator(&s.arena)
	dir := strings.concatenate({root, "/models"}, context.temp_allocator)
	if blob, err := os.read_entire_file(strings.concatenate({dir, "/", MODEL_LIBRARY_INDEX}, context.temp_allocator), context.temp_allocator); err == nil {
		j: Json_Model_Library
		if json.unmarshal(blob, &j, allocator = a) == nil && j.format == MODEL_LIBRARY_FORMAT {
			for item in j.models {
				if item.file != terrain.model_name(item.file, context.temp_allocator) || library_find(s, item.file) >= 0 {
					continue
				}
				f, ok := terrain.model_file_read(strings.concatenate({dir, "/", item.file, ".glb"}, context.temp_allocator), a)
				if ok {
					f.name = item.file
					append(&s.library, Library_Model{file = f, tags = item.tags, source = item.source})
				}
			}
		}
	}
	if s.user_dir != "" {
		user := strings.concatenate({s.user_dir, "/", USER_MODELS}, context.temp_allocator)
		entries, err := os.read_all_directory_by_path(user, context.temp_allocator)
		if err == nil {
			slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
			for en in entries {
				if !strings.has_suffix(en.name, ".glb") || library_find(s, strings.trim_suffix(en.name, ".glb")) >= 0 {
					continue
				}
				if f, ok := terrain.model_file_read(strings.concatenate({user, "/", en.name}, context.temp_allocator), a); ok {
					append(&s.library, Library_Model{file = f, source = "imported", imported = true})
				}
			}
		}
	}
	return len(s.library)
}

// The library's model file named `name`, or -1.
library_find :: proc(s: ^Scenery, name: string) -> int {
	for m, k in s.library {
		if m.file.name == name {
			return k
		}
	}
	return -1
}

// The library's profiles, `root`/models/profiles.json, and the user's, in
// their place where they share a name. The number read.
profiles_load :: proc(s: ^Scenery, root: string) -> int {
	a := virtual.arena_allocator(&s.arena)
	read :: proc(path: string, allocator: runtime.Allocator) -> []Profile {
		blob, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return nil
		}
		j: Json_Profiles
		if json.unmarshal(blob, &j, allocator = allocator) != nil || j.format != PROFILES_FORMAT {
			return nil
		}
		return j.profiles
	}
	clear(&s.profiles)
	if s.user_dir != "" {
		append(&s.profiles, ..read(strings.concatenate({s.user_dir, "/", USER_PROFILES}, context.temp_allocator), a))
	}
	outer: for pr in read(strings.concatenate({root, "/models/", PROFILES_FILE}, context.temp_allocator), a) {
		for have in s.profiles {
			if have.name == pr.name {
				continue outer
			}
		}
		append(&s.profiles, pr)
	}
	for &pr in s.profiles {
		pr.entries.allocator = a
	}
	s.profile = len(s.profiles) > 0 ? 0 : -1
	s.entry = -1
	s.profiles_dirty = false
	return len(s.profiles)
}

// Writes every profile to the user's data: the library's as changed too.
profiles_save :: proc(s: ^Scenery) -> bool {
	if s.user_dir == "" {
		return false
	}
	blob, err := json.marshal(Json_Profiles{format = PROFILES_FORMAT, profiles = s.profiles[:]}, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		return false
	}
	os.make_directory_all(s.user_dir)
	if os.write_entire_file(strings.concatenate({s.user_dir, "/", USER_PROFILES}, context.temp_allocator), blob) != nil {
		return false
	}
	s.profiles_dirty = false
	return true
}

// A new profile, a copy of `from` (or empty for -1), and selects it.
profile_add :: proc(s: ^Scenery, from: int, name: string) -> int {
	a := virtual.arena_allocator(&s.arena)
	pr := Profile {
		spacing   = 8,
		density   = 0.5,
		turn      = {0, 360},
		max_slope = 45,
		dry       = true,
	}
	if from >= 0 && from < len(s.profiles) {
		pr = s.profiles[from]
	}
	pr.name = strings.clone(name, a)
	pr.entries = slice.clone_to_dynamic(pr.entries[:], a)
	append(&s.profiles, pr)
	s.profile, s.entry = len(s.profiles) - 1, -1
	s.profiles_dirty = true
	return s.profile
}

profile_remove :: proc(s: ^Scenery, k: int) {
	if k < 0 || k >= len(s.profiles) {
		return
	}
	ordered_remove(&s.profiles, k)
	s.profile = min(k, len(s.profiles) - 1)
	s.entry = -1
	s.profiles_dirty = true
}

// Adds the library's model file `m` to the profile, any of its models.
profile_entry_add :: proc(s: ^Scenery, k: int, m: int) -> int {
	if k < 0 || k >= len(s.profiles) || m < 0 || m >= len(s.library) {
		return -1
	}
	pr := &s.profiles[k]
	append(&pr.entries, Profile_Entry{model = s.library[m].file.name, chance = 1, scale = {1, 1}})
	s.entry = len(pr.entries) - 1
	s.profiles_dirty = true
	return s.entry
}

// Reads the file at `path` (glTF, GLB or OBJ) into the library, brought
// under terrain.MODEL_TRIANGLES and kept in the user's data for every
// level after, under a name no library model has. Its place in the library, or -1.
editor_model_import :: proc(e: ^Editor, path: string) -> int {
	s := &e.scenery
	a := virtual.arena_allocator(&s.arena)
	f, ok := terrain.model_file_read(path, a)
	if !ok {
		return -1
	}
	// As the library's are: a 60 MB tree saved in every level that has one
	// is no good to anyone.
	terrain.model_file_simplify(&f, allocator = a)
	stem := f.name
	for n := 2; library_find(s, f.name) >= 0; n += 1 {
		f.name = fmt.aprintf("%s-%d", stem, n, allocator = a)
	}
	if s.user_dir != "" {
		dir := strings.concatenate({s.user_dir, "/", USER_MODELS}, context.temp_allocator)
		os.make_directory_all(dir)
		// Best effort: without it the model lasts this run.
		_ = terrain.model_file_write(strings.concatenate({dir, "/", f.name, ".glb"}, context.temp_allocator), f)
	}
	append(&s.library, Library_Model{file = f, source = strings.clone(path, a), imported = true})
	s.library_pick = c.int(len(s.library) - 1)
	return len(s.library) - 1
}

// The project's model for the library file `name`'s model `variant`, or
// -1.
project_model_find :: proc(p: ^terrain.Project, name: string, variant: int) -> int {
	for m, k in p.models {
		if m.file == name && m.variant == variant {
			return k
		}
	}
	return -1
}

// project_model_find's, added with its file if the project has neither.
// -1 if the library has no such.
project_model :: proc(e: ^Editor, name: string, variant: int) -> int {
	p := &e.project
	if k := project_model_find(p, name, variant); k >= 0 {
		return k
	}
	if terrain.model_file_find(p, name) < 0 {
		l := library_find(&e.scenery, name)
		if l < 0 {
			return -1
		}
		append(&p.model_files, terrain.model_file_clone(e.scenery.library[l].file, virtual.arena_allocator(e.arena)))
		terrain.renderer_models(&e.renderer, p)
	}
	f := &p.model_files[terrain.model_file_find(p, name)]
	if variant < 0 || variant >= len(f.variants) {
		return -1
	}
	l := library_find(&e.scenery, name)
	m := terrain.Model {
		name    = f.variants[variant].name,
		file    = f.name,
		variant = variant,
	}
	if l >= 0 {
		a := virtual.arena_allocator(e.arena)
		m.tags = slice.clone(e.scenery.library[l].tags, a)
		for &t in m.tags {
			t = strings.clone(t, a)
		}
		m.source = strings.clone(e.scenery.library[l].source, a)
	}
	append(&p.models, m)
	return len(p.models) - 1
}

// The variants an entry puts down: its own, or all its file's.
@(private = "file")
entry_variants :: proc(e: ^Editor, en: Profile_Entry) -> (first, count: int) {
	l := library_find(&e.scenery, en.model)
	if l < 0 {
		return
	}
	f := e.scenery.library[l].file
	if en.variant == "" {
		return 0, len(f.variants)
	}
	for v, k in f.variants {
		if v.name == en.variant {
			return k, 1
		}
	}
	return
}

// The project's models a profile puts down, those it has.
@(private = "file")
profile_models :: proc(e: ^Editor, pr: Profile) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for en in pr.entries {
		first, count := entry_variants(e, en)
		for v in first ..< first + count {
			if m := project_model_find(&e.project, en.model, v); m >= 0 && !slice.contains(out[:], m) {
				append(&out, m)
			}
		}
	}
	return out[:]
}

// A dab of the profile's brush at `at`: models put down until the circle
// holds as many of the profile's as its density asks, each at least its
// spacing from the others, on ground no steeper than it allows, and dry
// if it says. A library model is added to the project when first put
// down. True if any was.
scatter_dab :: proc(e: ^Editor, at: [2]f32) -> bool {
	s, p := &e.scenery, &e.project
	if s.profile < 0 || s.profile >= len(s.profiles) {
		return false
	}
	pr := s.profiles[s.profile]
	models := profile_models(e, pr)
	total: f32
	for en in pr.entries {
		_, count := entry_variants(e, en)
		if count > 0 {
			total += max(en.chance, 0)
		}
	}
	if total <= 0 {
		return false
	}
	r := max(e.brush.radius, 0.5)
	spacing := max(pr.spacing, 0.5)
	want := int(clamp(pr.density, 0, 1) * JAMMED * math.PI * r * r / (spacing * spacing) + 0.5)
	// The profile's instances near enough to count or to keep apart from.
	near := make([dynamic][2]f32, context.temp_allocator)
	have := 0
	for i in p.instances {
		if !slice.contains(models, i.model) {
			continue
		}
		d := [2]f32{i.x, i.y} - at
		if dd := d.x * d.x + d.y * d.y; dd <= (r + spacing) * (r + spacing) {
			append(&near, [2]f32{i.x, i.y})
			if dd <= r * r {
				have += 1
			}
		}
	}
	gen := rand.default_random_generator(&s.rng)
	put := false
	for tries := SCATTER_TRIES * max(want - have, 0); tries > 0 && have < want; tries -= 1 {
		// Evenly over the circle.
		a, d := rand.float32(gen) * math.TAU, r * math.sqrt(rand.float32(gen))
		pt := at + {math.cos(a), math.sin(a)} * d
		if pt.x < 0 || pt.y < 0 || pt.x >= f32(p.width) || pt.y >= f32(p.length) {
			continue
		}
		if !ground_allows(p, pr, pt) {
			continue
		}
		crowded := false
		for q in near {
			dq := q - pt
			if dq.x * dq.x + dq.y * dq.y < spacing * spacing {
				crowded = true
				break
			}
		}
		if crowded {
			continue
		}
		// Which entry, by its chance; which of its models, evenly.
		pick := rand.float32(gen) * total
		en: Profile_Entry
		first, count: int
		for x in pr.entries {
			f, n := entry_variants(e, x)
			if n == 0 || x.chance <= 0 {
				continue
			}
			en, first, count = x, f, n
			if pick -= x.chance; pick < 0 {
				break
			}
		}
		m := project_model(e, en.model, first + int(rand.float32(gen) * f32(count)) % count)
		if m < 0 {
			continue
		}
		append(&p.instances, terrain.Instance {
			model  = m,
			x      = pt.x,
			y      = pt.y,
			offset = between(en.offset, gen),
			turn   = math.mod(between(pr.turn, gen) + 360, 360),
			lean   = between(pr.lean, gen),
			scale  = max(between(en.scale, gen), 0.01),
		})
		append(&near, pt)
		have += 1
		put = true
	}
	return put
}

@(private = "file")
between :: proc(r: [2]f32, gen: rand.Generator) -> f32 {
	return r[0] + (r[1] - r[0]) * rand.float32(gen)
}

// Whether the profile may put a model at `pt`: the ground's slope, and
// the water.
@(private = "file")
ground_allows :: proc(p: ^terrain.Project, pr: Profile, pt: [2]f32) -> bool {
	g := terrain.ground_at(p, pt)
	if pr.dry && p.level.water.visible && g < p.level.water.height {
		return false
	}
	dx := (terrain.ground_at(p, pt + {1, 0}) - terrain.ground_at(p, pt - {1, 0})) / 2
	dy := (terrain.ground_at(p, pt + {0, 1}) - terrain.ground_at(p, pt - {0, 1})) / 2
	return math.to_degrees(math.atan(math.sqrt(dx * dx + dy * dy))) <= pr.max_slope
}

// A dab of the eraser at `at`: the profile's models in the circle taken
// away, or every model's. True if any was.
erase_dab :: proc(e: ^Editor, at: [2]f32) -> bool {
	s, p := &e.scenery, &e.project
	models: []int
	if !s.erase_any {
		if s.profile < 0 || s.profile >= len(s.profiles) {
			return false
		}
		models = profile_models(e, s.profiles[s.profile])
	}
	r := max(e.brush.radius, 0.5)
	n := len(p.instances)
	#reverse for i, k in p.instances {
		d := [2]f32{i.x, i.y} - at
		if d.x * d.x + d.y * d.y <= r * r && (s.erase_any || slice.contains(models, i.model)) {
			ordered_remove(&p.instances, k)
		}
	}
	return len(p.instances) != n
}

// Before any change to the instances: keeps them as they are, once.
instances_changing :: proc(e: ^Editor) {
	s := &e.scenery
	if s.changing {
		return
	}
	clear(&s.before)
	append(&s.before, ..e.project.instances[:])
	s.changing = true
}

// Records the change once nothing is being dragged, if the instances
// differ, and draws the light again over the whole map.
instances_settle :: proc(e: ^Editor, dragging: bool) {
	s := &e.scenery
	if !s.changing || dragging {
		return
	}
	s.changing = false
	if slice.equal(s.before[:], e.project.instances[:]) {
		return
	}
	history_instances(&e.history, s.before[:])
	e.dirty = true
	e.overview_stale = true
}

// The instances changed: drawn into the light again.
instances_drawn :: proc(e: ^Editor) {
	terrain.scenery_draw(&e.renderer, &e.project)
	e.view_stale = true
}

// Instance `i` as `to`, recorded with the change under way.
editor_instance_set :: proc(e: ^Editor, i: int, to: terrain.Instance) {
	if i < 0 || i >= len(e.project.instances) || e.project.instances[i] == to {
		return
	}
	instances_changing(e)
	e.project.instances[i] = to
	instances_drawn(e)
}

editor_instance_delete :: proc(e: ^Editor, i: int) {
	if i < 0 || i >= len(e.project.instances) {
		return
	}
	instances_changing(e)
	ordered_remove(&e.project.instances, i)
	e.scenery.instance, e.scenery.hovered = -1, -1
	instances_drawn(e)
	instances_settle(e, false)
}

// The instance under map point `at`, its triangles met from above, or
// failing that, the nearest whose point is within INSTANCE_PICK_SLACK.
instance_pick :: proc(e: ^Editor, at: [2]f32) -> int {
	if k := terrain.instance_pick(&e.project, at); k >= 0 {
		return k
	}
	best, pick := f32(INSTANCE_PICK_SLACK * INSTANCE_PICK_SLACK), -1
	for i, k in e.project.instances {
		d := [2]f32{i.x, i.y} - at
		if dd := d.x * d.x + d.y * d.y; dd <= best {
			best, pick = dd, k
		}
	}
	return pick
}
