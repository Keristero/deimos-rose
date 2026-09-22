// Phase 1 asset pipeline.
//
// Reads the four original PAK archives plus the loose " Data/Local" tree and
// writes an `assets/` directory of ordinary modern formats:
//
//   sprites/<dir>/<FOURCC>.png   IA alpha plate + IC colour plate -> RGBA PNG
//   images/<dir>/<FOURCC>.png    16-bit TGA -> RGBA PNG
//   audio/<FOURCC>.wav           AIFF-C ima4 -> 16-bit PCM WAV
//   films/<FOURCC>.film          replay data, copied verbatim
//   records/<dir>/<FOURCC>.bin   definition records, copied verbatim
//   manifest.json                every entry, with type, size and CRC32
//
// Definition records (unde/wede/plde/leve/...) are passed through byte-exact
// rather than decoded: their field layouts are Phase 3 work. The manifest still
// catalogues them so Phase 3 has an index to work from.
package extract

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"

Kind :: enum {
	Sprite,
	Image,
	Audio,
	Film,
	Record,
}

Manifest_Entry :: struct {
	fourcc:   string `json:"fourcc"`,
	name:     string `json:"name"`,
	kind:     string `json:"kind"`,
	dir:      string `json:"dir"`,
	source:   string `json:"source"`,
	output:   string `json:"output"`,
	bytes:    u32    `json:"bytes"`,
	crc32:    string `json:"crc32"`,
	width:    int    `json:"width,omitempty"`,
	height:   int    `json:"height,omitempty"`,
	channels: int    `json:"channels,omitempty"`,
	rate:     int    `json:"sample_rate,omitempty"`,
	frames:   int    `json:"frames,omitempty"`,
}

Manifest :: struct {
	generator: string           `json:"generator"`,
	game:      string           `json:"game"`,
	totals:    map[string]int   `json:"totals"`,
	entries:   []Manifest_Entry `json:"entries"`,
}

Stats :: struct {
	read, crc_ok, crc_bad, written, skipped: int,
}

g_entries: [dynamic]Manifest_Entry
g_stats: Stats

main :: proc() {
	args := os.args
	if len(args) < 3 {
		fmt.eprintln("usage: extract <original-install-dir> <assets-out-dir>")
		os.exit(2)
	}
	orig, out := args[1], args[2]

	rl.SetTraceLogLevel(.WARNING)

	paks := []string{"Audio.pak", "Game.pak", "Interface.pak", "Music.pak"}
	for p in paks {
		path := strings.concatenate({orig, "/ Data/Paks/", p}, context.temp_allocator)
		process_pak(path, p, out)
	}

	write_manifest(out)

	fmt.printfln(
		"\nread %v entries  crc ok %v  crc bad %v  written %v  passthrough %v",
		g_stats.read, g_stats.crc_ok, g_stats.crc_bad, g_stats.written, g_stats.skipped,
	)
	if g_stats.crc_bad > 0 {
		os.exit(1)
	}
}

process_pak :: proc(path, label, out: string) {
	z, err := data.zip_open(path)
	if err != .None {
		fmt.eprintfln("skip %v: %v", label, err)
		return
	}
	defer data.zip_close(&z)

	files := data.zip_files(&z)
	defer delete(files)
	fmt.printfln("%-16s %4d entries", label, len(files))

	// Gather sprite plates so IA/IC can be combined.
	plates := make(map[data.Pair_Key][2]([]byte))
	plate_meta := make(map[data.Pair_Key]data.Res_Name)
	defer delete(plates)
	defer delete(plate_meta)

	for e in files {
		g_stats.read += 1
		bytes, rerr := data.zip_read(&z, e)
		if rerr == .Crc_Mismatch {
			g_stats.crc_bad += 1
			fmt.eprintfln("  CRC MISMATCH %v", e.name)
			continue
		} else if rerr != .None {
			g_stats.crc_bad += 1
			fmt.eprintfln("  read failed %v: %v", e.name, rerr)
			continue
		}
		g_stats.crc_ok += 1

		rn, ok := data.parse_res_name(e.name)
		if !ok {
			fmt.eprintfln("  unparsed name: %v", e.name)
			continue
		}

		if rn.plate != .None {
			key := data.pair_key(rn)
			slot := plates[key]
			slot[rn.plate == .Alpha ? 0 : 1] = bytes
			plates[key] = slot
			// Either plate carries the same name and directory.
			plate_meta[key] = rn
			continue
		}
		emit_single(rn, e, bytes, label, out)
	}

	// Combine plates once both halves are known.
	keys, _ := slice.map_keys(plates)
	defer delete(keys)
	slice.sort_by(keys, proc(a, b: data.Pair_Key) -> bool {
		a, b := a, b // shadow so the fixed arrays become addressable
		if ad, bd := data.pair_dir(&a), data.pair_dir(&b); ad != bd {
			return ad < bd
		}
		return data.pair_fourcc(&a) < data.pair_fourcc(&b)
	})
	for key in keys {
		emit_sprite(key, plates[key], plate_meta[key], label, out)
	}
}

emit_single :: proc(rn: data.Res_Name, e: data.Zip_Entry, bytes: []byte, label, out: string) {
	crc := fmt.tprintf("%08x", hash.crc32(bytes))
	switch strings.to_lower(rn.ext, context.temp_allocator) {
	case "tga":
		px, w, h, terr := data.tga_decode_1555(bytes)
		if terr != .None {
			fmt.eprintfln("  tga %v: %v", e.name, terr)
			return
		}
		defer delete(px)
		rel := fmt.tprintf("images/%v/%v.png", rn.dir, rn.fourcc)
		if write_png(out, rel, px, w, h) {
			record(rn, "image", label, e, rel, crc, w, h, 0, 0, 0)
		}
	case "ima", "aif", "aiff":
		a, aerr := data.aiff_decode(bytes)
		if aerr != .None {
			fmt.eprintfln("  aiff %v: %v", e.name, aerr)
			return
		}
		defer delete(a.samples)
		rel := fmt.tprintf("audio/%v.wav", rn.fourcc)
		full := ensure_path(out, rel)
		defer delete(full)
		if data.wav_write(full, a) {
			g_stats.written += 1
			record(rn, "audio", label, e, rel, crc, 0, 0, a.channels, a.sample_rate,
				len(a.samples) / max(a.channels, 1))
		}
	case "film":
		rel := fmt.tprintf("films/%v.film", rn.fourcc)
		if write_raw(out, rel, bytes) {
			record(rn, "film", label, e, rel, crc, 0, 0, 0, 0, 0)
		}
	case:
		// Definition records: keep byte-exact for Phase 3.
		rel := fmt.tprintf("records/%v/%v.bin", rn.dir, rn.fourcc)
		if write_raw(out, rel, bytes) {
			g_stats.skipped += 1
			record(rn, "record", label, e, rel, crc, 0, 0, 0, 0, 0)
		}
	}
}

emit_sprite :: proc(key: data.Pair_Key, pair: [2]([]byte), rn: data.Res_Name, label, out: string) {
	key := key
	code := data.pair_fourcc(&key)
	alpha_raw, color_raw := pair[0], pair[1]
	if alpha_raw == nil || color_raw == nil {
		fmt.eprintfln("  incomplete plate pair %v/%v (alpha=%v colour=%v)",
			data.pair_dir(&key), code, alpha_raw != nil, color_raw != nil)
		return
	}

	ai := rl.LoadImageFromMemory(".gif", raw_data(alpha_raw), i32(len(alpha_raw)))
	ci := rl.LoadImageFromMemory(".gif", raw_data(color_raw), i32(len(color_raw)))
	defer rl.UnloadImage(ai)
	defer rl.UnloadImage(ci)
	if ai.data == nil || ci.data == nil {
		fmt.eprintfln("  gif decode failed for %v", code)
		return
	}
	if ai.width != ci.width || ai.height != ci.height {
		fmt.eprintfln("  plate size mismatch %v: %vx%v vs %vx%v",
			code, ai.width, ai.height, ci.width, ci.height)
		return
	}

	ap := rl.LoadImageColors(ai)
	cp := rl.LoadImageColors(ci)
	defer rl.UnloadImageColors(ap)
	defer rl.UnloadImageColors(cp)

	w, h := int(ai.width), int(ai.height)
	px := make([]data.Rgba, w * h)
	defer delete(px)
	for i in 0 ..< w * h {
		a := ap[i]
		c := cp[i]
		// The IA plate is a QuickDraw-style mask, so it is INVERTED with
		// respect to alpha: white (255) is fully transparent, black (0) fully
		// opaque, greys are partial coverage. Verified against Expl Small Red,
		// where IA is 255 across exactly the region IC fills with its
		// [0,255,156] background key.
		//
		// The two non-grey values, [0,0,255] and [255,0,255], appear
		// identically in both plates and are sprite-sheet grid markers rather
		// than image content. They are made transparent here; decoding them
		// into frame rectangles is Phase 3 work.
		alpha: u8 = 0
		if a.r == a.g && a.g == a.b {
			alpha = 255 - a.r
		}
		px[i] = data.Rgba{c.r, c.g, c.b, alpha}
	}

	rel := fmt.tprintf("sprites/%v/%v.png", rn.dir, code)
	if write_png(out, rel, px, w, h) {
		e := data.Zip_Entry{size = u32(len(alpha_raw) + len(color_raw))}
		record(rn, "sprite", label, e, rel,
			fmt.tprintf("%08x", hash.crc32(color_raw)), w, h, 0, 0, 0)
	}
}

// --- output helpers -------------------------------------------------------

// Join out+rel, create the parent directory chain, and return the full path.
ensure_path :: proc(out, rel: string) -> string {
	full := strings.concatenate({out, "/", rel})
	if i := strings.last_index_byte(full, '/'); i > 0 {
		os.make_directory_all(full[:i])
	}
	return full
}

write_raw :: proc(out, rel: string, bytes: []byte) -> bool {
	full := ensure_path(out, rel)
	defer delete(full)
	if os.write_entire_file(full, bytes) != nil {
		fmt.eprintfln("  write failed: %v", rel)
		return false
	}
	g_stats.written += 1
	return true
}

write_png :: proc(out, rel: string, px: []data.Rgba, w, h: int) -> bool {
	full := ensure_path(out, rel)
	defer delete(full)
	img := rl.Image {
		data    = raw_data(px),
		width   = i32(w),
		height  = i32(h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	cpath := strings.clone_to_cstring(full, context.temp_allocator)
	if !rl.ExportImage(img, cpath) {
		fmt.eprintfln("  png export failed: %v", rel)
		return false
	}
	g_stats.written += 1
	return true
}

record :: proc(
	rn: data.Res_Name,
	kind, source: string,
	e: data.Zip_Entry,
	rel, crc: string,
	w, h, ch, rate, frames: int,
) {
	append(&g_entries, Manifest_Entry {
		fourcc   = strings.clone(rn.fourcc),
		name     = strings.clone(rn.name),
		kind     = kind,
		dir      = strings.clone(rn.dir),
		source   = strings.clone(source),
		output   = strings.clone(rel),
		bytes    = e.size,
		crc32    = strings.clone(crc),
		width    = w,
		height   = h,
		channels = ch,
		rate     = rate,
		frames   = frames,
	})
}

write_manifest :: proc(out: string) {
	slice.sort_by(g_entries[:], proc(a, b: Manifest_Entry) -> bool {
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		if a.dir != b.dir {
			return a.dir < b.dir
		}
		return a.fourcc < b.fourcc
	})

	totals := make(map[string]int)
	defer delete(totals)
	for e in g_entries {
		totals[e.kind] += 1
	}
	totals["all"] = len(g_entries)

	m := Manifest {
		generator = "tools/extract",
		game      = "Deimos Rising 1.0.2 (Windows)",
		totals    = totals,
		entries   = g_entries[:],
	}
	blob, err := json.marshal(m, {pretty = true, use_spaces = true})
	if err != nil {
		fmt.eprintfln("manifest marshal failed: %v", err)
		return
	}
	defer delete(blob)
	full := ensure_path(out, "manifest.json")
	defer delete(full)
	if os.write_entire_file(full, blob) != nil {
		fmt.eprintln("manifest write failed")
		return
	}
	fmt.printfln("manifest: %v entries -> %v", len(g_entries), full)
}
