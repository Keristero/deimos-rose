package plugin_entry

// What makes a plugin's shared library loadable: the procedures the game
// looks up in it (Phase 10 stage 3, decisions.md D85).
//
// A plugin's library is built from a root package that imports this, the
// plugin's packages and nothing else (tools/plugins/plugin_libs.sh). The
// game asks which sources it was built from, and refuses it untouched if
// they are not the game's. Then the library's runtime starts and its
// `@(init)`s run, in its own copies of sim and the rest, queueing its
// registration steps there; and bind points each copy's block at the
// game's (dr:blocks) and carries the steps over.
//
// The runtime should start as the library loads, and a Windows DLL's
// DllMain does start it. On Linux, Odin dev-2026-09 passes the linker
// `-Wl,-init,'_odin_entry_point'` without a shell, so the quotes reach ld
// and name no symbol, and ld leaves the library with no DT_INIT: its
// `@(init)`s never run (seen: readelf -d lists no INIT; the arguments
// logged from a clang wrapper carry the quotes). So the game asks, and
// starts it itself when it has not started (game/plugin_libs.odin).

import "base:runtime"

import "dr:blocks"

// sim declares its block from an `@(init)`, so a library whose `@(init)`s
// have run has at least one.
@(export)
deimos_plugin_started :: proc "c" () -> bool {
	return blocks.table().count > 0
}

// The sources the library was built from (dr:blocks's ABI), asked before
// its runtime is started: a library from other sources is never started.
@(export)
deimos_plugin_abi :: proc "c" () -> cstring {
	return ABI
}

@(private = "file")
ABI: cstring : blocks.ABI

@(export)
deimos_plugin_bind :: proc "c" (host: ^blocks.Table) -> blocks.Load_Result {
	context = runtime.default_context()
	err, name := blocks.bind(host)
	return {err = err, detail = name}
}
