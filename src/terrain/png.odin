package terrain

// PNG writing, for the project's side files and the renderer's outputs.
// raylib's ExportImage writes 8-bit PNGs only, and a heightmap is 16-bit.
// The same pixels always give the same bytes, so a project saved twice is
// identical.

import "core:bytes"
import "core:hash"
import "core:os"

import rl "vendor:raylib"

// A picture in memory: rows from the top, `channels` samples a pixel, each
// one byte, or two (native order) when `depth` is 16.
Picture :: struct {
	width, height: int,
	channels:      int, // 1 grey, 3 RGB, 4 RGBA
	depth:         int, // 8 or 16
	pixels:        []u8,
}

picture_make :: proc(width, height, channels: int, depth := 8, allocator := context.allocator) -> Picture {
	return {width, height, channels, depth, make([]u8, width * height * channels * depth / 8, allocator)}
}

picture_destroy :: proc(p: ^Picture, allocator := context.allocator) {
	delete(p.pixels, allocator)
	p^ = {}
}

// The picture as a PNG file's bytes: each row Up-filtered, deflated by
// raylib.
png_encode :: proc(p: Picture, allocator := context.allocator) -> []u8 {
	stride := p.width * p.channels * p.depth / 8
	raw := make([]u8, (stride + 1) * p.height, context.temp_allocator)
	for y in 0 ..< p.height {
		row := raw[y * (stride + 1):][:stride + 1]
		row[0] = 2 // Up
		src := p.pixels[y * stride:][:stride]
		for x in 0 ..< stride {
			v := src[x]
			if p.depth == 16 {
				v = src[x ~ 1] // big-endian samples, from native order
			}
			above: u8
			if y > 0 {
				prev := p.pixels[(y - 1) * stride:]
				above = p.depth == 16 ? prev[x ~ 1] : prev[x]
			}
			row[1 + x] = v - above
		}
	}
	size: i32
	deflated := rl.CompressData(raw_data(raw), i32(len(raw)), &size)
	defer rl.MemFree(deflated)

	b: bytes.Buffer
	bytes.buffer_init_allocator(&b, 0, int(size) + 1024, allocator)
	bytes.buffer_write(&b, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})

	COLOUR_TYPES := [5]u8{0, 0, 4, 2, 6}
	colour_type := COLOUR_TYPES[p.channels]
	ihdr: [13]u8
	be32(ihdr[0:], u32(p.width))
	be32(ihdr[4:], u32(p.height))
	ihdr[8], ihdr[9] = u8(p.depth), colour_type
	png_chunk(&b, "IHDR", ihdr[:])

	// A zlib stream around raylib's raw deflate: header, data, Adler-32.
	z := make([]u8, int(size) + 6, context.temp_allocator)
	z[0], z[1] = 0x78, 0x01
	copy(z[2:], deflated[:size])
	be32(z[2 + size:], hash.adler32(raw))
	png_chunk(&b, "IDAT", z)
	png_chunk(&b, "IEND", nil)
	return b.buf[:]
}

png_write :: proc(path: string, p: Picture) -> bool {
	blob := png_encode(p, context.temp_allocator)
	return os.write_entire_file(path, blob) == nil
}

@(private = "file")
png_chunk :: proc(b: ^bytes.Buffer, type: string, data: []u8) {
	n: [4]u8
	be32(n[:], u32(len(data)))
	bytes.buffer_write(b, n[:])
	start := bytes.buffer_length(b)
	bytes.buffer_write_string(b, type)
	bytes.buffer_write(b, data)
	be32(n[:], hash.crc32(b.buf[start:]))
	bytes.buffer_write(b, n[:])
}

@(private = "file")
be32 :: proc(out: []u8, v: u32) {
	out[0], out[1], out[2], out[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}
