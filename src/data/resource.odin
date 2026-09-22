package data

import "core:strings"

// Resource naming in the original PAKs and in " Data/Local":
//
//     im08/Expl Small Red IA[EXSR].gif
//     unde/Assault Flipper[aspl].unde
//     \___/\______________/ \/\____/ \__/
//      dir      name      plate fourcc ext
//
// The four-byte code is the resource identity the engine looks up; the human
// name is documentation. Sprite sheets ship as two plates: `IA` carries a
// greyscale alpha mask under an UPPERCASE code, `IC` the colour image under the
// same code lowercased.
Plate :: enum u8 {
	None,
	Alpha, // IA
	Color, // IC
}

Res_Name :: struct {
	dir:    string, // FourCC directory, e.g. "im08"; empty for flat archives
	name:   string, // trimmed human-readable name
	plate:  Plate,
	fourcc: string, // exactly 4 bytes, case-significant
	ext:    string, // without the dot
}

// Identity shared by an IA/IC plate pair: the directory plus the four-byte
// code with case folded away. A fixed-size value so that grouping plates
// needs no allocation and no cleanup.
Pair_Key :: struct {
	dir:    [16]u8,
	fourcc: [4]u8,
}

// Views onto a Pair_Key. These take a pointer because Odin cannot slice a
// fixed array held in a by-value parameter.
pair_dir :: proc(k: ^Pair_Key) -> string {
	n := 0
	for n < len(k.dir) && k.dir[n] != 0 {
		n += 1
	}
	return string(k.dir[:n])
}

pair_fourcc :: proc(k: ^Pair_Key) -> string {
	return string(k.fourcc[:])
}

pair_key :: proc(r: Res_Name) -> (k: Pair_Key) {
	n := min(len(r.dir), len(k.dir))
	copy(k.dir[:n], r.dir[:n])
	for i in 0 ..< min(len(r.fourcc), 4) {
		c := r.fourcc[i]
		k.fourcc[i] = c >= 'a' && c <= 'z' ? c - 32 : c
	}
	return
}

// Parse a PAK entry path. Returns ok=false if the name does not carry a
// bracketed four-byte code.
// All fields alias `path`; nothing is allocated, so there is nothing to free.
parse_res_name :: proc(path: string) -> (r: Res_Name, ok: bool) {
	rest := path
	if i := strings.last_index_byte(rest, '/'); i >= 0 {
		r.dir = rest[:i]
		rest = rest[i + 1:]
	}
	dot := strings.last_index_byte(rest, '.')
	if dot < 0 {
		return {}, false
	}
	r.ext = rest[dot + 1:]
	stem := rest[:dot]

	open := strings.last_index_byte(stem, '[')
	if open < 0 || len(stem) == 0 || stem[len(stem) - 1] != ']' {
		return {}, false
	}
	r.fourcc = stem[open + 1:len(stem) - 1]
	if len(r.fourcc) != 4 {
		return {}, false
	}

	label := strings.trim_space(stem[:open])
	switch {
	case strings.has_suffix(label, " IA"):
		r.plate = .Alpha
		label = strings.trim_space(label[:len(label) - 3])
	case strings.has_suffix(label, " IC"):
		r.plate = .Color
		label = strings.trim_space(label[:len(label) - 3])
	}
	r.name = label
	return r, true
}
