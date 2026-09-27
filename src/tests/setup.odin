package tests

import "base:runtime"

import "dr:sim"

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
