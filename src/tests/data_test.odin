package tests

import "core:os"
import "core:testing"

import "dr:data"

// --- resource names -------------------------------------------------------

@(test)
res_name_parses_sprite_plates :: proc(t: ^testing.T) {
	a, ok1 := data.parse_res_name("im08/Expl Small Red IA[EXSR].gif")
	testing.expect(t, ok1, "alpha plate should parse")
	testing.expect_value(t, a.dir, "im08")
	testing.expect_value(t, a.name, "Expl Small Red")
	testing.expect_value(t, a.fourcc, "EXSR")
	testing.expect_value(t, a.ext, "gif")
	testing.expect_value(t, a.plate, data.Plate.Alpha)

	c, ok2 := data.parse_res_name("im08/Expl Small Red IC[exsr].gif")
	testing.expect(t, ok2, "colour plate should parse")
	testing.expect_value(t, c.plate, data.Plate.Color)
	testing.expect_value(t, c.fourcc, "exsr")

	// The pair key folds case on the code, so the two plates meet.
	testing.expect_value(t, data.pair_key(a), data.pair_key(c))
}

@(test)
res_name_parses_records :: proc(t: ^testing.T) {
	r, ok := data.parse_res_name("unde/Assault Flipper[aspl].unde")
	testing.expect(t, ok, "record should parse")
	testing.expect_value(t, r.dir, "unde")
	testing.expect_value(t, r.name, "Assault Flipper")
	testing.expect_value(t, r.fourcc, "aspl")
	testing.expect_value(t, r.plate, data.Plate.None)
}

@(test)
res_name_handles_flat_archives :: proc(t: ^testing.T) {
	r, ok := data.parse_res_name("Accuracy Bonus[acbo].IMA")
	testing.expect(t, ok, "flat entry should parse")
	testing.expect_value(t, r.dir, "")
	testing.expect_value(t, r.fourcc, "acbo")
	testing.expect_value(t, r.ext, "IMA")
}

@(test)
res_name_rejects_malformed :: proc(t: ^testing.T) {
	for bad in ([]string{"no-brackets.gif", "im08/tooshort[ABC].gif", "noextension[ABCD]"}) {
		_, ok := data.parse_res_name(bad)
		testing.expectf(t, !ok, "%q should not parse", bad)
	}
}

// --- 16-bit TGA -----------------------------------------------------------

@(private = "file")
make_tga_1555 :: proc(w, h: int, px: []u16, top_origin: bool) -> []byte {
	buf := make([]byte, 18 + len(px) * 2)
	buf[2] = 2 // uncompressed true-colour
	buf[12] = u8(w)
	buf[13] = u8(w >> 8)
	buf[14] = u8(h)
	buf[15] = u8(h >> 8)
	buf[16] = 16
	buf[17] = top_origin ? 0x20 : 0x00
	for v, i in px {
		buf[18 + i * 2] = u8(v)
		buf[18 + i * 2 + 1] = u8(v >> 8)
	}
	return buf
}

@(test)
tga_expands_555_to_888 :: proc(t: ^testing.T) {
	RED :: u16(31) << 10
	src := make_tga_1555(1, 1, []u16{RED}, true)
	defer delete(src)

	px, w, h, err := data.tga_decode_1555(src)
	defer delete(px)
	testing.expect_value(t, err, data.Tga_Error.None)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, h, 1)
	// 5 bits of 1s must expand to a full 255, not 248.
	testing.expect_value(t, px[0], data.Rgba{255, 0, 0, 255})
}

@(test)
tga_flips_bottom_origin_rows :: proc(t: ^testing.T) {
	RED :: u16(31) << 10
	BLUE :: u16(31)
	// One column, two rows. Stored bottom-up: first stored pixel is the
	// BOTTOM row, so decoded row 0 must be the second stored value.
	src := make_tga_1555(1, 2, []u16{RED, BLUE}, false)
	defer delete(src)

	px, _, _, err := data.tga_decode_1555(src)
	defer delete(px)
	testing.expect_value(t, err, data.Tga_Error.None)
	testing.expect_value(t, px[0], data.Rgba{0, 0, 255, 255}) // top row
	testing.expect_value(t, px[1], data.Rgba{255, 0, 0, 255}) // bottom row

	top := make_tga_1555(1, 2, []u16{RED, BLUE}, true)
	defer delete(top)
	px2, _, _, _ := data.tga_decode_1555(top)
	defer delete(px2)
	testing.expect_value(t, px2[0], data.Rgba{255, 0, 0, 255})
}

@(test)
tga_rejects_unsupported :: proc(t: ^testing.T) {
	src := make_tga_1555(1, 1, []u16{0}, true)
	defer delete(src)
	src[16] = 24 // 24bpp is handled by raylib, not by this decoder
	_, _, _, err := data.tga_decode_1555(src)
	testing.expect_value(t, err, data.Tga_Error.Unsupported)
}

// --- AIFF-C / ima4 --------------------------------------------------------

@(private = "file")
make_aifc_ima4 :: proc(packet: []byte) -> []byte {
	comm_size := 22 + 2 // + 1-byte pstring "" padded
	ssnd_size := 8 + len(packet)
	total := 4 + (8 + comm_size) + (8 + ssnd_size)
	buf := make([]byte, 8 + total)

	be32 :: proc(b: []byte, o: int, v: u32) {
		b[o] = u8(v >> 24); b[o+1] = u8(v >> 16); b[o+2] = u8(v >> 8); b[o+3] = u8(v)
	}
	be16 :: proc(b: []byte, o: int, v: u16) { b[o] = u8(v >> 8); b[o+1] = u8(v) }
	str :: proc(b: []byte, o: int, s: string) { for i in 0 ..< len(s) { b[o+i] = s[i] } }

	str(buf, 0, "FORM"); be32(buf, 4, u32(total)); str(buf, 8, "AIFC")
	o := 12
	str(buf, o, "COMM"); be32(buf, o+4, u32(comm_size))
	be16(buf, o+8, 1)          // channels
	be32(buf, o+10, 1)         // numSampleFrames (packet count for ima4)
	be16(buf, o+14, 16)        // sample size
	// 44100 as 80-bit IEEE extended.
	buf[o+16] = 0x40; buf[o+17] = 0x0E; buf[o+18] = 0xAC; buf[o+19] = 0x44
	str(buf, o+26, "ima4")
	o += 8 + comm_size
	str(buf, o, "SSND"); be32(buf, o+4, u32(ssnd_size))
	copy(buf[o+16:], packet)
	return buf
}

@(test)
aiff_decodes_ima4_packet :: proc(t: ^testing.T) {
	pkt := make([]byte, data.IMA_PACKET_BYTES)
	defer delete(pkt)
	// preamble 0 => predictor 0, step index 0.
	// First nibble (low nibble of byte 2) = 4 => diff = step_table[0] = 7.
	pkt[2] = 0x04

	src := make_aifc_ima4(pkt)
	defer delete(src)

	a, err := data.aiff_decode(src)
	defer delete(a.samples)
	testing.expect_value(t, err, data.Aiff_Error.None)
	testing.expect_value(t, a.channels, 1)
	testing.expect_value(t, a.sample_rate, 44100)
	testing.expect_value(t, len(a.samples), data.IMA_PACKET_SAMPLES)
	testing.expect_value(t, a.samples[0], i16(7))
	// Second nibble is 0: diff = step_table[2] >> 3 = 1, so 7 + 1 = 8.
	testing.expect_value(t, a.samples[1], i16(8))
}

@(test)
aiff_rejects_non_aiff :: proc(t: ^testing.T) {
	_, err := data.aiff_decode([]byte{'J', 'U', 'N', 'K', 0, 0, 0, 0, 'A', 'I', 'F', 'C'})
	testing.expect_value(t, err, data.Aiff_Error.Not_Aiff)
}

// --- integration ----------------------------------------------------------
// Skipped unless the extracted original install is present, so CI stays
// runnable without shipping copyrighted data.

@(test)
original_paks_crc_validate :: proc(t: ^testing.T) {
	path := "../game/ Data/Paks/Game.pak"
	if !os.exists(path) {
		// The original data is not redistributed, so CI can run without it.
		return
	}
	z, err := data.zip_open(path)
	testing.expect_value(t, err, data.Zip_Error.None)
	if err != .None {
		return
	}
	defer data.zip_close(&z)

	files := data.zip_files(&z)
	defer delete(files)
	testing.expect_value(t, len(files), 763)

	bad := 0
	for e in files {
		if _, rerr := data.zip_read(&z, e); rerr != .None {
			bad += 1
		}
	}
	testing.expect_value(t, bad, 0)
}
