package data

import "core:strconv"
import "core:strings"

// Ten of the eleven resource families -- leve, unde, plde, wede, idli, flli,
// coli, tefo, stli, reli -- are not binary structs. They are seven-bit ASCII
// text put through a reversible per-byte transform, then stored NUL-terminated.
//
// Verified over the whole Windows 1.0.2 corpus: all 473 records decode to pure
// ASCII with no replacement characters. The only non-printable bytes are one
// trailing NUL per record and four stray control characters that sit inside
// human-written #description_STR values in the original data.
//
// The transform matches the one the clean-room remaster documents for Mac
// 1.0.6, which is a useful cross-check: the same encoding shipped on both
// platforms.

// decode(c) is its own inverse only up to the ambiguity noted below.
tagged_decode_byte :: proc "contextless" (c: u8) -> u8 {
	v := ((c & 0x07) << 4) | (c >> 4)
	if c & 0x08 != 0 {
		v ~= 0x7f
	}
	return v
}

// Decode a resource body. The trailing NUL, if present, is dropped.
//
// Note that `decode(c) == decode(c ~ 0xff)`, so two distinct encoded bytes can
// represent the same character. Decoding is therefore well defined, but
// re-encoding cannot be guaranteed to reproduce the original byte stream.
tagged_decode :: proc(src: []byte, allocator := context.allocator) -> []byte {
	out := make([]byte, len(src), allocator)
	for c, i in src {
		out[i] = tagged_decode_byte(c)
	}
	n := len(out)
	for n > 0 && out[n - 1] == 0 {
		n -= 1
	}
	return out[:n]
}

// One `#key <value>` line.
Tag :: struct {
	key:   string,
	value: string,
}

// Parse decoded text into tag records.
//
// Grammar, as observed across the corpus: records are `#key <value>`, lines may
// be indented, line endings may be CR (Mac), LF or CRLF, `//` starts a comment,
// and `.stli` string lists contain bare lines with no `#key` at all. Bare lines
// are returned with an empty key so string lists work through the same parser.
tagged_parse :: proc(text: []byte, allocator := context.allocator) -> []Tag {
	out := make([dynamic]Tag, 0, 64, allocator)
	rest := string(text)
	for len(rest) > 0 {
		line: string
		if i := strings.index_any(rest, "\r\n"); i >= 0 {
			was_cr := rest[i] == '\r'
			line = rest[:i]
			rest = rest[i + 1:]
			// Swallow the LF of a CRLF pair so it does not yield a blank line.
			if was_cr && len(rest) > 0 && rest[0] == '\n' {
				rest = rest[1:]
			}
		} else {
			line = rest
			rest = ""
		}

		line = strings.trim_space(line)
		if len(line) == 0 || strings.has_prefix(line, "//") {
			continue
		}
		if line[0] != '#' {
			// Bare line: a .stli entry.
			append(&out, Tag{key = "", value = line})
			continue
		}

		body := line[1:]
		open := strings.index_byte(body, '<')
		if open < 0 {
			append(&out, Tag{key = strings.trim_space(body), value = ""})
			continue
		}
		// Values may themselves contain '>' only at the very end, and an
		// inline // comment may follow the closing bracket.
		close := strings.last_index_byte(body, '>')
		if close < open {
			continue
		}
		append(&out, Tag{
			key   = strings.trim_space(body[:open]),
			value = body[open + 1:close],
		})
	}
	return out[:]
}

// --- typed values ---------------------------------------------------------

// A four-byte resource identity. Whitespace inside it is significant: the
// canonical air layer really is "air " with a trailing space, so these are
// never trimmed.
FourCC :: distinct [4]u8

Rect :: struct {
	left, top, right, bottom: int,
}

Rgb :: [3]u8

fourcc_from :: proc(s: string) -> (f: FourCC) {
	for i in 0 ..< min(len(s), 4) {
		f[i] = s[i]
	}
	// Short codes are space padded, matching how the originals are written.
	for i in len(s) ..< 4 {
		f[i] = ' '
	}
	return
}

fourcc_string :: proc(f: ^FourCC) -> string {
	return string(f[:])
}

tag_int :: proc(value: string) -> (int, bool) {
	return strconv.parse_int(strings.trim_space(value))
}

tag_float :: proc(value: string) -> (f64, bool) {
	return strconv.parse_f64(strings.trim_space(value))
}

// The corpus writes booleans as bare TRUE / FALSE.
tag_bool :: proc(value: string) -> (bool, bool) {
	switch strings.trim_space(value) {
	case "TRUE":
		return true, true
	case "FALSE":
		return false, true
	}
	return false, false
}

tag_fourcc :: proc(value: string) -> (FourCC, bool) {
	if len(value) != 4 {
		return {}, false
	}
	return fourcc_from(value), true
}

// "0, 0, 480, 3600" -- ordered left, top, right, bottom.
tag_rect :: proc(value: string) -> (r: Rect, ok: bool) {
	parts := strings.split(value, ",", context.temp_allocator)
	if len(parts) != 4 {
		return {}, false
	}
	vals: [4]int
	for p, i in parts {
		v, good := strconv.parse_int(strings.trim_space(p))
		if !good {
			return {}, false
		}
		vals[i] = v
	}
	return Rect{vals[0], vals[1], vals[2], vals[3]}, true
}

// 24-bit hex, with or without a leading '#' or '0x'.
tag_rgb :: proc(value: string) -> (c: Rgb, ok: bool) {
	s := strings.trim_space(value)
	s = strings.trim_prefix(s, "#")
	s = strings.trim_prefix(s, "0x")
	if len(s) != 6 {
		return {}, false
	}
	v, good := strconv.parse_u64_of_base(s, 16)
	if !good {
		return {}, false
	}
	return Rgb{u8(v >> 16), u8(v >> 8), u8(v)}, true
}
