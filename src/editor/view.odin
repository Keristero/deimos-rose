package editor

// The editor's views of the project, all drawn by the terrain renderer: the
// map from above, zoomed from ZOOM_MIN to ZOOM_MAX and scrolled up and down
// the level; the whole level down the right-hand side, to scroll by; and a
// tilted view for looking at the relief, the same render laid over the
// heights as a mesh.

import "core:math"

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import "dr:terrain"

PANEL_WIDTH :: 300
OVERVIEW_WIDTH :: 136
STATUS_HEIGHT :: 24
// The longest level the overview draws whole.
OVERVIEW_MAX :: 8192
// The tilted view's mesh has at most this many vertices (16-bit indices).
MESH_VERTICES_MAX :: 65535
// Screen pixels a map pixel, at least and at most. At a quarter a 3600-row
// level is 900 px high, all in view on a 1080p screen; past 4 the 2x
// render's own texels (and the models layer's) are all that is magnified.
// Provisional: a guess at what is useful, not measured.
ZOOM_MIN :: 0.25
ZOOM_MAX :: 4
// The view's target is made a whole number of these rows high, so zooming
// out does not make it again every frame.
TARGET_ROWS_STEP :: 64

View :: struct {
	row:            f32, // the map row at the view's top
	left:           f32, // map columns scrolled off the view's left
	zoom:           f32,
	live_light:     bool, // lit, or the unlit colour
	tilted:         bool,
	tilt:           f32, // degrees from straight down
	turn:           f32, // degrees about the vertical
	view_stale:     bool,
	overview_stale: bool,
	// The view from above, map rows from `drawn_from` down, rendered at
	// `drawn_scale` (view_scale) and drawn at the zoom.
	target:         rl.RenderTexture2D,
	drawn_from:     int,
	drawn_scale:    int,
	minified:       bool, // drawn smaller than rendered: mipmapped, trilinear
	overview:       rl.RenderTexture2D,
	tilted_target:  rl.RenderTexture2D,
	mesh:           rl.Mesh,
	material:       rl.Material,
	// The mesh's mean and highest heights, which the camera frames.
	mesh_mean:      f32,
	mesh_top:       f32,
	// Where the mouse is on the map, when it is over the view.
	cursor:         [2]f32,
	over_map:       bool,
}

// The window's parts.
Layout :: struct {
	panel, view, overview, status: rl.Rectangle,
}

layout :: proc(width, height: f32) -> Layout {
	h := height - STATUS_HEIGHT
	return {
		panel    = {0, 0, PANEL_WIDTH, h},
		view     = {PANEL_WIDTH, 0, max(width - PANEL_WIDTH - OVERVIEW_WIDTH, 1), h},
		overview = {width - OVERVIEW_WIDTH, 0, OVERVIEW_WIDTH, h},
		status   = {0, h, width, STATUS_HEIGHT},
	}
}

// A project just opened: shown from its bottom, where a level starts.
view_reset :: proc(v: ^View, p: ^terrain.Project) {
	v.row = f32(p.length)
	v.left = 0
	v.view_stale, v.overview_stale = true, true
}

view_destroy :: proc(v: ^View) {
	unload :: proc(t: ^rl.RenderTexture2D) {
		if t.id != 0 {
			rl.UnloadRenderTexture(t^)
		}
		t^ = {}
	}
	unload(&v.target)
	unload(&v.overview)
	unload(&v.tilted_target)
	if v.mesh.vaoId != 0 {
		rl.UnloadMesh(v.mesh)
	}
	v.mesh = {}
	if v.material.maps != nil {
		// Not UnloadMaterial: it would unload the view's texture with it.
		rl.MemFree(v.material.maps)
	}
	v.material = {}
}

// Map rows the view shows.
view_rows :: proc(v: ^View, area: rl.Rectangle) -> f32 {
	return area.height / v.zoom
}

// Map columns the view has room for.
view_cols :: proc(v: ^View, area: rl.Rectangle) -> f32 {
	return area.width / v.zoom
}

// The renderer's output pixels a map pixel for the view: 2 when zoomed in
// past 1x, so the models layer's 2 texels a pixel show; else 1, scaled
// down from there.
view_scale :: proc(v: ^View) -> int {
	return v.zoom > 1 ? 2 : 1
}

// Keeps the scroll inside the map.
view_clamp :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle) {
	v.zoom = clamp(v.zoom, ZOOM_MIN, ZOOM_MAX)
	v.row = clamp(v.row, 0, max(f32(p.length) - view_rows(v, area), 0))
	v.left = clamp(v.left, 0, max(f32(p.width) - view_cols(v, area), 0))
}

// Where map pixel (0, row) is drawn, and so every other.
@(private = "file")
view_origin :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle) -> [2]f32 {
	mw := f32(p.width) * v.zoom
	x := mw < area.width ? area.x + math.floor((area.width - mw) / 2) : area.x - v.left * v.zoom
	return {x, area.y - v.row * v.zoom}
}

view_to_map :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle, screen: [2]f32) -> [2]f32 {
	return (screen - view_origin(v, p, area)) / v.zoom
}

// Zooms by `factor` about `screen`: the map point under it stays under it,
// as far as the scroll's clamp allows.
view_zoom_at :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle, screen: [2]f32, factor: f32) {
	at := view_to_map(v, p, area, screen)
	v.zoom = clamp(v.zoom * factor, ZOOM_MIN, ZOOM_MAX)
	// The origin moves with the scroll one for one, a zoom's worth of map
	// pixels a pixel, so one step puts `at` back under `screen`.
	d := at - view_to_map(v, p, area, screen)
	v.left += d.x
	v.row += d.y
	view_clamp(v, p, area)
}

// Draws what changed into the offscreen targets, before the frame.
view_prepare :: proc(e: ^Editor, area: rl.Rectangle) {
	v, p := &e.view, &e.project
	view_clamp(v, p, area)
	scale := view_scale(v)
	rows := (int(math.ceil(view_rows(v, area))) + 1 + TARGET_ROWS_STEP - 1) / TARGET_ROWS_STEP * TARGET_ROWS_STEP
	rows = min(rows, max(p.length, 1), terrain.STRIP_MAX / scale)
	w, h := i32(p.width * scale), i32(rows * scale)
	if w > terrain.STRIP_MAX || h <= 0 {
		return
	}
	if v.target.texture.width != w || v.target.texture.height != h {
		if v.target.id != 0 {
			rl.UnloadRenderTexture(v.target)
		}
		v.target = rl.LoadRenderTexture(w, h)
		v.view_stale = true
	}
	from := int(v.row)
	rendered := false
	if v.view_stale || from != v.drawn_from || scale != v.drawn_scale {
		rendered = true
		terrain.render_into(&e.renderer, p, {output = v.live_light ? .Lit : .Albedo, scale = scale, from = from}, v.target)
		v.drawn_from, v.drawn_scale = from, scale
		v.view_stale = false
		if v.tilted {
			view_mesh(v, p)
		} else if v.mesh.vaoId != 0 {
			// Made again from the heights when the view tilts next.
			rl.UnloadMesh(v.mesh)
			v.mesh = {}
		}
	} else if v.tilted && v.mesh.vaoId == 0 {
		view_mesh(v, p)
	}
	view_filter(v, rendered)
	if v.overview_stale && p.length <= OVERVIEW_MAX && p.width <= terrain.STRIP_MAX {
		if v.overview.texture.width != i32(p.width) || v.overview.texture.height != i32(p.length) {
			if v.overview.id != 0 {
				rl.UnloadRenderTexture(v.overview)
			}
			v.overview = rl.LoadRenderTexture(i32(p.width), i32(p.length))
			rl.SetTextureFilter(v.overview.texture, .BILINEAR)
		}
		terrain.render_into(&e.renderer, p, {output = v.live_light ? .Lit : .Albedo, scale = 1}, v.overview)
		v.overview_stale = false
		e.level_panel.preview_stale = true
	}
	level_preview_prepare(e)
	if v.tilted {
		view_tilted(v, p, area)
	}
}

// Draws the views into the frame.
view_draw :: proc(e: ^Editor, l: Layout) {
	v, p := &e.view, &e.project
	area := l.view
	rl.DrawRectangleRec(area, {24, 26, 30, 255})
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	if v.tilted && v.tilted_target.id != 0 {
		t := v.tilted_target.texture
		rl.DrawTextureRec(t, {0, 0, f32(t.width), -f32(t.height)}, {area.x, area.y}, rl.WHITE)
	} else if v.target.id != 0 {
		// The target holds the map's rows top first, as render reads them.
		o := view_origin(v, p, area)
		// Only its rows on the map: the rest are the renderer's edge
		// smeared, when the view reaches past the level's end.
		t := v.target.texture
		k := v.zoom / f32(v.drawn_scale)
		h := min(f32(t.height), f32((p.length - v.drawn_from) * v.drawn_scale))
		rl.DrawTexturePro(t, {0, 0, f32(t.width), h}, {o.x, o.y + f32(v.drawn_from) * v.zoom, f32(t.width) * k, h * k}, {}, 0, rl.WHITE)
		if e.show_units {
			units_draw(e, o, area)
		}
		if Tab(e.tab) == .Models {
			models_draw(e, o)
		}
		if Tab(e.tab) == .Level {
			b := preview_box(p)
			rl.DrawRectangleLinesEx({o.x + b.x * v.zoom, o.y + b.y * v.zoom, b.width * v.zoom, b.height * v.zoom}, 2, PREVIEW_COLOUR)
		}
		if v.over_map && Tab(e.tab) != .Units && Tab(e.tab) != .Level && !(Tab(e.tab) == .Models && Models_Mode(e.scenery.mode) == .Select) {
			brush_outline(e, o)
		}
	}
	rl.EndScissorMode()

	// The whole level, and the part in view.
	ov := l.overview
	rl.DrawRectangleRec(ov, {18, 19, 22, 255})
	if v.overview.id != 0 && !v.overview_stale {
		s, r := overview_fit(p, ov)
		t := v.overview.texture
		rl.DrawTexturePro(t, {0, 0, f32(t.width), f32(t.height)}, r, {}, 0, rl.WHITE)
		if e.show_units {
			units_overview(e, s, r)
		}
		b := overview_box(v, p, area, s, r)
		rl.DrawRectangleLinesEx({b.x - 1, b.y - 1, b.width + 2, b.height + 2}, 1, {255, 220, 90, 255})
		if Tab(e.tab) == .Level {
			c := preview_box(p)
			rl.DrawRectangleLinesEx({r.x + c.x * s, r.y + c.y * s, c.width * s, c.height * s}, 1, PREVIEW_COLOUR)
		}
	}
}

// The preview's crop, in map pixels, and the colour it is outlined in.
PREVIEW_COLOUR :: rl.Color{110, 200, 240, 255}

preview_box :: proc(p: ^terrain.Project) -> rl.Rectangle {
	at := terrain.preview_crop_clamp(p.preview, p.width, p.length)
	return {f32(at.x), f32(at.y), terrain.PREVIEW_CROP_WIDTH, terrain.PREVIEW_CROP_HEIGHT}
}

// Drawn smaller than it was rendered, the view is mipmapped, made again
// after each render, so a zoom out does not alias the map's fine detail
// into noise; drawn at its size or larger, its pixels are kept sharp.
@(private = "file")
view_filter :: proc(v: ^View, rendered: bool) {
	minify := v.zoom < f32(v.drawn_scale)
	if minify && (rendered || !v.minified) {
		rl.GenTextureMipmaps(&v.target.texture)
		rl.SetTextureFilter(v.target.texture, .TRILINEAR)
	} else if !minify && v.minified {
		rl.SetTextureFilter(v.target.texture, .POINT)
	}
	v.minified = minify
}

// Where the overview draws the map, and its scale.
overview_fit :: proc(p: ^terrain.Project, area: rl.Rectangle) -> (s: f32, r: rl.Rectangle) {
	s = min((area.width - 8) / f32(p.width), (area.height - 8) / f32(p.length))
	w, h := f32(p.width) * s, f32(p.length) * s
	return s, {area.x + math.floor((area.width - w) / 2), area.y + math.floor((area.height - h) / 2), w, h}
}

// The part of the map in view, where the overview draws it (`s` and `r`
// from overview_fit): across as well as along, zoomed in, as the view
// pans both ways.
overview_box :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle, s: f32, r: rl.Rectangle) -> rl.Rectangle {
	cols := min(view_cols(v, area), f32(p.width) - v.left)
	rows := min(view_rows(v, area), f32(p.length) - v.row)
	return {r.x + v.left * s, r.y + v.row * s, cols * s, rows * s}
}

@(private = "file")
brush_outline :: proc(e: ^Editor, o: [2]f32) {
	b := e.brush
	z := e.zoom
	c := o + e.cursor * z
	colour := rl.Color{255, 255, 255, 200}
	switch b.shape {
	case .Round, .Rough:
		rl.DrawCircleLinesV(c, b.radius * z, colour)
		if b.falloff > 0 {
			rl.DrawCircleLinesV(c, b.radius * (1 - b.falloff) * z, {255, 255, 255, 90})
		}
	case .Square:
		r := b.radius * z
		rl.DrawRectangleLinesEx({c.x - r, c.y - r, 2 * r, 2 * r}, 1, colour)
	}
}

// The heights of the rows in the view from above, as a grid, textured
// with that view.
@(private = "file")
view_mesh :: proc(v: ^View, p: ^terrain.Project) {
	if v.mesh.vaoId != 0 {
		rl.UnloadMesh(v.mesh)
		v.mesh = {}
	}
	rows := int(v.target.texture.height) / v.drawn_scale
	step := 2
	for (p.width / step + 1) * (rows / step + 1) > MESH_VERTICES_MAX {
		step += 1
	}
	nx, ny := p.width / step + 1, rows / step + 1
	m: rl.Mesh
	m.vertexCount = i32(nx * ny)
	m.triangleCount = i32((nx - 1) * (ny - 1) * 2)
	m.vertices = ([^]f32)(rl.MemAlloc(u32(nx * ny * 3 * size_of(f32))))
	m.texcoords = ([^]f32)(rl.MemAlloc(u32(nx * ny * 2 * size_of(f32))))
	m.indices = ([^]u16)(rl.MemAlloc(u32(m.triangleCount * 3 * size_of(u16))))
	water := p.level.water
	sum: f64
	v.mesh_top = 0
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			x := min(i * step, p.width - 1)
			y := min(v.drawn_from + j * step, p.length - 1)
			k := y * p.width + x
			h := p.heights[k]
			if p.canopy != nil {
				h += f32(p.canopy[k]) / 255 * p.canopy_height
			}
			if water.visible {
				h = max(h, water.height)
			}
			sum += f64(h)
			v.mesh_top = max(v.mesh_top, h)
			n := j * nx + i
			// Map x right, rows toward +z, height up; centred on the view.
			m.vertices[n * 3 + 0] = f32(x) - f32(p.width) / 2
			m.vertices[n * 3 + 1] = h
			m.vertices[n * 3 + 2] = f32(j * step) - f32(rows) / 2
			m.texcoords[n * 2 + 0] = (f32(x) + 0.5) / f32(p.width)
			m.texcoords[n * 2 + 1] = (f32(j * step) + 0.5) / f32(rows)
		}
	}
	v.mesh_mean = f32(sum / f64(nx * ny))
	t := 0
	for j in 0 ..< ny - 1 {
		for i in 0 ..< nx - 1 {
			a := u16(j * nx + i)
			b, c, d := a + 1, a + u16(nx), a + u16(nx) + 1
			for q in ([6]u16{a, c, b, b, c, d}) {
				m.indices[t] = q
				t += 1
			}
		}
	}
	rl.UploadMesh(&m, false)
	v.mesh = m
	if v.material.maps == nil {
		v.material = rl.LoadMaterialDefault()
	}
	v.material.maps[rl.MaterialMapIndex.ALBEDO].texture = v.target.texture
}

@(private = "file")
view_tilted :: proc(v: ^View, p: ^terrain.Project, area: rl.Rectangle) {
	w, h := i32(area.width), i32(area.height)
	if v.tilted_target.texture.width != w || v.tilted_target.texture.height != h {
		if v.tilted_target.id != 0 {
			rl.UnloadRenderTexture(v.tilted_target)
		}
		v.tilted_target = rl.LoadRenderTexture(w, h)
	}
	if v.mesh.vaoId == 0 {
		return
	}
	rows := f32(v.target.texture.height) / f32(v.drawn_scale)
	tilt := math.to_radians(clamp(v.tilt, 5, 85))
	turn := math.to_radians(v.turn)
	fovy := f32(45)
	// At the ground's mean height, far enough back that the view's rows
	// would fill the height from above, and back again by the relief over
	// it.
	d := rows / 2 / math.tan(math.to_radians(fovy / 2)) + (v.mesh_top - v.mesh_mean)
	target := [3]f32{0, v.mesh_mean, 0}
	cam := rl.Camera3D {
		position   = target + d * [3]f32{math.sin(tilt) * math.sin(turn), math.cos(tilt), math.sin(tilt) * math.cos(turn)},
		target     = target,
		up         = {0, 1, 0},
		fovy       = fovy,
		projection = .PERSPECTIVE,
	}
	rl.BeginTextureMode(v.tilted_target)
	rl.ClearBackground({24, 26, 30, 255})
	rlgl.SetClipPlanes(1, f64(4 * d + 4096))
	rl.BeginMode3D(cam)
	rl.DrawMesh(v.mesh, v.material, rl.Matrix(1))
	rl.EndMode3D()
	rlgl.SetClipPlanes(rlgl.CULL_DISTANCE_NEAR, rlgl.CULL_DISTANCE_FAR)
	rl.EndTextureMode()
}
