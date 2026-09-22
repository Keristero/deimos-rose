package data

import "core:os"

// Canonical 16-bit PCM WAV writer.
//
// WAV rather than OGG: Odin's vendored stb_vorbis and raylib both decode Vorbis
// but neither encodes it, and pulling an encoder in to shrink 99 sound effects
// is not worth a build dependency. WAV is lossless, universally readable, and
// raylib loads it directly.
wav_write :: proc(path: string, a: Audio) -> bool {
	data_bytes := len(a.samples) * 2
	header: [44]byte

	put_str :: proc(b: []byte, o: int, s: string) {
		for i in 0 ..< len(s) {
			b[o + i] = s[i]
		}
	}
	put_u32 :: proc(b: []byte, o: int, v: u32) {
		b[o + 0] = u8(v)
		b[o + 1] = u8(v >> 8)
		b[o + 2] = u8(v >> 16)
		b[o + 3] = u8(v >> 24)
	}
	put_u16 :: proc(b: []byte, o: int, v: u16) {
		b[o + 0] = u8(v)
		b[o + 1] = u8(v >> 8)
	}

	byte_rate := u32(a.sample_rate * a.channels * 2)
	put_str(header[:], 0, "RIFF")
	put_u32(header[:], 4, u32(36 + data_bytes))
	put_str(header[:], 8, "WAVE")
	put_str(header[:], 12, "fmt ")
	put_u32(header[:], 16, 16)
	put_u16(header[:], 20, 1) // PCM
	put_u16(header[:], 22, u16(a.channels))
	put_u32(header[:], 24, u32(a.sample_rate))
	put_u32(header[:], 28, byte_rate)
	put_u16(header[:], 32, u16(a.channels * 2)) // block align
	put_u16(header[:], 34, 16)                  // bits per sample
	put_str(header[:], 36, "data")
	put_u32(header[:], 40, u32(data_bytes))

	buf := make([]byte, 44 + data_bytes, context.temp_allocator)
	copy(buf[:44], header[:])
	if data_bytes > 0 {
		raw := (cast([^]byte)raw_data(a.samples))[:data_bytes]
		copy(buf[44:], raw)
	}
	return os.write_entire_file(path, buf) == nil
}
