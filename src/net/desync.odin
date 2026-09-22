package netplay

// Phase 6 stage 4: desync detection. Rollback only ever corrects a
// misprediction it can see -- a genuine divergence (a real bug, or two
// builds that disagree) produces no error of its own, just two states that
// quietly stop matching. The only way to notice is to compare checksums the
// two peers computed independently and see if they still agree.

// Longer than ROLLBACK_DEPTH (net/session.odin): a checksum only needs to
// survive long enough for the peer's own report of it to arrive and be
// compared, which is a much smaller ask than surviving long enough to
// resimulate from.
CHECKSUM_LOG_DEPTH :: 256

@(private = "file")
Checksum_Slot :: struct {
	frame: u32,
	sum:   u64,
}

Checksum_Log :: struct {
	slots: [CHECKSUM_LOG_DEPTH]Checksum_Slot,
}

checksum_log_set :: proc(log: ^Checksum_Log, frame: u32, sum: u64) {
	log.slots[frame % CHECKSUM_LOG_DEPTH] = {frame, sum}
}

// ok is false when this frame was never recorded, or has since been
// overwritten by a later one landing in the same slot -- "don't know yet",
// not "known to match".
checksum_log_get :: proc(log: ^Checksum_Log, frame: u32) -> (sum: u64, ok: bool) {
	slot := log.slots[frame % CHECKSUM_LOG_DEPTH]
	if slot.frame != frame {
		return 0, false
	}
	return slot.sum, true
}

encode_checksum :: proc(buf: []byte, frame: u32, sum: u64) -> int {
	buf[0] = u8(Packet_Kind.Checksum)
	buf[1] = u8(frame); buf[2] = u8(frame >> 8); buf[3] = u8(frame >> 16); buf[4] = u8(frame >> 24)
	for i in 0 ..< 8 {
		buf[5 + i] = u8(sum >> uint(i * 8))
	}
	return 13
}

decode_checksum :: proc(buf: []byte) -> (frame: u32, sum: u64, ok: bool) {
	if len(buf) < 13 || Packet_Kind(buf[0]) != .Checksum {
		return 0, 0, false
	}
	frame = u32(buf[1]) | u32(buf[2]) << 8 | u32(buf[3]) << 16 | u32(buf[4]) << 24
	for i in 0 ..< 8 {
		sum |= u64(buf[5 + i]) << uint(i * 8)
	}
	return frame, sum, true
}

Desync_Monitor :: struct {
	log:          Checksum_Log,
	desynced:     bool,
	desync_frame: u32,
}

// Call once per frame (or at whatever cadence the caller sends Checksum
// packets on -- every frame recorded here costs nothing but 12 bytes of a
// fixed array, so there is no reason to record less often than that even if
// packets go out less often).
desync_monitor_record :: proc(dm: ^Desync_Monitor, frame: u32, sum: u64) {
	checksum_log_set(&dm.log, frame, sum)
}

// Call for every decoded Checksum packet from the peer. Compares it against
// this machine's own recorded checksum for the same frame, if that frame is
// still in the log; latches `desynced` permanently once any mismatch is
// found; returns whether the frame was known and, if so, whether it matched.
desync_monitor_receive :: proc(dm: ^Desync_Monitor, frame: u32, remote_sum: u64) -> (known: bool, matched: bool) {
	local_sum, ok := checksum_log_get(&dm.log, frame)
	if !ok {
		return false, false
	}
	matched = local_sum == remote_sum
	if !matched && !dm.desynced {
		dm.desynced = true
		dm.desync_frame = frame
	}
	return true, matched
}
