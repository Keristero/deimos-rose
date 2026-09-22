// Verifies an extracted assets/ tree against its manifest and against the
// original PAKs. Run by `mise run assets:verify`; exits non-zero on any
// discrepancy so CI can depend on it.
package verify

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"

Entry :: struct {
	fourcc:   string `json:"fourcc"`,
	name:     string `json:"name"`,
	kind:     string `json:"kind"`,
	dir:      string `json:"dir"`,
	source:   string `json:"source"`,
	output:   string `json:"output"`,
	bytes:    u32    `json:"bytes"`,
	crc32:    string `json:"crc32"`,
	width:    int    `json:"width"`,
	height:   int    `json:"height"`,
	channels: int    `json:"channels"`,
	rate:     int    `json:"sample_rate"`,
	frames:   int    `json:"frames"`,
}

Frame_Rect :: struct {
	x, y, w, h: int,
}

Sprite_Index_Entry :: struct {
	fourcc: string       `json:"fourcc"`,
	dir:    string       `json:"dir"`,
	image:  string       `json:"image"`,
	width:  int          `json:"width"`,
	height: int          `json:"height"`,
	frames: []Frame_Rect `json:"frames"`,
}

Sprite_Index :: struct {
	generator: string               `json:"generator"`,
	totals:    map[string]int       `json:"totals"`,
	sprites:   []Sprite_Index_Entry `json:"sprites"`,
}

Manifest :: struct {
	generator: string         `json:"generator"`,
	game:      string         `json:"game"`,
	totals:    map[string]int `json:"totals"`,
	entries:   []Entry        `json:"entries"`,
}

fails := 0

fail :: proc(format: string, args: ..any) {
	fmt.eprintf("  FAIL ")
	fmt.eprintfln(format, ..args)
	fails += 1
}

main :: proc() {
	args := os.args
	if len(args) < 3 {
		fmt.eprintln("usage: verify <original-install-dir> <assets-dir>")
		os.exit(2)
	}
	orig, assets := args[1], args[2]
	rl.SetTraceLogLevel(.ERROR)

	// 1. Every shipped PAK entry still CRC-validates.
	total_pak := 0
	for p in ([]string{"Audio.pak", "Game.pak", "Interface.pak", "Music.pak"}) {
		path := strings.concatenate({orig, "/ Data/Paks/", p}, context.temp_allocator)
		z, err := data.zip_open(path)
		if err != .None {
			fail("cannot open %v: %v", p, err)
			continue
		}
		defer data.zip_close(&z)
		files := data.zip_files(&z)
		defer delete(files)
		for e in files {
			total_pak += 1
			if _, rerr := data.zip_read(&z, e); rerr != .None {
				fail("%v/%v: %v", p, e.name, rerr)
			}
		}
	}
	fmt.printfln("pak entries CRC-verified: %v", total_pak)

	// 2. The manifest matches what is on disk.
	mpath := strings.concatenate({assets, "/manifest.json"}, context.temp_allocator)
	blob, rerr := os.read_entire_file(mpath, context.allocator)
	if rerr != nil {
		fail("manifest unreadable: %v", mpath)
		os.exit(1)
	}
	defer delete(blob)

	m: Manifest
	if jerr := json.unmarshal(blob, &m); jerr != nil {
		fail("manifest parse: %v", jerr)
		os.exit(1)
	}
	fmt.printfln("manifest entries: %v  totals: %v", len(m.entries), m.totals)

	if m.totals["all"] != len(m.entries) {
		fail("totals.all=%v but %v entries present", m.totals["all"], len(m.entries))
	}

	counted := 0
	for e in m.entries {
		full := strings.concatenate({assets, "/", e.output}, context.temp_allocator)
		fi, serr := os.stat(full, context.temp_allocator)
		if serr != nil {
			fail("missing output %v", e.output)
			continue
		}
		if fi.size == 0 {
			fail("empty output %v", e.output)
			continue
		}
		counted += 1

		// 3. Images re-decode at the recorded dimensions.
		if e.kind == "sprite" || e.kind == "image" {
			c := strings.clone_to_cstring(full, context.temp_allocator)
			img := rl.LoadImage(c)
			if img.data == nil {
				fail("png will not decode: %v", e.output)
				continue
			}
			defer rl.UnloadImage(img)
			if int(img.width) != e.width || int(img.height) != e.height {
				fail("%v: manifest says %vx%v, file is %vx%v",
					e.output, e.width, e.height, img.width, img.height)
			}
		}

		// 4. WAV headers agree with the manifest.
		if e.kind == "audio" {
			wav, werr := os.read_entire_file(full, context.temp_allocator)
			if werr != nil || len(wav) < 44 {
				fail("wav unreadable: %v", e.output)
				continue
			}
			if string(wav[0:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
				fail("not a RIFF/WAVE file: %v", e.output)
				continue
			}
			ch := int(wav[22]) | int(wav[23]) << 8
			rate := int(wav[24]) | int(wav[25]) << 8 | int(wav[26]) << 16 | int(wav[27]) << 24
			if ch != e.channels || rate != e.rate {
				fail("%v: manifest %vch/%vHz, file %vch/%vHz",
					e.output, e.channels, e.rate, ch, rate)
			}
		}
	}

	fmt.printfln("outputs present: %v/%v", counted, len(m.entries))

	verify_sprite_index(assets)
	if fails > 0 {
		fmt.eprintfln("\n%v problem(s)", fails)
		os.exit(1)
	}
	fmt.println("assets verified")
}

// 5. Frame rectangles: inside their plate, non-empty, and -- when a dump from
// the running original is present -- the same size the original computed.
//
// $DR_WINE/sprites.tsv is written by `mise run oracle:sprites`, which reads
// every loaded sprite group out of the live game under gdb. It covers the 55
// groups a demo session loads, which is the only ground truth we have; the
// remaining plates are checked for self-consistency only.
verify_sprite_index :: proc(assets: string) {
	path := strings.concatenate({assets, "/sprites/index.json"}, context.temp_allocator)
	blob, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fail("sprite index unreadable: %v", path)
		return
	}
	idx: Sprite_Index
	if jerr := json.unmarshal(blob, &idx, allocator = context.temp_allocator); jerr != nil {
		fail("sprite index parse: %v", jerr)
		return
	}
	frames := 0
	for s in idx.sprites {
		if len(s.frames) == 0 {
			fail("%v: no frames", s.fourcc)
		}
		for f, i in s.frames {
			frames += 1
			if f.w < 1 || f.h < 1 {
				fail("%v frame %v: empty rect %vx%v", s.fourcc, i, f.w, f.h)
			}
			if f.x < 0 || f.y < 0 || f.x + f.w > s.width || f.y + f.h > s.height {
				fail("%v frame %v: %v,%v %vx%v outside the %vx%v plate",
					s.fourcc, i, f.x, f.y, f.w, f.h, s.width, s.height)
			}
		}
	}
	fmt.printfln("sprite index: %v plates, %v frames", len(idx.sprites), frames)

	dump := strings.concatenate({os.get_env("DR_WINE", context.temp_allocator), "/sprites.tsv"},
		context.temp_allocator)
	text, terr := os.read_entire_file(dump, context.temp_allocator)
	if terr != nil {
		fmt.printfln("no %v; skipping the comparison with the original", dump)
		return
	}
	by_id := make(map[string][]Frame_Rect, len(idx.sprites), context.temp_allocator)
	for s in idx.sprites {
		by_id[strings.to_lower(s.fourcc, context.temp_allocator)] = s.frames
	}
	checked, missing := 0, 0
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 4 || f[0] == "sprite" {
			continue // header or blank
		}
		i, ok1 := strconv.parse_int(f[1])
		w, ok2 := strconv.parse_int(f[2])
		h, ok3 := strconv.parse_int(f[3])
		if !(ok1 && ok2 && ok3) {
			continue
		}
		rects, known := by_id[f[0]]
		if !known || i >= len(rects) {
			missing += 1
			continue
		}
		checked += 1
		if rects[i].w != w || rects[i].h != h {
			fail("%v frame %v: the original says %vx%v, our cut is %vx%v",
				f[0], i, w, h, rects[i].w, rects[i].h)
		}
	}
	if missing > 0 {
		fail("%v frame(s) in the original's dump have no entry in our index", missing)
	}
	fmt.printfln("frames checked against the running original: %v", checked)
}
