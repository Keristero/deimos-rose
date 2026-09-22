package sim

// Phase 6, stage 1: a fixed-depth ring of full-state snapshots. State (see the
// struct comment in state.odin) is entirely fixed-size fields plus two
// pointers into read-only/debug data, so `slot = s^` is already a complete,
// alias-free copy -- no custom clone logic is needed here, only somewhere to
// put the copies and a way to find one again by frame number.
//
// Indexing by `frame % depth` (rather than tracking a write cursor) means
// restore can go straight to the right slot without scanning, at the cost of
// only being able to ask for a frame that is still within the last `depth`
// steps -- exactly the rollback window a caller needs anyway.

Snapshot_Ring :: struct {
	slots:   []State,
	written: []bool, // slots[i] holds a real snapshot, not just zero value
}

snapshot_ring_init :: proc(r: ^Snapshot_Ring, depth: int, allocator := context.allocator) {
	r.slots = make([]State, depth, allocator)
	r.written = make([]bool, depth, allocator)
}

snapshot_ring_destroy :: proc(r: ^Snapshot_Ring, allocator := context.allocator) {
	delete(r.slots, allocator)
	delete(r.written, allocator)
	r^ = {}
}

// Records s as the snapshot for its current frame, overwriting whichever
// older snapshot last landed in that slot.
snapshot_save :: proc(r: ^Snapshot_Ring, s: ^State) {
	i := s.frame % u32(len(r.slots))
	r.slots[i] = s^
	r.written[i] = true
}

// Restores s to the snapshot recorded for `frame`. Returns false, leaving s
// untouched, if that frame was never saved or has since been overwritten by a
// later snapshot landing in the same slot (i.e. it is more than `depth`
// frames in the past). `written` distinguishes a real frame-0 snapshot from
// an untouched slot, which would otherwise also read as frame 0.
snapshot_restore :: proc(r: ^Snapshot_Ring, s: ^State, frame: u32) -> bool {
	i := frame % u32(len(r.slots))
	if !r.written[i] || r.slots[i].frame != frame {
		return false
	}
	s^ = r.slots[i]
	return true
}
