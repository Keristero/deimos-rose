package sim

// G_Debris: rectangles of wreckage left on the ground. They block ground
// units that collide with obstacles, and scroll with the background.
//
// The original keeps them in an unbounded list that is only cleared at level
// start; here the pool is fixed and further debris is dropped, which can only
// differ from the original in a level that leaves more than MAX_DEBRIS
// obstacles.
MAX_DEBRIS :: 512

Debris :: struct {
	rects: [MAX_DEBRIS]Rect,
	count: i32,
}

// G_Debris_New.
debris_new :: proc "contextless" (s: ^State, r: Rect) {
	if single(s, Debris).count < MAX_DEBRIS {
		single(s, Debris).rects[single(s, Debris).count] = r
		single(s, Debris).count += 1
	}
}

// G_Debris_Process: ride the scroll.
debris_process :: proc "contextless" (s: ^State) {
	d := single(s, Bgnd).scrolled
	for &r in single(s, Debris).rects[:single(s, Debris).count] {
		r.top += d
		r.bottom += d
	}
}

// G_Debris_CheckCollision.
debris_hits :: proc "contextless" (s: ^State, r: Rect) -> bool {
	for &d in single(s, Debris).rects[:single(s, Debris).count] {
		if d.top <= r.bottom && r.top <= d.bottom && d.left <= r.right && r.left <= d.right {
			return true
		}
	}
	return false
}
