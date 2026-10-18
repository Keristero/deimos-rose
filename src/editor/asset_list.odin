package editor

// A list of assets, the game's own and the rest together, each row with
// where it is from in a column at its right: the plugin's name, "this
// level" for what the level brings, "imported" for what the user dropped
// in. The game's own say nothing there. Every asset list in the editor is
// one (D77).

import "core:c"
import "core:strings"

import rl "vendor:raylib"

Asset_Row :: struct {
	name:   string,
	source: string, // "" for the game's own
}

// The list: `active` is the chosen row, -1 for none, and `scroll` the
// first shown, as for raygui's list view, which draws it.
asset_list :: proc(bounds: rl.Rectangle, rows: []Asset_Row, scroll, active: ^c.int) {
	font, size, spacing := gui_font()
	// raygui 4.0's GuiListViewEx lays its rows out so: from the border
	// and the items' spacing in, less the scroll bar when they overflow.
	style :: proc(p: rl.GuiListViewProperty) -> f32 {
		return f32(rl.GuiGetStyle(.LISTVIEW, c.int(p)))
	}
	item_h, gap := style(.LIST_ITEMS_HEIGHT), style(.LIST_ITEMS_SPACING)
	border := f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_WIDTH)))
	pad := f32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_PADDING)))
	item_w := bounds.width - 2 * gap - border
	if (item_h + gap) * f32(len(rows)) > bounds.height {
		item_w -= style(.SCROLLBAR_WIDTH)
	}

	// The column is as wide as the widest source, so the names end in line.
	column: f32
	for r in rows {
		column = max(column, text_width(r.source))
	}
	room := item_w - 2 * pad - (column > 0 ? column + 2 * pad : 0)
	names := make([]cstring, len(rows), context.temp_allocator)
	for r, i in rows {
		names[i] = strings.clone_to_cstring(fitted(r.name, room), context.temp_allocator)
	}
	focus := c.int(-1)
	rl.GuiListViewEx(bounds, raw_data(names), c.int(len(rows)), scroll, active, &focus)
	if column == 0 {
		return
	}

	// raygui leaves `scroll` at the first row it drew.
	shown := min(int(bounds.height / (item_h + gap)), len(rows))
	first := clamp(int(scroll^), 0, len(rows) - shown)
	normal := rl.GetColor(u32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_COLOR_NORMAL))))
	pressed := rl.GetColor(u32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_COLOR_PRESSED))))
	disabled := rl.GetColor(u32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_COLOR_DISABLED))))
	for k in 0 ..< shown {
		i := first + k
		if rows[i].source == "" {
			continue
		}
		colour := rl.Fade(normal, 0.6)
		switch {
		case rl.GuiGetState() == c.int(rl.GuiState.STATE_DISABLED):
			colour = disabled
		case c.int(i) == active^:
			colour = pressed
		}
		top := bounds.y + gap + border + f32(k) * (item_h + gap)
		at := rl.Vector2{bounds.x + gap + item_w - pad - text_width(rows[i].source), top + (item_h - size) / 2}
		rl.DrawTextEx(font, strings.clone_to_cstring(rows[i].source, context.temp_allocator), at, size, spacing, colour)
	}
}

// How tall a list is to show `rows` rows, as raygui counts them.
asset_list_height :: proc(rows: int) -> f32 {
	item_h := f32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiListViewProperty.LIST_ITEMS_HEIGHT)))
	gap := f32(rl.GuiGetStyle(.LISTVIEW, c.int(rl.GuiListViewProperty.LIST_ITEMS_SPACING)))
	border := f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_WIDTH)))
	return f32(rows) * (item_h + gap) + gap + 2 * border
}

// raygui's font, and the size and spacing it draws text at.
@(private = "file")
gui_font :: proc() -> (font: rl.Font, size, spacing: f32) {
	size = f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE)))
	spacing = f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SPACING)))
	return rl.GuiGetFont(), size, spacing
}

@(private = "file")
text_width :: proc(s: string) -> f32 {
	font, size, spacing := gui_font()
	return rl.MeasureTextEx(font, strings.clone_to_cstring(s, context.temp_allocator), size, spacing).x
}

// `s`, or as much of it as fits in `w` and an ellipsis.
@(private = "file")
fitted :: proc(s: string, w: f32) -> string {
	if text_width(s) <= w {
		return s
	}
	n := len(s)
	for n > 0 {
		n -= 1
		for n > 0 && s[n] & 0xc0 == 0x80 {
			n -= 1 // not inside a character
		}
		t := strings.concatenate({s[:n], "..."}, context.temp_allocator)
		if text_width(t) <= w {
			return t
		}
	}
	return "..."
}
