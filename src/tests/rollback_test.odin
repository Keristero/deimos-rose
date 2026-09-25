package tests

import "core:testing"

import "dr:sim"

// Phase 6 stage 1: prove that saving a snapshot, rolling back to it and
// resimulating with the same inputs reproduces exactly the checksums an
// uninterrupted run produced -- the guarantee rollback netcode depends on.
@(test)
rollback_resimulation_matches_uninterrupted_play :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	session := sim.Session{seed = 0xC0FFEE, level_id = sim.level_id("le01"), game_type = .Co_Op}

	inputs := make([]sim.Frame_Input, 50, context.temp_allocator)
	r := sim.rand_init(7)
	for i in 0 ..< len(inputs) {
		a, b := sim.Buttons{}, sim.Buttons{}
		if sim.random_int(&r, 0, 1, 0) == 0 { a += {.Left} }
		if sim.random_int(&r, 0, 1, 0) == 0 { b += {.Fire_Ground} }
		inputs[i] = sim.Frame_Input{a, b}
	}

	// Reference: an uninterrupted run, one checksum recorded per step.
	ref := make([]u64, len(inputs), context.temp_allocator)
	reference := new(sim.State, context.temp_allocator)
	defer sim.destroy(reference)
	sim.init(reference, session, defs)
	for in_, i in inputs {
		sim.step(reference, in_)
		ref[i] = sim.checksum(reference)
	}

	// A second run that steps the first 30 frames while saving a snapshot
	// after each one, then deliberately rewinds to frame 20 and resimulates
	// the remaining frames from there using the same recorded inputs.
	ring: sim.Snapshot_Ring
	sim.snapshot_ring_init(&ring, 16, context.temp_allocator)
	defer sim.snapshot_ring_destroy(&ring, context.temp_allocator)

	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, session, defs)
	for i in 0 ..< 30 {
		sim.step(s, inputs[i])
		sim.snapshot_save(&ring, s)
	}
	testing.expect_value(t, s.frame, u32(30))

	// Frame 1 is 29 frames behind frame 30, well outside the 16-deep ring:
	// restoring it must fail and must not touch s.
	before := sim.checksum(s)
	testing.expect(t, !sim.snapshot_restore(&ring, s, 1), "frame 1 should have aged out of the ring")
	testing.expect_value(t, sim.checksum(s), before)

	// Frame 20 is only 10 frames behind and must still be there.
	testing.expect(t, sim.snapshot_restore(&ring, s, 20), "frame 20 should still be in the ring")
	testing.expect_value(t, s.frame, u32(20))
	testing.expect_value(t, sim.checksum(s), ref[19])

	// Resimulating from the restored frame 20 with the same inputs must
	// retrace the reference run exactly, frame by frame, all the way past
	// where the first pass had already reached.
	for i in 20 ..< len(inputs) {
		sim.step(s, inputs[i])
		sim.snapshot_save(&ring, s)
		testing.expectf(t, sim.checksum(s) == ref[i], "frame %d: rollback resimulation diverged", i + 1)
	}
}

@(test)
snapshot_restore_rejects_a_never_saved_frame :: proc(t: ^testing.T) {
	ring: sim.Snapshot_Ring
	sim.snapshot_ring_init(&ring, 4, context.temp_allocator)
	defer sim.snapshot_ring_destroy(&ring, context.temp_allocator)

	defs := synthetic_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	testing.expect(t, !sim.snapshot_restore(&ring, s, 0), "an empty ring has nothing to restore")
}

// Reconnection sends a whole state with state_write; the reader must carry
// on exactly as the writer does, and a snapshot's checksum must be the
// state's.
@(test)
a_written_state_reads_back_and_plays_on_identically :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	a := new(sim.State, context.temp_allocator)
	defer sim.destroy(a)
	b := new(sim.State, context.temp_allocator)
	defer sim.destroy(b)
	sim.init(a, sim.Session{seed = 11, level_id = sim.level_id("le01"), game_type = .Co_Op}, defs)
	sim.init(b, sim.Session{seed = 99, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	press := sim.Frame_Input{{.Fire_Ground, .Left}, {.Fire_Air}}
	for _ in 0 ..< 40 {
		sim.session_step(a, press)
	}
	ring: sim.Snapshot_Ring
	sim.snapshot_ring_init(&ring, 4, context.temp_allocator)
	defer sim.snapshot_ring_destroy(&ring, context.temp_allocator)
	sim.snapshot_save(&ring, a)
	sum, ok := sim.snapshot_checksum(&ring, a.frame)
	testing.expect(t, ok)
	testing.expect_value(t, sum, sim.checksum(a))

	buf := make([dynamic]byte, context.temp_allocator)
	sim.state_write(a, &buf)
	testing.expect(t, sim.state_read(b, buf[:]))
	testing.expect_value(t, sim.checksum(b), sim.checksum(a))
	testing.expect(t, b.defs == defs && b.level == a.level)
	for i in 0 ..< 40 {
		sim.session_step(a, press)
		sim.session_step(b, press)
		testing.expectf(t, sim.checksum(a) == sim.checksum(b), "step %d after reading: diverged", i + 1)
	}
	testing.expect(t, !sim.state_read(b, buf[:len(buf) - 1]))
}
