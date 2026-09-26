package debris_system

// G_Debris: rectangles of wreckage left on the ground (sim.Debris). They
// block ground units that collide with obstacles, and scroll with the
// background.

import "dr:sim"

// G_Debris_New.
debris_new :: proc "contextless" (s: ^sim.State, r: sim.Rect) {
	if sim.single(s, sim.Debris).count < sim.MAX_DEBRIS {
		sim.single(s, sim.Debris).rects[sim.single(s, sim.Debris).count] = r
		sim.single(s, sim.Debris).count += 1
	}
}

// G_Debris_Process: ride the scroll.
debris_process :: proc "contextless" (s: ^sim.State) {
	d := sim.single(s, sim.Bgnd).scrolled
	for &r in sim.single(s, sim.Debris).rects[:sim.single(s, sim.Debris).count] {
		r.top += d
		r.bottom += d
	}
}

// G_Debris_CheckCollision.
debris_hits :: proc "contextless" (s: ^sim.State, r: sim.Rect) -> bool {
	for &d in sim.single(s, sim.Debris).rects[:sim.single(s, sim.Debris).count] {
		if d.top <= r.bottom && r.top <= d.bottom && d.left <= r.right && r.left <= d.right {
			return true
		}
	}
	return false
}

// G_Debris_Process moves the ground wreckage with the scroll.
debris_scroll_system :: proc(s: ^sim.State, step: ^sim.Step) {
	debris_process(s)
}
