package editor

// Undo and redo. An edit keeps what it replaced, and undoing it swaps that
// back into the project, so the edit then holds what was undone, for redo.
// A brush stroke keeps only the TILE x TILE tiles of the heights and the
// water layer it touched, as they were before its first dab: changed
// regions, not copies of the map (notes/level-editor-plan.md, Stage 7). A
// change to the light, water or wind keeps the settings before it, and a
// change to the units the list of them before it: a few hundred records,
// so a copy is cheaper to reason about than a diff.

import "core:mem"
import "core:slice"

import "dr:data"
import "dr:terrain"

TILE :: 32
// Older edits are dropped past this many, or once the tiles kept pass
// HISTORY_BYTES. A tile is 8 KiB with a water layer, so a stroke over the
// whole of an original level keeps 14 MB; 256 of those would be 3.5 GB.
HISTORY_MAX :: 256
HISTORY_BYTES :: 512 * mem.Megabyte

// The level settings the panels edit, undone as one.
Settings :: struct {
	lighting: data.Level_Lighting,
	water:    data.Level_Water,
	wind:     data.Level_Wind,
}

settings_of :: proc(p: ^terrain.Project) -> Settings {
	return {p.level.lighting, p.level.water, p.level.wind}
}

settings_set :: proc(p: ^terrain.Project, s: Settings) {
	p.level.lighting, p.level.water, p.level.wind = s.lighting, s.water, s.wind
}

@(private = "file")
Tile :: struct {
	index:   int, // tile row x tiles across + tile column
	heights: []f32,
	water:   []u8, // nil when the project has no water layer
}

Edit :: struct {
	tiles:      [dynamic]Tile,
	settings:   Maybe(Settings),
	// On the heap. The records' strings are the project's, or the
	// catalogue's: history is cleared before the project goes.
	placements: Maybe([]data.Json_Placement),
}

History :: struct {
	done:   [dynamic]Edit,
	undone: [dynamic]Edit,
	// A stroke being recorded into done's last edit, and its tiles so far.
	open:   bool,
	kept:   map[int]bool,
	// The tiles' bytes, done and undone, and the most they may be: 0 for
	// HISTORY_BYTES. The newest edit is kept whatever it holds.
	bytes:  int,
	budget: int,
}

history_destroy :: proc(h: ^History) {
	for &e in h.done {
		edit_destroy(&e)
	}
	for &e in h.undone {
		edit_destroy(&e)
	}
	delete(h.done)
	delete(h.undone)
	delete(h.kept)
	h^ = {}
}

// Forgets every edit: a project opened or made anew.
history_clear :: proc(h: ^History) {
	budget := h.budget
	history_destroy(h)
	h.budget = budget
}

// Starts a stroke: the dabs until history_end undo as one.
history_begin :: proc(h: ^History) {
	history_push(h, {})
	h.open = true
	clear(&h.kept)
}

history_end :: proc(h: ^History) {
	if h.open && len(h.done[len(h.done) - 1].tiles) == 0 {
		e := pop(&h.done)
		edit_destroy(&e)
	}
	h.open = false
	history_trim(h)
}

// Keeps the tiles of `rect` the open stroke has not kept yet, before a dab
// changes them.
history_touch :: proc(h: ^History, p: ^terrain.Project, rect: terrain.Rect) {
	if !h.open {
		return
	}
	e := &h.done[len(h.done) - 1]
	across := tiles_across(p)
	for ty in rect.y0 / TILE ..= (rect.y1 - 1) / TILE {
		for tx in rect.x0 / TILE ..= (rect.x1 - 1) / TILE {
			index := ty * across + tx
			if h.kept[index] {
				continue
			}
			h.kept[index] = true
			r := tile_rect(p, index)
			n := (r.x1 - r.x0) * (r.y1 - r.y0)
			t := Tile{index = index, heights = make([]f32, n)}
			if p.water != nil {
				t.water = make([]u8, n * 4)
			}
			tile_take(p, &t)
			append(&e.tiles, t)
			h.bytes += tile_bytes(t)
		}
	}
}

// Records a change of the settings from `before`.
history_settings :: proc(h: ^History, before: Settings) {
	history_push(h, {settings = before})
}

// Records a change of the units from `before`.
history_placements :: proc(h: ^History, before: []data.Json_Placement) {
	e := Edit{placements = slice.clone(before)}
	h.bytes += edit_bytes(e)
	history_push(h, e)
}

// What an undo or redo changed: the region of the map, the settings, the
// units.
Change :: struct {
	area:       terrain.Rect,
	map_:       bool,
	settings:   bool,
	placements: bool,
}

history_undo :: proc(h: ^History, p: ^terrain.Project) -> (c: Change, ok: bool) {
	return history_move(h, p, &h.done, &h.undone)
}

history_redo :: proc(h: ^History, p: ^terrain.Project) -> (c: Change, ok: bool) {
	return history_move(h, p, &h.undone, &h.done)
}

@(private = "file")
history_move :: proc(h: ^History, p: ^terrain.Project, from, to: ^[dynamic]Edit) -> (c: Change, ok: bool) {
	if len(from) == 0 {
		return
	}
	e := pop(from)
	c.area = {max(int), max(int), 0, 0}
	for &t in e.tiles {
		tile_swap(p, &t)
		r := tile_rect(p, t.index)
		c.area = {min(c.area.x0, r.x0), min(c.area.y0, r.y0), max(c.area.x1, r.x1), max(c.area.y1, r.y1)}
		c.map_ = true
	}
	if !c.map_ {
		c.area = {}
	}
	if s, has := e.settings.?; has {
		e.settings = settings_of(p)
		settings_set(p, s)
		c.settings = true
	}
	if ps, has := e.placements.?; has {
		// The list swapped in may be longer or shorter than the one kept.
		h.bytes += (len(p.placements) - len(ps)) * size_of(data.Json_Placement)
		e.placements = slice.clone(p.placements[:])
		clear(&p.placements)
		append(&p.placements, ..ps)
		delete(ps)
		c.placements = true
	}
	append(to, e)
	return c, true
}

@(private = "file")
history_push :: proc(h: ^History, e: Edit) {
	h.open = false
	for &u in h.undone {
		h.bytes -= edit_bytes(u)
		edit_destroy(&u)
	}
	clear(&h.undone)
	append(&h.done, e)
	history_trim(h)
}

// Drops the oldest edits past HISTORY_MAX or the budget.
@(private = "file")
history_trim :: proc(h: ^History) {
	budget := h.budget > 0 ? h.budget : HISTORY_BYTES
	for len(h.done) > 1 && (len(h.done) > HISTORY_MAX || h.bytes > budget) {
		h.bytes -= edit_bytes(h.done[0])
		edit_destroy(&h.done[0])
		ordered_remove(&h.done, 0)
	}
}

@(private = "file")
edit_bytes :: proc(e: Edit) -> (n: int) {
	for t in e.tiles {
		n += tile_bytes(t)
	}
	if ps, has := e.placements.?; has {
		n += len(ps) * size_of(data.Json_Placement)
	}
	return
}

@(private = "file")
tile_bytes :: proc(t: Tile) -> int {
	return len(t.heights) * size_of(f32) + len(t.water)
}

@(private = "file")
edit_destroy :: proc(e: ^Edit) {
	for t in e.tiles {
		delete(t.heights)
		delete(t.water)
	}
	delete(e.tiles)
	if ps, has := e.placements.?; has {
		delete(ps)
	}
}

@(private = "file")
tiles_across :: proc(p: ^terrain.Project) -> int {
	return (p.width + TILE - 1) / TILE
}

@(private = "file")
tile_rect :: proc(p: ^terrain.Project, index: int) -> terrain.Rect {
	across := tiles_across(p)
	x0, y0 := index % across * TILE, index / across * TILE
	return {x0, y0, min(x0 + TILE, p.width), min(y0 + TILE, p.length)}
}

// Swaps the tile's cells with the project's.
@(private = "file")
tile_swap :: proc(p: ^terrain.Project, t: ^Tile) {
	r := tile_rect(p, t.index)
	w := r.x1 - r.x0
	for y in r.y0 ..< r.y1 {
		row := (y - r.y0) * w
		for x in 0 ..< w {
			i := y * p.width + r.x0 + x
			p.heights[i], t.heights[row + x] = t.heights[row + x], p.heights[i]
			if t.water != nil && p.water != nil {
				for c in 0 ..< 4 {
					p.water[i * 4 + c], t.water[(row + x) * 4 + c] = t.water[(row + x) * 4 + c], p.water[i * 4 + c]
				}
			}
		}
	}
}

// Copies the project's cells into the tile.
@(private = "file")
tile_take :: proc(p: ^terrain.Project, t: ^Tile) {
	r := tile_rect(p, t.index)
	w := r.x1 - r.x0
	for y in r.y0 ..< r.y1 {
		copy(t.heights[(y - r.y0) * w:][:w], p.heights[y * p.width + r.x0:][:w])
		if t.water != nil {
			copy(t.water[(y - r.y0) * w * 4:][:w * 4], p.water[(y * p.width + r.x0) * 4:][:w * 4])
		}
	}
}
