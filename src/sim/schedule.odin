package sim

// Run order for systems. A system names the systems it runs after; that is
// all a dependency means (notes/ecs-refactor.md). Systems otherwise run in
// the order they were registered, so adding a plugin never reorders the
// systems it does not name, and the core's order stays the original's.

Order_Item :: struct {
	name:  string,
	after: []string,
}

// Indexes into items in run order: each after everything it names, and
// otherwise in registration order. A name nobody has is ignored, so a
// system can run after one from a plugin that may not be there. Fails on a
// cycle.
schedule :: proc(items: []Order_Item, allocator := context.allocator) -> (order: []int, ok: bool) {
	n := len(items)
	order = make([]int, n, allocator)
	placed := make([]bool, n, context.temp_allocator)
	for k in 0 ..< n {
		next := -1
		find: for i in 0 ..< n {
			if placed[i] {
				continue
			}
			for dep in items[i].after {
				for j in 0 ..< n {
					if !placed[j] && j != i && items[j].name == dep {
						continue find
					}
				}
			}
			next = i
			break
		}
		if next < 0 {
			delete(order, allocator)
			return nil, false
		}
		placed[next] = true
		order[k] = next
	}
	return order, true
}

// The names items run after that no item has: in a registry that is
// always a typo, since every plugin registers whether enabled or not.
schedule_unknown :: proc(items: []Order_Item, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for it in items {
		dep: for d in it.after {
			for other in items {
				if other.name == d {
					continue dep
				}
			}
			append(&out, d)
		}
	}
	return out[:]
}
