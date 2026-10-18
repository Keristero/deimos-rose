package game

// Loads the code plugins: a shared library per plugin, found beside its
// content, `plugins/<name>/<name>.so` (`.dll` on Windows), Phase 10 stage
// 3, decisions.md D85. The game imports no plugin; one is in the game when
// its library is in a plugins folder.
//
// A library's `@(init)`s queue the plugin's registration steps in its own
// copy of sim. Binding it (dr:plugin_entry's deimos_plugin_bind) points
// every package's state in the library at the game's (dr:blocks), and
// carries those steps over, so sim.register_all, which must come after,
// registers the plugin as if it were compiled in. The order libraries load
// in changes nothing: blocks bind by package name, and steps run sorted by
// stage and name. plugins:check proves it: the same plugins, ids and
// registration hash as a build with every plugin compiled in.
//
// A bound library is never unloaded: its procedures are in the game's
// registries, and its string literals in the game's tables, for the rest
// of the run.

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "dr:blocks"
import "dr:sim"

PLUGIN_LIB_EXT :: ".dll" when ODIN_OS == .Windows else ".dylib" when ODIN_OS == .Darwin else ".so"

// A library that was found and not loaded, and why.
Plugin_Lib_Problem :: struct {
	path:   string,
	reason: string,
}

// Every plugin library under `roots`, and under `plugins` beside the
// game's executable (where a build leaves them: build/plugins in
// development, the release's own plugins folder), loaded and bound into
// this module's blocks. A name found twice is taken from the first. Call
// before sim.register_all.
plugin_libs_load :: proc(roots: []string, allocator := context.allocator) -> (loaded: []string, problems: []Plugin_Lib_Problem) {
	names := make([dynamic]string, 0, 16, allocator)
	bad := make([dynamic]Plugin_Lib_Problem, 0, 0, allocator)
	dirs := make([dynamic]string, 0, len(roots) + 1, context.temp_allocator)
	append(&dirs, ..roots)
	if exe, err := os.get_executable_directory(context.temp_allocator); err == nil {
		append(&dirs, strings.concatenate({exe, "/plugins"}, context.temp_allocator))
	}
	for dir in dirs {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			continue
		}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries {
			if e.type != .Directory || slice.contains(names[:], e.name) {
				continue
			}
			path := strings.concatenate({dir, "/", e.name, "/", e.name, PLUGIN_LIB_EXT}, allocator)
			if !os.exists(path) {
				continue
			}
			if reason := plugin_lib_bind(path); reason != "" {
				append(&bad, Plugin_Lib_Problem{path, reason})
				continue
			}
			append(&names, strings.clone(e.name, allocator))
		}
	}
	return names[:], bad[:]
}

// Loads one library and binds it: "" when it is in, else why not.
//
// What it exports is checked before its runtime starts: a library that is
// not a plugin, or is from other sources, is unloaded untouched. Once its
// runtime has started it stays loaded even if bind refuses it, since the
// runtime may have left the process something to call back: a first cut
// that started a stale library and then unloaded it crashed the game
// (plugins:check, 2026-10-18), and checking the ABI first fixed it.
@(private = "file")
plugin_lib_bind :: proc(path: string) -> (reason: string) {
	lib, ok := dynlib.load_library(path)
	if !ok {
		return strings.clone(dynlib.last_error())
	}
	abi, has_abi := dynlib.symbol_address(lib, blocks.ABI_SYMBOL)
	started, has_started := dynlib.symbol_address(lib, blocks.STARTED_SYMBOL)
	bind, has_bind := dynlib.symbol_address(lib, blocks.BIND_SYMBOL)
	if !has_abi || !has_started || !has_bind {
		dynlib.unload_library(lib)
		return "not a plugin: it has no " + blocks.BIND_SYMBOL
	}
	if theirs := string(blocks.Abi_Proc(abi)()); theirs != blocks.ABI {
		reason = strings.concatenate({"built from other sources (", theirs, ") than this game (", blocks.ABI, ")"})
		dynlib.unload_library(lib)
		return
	}
	// Where loading did not start its runtime (Linux, plugin_entry says
	// why), start it: its `@(init)`s declare its blocks and queue its steps.
	if !blocks.Started_Proc(started)() {
		start, has_start := dynlib.symbol_address(lib, blocks.START_SYMBOL)
		if !has_start {
			dynlib.unload_library(lib)
			return "its runtime did not start, and it has no " + blocks.START_SYMBOL
		}
		blocks.Start_Proc(start)()
		if !blocks.Started_Proc(started)() {
			return "its runtime did not start"
		}
	}
	r := blocks.Bind_Proc(bind)(blocks.table())
	switch r.err {
	case .None:
		return ""
	case .Type_Mismatch:
		return strings.concatenate({"its ", r.detail, " is not this game's: built from other sources"})
	case .Full:
		return "too many packages in the game's plugins (blocks.MAX_BLOCKS)"
	}
	return "unknown"
}

// -list-plugins: every registered plugin by id, and the registration
// hash, then exits; 1 when a library would not load (main printed why).
plugins_list :: proc(all_loaded: bool) -> ! {
	for p, id in sim.registered_plugins() {
		if id == 0 {
			continue // the core
		}
		fmt.printfln("plugin %d %s %q version %q deps %v session %v", id, p.name, p.label, p.version, p.deps, p.session)
	}
	fmt.printfln("registration %16x", sim.registration_hash())
	os.exit(all_loaded ? 0 : 1)
}
