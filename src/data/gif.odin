package data

// A GIF decoder that returns palette *indices*, not colours.
//
// The original cuts sprite plates into frames by comparing raw 8-bit pixel
// values (U_Image_GetPixelBuffer(id, 8, 'GIF ') feeding
// U_SpritePlate_GetBitmapRectListFromPlate), so frame geometry must be
// computed on indices: two palette entries with the same colour are still
// different markers. Only the first image of a file is decoded, which is all
// the sprite plates contain.

Gif_Error :: enum {
	None,
	Not_Gif,
	Truncated,
	No_Image,
	Bad_Code,
}

Gif :: struct {
	width, height: int,
	pixels:        []u8, // width * height palette indices, row-major
	palette:       [][3]u8,
}

gif_destroy :: proc(g: ^Gif, allocator := context.allocator) {
	delete(g.pixels, allocator)
	delete(g.palette, allocator)
}

gif_decode :: proc(src: []byte, allocator := context.allocator) -> (g: Gif, err: Gif_Error) {
	if len(src) < 13 || string(src[:3]) != "GIF" {
		return {}, .Not_Gif
	}
	pos: int
	u16le :: proc(b: []byte, o: int) -> int { return int(b[o]) | int(b[o + 1]) << 8 }

	flags := src[10]
	pos = 13
	global: [][3]u8
	if flags & 0x80 != 0 {
		n := 1 << (uint(flags & 7) + 1)
		if pos + 3 * n > len(src) {
			return {}, .Truncated
		}
		global = (transmute([][3]u8)src[pos:pos + 3 * n])[:n]
		pos += 3 * n
	}

	for pos < len(src) {
		switch src[pos] {
		case 0x21: // extension: label, then sub-blocks
			pos += 2
			for pos < len(src) && src[pos] != 0 {
				pos += int(src[pos]) + 1
			}
			pos += 1
		case 0x2c: // image descriptor
			if pos + 10 > len(src) {
				return {}, .Truncated
			}
			w, h := u16le(src, pos + 5), u16le(src, pos + 7)
			iflags := src[pos + 9]
			pos += 10
			pal := global
			if iflags & 0x80 != 0 {
				n := 1 << (uint(iflags & 7) + 1)
				if pos + 3 * n > len(src) {
					return {}, .Truncated
				}
				pal = (transmute([][3]u8)src[pos:pos + 3 * n])[:n]
				pos += 3 * n
			}
			if pos >= len(src) {
				return {}, .Truncated
			}
			min_code := int(src[pos])
			pos += 1

			// Gather the sub-blocks into one LZW stream.
			stream := make([dynamic]byte, 0, len(src) - pos, context.temp_allocator)
			for pos < len(src) && src[pos] != 0 {
				n := int(src[pos])
				if pos + 1 + n > len(src) {
					return {}, .Truncated
				}
				append(&stream, ..src[pos + 1:pos + 1 + n])
				pos += n + 1
			}

			g.width, g.height = w, h
			g.pixels = make([]u8, w * h, allocator)
			g.palette = make([][3]u8, len(pal), allocator)
			copy(g.palette, pal)
			out := make([]u8, w * h, context.temp_allocator)
			if e := lzw_decode(stream[:], min_code, out); e != .None {
				gif_destroy(&g, allocator)
				return {}, e
			}
			if iflags & 0x40 != 0 {
				// Interlaced: rows arrive in four passes.
				row := 0
				starts := [4]int{0, 4, 2, 1}
				steps := [4]int{8, 8, 4, 2}
				for pass in 0 ..< 4 {
					start, step := starts[pass], steps[pass]
					for y := start; y < h; y += step {
						copy(g.pixels[y * w:(y + 1) * w], out[row * w:(row + 1) * w])
						row += 1
					}
				}
			} else {
				copy(g.pixels, out)
			}
			return g, .None
		case 0x3b:
			return {}, .No_Image
		case:
			return {}, .Bad_Code
		}
	}
	return {}, .No_Image
}

@(private = "file")
lzw_decode :: proc(stream: []byte, min_code: int, out: []u8) -> Gif_Error {
	if min_code < 2 || min_code > 11 {
		return .Bad_Code
	}
	clear_code := 1 << uint(min_code)
	end_code := clear_code + 1

	// Each code is a (prefix, suffix) pair; strings are rebuilt backwards.
	prefix: [4096]u16
	suffix: [4096]u8
	first: [4096]u8
	length: [4096]u16
	for i in 0 ..< clear_code {
		suffix[i], first[i], length[i] = u8(i), u8(i), 1
	}

	size := min_code + 1
	next := end_code + 1
	prev := -1
	bits, nbits := 0, 0
	o := 0
	i := 0
	for {
		for nbits < size {
			if i >= len(stream) {
				return .None // tolerate a missing end code
			}
			bits |= int(stream[i]) << uint(nbits)
			nbits += 8
			i += 1
		}
		code := bits & ((1 << uint(size)) - 1)
		bits >>= uint(size)
		nbits -= size

		if code == clear_code {
			size, next, prev = min_code + 1, end_code + 1, -1
			continue
		}
		if code == end_code {
			return .None
		}
		if prev < 0 {
			if code >= clear_code {
				return .Bad_Code
			}
			if o < len(out) {
				out[o] = u8(code)
				o += 1
			}
			prev = code
			continue
		}

		// A code not yet in the table is prev's string plus its first byte.
		known := code < next
		if !known && code != next {
			return .Bad_Code
		}
		if next < 4096 {
			prefix[next] = u16(prev)
			suffix[next] = known ? first[code] : first[prev]
			first[next] = first[prev]
			length[next] = length[prev] + 1
			next += 1
			if next == 1 << uint(size) && size < 12 {
				size += 1
			}
		}

		n := int(length[code])
		end := min(o + n, len(out))
		c := code
		for k := o + n - 1; k >= o; k -= 1 {
			if k < end {
				out[k] = suffix[c]
			}
			c = int(prefix[c])
		}
		o = end
		prev = code
	}
}
