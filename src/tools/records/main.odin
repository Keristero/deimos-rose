// Decode the tagged-text resources into JSON.
//
// Ten resource families (leve, unde, plde, wede, idli, flli, coli, tefo, stli,
// reli) are seven-bit ASCII behind a reversible byte transform. Phase 1 copied
// them out byte-exact; this turns them into ordinary JSON.
//
// Levels get a typed schema because their layout is fully understood. The other
// nine families are emitted as ordered key/value lists, which is lossless and
// lets later phases add typed loaders without re-deriving the encoding.
//
//   assets/data/levels/<id>.json     typed
//   assets/data/<type>/<id>.json     ordered fields
//   assets/data/index.json           what was produced
package records

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "dr:data"

TAGGED :: []string {
	"coli", "flli", "idli", "leve", "plde", "reli", "stli", "tefo", "unde", "wede",
}

Field :: struct {
	key:   string `json:"key"`,
	value: string `json:"value"`,
}

Generic :: struct {
	id:     string  `json:"id"`,
	type:   string  `json:"type"`,
	fields: []Field `json:"fields"`,
}

Json_Placement :: struct {
	unit:            string `json:"unit"`,
	layer:           string `json:"layer"`,
	x:               int    `json:"x"`,
	y:               int    `json:"y"`,
	heading_degrees: int    `json:"heading_degrees"`,
	is_stationary:   bool   `json:"is_stationary"`,
	terrain_effects: bool   `json:"terrain_effects"`,
}

Json_Level :: struct {
	id:               string           `json:"id"`,
	name:             string           `json:"name"`,
	identifier:       string           `json:"identifier"`,
	description:      string           `json:"description"`,
	copyright:        string           `json:"copyright"`,
	background:       [4]int           `json:"background"`,
	background_image: string           `json:"background_image"`,
	preview_image:    string           `json:"preview_image"`,
	music:            string           `json:"music"`,
	media_mask:       string           `json:"media_mask"`,
	briefing:         string           `json:"briefing"`,
	placements:       []Json_Placement `json:"placements"`,
}

Index :: struct {
	generator:        string         `json:"generator"`,
	counts:           map[string]int `json:"counts"`,
	total_placements: int            `json:"total_placements"`,
}

fails := 0

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: records <assets-dir>")
		os.exit(2)
	}
	assets := os.args[1]

	counts := make(map[string]int)
	defer delete(counts)
	total_placements := 0

	for type in TAGGED {
		dir := fmt.tprintf("%s/records/%s", assets, type)
		handle, oerr := os.open(dir)
		if oerr != nil {
			fmt.eprintfln("skip %v: not extracted", type)
			continue
		}
		defer os.close(handle)
		entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
		if rerr != nil {
			continue
		}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

		for e in entries {
			if !strings.has_suffix(e.name, ".bin") {
				continue
			}
			id := strings.trim_suffix(e.name, ".bin")
			raw, err := os.read_entire_file(
				fmt.tprintf("%s/%s", dir, e.name), context.temp_allocator)
			if err != nil {
				fmt.eprintfln("  unreadable: %v/%v", type, e.name)
				fails += 1
				continue
			}

			if type == "leve" {
				n := emit_level(assets, id, raw)
				if n < 0 {
					fails += 1
					continue
				}
				total_placements += n
			} else if !emit_generic(assets, type, id, raw) {
				fails += 1
				continue
			}
			counts[type] += 1
		}
		fmt.printfln("%-6s %4d records", type, counts[type])
	}

	idx := Index {
		generator        = "tools/records",
		counts           = counts,
		total_placements = total_placements,
	}
	write_json(fmt.tprintf("%s/data/index.json", assets), idx)

	total := 0
	for _, v in counts {
		total += v
	}
	fmt.printfln("\n%d records -> JSON, %d level placements", total, total_placements)
	if fails > 0 {
		fmt.eprintfln("%d failures", fails)
		os.exit(1)
	}
}

emit_level :: proc(assets, id: string, raw: []byte) -> int {
	lv, err := data.level_parse(raw, context.temp_allocator)
	if err != .None {
		fmt.eprintfln("  level %v: %v", id, err)
		return -1
	}
	fc :: proc(f: FourCC_Alias) -> string {
		f := f
		return strings.clone(data.fourcc_string(&f), context.temp_allocator)
	}
	out := Json_Level {
		id               = id,
		name             = lv.name,
		identifier       = lv.identifier,
		description      = lv.description,
		copyright        = lv.copyright,
		background       = {lv.background.left, lv.background.top,
		                    lv.background.right, lv.background.bottom},
		background_image = fc(lv.background_image),
		preview_image    = fc(lv.preview_image),
		music            = fc(lv.music),
		media_mask       = fc(lv.media_mask),
		briefing         = fc(lv.briefing),
	}
	ps := make([]Json_Placement, len(lv.placements), context.temp_allocator)
	for p, i in lv.placements {
		ps[i] = Json_Placement {
			unit            = fc(p.unit),
			layer           = fc(p.layer),
			x               = p.x,
			y               = p.y,
			heading_degrees = p.heading_degrees,
			is_stationary   = p.is_stationary,
			terrain_effects = p.terrain_effects,
		}
	}
	out.placements = ps
	write_json(fmt.tprintf("%s/data/levels/%s.json", assets, id), out)
	return len(lv.placements)
}

FourCC_Alias :: data.FourCC

emit_generic :: proc(assets, type, id: string, raw: []byte) -> bool {
	text := data.tagged_decode(raw, context.temp_allocator)
	for c in text {
		if c >= 0x80 {
			fmt.eprintfln("  %v/%v: non-ASCII after decode", type, id)
			return false
		}
	}
	tags := data.tagged_parse(text, context.temp_allocator)
	fields := make([]Field, len(tags), context.temp_allocator)
	for tg, i in tags {
		fields[i] = Field{key = tg.key, value = tg.value}
	}
	write_json(fmt.tprintf("%s/data/%s/%s.json", assets, type, id),
		Generic{id = id, type = type, fields = fields})
	return true
}

write_json :: proc(path: string, value: any) {
	blob, err := json.marshal(value, {pretty = true, use_spaces = true},
		context.temp_allocator)
	if err != nil {
		fmt.eprintfln("  marshal failed for %v: %v", path, err)
		fails += 1
		return
	}
	if i := strings.last_index_byte(path, '/'); i > 0 {
		os.make_directory_all(path[:i])
	}
	if os.write_entire_file(path, blob) != nil {
		fmt.eprintfln("  write failed: %v", path)
		fails += 1
	}
}
