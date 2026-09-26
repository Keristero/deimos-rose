package sim

// A fixed-size list filled from `@(init)` procedures: what the core and the
// plugins register -- systems, stages, prefab builders, hooks, components
// -- and the presentation's render systems and overlays. Fixed-size, so
// registering allocates nothing and a registry is the same in every run of
// a build.
Registry :: struct($T: typeid, $N: int) {
	items: [N]T,
	count: int,
}

// Adds item, and returns its index. A full registry is a bug in whoever
// sized it: the assertion names the register call that found it full.
registry_add :: proc(r: ^Registry($T, $N), item: T, loc := #caller_location) -> int {
	assert(r.count < N, "sim: a registry is full", loc)
	r.items[r.count] = item
	r.count += 1
	return r.count - 1
}

registry_items :: #force_inline proc "contextless" (r: ^Registry($T, $N)) -> []T {
	return r.items[:r.count]
}
