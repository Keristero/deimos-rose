package data

// Decoder for the AIFF-C / `ima4` audio shipped in Audio.pak and Music.pak.
//
// All 99 files are 44100 Hz AIFF-C with Apple's IMA ADPCM variant: 96 mono and
// 3 stereo. Each packet is 34 bytes and expands to 64 samples for one channel;
// stereo packets alternate left, right. The original decodes these through
// ADPCM_Mixer / ConvertFromIeeeExtended in the shipped binary.

Aiff_Error :: enum {
	None,
	Not_Aiff,
	Truncated,
	Unsupported_Compression,
	Missing_Chunk,
}

Audio :: struct {
	channels:    int,
	sample_rate: int,
	samples:     []i16, // interleaved
}

IMA_PACKET_BYTES :: 34
IMA_PACKET_SAMPLES :: 64

@(private)
ima_index_table := [16]i8{-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8}

@(private)
ima_step_table := [89]i32 {
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
	253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
	1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
	3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
	11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
	32767,
}

@(private)
be_u16 :: proc(b: []byte, o: int) -> u16 { return u16(b[o]) << 8 | u16(b[o + 1]) }

@(private)
be_u32 :: proc(b: []byte, o: int) -> u32 {
	return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3])
}

// 80-bit IEEE 754 extended -> int. AIFF stores the sample rate this way.
@(private)
ieee80_to_int :: proc(b: []byte) -> int {
	expon := int(be_u16(b, 0) & 0x7fff)
	mant := u64(be_u32(b, 2)) << 32 | u64(be_u32(b, 6))
	if expon == 0 && mant == 0 {
		return 0
	}
	shift := expon - 16383 - 63
	v := f64(mant)
	for _ in 0 ..< abs(shift) {
		if shift > 0 { v *= 2 } else { v /= 2 }
	}
	if b[0] & 0x80 != 0 {
		v = -v
	}
	return int(v + 0.5)
}

// Decode one 34-byte IMA packet into 64 samples, advancing predictor/index.
@(private)
ima_decode_packet :: proc(pkt: []byte, out: []i16, stride: int, pred: ^i32, index: ^i32) {
	preamble := be_u16(pkt, 0)
	// Top 9 bits are the predictor; bottom 7 the step index.
	pred^ = i32(i16(preamble & 0xff80))
	index^ = clamp(i32(preamble & 0x007f), 0, 88)

	o := 0
	for i in 0 ..< IMA_PACKET_SAMPLES {
		byte_index := 2 + i / 2
		nib: u8
		// Low nibble first.
		if i & 1 == 0 {
			nib = pkt[byte_index] & 0x0f
		} else {
			nib = pkt[byte_index] >> 4
		}

		step := ima_step_table[index^]
		diff := step >> 3
		if nib & 1 != 0 { diff += step >> 2 }
		if nib & 2 != 0 { diff += step >> 1 }
		if nib & 4 != 0 { diff += step }
		if nib & 8 != 0 { diff = -diff }

		pred^ = clamp(pred^ + diff, -32768, 32767)
		index^ = clamp(index^ + i32(ima_index_table[nib]), 0, 88)

		out[o] = i16(pred^)
		o += stride
	}
}

aiff_decode :: proc(src: []byte, allocator := context.allocator) -> (a: Audio, err: Aiff_Error) {
	if len(src) < 12 || string(src[0:4]) != "FORM" {
		return {}, .Not_Aiff
	}
	form := string(src[8:12])
	if form != "AIFC" && form != "AIFF" {
		return {}, .Not_Aiff
	}

	channels, rate := 0, 0
	compressed := false
	ssnd: []byte

	o := 12
	for o + 8 <= len(src) {
		id := string(src[o:o + 4])
		sz := int(be_u32(src, o + 4))
		body := o + 8
		if body + sz > len(src) {
			break
		}
		switch id {
		case "COMM":
			if sz < 18 {
				return {}, .Truncated
			}
			channels = int(be_u16(src, body))
			rate = ieee80_to_int(src[body + 8:body + 18])
			if sz >= 22 {
				comp := string(src[body + 18:body + 22])
				if comp != "ima4" {
					return {}, .Unsupported_Compression
				}
				compressed = true
			}
		case "SSND":
			if sz < 8 {
				return {}, .Truncated
			}
			// Skip the offset/blockSize header; both are zero in this corpus.
			ssnd = src[body + 8:body + sz]
		}
		o += 8 + sz + (sz & 1) // chunks are word-aligned
	}

	if channels == 0 || ssnd == nil {
		return {}, .Missing_Chunk
	}
	if !compressed {
		return {}, .Unsupported_Compression
	}

	packet_count := len(ssnd) / IMA_PACKET_BYTES
	// Stereo packets alternate channels, so whole frames need a full set.
	packet_count -= packet_count % channels
	frames := (packet_count / channels) * IMA_PACKET_SAMPLES

	a.channels = channels
	a.sample_rate = rate
	a.samples = make([]i16, frames * channels, allocator)

	preds := make([]i32, channels, context.temp_allocator)
	idxs := make([]i32, channels, context.temp_allocator)

	for p in 0 ..< packet_count {
		ch := p % channels
		frame := (p / channels) * IMA_PACKET_SAMPLES
		pkt := ssnd[p * IMA_PACKET_BYTES:(p + 1) * IMA_PACKET_BYTES]
		dst := a.samples[frame * channels + ch:]
		ima_decode_packet(pkt, dst, channels, &preds[ch], &idxs[ch])
	}
	return a, .None
}
