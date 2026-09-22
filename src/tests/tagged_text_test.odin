package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "dr:data"

// Canonical encoder for synthetic fixtures. The transform is not injective --
// decode(c) == decode(c ~ 0xff) -- so we simply pick the lowest byte that
// decodes to each value rather than pretend to reproduce the original stream.
@(private = "file")
encode :: proc(plain: string, allocator := context.allocator) -> []byte {
	table: [128]u8
	seen: [128]bool
	for c in 0 ..= 255 {
		v := data.tagged_decode_byte(u8(c))
		if v < 128 && !seen[v] {
			seen[v] = true
			table[v] = u8(c)
		}
	}
	out := make([]byte, len(plain), allocator)
	for i in 0 ..< len(plain) {
		out[i] = table[plain[i] & 0x7f]
	}
	return out
}

@(test)
tagged_encode_decode_round_trips :: proc(t: ^testing.T) {
	plain := "#name_STR <Kepler Massif>\r#numObjects_INT <46>\r"
	enc := encode(plain)
	defer delete(enc)
	dec := data.tagged_decode(enc)
	defer delete(dec)
	testing.expect_value(t, string(dec), plain)
}

@(test)
tagged_decode_drops_trailing_nul :: proc(t: ^testing.T) {
	enc := encode("ab\x00")
	defer delete(enc)
	dec := data.tagged_decode(enc)
	defer delete(dec)
	testing.expect_value(t, string(dec), "ab")
}

@(test)
tagged_parse_handles_the_observed_grammar :: proc(t: ^testing.T) {
	text := "// leading comment\r" +
		"#name_STR <Kepler Massif>\r" +
		"\t  #layer_ID <air >\r" +
		"\r" +
		"#count_INT <46> // trailing comment\r" +
		"a bare string list line\r"
	tags := data.tagged_parse(transmute([]byte)text)
	defer delete(tags)

	testing.expect_value(t, len(tags), 4)
	testing.expect_value(t, tags[0].key, "name_STR")
	testing.expect_value(t, tags[0].value, "Kepler Massif")
	// Indentation is stripped, but FourCC padding inside the value is not.
	testing.expect_value(t, tags[1].key, "layer_ID")
	testing.expect_value(t, tags[1].value, "air ")
	testing.expect_value(t, tags[2].value, "46")
	// A bare line becomes a keyless record, which is how .stli works.
	testing.expect_value(t, tags[3].key, "")
	testing.expect_value(t, tags[3].value, "a bare string list line")
}

@(test)
tagged_typed_values :: proc(t: ^testing.T) {
	i, ok1 := data.tag_int(" 46 ")
	testing.expect(t, ok1 && i == 46, "int")

	f, ok2 := data.tag_float("1.5")
	testing.expect(t, ok2 && f == 1.5, "float")

	b, ok3 := data.tag_bool("TRUE")
	testing.expect(t, ok3 && b, "TRUE")
	b2, ok4 := data.tag_bool("FALSE")
	testing.expect(t, ok4 && !b2, "FALSE")
	_, ok5 := data.tag_bool("true")
	testing.expect(t, !ok5, "lowercase is not valid in this corpus")

	// FourCC whitespace is significant: the air layer really is "air ".
	fc, ok6 := data.tag_fourcc("air ")
	testing.expect(t, ok6, "fourcc")
	testing.expect_value(t, data.fourcc_string(&fc), "air ")

	r, ok7 := data.tag_rect("0, 0, 480, 3600")
	testing.expect(t, ok7, "rect")
	testing.expect_value(t, r, data.Rect{0, 0, 480, 3600})

	c, ok8 := data.tag_rgb("#ff8000")
	testing.expect(t, ok8, "rgb")
	testing.expect_value(t, c, data.Rgb{255, 128, 0})
}

@(test)
level_parses_a_synthetic_resource :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	fmt.sbprint(&sb, "#name_STR <Test>\r#indentifier_STR <T>\r#description_STR <>\r")
	fmt.sbprint(&sb, "#copyright_STR <me>\r#background_RECT <0, 0, 480, 3600>\r")
	fmt.sbprint(&sb, "#backgroundImage_ID <cam1>\r#previewImage_ID <cap1>\r")
	fmt.sbprint(&sb, "#music_ID <mu03>\r#mediaMask_ID <cat1>\r#briefing_ID <none>\r")
	fmt.sbprint(&sb, "#numObjects_INT <1>\r")
	fmt.sbprint(&sb, "#unit_ID <fl02>\r#layer_ID <air >\r#xLoc_INT <178>\r#yLoc_INT <3020>\r")
	fmt.sbprint(&sb, "#headingDegrees_INT <0>\r#isStationary_BOOL <FALSE>\r")
	fmt.sbprint(&sb, "#enableTerrainEffects_BOOL <TRUE>\r")

	enc := encode(strings.to_string(sb))
	defer delete(enc)

	lv, err := data.level_parse(enc)
	defer data.level_destroy(&lv)
	testing.expect_value(t, err, data.Level_Error.None)
	testing.expect_value(t, lv.name, "Test")
	testing.expect_value(t, len(lv.placements), 1)
	testing.expect_value(t, lv.placements[0].x, 178)
	testing.expect_value(t, lv.placements[0].y, 3020)
	testing.expect(t, lv.placements[0].terrain_effects, "terrain effects flag")
	testing.expect(t, !lv.placements[0].is_stationary, "stationary flag")
}

@(test)
level_rejects_a_count_mismatch :: proc(t: ^testing.T) {
	text := "#name_STR <T>\r#indentifier_STR <T>\r#description_STR <>\r#copyright_STR <>\r" +
		"#background_RECT <0, 0, 1, 1>\r#backgroundImage_ID <cam1>\r#previewImage_ID <cap1>\r" +
		"#music_ID <mu03>\r#mediaMask_ID <cat1>\r#briefing_ID <none>\r#numObjects_INT <5>\r"
	enc := encode(text)
	defer delete(enc)
	_, err := data.level_parse(enc)
	testing.expect_value(t, err, data.Level_Error.Placement_Count_Mismatch)
}

// --- integration: the real corpus -----------------------------------------
// Skipped when assets/ has not been extracted, so CI runs without game data.

// Shared by the integration tests in this package.
ASSETS :: "assets"

@(test)
all_twelve_levels_reconcile :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records/leve") {
		return
	}
	total := 0
	for i in 1 ..= 12 {
		path := fmt.tprintf("%s/records/leve/le%02d.bin", ASSETS, i)
		raw, err := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, err == nil, "cannot read %v", path)
		if err != nil {
			continue
		}
		lv, perr := data.level_parse(raw)
		defer data.level_destroy(&lv)
		testing.expectf(t, perr == .None, "%v: %v", path, perr)
		total += len(lv.placements)
	}
	// The whole campaign places exactly this many objects.
	testing.expect_value(t, total, 565)
}

@(test)
every_record_decodes_to_ascii :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records") {
		return
	}
	dirs := []string {
		"coli", "flli", "idli", "leve", "plde", "reli", "stli", "tefo", "unde", "wede",
	}
	count := 0
	for d in dirs {
		dir := fmt.tprintf("%s/records/%s", ASSETS, d)
		handle, oerr := os.open(dir)
		if oerr != nil {
			continue
		}
		defer os.close(handle)
		entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
		if rerr != nil {
			continue
		}
		for e in entries {
			path := fmt.tprintf("%s/%s", dir, e.name)
			raw, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil {
				continue
			}
			dec := data.tagged_decode(raw, context.temp_allocator)
			for c in dec {
				testing.expectf(t, c < 0x80, "%v: non-ASCII byte 0x%02x", path, c)
			}
			count += 1
		}
	}
	// Ten tagged-text families, 473 records in total.
	testing.expect_value(t, count, 473)
}

// Collect the resource ids present in a directory, folding case so that
// sprite plates (stored under an uppercased code) match level references.
@(private = "file")
ids_in :: proc(dir, suffix: string, out: ^map[string]bool) {
	handle, oerr := os.open(dir)
	if oerr != nil {
		return
	}
	defer os.close(handle)
	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for e in entries {
		if !strings.has_suffix(e.name, suffix) {
			continue
		}
		id := strings.trim_suffix(e.name, suffix)
		out[strings.to_lower(id, context.temp_allocator)] = true
	}
}

@(test)
level_cross_resource_references_resolve :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records/leve") || !os.exists(ASSETS + "/manifest.json") {
		return
	}

	units := make(map[string]bool, 512, context.temp_allocator)
	ids_in(ASSETS + "/records/unde", ".bin", &units)
	testing.expect_value(t, len(units), 386)

	art := make(map[string]bool, 256, context.temp_allocator)
	ids_in(ASSETS + "/images/im16", ".png", &art)
	ids_in(ASSETS + "/sprites/im08", ".png", &art)

	audio := make(map[string]bool, 128, context.temp_allocator)
	ids_in(ASSETS + "/audio", ".wav", &audio)

	check :: proc(t: ^testing.T, set: ^map[string]bool, id: data.FourCC, what, lv: string) {
		id := id
		s := strings.trim_space(data.fourcc_string(&id))
		if s == "none" || s == "" {
			return
		}
		key := strings.to_lower(s, context.temp_allocator)
		testing.expectf(t, key in set^, "%v: %v %q does not resolve", lv, what, s)
	}

	layers := make(map[string]bool, 8, context.temp_allocator)
	total := 0
	for i in 1 ..= 12 {
		name := fmt.tprintf("le%02d", i)
		raw, err := os.read_entire_file(
			fmt.tprintf("%s/records/leve/%s.bin", ASSETS, name), context.temp_allocator)
		if err != nil {
			continue
		}
		lv, perr := data.level_parse(raw, context.temp_allocator)
		if perr != .None {
			continue
		}
		check(t, &art, lv.background_image, "backgroundImage", name)
		check(t, &art, lv.preview_image, "previewImage", name)
		check(t, &art, lv.media_mask, "mediaMask", name)
		check(t, &audio, lv.music, "music", name)

		for p in lv.placements {
			check(t, &units, p.unit, "unit", name)
			id := p.layer
			layers[strings.clone(data.fourcc_string(&id), context.temp_allocator)] = true
			total += 1
		}
	}
	testing.expect_value(t, total, 565)
	// The campaign uses a small closed set of layer ids.
	testing.expect(t, len(layers) > 0 && len(layers) <= 8, "layer id set should be small")
}
