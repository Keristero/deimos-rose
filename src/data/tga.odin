package data

// Reader for the uncompressed 16-bit TGAs in Interface.pak / im16.
//
// These are image type 2, 16 bits per pixel, bottom-origin, with the layout
// A RRRRR GGGGG BBBBB packed little-endian -- the same 1555 pixel the engine's
// 16-bit blitter (U_Pixel16, W_Pixel16) works in. stb_image, and therefore
// raylib's loader, rejects 16bpp TGA, so we decode it ourselves.

Tga_Error :: enum {
	None,
	Truncated,
	Unsupported,
}

Rgba :: [4]u8

tga_decode_1555 :: proc(
	src: []byte,
	allocator := context.allocator,
) -> (
	pixels: []Rgba,
	w, h: int,
	err: Tga_Error,
) {
	if len(src) < 18 {
		return nil, 0, 0, .Truncated
	}
	id_len := int(src[0])
	cmap_type := src[1]
	img_type := src[2]
	width := int(r_u16(src, 12))
	height := int(r_u16(src, 14))
	depth := int(src[16])
	desc := src[17]

	if cmap_type != 0 || img_type != 2 || depth != 16 {
		return nil, 0, 0, .Unsupported
	}
	off := 18 + id_len
	need := width * height * 2
	if off + need > len(src) {
		return nil, 0, 0, .Truncated
	}

	top_origin := desc & 0x20 != 0
	out := make([]Rgba, width * height, allocator)
	for y in 0 ..< height {
		// TGA rows run bottom-to-top unless bit 5 of the descriptor is set.
		src_y := top_origin ? y : height - 1 - y
		for x in 0 ..< width {
			v := r_u16(src, off + (src_y * width + x) * 2)
			r5 := u8((v >> 10) & 0x1f)
			g5 := u8((v >> 5) & 0x1f)
			b5 := u8(v & 0x1f)
			// 5 -> 8 bit expansion that preserves full range.
			expand :: proc(c: u8) -> u8 { return (c << 3) | (c >> 2) }
			out[y * width + x] = Rgba{expand(r5), expand(g5), expand(b5), 255}
		}
	}
	return out, width, height, .None
}

// Raw 16-bit pixel values in top-down row order, as U_PixelBuffer holds them
// after U_Image loads a TGA. The media masks are compared against raw values
// (G_Bgnd_MediaMask_GetSurfaceAtLoc tests `== 0x1f`), so no conversion.
tga_decode_raw16 :: proc(
	src: []byte,
	allocator := context.allocator,
) -> (
	pixels: []u16,
	w, h: int,
	err: Tga_Error,
) {
	if len(src) < 18 {
		return nil, 0, 0, .Truncated
	}
	id_len := int(src[0])
	width := int(r_u16(src, 12))
	height := int(r_u16(src, 14))
	if src[1] != 0 || src[2] != 2 || src[16] != 16 {
		return nil, 0, 0, .Unsupported
	}
	off := 18 + id_len
	if off + width * height * 2 > len(src) {
		return nil, 0, 0, .Truncated
	}
	top_origin := src[17] & 0x20 != 0
	out := make([]u16, width * height, allocator)
	for y in 0 ..< height {
		src_y := top_origin ? y : height - 1 - y
		for x in 0 ..< width {
			out[y * width + x] = r_u16(src, off + (src_y * width + x) * 2)
		}
	}
	return out, width, height, .None
}
