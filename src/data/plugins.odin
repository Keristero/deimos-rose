package data

// Plugin folders (D51, D52): where each plugin's content is, and the data
// plugins, which are folders with a plugin.json and content but no code.
//
// The folders are found under the plugins roots: any added with
// plugins_root_add (the game's -plugins flag), then $DR_PLUGINS, or
// `plugins` in the working directory. A name found under two roots is
// taken from the first. game/main discovers the data plugins and declares
// them before sim.register_all, which registers them after the compiled
// plugins, in name order, so every machine with the same folders gives
// them the same ids.

import "core:encoding/json"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"

import "dr:sim"

// A plugin.json. The plugin's name is its folder's.
Json_Plugin :: struct {
	label:       string   `json:"label"`,
	description: string   `json:"description"`,
	version:     string   `json:"version"`,
	deps:        []string `json:"deps"`,
	default_on:  bool     `json:"default_on"`,
	session:     bool     `json:"session"`,
	// A campaign's levels, by identifier, in play order (D53). Each is a
	// data/levels/*.json in the plugin's folder.
	levels:      []string `json:"levels"`,
}

PLUGIN_MANIFEST :: "plugin.json"

// The plugin that holds the original's twelve levels: campaign CORE, which
// films, the oracle and classic mode play (D53). Found by name under the
// plugins roots even when nothing declared it, as in tests and tools.
CLASSIC_LEVELS :: "classic_levels"

// The subfolders that make a plugin folder hold content.
@(private = "file")
CONTENT_DIRS :: [?]string{"data", "sprites", "images", "audio"}

@(private = "file")
extra_roots: [dynamic]string
// Each discovered plugin's folder, by name.
@(private = "file")
discovered: map[string]string

// Adds a plugins root, searched before $DR_PLUGINS; `dir` must outlive
// the program. For the game's -plugins flag, before plugins_discover.
plugins_root_add :: proc(dir: string) {
	append(&extra_roots, dir)
}

// $DR_PLUGINS, or `plugins` in the working directory. That is src/plugins
// when run from src/, as mise tasks and tests are, and deimos/plugins in a
// release, where each folder holds only a plugin's content. $DR_PLUGINS
// may list several, as PATH does (':', ';' on Windows), first first.
plugins_root :: proc() -> string {
	if dir := os.get_env("DR_PLUGINS", context.temp_allocator); dir != "" {
		return dir
	}
	return "plugins"
}

// Every plugins root, first first.
plugins_roots :: proc(allocator := context.temp_allocator) -> []string {
	roots := make([dynamic]string, 0, len(extra_roots) + 1, allocator)
	append(&roots, ..extra_roots[:])
	for dir in strings.split(plugins_root(), LIST_SEPARATOR, allocator) {
		if dir != "" {
			append(&roots, dir)
		}
	}
	return roots[:]
}

@(private = "file")
LIST_SEPARATOR :: ";" when ODIN_OS == .Windows else ":"

// Where a plugin's own content is, if it has any: the folder found for it
// by plugins_discover, else `<root>/<plugin name>` under the first root
// that has one with content. Content is data/, sprites/, images/im16/ and
// audio/, each laid out as the game's own tree is. A plugin whose folder
// holds only code has none.
plugin_content_dir :: proc(id: sim.Plugin_ID) -> (dir: string, found: bool) {
	name := sim.registered_plugins()[id].name
	if d, ok := discovered[name]; ok {
		return d, has_content(d)
	}
	for root in plugins_roots() {
		dir = strings.concatenate({root, "/", name}, context.temp_allocator)
		if has_content(dir) {
			return dir, true
		}
	}
	return dir, false
}

@(private = "file")
has_content :: proc(dir: string) -> bool {
	for sub in CONTENT_DIRS {
		if os.exists(strings.concatenate({dir, "/", sub}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

// Where the Classic Levels plugin is: the folder plugins_discover found, else
// the first root that has one.
classic_levels_dir :: proc() -> (dir: string, found: bool) {
	if d, ok := discovered[CLASSIC_LEVELS]; ok {
		return d, true
	}
	for root in plugins_roots() {
		dir = strings.concatenate({root, "/", CLASSIC_LEVELS}, context.temp_allocator)
		if os.exists(strings.concatenate({dir, "/", PLUGIN_MANIFEST}, context.temp_allocator)) {
			return dir, true
		}
	}
	return dir, false
}

// The levels a plugin folder's manifest lists, in play order: none for a
// plugin that is not a campaign.
manifest_levels :: proc(dir: string, allocator := context.temp_allocator) -> []string {
	m: Json_Plugin
	if !read_manifest(strings.concatenate({dir, "/", PLUGIN_MANIFEST}, context.temp_allocator), &m, allocator) {
		return nil
	}
	return m.levels
}

// A plugin folder that could not be read, and why.
Plugin_Problem :: struct {
	dir:    string,
	reason: string,
}

// Every folder under `roots` with a plugin.json, as the plugin it
// describes, in name order: what sim.plugins_declare takes. A folder whose
// name is not lower-case letters, digits and underscores, or whose
// manifest does not parse, is left out and reported. Each found folder is
// remembered, for plugin_content_dir.
plugins_discover :: proc(roots: []string, allocator := context.allocator) -> (list: []sim.Plugin, problems: []Plugin_Problem) {
	found := make([dynamic]sim.Plugin, 0, 8, allocator)
	bad := make([dynamic]Plugin_Problem, 0, 0, allocator)
	if discovered == nil {
		discovered = make(map[string]string, allocator)
	}
	for root in roots {
		entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
		if err != nil {
			continue
		}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries {
			if e.type != .Directory || e.name in discovered {
				continue
			}
			dir := strings.concatenate({root, "/", e.name}, allocator)
			path := strings.concatenate({dir, "/", PLUGIN_MANIFEST}, context.temp_allocator)
			if !os.exists(path) {
				continue
			}
			if !plugin_name_valid(e.name) {
				append(&bad, Plugin_Problem{dir, "the folder's name is not lower-case letters, digits and underscores"})
				continue
			}
			m: Json_Plugin
			if !read_manifest(path, &m, allocator) {
				append(&bad, Plugin_Problem{dir, "plugin.json does not parse"})
				continue
			}
			name := strings.clone(e.name, allocator)
			discovered[name] = dir
			append(&found, sim.Plugin {
				name        = name,
				label       = m.label != "" ? m.label : name,
				description = m.description,
				deps        = m.deps,
				session     = m.session,
				default_on  = m.default_on,
				version     = m.version,
			})
		}
	}
	slice.sort_by(found[:], proc(a, b: sim.Plugin) -> bool {return a.name < b.name})
	return found[:], bad[:]
}

@(private = "file")
read_manifest :: proc(path: string, m: ^Json_Plugin, allocator := context.allocator) -> bool {
	blob, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return json.unmarshal(blob, m, allocator = allocator) == nil
}

plugin_name_valid :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	for c in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// Records a digest of each plugin's content folder (sim.plugin_digest_set),
// which registration_hash then covers: two peers whose level packs differ
// refuse each other rather than desync.
plugins_digest :: proc() {
	for i in 1 ..< len(sim.registered_plugins()) {
		if dir, found := plugin_content_dir(sim.Plugin_ID(i)); found {
			sim.plugin_digest_set(sim.Plugin_ID(i), content_digest(dir))
		}
	}
}

// A digest of every file under `dir` but Odin source, by path relative to
// it and contents, in path order.
content_digest :: proc(dir: string) -> u64 {
	files := make([dynamic]string, 0, 32, context.temp_allocator)
	content_files(dir, "", &files)
	slice.sort(files[:])
	entries := make([dynamic]u8, 0, 64 * len(files), context.temp_allocator)
	for rel in files {
		blob, err := os.read_entire_file(strings.concatenate({dir, "/", rel}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			continue
		}
		sum := xxhash.XXH3_64_default(blob)
		append(&entries, ..transmute([]u8)rel)
		append(&entries, 0)
		le := transmute([8]u8)u64le(sum)
		append(&entries, ..le[:])
	}
	return xxhash.XXH3_64_default(entries[:])
}

@(private = "file")
content_files :: proc(dir, rel: string, out: ^[dynamic]string) {
	path := rel == "" ? dir : strings.concatenate({dir, "/", rel}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		sub := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		switch {
		case e.type == .Directory:
			content_files(dir, sub, out)
		case !strings.has_suffix(e.name, ".odin"):
			append(out, sub)
		}
	}
}
