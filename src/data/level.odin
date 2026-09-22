package data

// Level resources (`leve`, 12 of them) as tagged text.
//
// Every level opens with the same eleven fields in the same order, followed by
// exactly `numObjects_INT` placements of seven fields each. Verified across all
// 12 levels of the Windows 1.0.2 corpus: declared counts reconcile exactly,
// totalling 565 placements.

Level_Error :: enum {
	None,
	Missing_Field,
	Bad_Value,
	Wrong_Field_Order,
	Placement_Count_Mismatch,
}

Placement :: struct {
	unit:             FourCC,
	layer:            FourCC,
	x, y:             int,
	heading_degrees:  int,
	is_stationary:    bool,
	terrain_effects:  bool,
}

Level :: struct {
	name:        string,
	// The original data misspells this tag as `indentifier_STR`; the
	// misspelling is part of the format and is matched verbatim below.
	identifier:  string,
	description: string,
	copyright:   string,

	background:       Rect,
	background_image: FourCC,
	preview_image:    FourCC,
	music:            FourCC,
	media_mask:       FourCC,
	briefing:         FourCC,

	placements: []Placement,
}

@(private = "file")
HEADER := [11]string {
	"name_STR",
	"indentifier_STR",
	"description_STR",
	"copyright_STR",
	"background_RECT",
	"backgroundImage_ID",
	"previewImage_ID",
	"music_ID",
	"mediaMask_ID",
	"briefing_ID",
	"numObjects_INT",
}

@(private = "file")
PLACEMENT := [7]string {
	"unit_ID",
	"layer_ID",
	"xLoc_INT",
	"yLoc_INT",
	"headingDegrees_INT",
	"isStationary_BOOL",
	"enableTerrainEffects_BOOL",
}

// Parse a level from its *encoded* resource bytes.
level_parse :: proc(
	encoded: []byte,
	allocator := context.allocator,
) -> (
	lv: Level,
	err: Level_Error,
) {
	text := tagged_decode(encoded, context.temp_allocator)
	tags := tagged_parse(text, context.temp_allocator)

	if len(tags) < len(HEADER) {
		return {}, .Missing_Field
	}
	// Field order is part of the format, so it is checked rather than assumed.
	for want, i in HEADER {
		if tags[i].key != want {
			return {}, .Wrong_Field_Order
		}
	}

	ok: bool
	lv.name = tags[0].value
	lv.identifier = tags[1].value
	lv.description = tags[2].value
	lv.copyright = tags[3].value
	if lv.background, ok = tag_rect(tags[4].value); !ok {
		return {}, .Bad_Value
	}
	if lv.background_image, ok = tag_fourcc(tags[5].value); !ok {
		return {}, .Bad_Value
	}
	if lv.preview_image, ok = tag_fourcc(tags[6].value); !ok {
		return {}, .Bad_Value
	}
	if lv.music, ok = tag_fourcc(tags[7].value); !ok {
		return {}, .Bad_Value
	}
	if lv.media_mask, ok = tag_fourcc(tags[8].value); !ok {
		return {}, .Bad_Value
	}
	if lv.briefing, ok = tag_fourcc(tags[9].value); !ok {
		return {}, .Bad_Value
	}

	count: int
	if count, ok = tag_int(tags[10].value); !ok {
		return {}, .Bad_Value
	}

	body := tags[len(HEADER):]
	if len(body) != count * len(PLACEMENT) {
		return {}, .Placement_Count_Mismatch
	}

	lv.placements = make([]Placement, count, allocator)
	for i in 0 ..< count {
		rec := body[i * len(PLACEMENT):][:len(PLACEMENT)]
		for want, j in PLACEMENT {
			if rec[j].key != want {
				delete(lv.placements, allocator)
				return {}, .Wrong_Field_Order
			}
		}
		p: Placement
		if p.unit, ok = tag_fourcc(rec[0].value); !ok {
			break
		}
		if p.layer, ok = tag_fourcc(rec[1].value); !ok {
			break
		}
		if p.x, ok = tag_int(rec[2].value); !ok {
			break
		}
		if p.y, ok = tag_int(rec[3].value); !ok {
			break
		}
		if p.heading_degrees, ok = tag_int(rec[4].value); !ok {
			break
		}
		if p.is_stationary, ok = tag_bool(rec[5].value); !ok {
			break
		}
		if p.terrain_effects, ok = tag_bool(rec[6].value); !ok {
			break
		}
		lv.placements[i] = p
	}
	if !ok {
		delete(lv.placements, allocator)
		return {}, .Bad_Value
	}

	// The strings alias the temp-allocated decode buffer, so clone them into
	// the caller's allocator before that buffer is recycled.
	lv.name = clone_str(lv.name, allocator)
	lv.identifier = clone_str(lv.identifier, allocator)
	lv.description = clone_str(lv.description, allocator)
	lv.copyright = clone_str(lv.copyright, allocator)
	return lv, .None
}

level_destroy :: proc(lv: ^Level, allocator := context.allocator) {
	delete(lv.name, allocator)
	delete(lv.identifier, allocator)
	delete(lv.description, allocator)
	delete(lv.copyright, allocator)
	delete(lv.placements, allocator)
	lv^ = {}
}

@(private = "file")
clone_str :: proc(s: string, allocator := context.allocator) -> string {
	b := make([]byte, len(s), allocator)
	copy(b, s)
	return string(b)
}
