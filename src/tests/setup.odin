package tests

import "base:runtime"

import "dr:sim"
import support "dr:tests/support"

// The tests' one `@(init)`: the build's registration, in its fixed order
// (sim.register_all), then what the tests register of their own, after
// it, so the tests see the ids a game sees.
@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	sim.register_all()
	register_test_components()
	register_test_effect()
	register_test_prefab()
	register_query_tests()
}

// The helpers every test package shares (tests/support), by the names
// this suite has always called them.
assets_defs :: support.assets_defs
content_defs :: support.content_defs
weapon_index :: support.weapon_index
play_start :: support.play_start
unit_spawn :: support.unit_spawn
mine_spawn :: support.mine_spawn
