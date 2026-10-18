package sim

// Phase 6, stage 1: a fixed-depth ring of full-state snapshots. A snapshot
// is the state's own fields, copied, plus its world written out by
// ecs_write (D39); restoring copies the fields back and reads the world in.
// The buffers are kept and reused, so a warm ring saves without allocating.
//
// Indexing by `frame % depth` (rather than tracking a write cursor) means
// restore can go straight to the right slot without scanning, at the cost of
// only being able to ask for a frame that is still within the last `depth`
// steps -- exactly the rollback window a caller needs anyway.

Snapshot :: struct {
	fields:  State,
	world:   [dynamic]byte,
	frame:   u32, // the frame it was saved at, which is in the world
	written: bool, // holds a real snapshot, not just zero value
}

Snapshot_Ring :: struct {
	slots: []Snapshot,
}

snapshot_ring_init :: proc(r: ^Snapshot_Ring, depth: int, allocator := context.allocator) {
	r.slots = make([]Snapshot, depth, allocator)
	for &slot in r.slots {
		slot.world = make([dynamic]byte, allocator)
	}
}

snapshot_ring_destroy :: proc(r: ^Snapshot_Ring, allocator := context.allocator) {
	for &slot in r.slots {
		delete(slot.world)
	}
	delete(r.slots, allocator)
	r^ = {}
}

// Records s as the snapshot for its current frame, overwriting whichever
// older snapshot last landed in that slot.
snapshot_save :: proc(r: ^Snapshot_Ring, s: ^State) {
	frame := frame_of(s)
	slot := &r.slots[frame % u32(len(r.slots))]
	slot.fields = s^
	slot.frame = frame
	clear(&slot.world)
	ecs_write(s.ecs, &slot.world)
	slot.written = true
}

@(private = "file")
snapshot_find :: proc(r: ^Snapshot_Ring, frame: u32) -> ^Snapshot {
	slot := &r.slots[frame % u32(len(r.slots))]
	if !slot.written || slot.frame != frame {
		return nil
	}
	return slot
}

// Restores s to the snapshot recorded for `frame`. Returns false, leaving s
// untouched, if that frame was never saved or has since been overwritten by a
// later snapshot landing in the same slot (i.e. it is more than `depth`
// frames in the past). `written` distinguishes a real frame-0 snapshot from
// an untouched slot, which would otherwise also read as frame 0.
snapshot_restore :: proc(r: ^Snapshot_Ring, s: ^State, frame: u32) -> bool {
	slot := snapshot_find(r, frame)
	if slot == nil {
		return false
	}
	if _, ok := ecs_read(s.ecs, slot.world[:]); !ok {
		return false
	}
	restore_plain(s, &slot.fields)
	return true
}

// The checksum of whatever snapshot is recorded for `frame`, without
// restoring it first -- desync detection (net/desync.odin) only ever needs
// the digest, and it already reflects the latest resimulation, since
// snapshot_save overwrites the slot every time a rollback replays past it.
// The world's bytes are the ones ecs_hash would hash, so this equals
// checksum() of the state as it was.
snapshot_checksum :: proc(r: ^Snapshot_Ring, frame: u32) -> (sum: u64, ok: bool) {
	slot := snapshot_find(r, frame)
	if slot == nil {
		return 0, false
	}
	h := hasher()
	hash_bytes(&h, raw_data(slot.world), len(slot.world))
	return h.sum, true
}
