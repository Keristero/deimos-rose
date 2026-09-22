package data

import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"

// Minimal ZIP reader for the original PAK archives.
//
// Every entry in all four shipped PAKs uses compression method 0 (stored), so
// no decompressor is required -- only the central directory walk. This matches
// the U_Pak / unzip.obj pairing in the original binary.

Zip_Entry :: struct {
	name:        string,
	crc32:       u32,
	size:        u32,
	comp_size:   u32,
	method:      u16,
	local_off:   u32,
}

Zip :: struct {
	raw:     []byte,
	entries: []Zip_Entry,
}

Zip_Error :: enum {
	None,
	Read_Failed,
	Not_An_Archive,
	Truncated,
	Unsupported_Compression,
	Crc_Mismatch,
}

@(private)
r_u16 :: proc(b: []byte, o: int) -> u16 {
	return u16(b[o]) | u16(b[o + 1]) << 8
}

@(private)
r_u32 :: proc(b: []byte, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

zip_open :: proc(path: string, allocator := context.allocator) -> (z: Zip, err: Zip_Error) {
	raw, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return {}, .Read_Failed
	}
	z.raw = raw

	// Locate the End Of Central Directory record by scanning backwards.
	eocd := -1
	if len(raw) >= 22 {
		lo := max(0, len(raw) - 65557)
		for i := len(raw) - 22; i >= lo; i -= 1 {
			if r_u32(raw, i) == 0x0605_4b50 {
				eocd = i
				break
			}
		}
	}
	if eocd < 0 {
		delete(raw, allocator)
		return {}, .Not_An_Archive
	}

	count := int(r_u16(raw, eocd + 10))
	cd_off := int(r_u32(raw, eocd + 16))

	entries := make([dynamic]Zip_Entry, 0, count, allocator)
	o := cd_off
	for _ in 0 ..< count {
		if o + 46 > len(raw) || r_u32(raw, o) != 0x0201_4b50 {
			break
		}
		name_len := int(r_u16(raw, o + 28))
		extra_len := int(r_u16(raw, o + 30))
		cmt_len := int(r_u16(raw, o + 32))
		e := Zip_Entry {
			method    = r_u16(raw, o + 10),
			crc32     = r_u32(raw, o + 16),
			comp_size = r_u32(raw, o + 20),
			size      = r_u32(raw, o + 24),
			local_off = r_u32(raw, o + 42),
			name      = strings.clone(string(raw[o + 46:o + 46 + name_len]), allocator),
		}
		append(&entries, e)
		o += 46 + name_len + extra_len + cmt_len
	}
	z.entries = entries[:]
	return z, .None
}

zip_close :: proc(z: ^Zip, allocator := context.allocator) {
	for e in z.entries {
		delete(e.name, allocator)
	}
	delete(z.entries, allocator)
	delete(z.raw, allocator)
	z^ = {}
}

// Return a view into the archive buffer. Verifies the stored CRC32, which is
// how we assert byte-exact extraction of all 871 shipped files.
zip_read :: proc(z: ^Zip, e: Zip_Entry) -> (out: []byte, err: Zip_Error) {
	if e.method != 0 {
		return nil, .Unsupported_Compression
	}
	o := int(e.local_off)
	if o + 30 > len(z.raw) || r_u32(z.raw, o) != 0x0403_4b50 {
		return nil, .Truncated
	}
	name_len := int(r_u16(z.raw, o + 26))
	extra_len := int(r_u16(z.raw, o + 28))
	start := o + 30 + name_len + extra_len
	if start + int(e.size) > len(z.raw) {
		return nil, .Truncated
	}
	out = z.raw[start:start + int(e.size)]
	if hash.crc32(out) != e.crc32 {
		return out, .Crc_Mismatch
	}
	return out, .None
}

// Entries excluding directory markers, sorted by name for stable output.
zip_files :: proc(z: ^Zip, allocator := context.allocator) -> []Zip_Entry {
	out := make([dynamic]Zip_Entry, 0, len(z.entries), allocator)
	for e in z.entries {
		if len(e.name) > 0 && e.name[len(e.name) - 1] != '/' {
			append(&out, e)
		}
	}
	slice.sort_by(out[:], proc(a, b: Zip_Entry) -> bool { return a.name < b.name })
	return out[:]
}
