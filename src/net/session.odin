package netplay

// Phase 6 stage 3: input prediction and rollback, wired onto sim.State and
// sim.Snapshot_Ring (stage 1). This file touches no socket at all -- it only
// turns "my local input" and "a decoded Input_Packet from the peer" into
// calls to sim.step, predicting the remote player's input when nothing new
// has arrived and rolling back to resimulate when a prediction turns out to
// have been wrong. Sending/receiving those packets over the wire is the
// caller's job (net/socket.odin supplies the transport, a later stage wires
// it into game/).

import "dr:sim"

// How many frames back a rollback can reach: the ring buffer's depth and the
// input log's indexing modulus share it, since a rollback that needed to go
// further back than the snapshot ring can hold would have nothing to
// restore from anyway. 64 frames at 30 Hz is a little over 2 seconds --
// comfortably more than any real round trip this is meant to tolerate.
ROLLBACK_DEPTH :: 64

Input_Slot :: struct {
	frame:     u32,
	buttons:   sim.Buttons,
	confirmed: bool, // false: a prediction (repeat of the last known value)
}

Input_Log :: struct {
	slots: [ROLLBACK_DEPTH]Input_Slot,
}

@(private = "file")
input_log_set :: proc(log: ^Input_Log, frame: u32, buttons: sim.Buttons, confirmed: bool) {
	i := frame % ROLLBACK_DEPTH
	if log.slots[i].confirmed && log.slots[i].frame == frame && !confirmed {
		return // never downgrade an already-confirmed frame back to a prediction
	}
	if log.slots[i].frame > frame {
		return // a stale, out-of-order write; the newer value already there stands
	}
	log.slots[i] = {frame, buttons, confirmed}
}

@(private = "file")
input_log_get :: proc(log: ^Input_Log, frame: u32) -> Input_Slot {
	slot := log.slots[frame % ROLLBACK_DEPTH]
	if slot.frame != frame {
		return {frame, {}, false}
	}
	return slot
}

Rollback_Session :: struct {
	state:         ^sim.State,
	ring:          sim.Snapshot_Ring,
	local_player:  int, // 0 or 1: which Frame_Input slot this machine drives
	remote_player: int,
	local_log:     Input_Log,
	remote_log:    Input_Log,
	rollback_count: int, // how many times a misprediction has forced a resimulation
}

rollback_session_init :: proc(rs: ^Rollback_Session, state: ^sim.State, local_player: int, allocator := context.allocator) {
	rs.state = state
	rs.local_player = local_player
	rs.remote_player = 1 - local_player
	sim.snapshot_ring_init(&rs.ring, ROLLBACK_DEPTH, allocator)
	rs.local_log = {}
	rs.remote_log = {}
}

rollback_session_destroy :: proc(rs: ^Rollback_Session, allocator := context.allocator) {
	sim.snapshot_ring_destroy(&rs.ring, allocator)
}

// Repeats the last known value (confirmed or, itself, an earlier prediction)
// for a remote frame nothing new has arrived for. The standard rollback-
// netcode first guess: most buttons are held for many frames in a row, so
// repeating rarely mispredicts, and the cost of a wrong guess is only ever a
// resimulation, never an incorrect final result.
@(private = "file")
resolve_remote_input :: proc(rs: ^Rollback_Session, frame: u32) -> sim.Buttons {
	slot := input_log_get(&rs.remote_log, frame)
	if slot.confirmed {
		return slot.buttons
	}
	predicted := frame > 0 ? input_log_get(&rs.remote_log, frame - 1).buttons : sim.Buttons{}
	input_log_set(&rs.remote_log, frame, predicted, false)
	return predicted
}

// Advances the simulation by exactly one frame using this machine's own
// input (always exact) and the remote player's input (confirmed if it has
// arrived, predicted otherwise). Call once per fixed-step tick.
rollback_session_advance :: proc(rs: ^Rollback_Session, local_input: sim.Buttons) {
	frame := rs.state.frame
	input_log_set(&rs.local_log, frame, local_input, true)
	remote_input := resolve_remote_input(rs, frame)

	input: sim.Frame_Input
	input[rs.local_player] = local_input
	input[rs.remote_player] = remote_input
	sim.step(rs.state, input)
	sim.snapshot_save(&rs.ring, rs.state)
}

// Feed every Input_Packet decoded from the remote peer here, before this
// tick's rollback_session_advance call. Confirms whichever of its frames
// this session did not already know, and if any of those frames had already
// been simulated on a mispredicted guess, rolls back to just before the
// earliest one and resimulates forward with the now-confirmed input in
// place of the guess.
rollback_session_receive :: proc(rs: ^Rollback_Session, pkt: Input_Packet) {
	earliest: u32
	mispredicted := false
	for i in 0 ..< pkt.count {
		frame := pkt.start_frame + u32(i)
		slot := input_log_get(&rs.remote_log, frame)
		if slot.confirmed {
			continue // a real peer never sends a different value for a frame twice
		}
		wrong_guess := frame <= rs.state.frame && slot.buttons != pkt.frames[i]
		input_log_set(&rs.remote_log, frame, pkt.frames[i], true)
		if wrong_guess && (!mispredicted || frame < earliest) {
			earliest, mispredicted = frame, true
		}
	}
	if mispredicted {
		rollback_to(rs, earliest)
	}
}

@(private = "file")
rollback_to :: proc(rs: ^Rollback_Session, frame: u32) {
	if frame == 0 {
		return // nothing precedes the first frame; nothing to roll back to
	}
	target := rs.state.frame // how far the mispredicted run had already reached
	if !sim.snapshot_restore(&rs.ring, rs.state, frame - 1) {
		return // frame-1 has aged out of the ring -- beyond ROLLBACK_DEPTH back, unrecoverable here
	}
	rs.rollback_count += 1
	for rs.state.frame < target {
		f := rs.state.frame
		local := input_log_get(&rs.local_log, f).buttons // local input is never mispredicted
		remote := resolve_remote_input(rs, f)
		input: sim.Frame_Input
		input[rs.local_player] = local
		input[rs.remote_player] = remote
		sim.step(rs.state, input)
		sim.snapshot_save(&rs.ring, rs.state)
	}
}

// Copies up to `window` of the most recently simulated local frames, oldest
// first, into out (sized MAX_INPUT_FRAMES by callers building an outgoing
// Input packet) -- the redundancy that lets that packet tolerate loss.
// Returns the frame number of out[0] and how many entries were written.
rollback_session_local_window :: proc(rs: ^Rollback_Session, window: int, out: []sim.Buttons) -> (start_frame: u32, count: int) {
	if rs.state.frame == 0 {
		return 0, 0 // nothing simulated yet
	}
	last := rs.state.frame - 1 // the most recent frame recorded by advance
	count = min(window, len(out), int(last) + 1)
	start_frame = last + 1 - u32(count)
	for i in 0 ..< count {
		out[i] = input_log_get(&rs.local_log, start_frame + u32(i)).buttons
	}
	return
}
