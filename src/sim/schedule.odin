package sim

// Run order for systems. A system names the systems it runs after, or
// before; that is all a dependency means (notes/ecs-refactor.md). Systems
// otherwise run in the order they were registered, so adding a plugin never
// reorders the systems it does not name, and the core's order stays the
// original's.

Order_Item :: struct {
	name:   string,
	after:  []string,
	before: []string,
}

// Indexes into items in run order. Items go in registration order, each
// preceded by whatever must run before it that has not run yet: what it
// names in `after`, and what names it in `before`. So `before` pulls a
// later-registered item forward to just ahead of the one it names, which
// is how a plugin puts a system in the middle of the core's. A name nobody
// has is ignored, so a system can be placed against one from a plugin that
// may not be there. Fails on a cycle.
schedule :: proc(items: []Order_Item, allocator := context.allocator) -> (order: []int, ok: bool) {
	Mark :: enum u8 {
		None,
		Visiting,
		Placed,
	}
	n := len(items)
	order = make([]int, n, allocator)
	marks := make([]Mark, n, context.temp_allocator)
	placed := 0
	visit :: proc(items: []Order_Item, marks: []Mark, order: []int, placed: ^int, i: int) -> bool {
		switch marks[i] {
		case .Placed:
			return true
		case .Visiting:
			return false
		case .None:
		}
		marks[i] = .Visiting
		for j in 0 ..< len(items) {
			if j == i {
				continue
			}
			first := false
			for d in items[i].after {
				if d == items[j].name {
					first = true
				}
			}
			for b in items[j].before {
				if b == items[i].name {
					first = true
				}
			}
			if first && !visit(items, marks, order, placed, j) {
				return false
			}
		}
		marks[i] = .Placed
		order[placed^] = i
		placed^ += 1
		return true
	}
	for i in 0 ..< n {
		if !visit(items, marks, order, &placed, i) {
			delete(order, allocator)
			return nil, false
		}
	}
	return order, true
}

// The names items are placed against that no item has: in a registry that is
// always a typo, since every plugin registers whether enabled or not.
schedule_unknown :: proc(items: []Order_Item, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for it in items {
		for list in ([2][]string{it.after, it.before}) {
			dep: for d in list {
				for other in items {
					if other.name == d {
						continue dep
					}
				}
				append(&out, d)
			}
		}
	}
	return out[:]
}
