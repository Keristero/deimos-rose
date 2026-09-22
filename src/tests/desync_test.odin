package tests

import "core:testing"

import net "dr:net"

@(test)
checksum_packet_round_trips :: proc(t: ^testing.T) {
	buf: [32]byte
	n := net.encode_checksum(buf[:], 12345, 0xDEAD_BEEF_CAFE_F00D)
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.Checksum)
	frame, sum, ok := net.decode_checksum(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, frame, u32(12345))
	testing.expect_value(t, sum, u64(0xDEAD_BEEF_CAFE_F00D))
}

@(test)
desync_monitor_is_inconclusive_before_the_frame_is_recorded :: proc(t: ^testing.T) {
	dm: net.Desync_Monitor
	known, matched := net.desync_monitor_receive(&dm, 10, 0xABC)
	testing.expect(t, !known, "a frame this machine hasn't reached yet can't be compared")
	testing.expect(t, !matched)
	testing.expect(t, !dm.desynced)
}

@(test)
desync_monitor_accepts_matching_checksums :: proc(t: ^testing.T) {
	dm: net.Desync_Monitor
	for f in u32(0) ..< 10 {
		net.desync_monitor_record(&dm, f, u64(f) * 7 + 1)
	}
	for f in u32(0) ..< 10 {
		known, matched := net.desync_monitor_receive(&dm, f, u64(f) * 7 + 1)
		testing.expect(t, known)
		testing.expect(t, matched)
	}
	testing.expect(t, !dm.desynced)
}

@(test)
desync_monitor_flags_the_first_mismatch_and_latches_it :: proc(t: ^testing.T) {
	dm: net.Desync_Monitor
	for f in u32(0) ..< 10 {
		net.desync_monitor_record(&dm, f, 42)
	}
	known5, matched5 := net.desync_monitor_receive(&dm, 5, 42)
	testing.expect(t, known5 && matched5)
	testing.expect(t, !dm.desynced)

	known7, matched7 := net.desync_monitor_receive(&dm, 7, 999) // a peer that has diverged
	testing.expect(t, known7)
	testing.expect(t, !matched7)
	testing.expect(t, dm.desynced)
	testing.expect_value(t, dm.desync_frame, u32(7))

	// A later matching report must not clear an already-latched desync --
	// the two states did diverge at frame 7, regardless of what happens
	// after.
	known9, matched9 := net.desync_monitor_receive(&dm, 9, 42)
	testing.expect(t, known9 && matched9)
	testing.expect(t, dm.desynced)
	testing.expect_value(t, dm.desync_frame, u32(7))
}
