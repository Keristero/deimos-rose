package editor

// The Campaign tab (Stage 9): a campaign's name and words, its levels in
// play order, and exporting it as a plugin; and Play, the level open
// exported alone and started in the game. The export runs a level a frame
// (campaign_update), so the window shows how far it is.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

Campaign_Field :: enum c.int {
	Name,
	Label,
	Description,
	Version,
}

@(private = "file")
CAMPAIGN_LABELS := [Campaign_Field]cstring {
	.Name        = "Name",
	.Label       = "Label",
	.Description = "Description",
	.Version     = "Version",
}

Campaign_Panel :: struct {
	// The campaign's memory, freed when another is opened or made.
	arena:      ^virtual.Arena,
	campaign:   Campaign,
	path:       [1024]u8, // where it saves, NUL-terminated for the text box
	path_edit:  bool,
	buffers:    [Campaign_Field][256]u8,
	editing:    c.int, // the field being typed in, or -1
	selected:   c.int, // the level chosen in the list, or -1
	scroll:     c.int,
	// Each level's identifier, read from its project when listed.
	labels:     [dynamic]string,
	// Where it exports: the plugins root's folder of its name, unless one
	// was typed.
	dir:        [1024]u8,
	dir_edit:   bool,
	dir_typed:  bool,
	// The export under way, or the last one, whose problems are shown.
	export:     Export,
	has_export: bool,
	// What the export was: Play's, which starts the game when it is done.
	playing:    bool,
	game:       os.Process,
	game_on:    bool,
}

campaign_panel_init :: proc(cp: ^Campaign_Panel) {
	cp.editing, cp.selected = -1, -1
	campaign_new(cp)
}

campaign_panel_destroy :: proc(cp: ^Campaign_Panel) {
	if cp.has_export {
		export_destroy(&cp.export)
	}
	arena_free(cp.arena)
	cp.arena = nil
}

// A new campaign, in place of the one open.
campaign_new :: proc(cp: ^Campaign_Panel) {
	arena_free(cp.arena)
	cp.arena, _ = arena_new()
	a := virtual.arena_allocator(cp.arena)
	cp.campaign = campaign_make("my_campaign", a)
	cp.campaign.label = "My campaign"
	cp.labels = make([dynamic]string, a)
	cp.selected, cp.editing, cp.dir_typed = -1, -1, false
	box_set(cp.path[:], "untitled" + CAMPAIGN_SUFFIX)
}

campaign_path :: proc(cp: ^Campaign_Panel) -> string {
	return box_text(cp.path[:])
}

// Opens the campaign at `path`, in place of the one open.
campaign_open :: proc(e: ^Editor, path: string) -> bool {
	cp := &e.campaign_panel
	arena := arena_new() or_return
	c, ok := campaign_load(path, virtual.arena_allocator(arena))
	if !ok {
		arena_free(arena)
		return false
	}
	arena_free(cp.arena)
	cp.arena, cp.campaign = arena, c
	cp.labels = make([dynamic]string, virtual.arena_allocator(arena))
	cp.selected, cp.editing, cp.dir_typed = -1, -1, false
	box_set(cp.path[:], path)
	campaign_relabel(cp)
	return true
}

campaign_save_to :: proc(e: ^Editor, path: string) -> bool {
	cp := &e.campaign_panel
	if !strings.has_suffix(path, CAMPAIGN_SUFFIX) || !campaign_save(&cp.campaign, path) {
		return false
	}
	box_set(cp.path[:], path)
	return true
}

// Adds the project at `path` to the campaign's end.
campaign_add :: proc(e: ^Editor, path: string) -> bool {
	cp := &e.campaign_panel
	if !strings.has_suffix(path, terrain.PROJECT_SUFFIX) || !os.exists(path) {
		return false
	}
	append(&cp.campaign.levels, absolute(path, virtual.arena_allocator(cp.arena)))
	cp.selected = c.int(len(cp.campaign.levels) - 1)
	campaign_relabel(cp)
	return true
}

// Moves the chosen level `by` places, or takes it out (by 0).
campaign_move :: proc(cp: ^Campaign_Panel, by: int, remove := false) {
	i := int(cp.selected)
	levels := &cp.campaign.levels
	if i < 0 || i >= len(levels) {
		return
	}
	if remove {
		ordered_remove(levels, i)
		cp.selected = c.int(min(i, len(levels) - 1))
	} else if j := i + by; j >= 0 && j < len(levels) {
		levels[i], levels[j] = levels[j], levels[i]
		cp.selected = c.int(j)
	}
	campaign_relabel(cp)
}

// Reads each level's identifier from its project, for the list.
@(private = "file")
campaign_relabel :: proc(cp: ^Campaign_Panel) {
	Head :: struct {
		level: struct {
			identifier: string `json:"identifier"`,
		} `json:"level"`,
	}
	a := virtual.arena_allocator(cp.arena)
	clear(&cp.labels)
	for path in cp.campaign.levels {
		h: Head
		label := ""
		if blob, err := os.read_entire_file(path, context.temp_allocator); err == nil && json.unmarshal(blob, &h, allocator = context.temp_allocator) == nil {
			label = strings.clone(h.level.identifier, a)
		}
		append(&cp.labels, label)
	}
}

// The export started, of the campaign or (`play`) of the level open.
@(private = "file")
export_start :: proc(e: ^Editor, play: bool) {
	cp := &e.campaign_panel
	level_panel_leave(e)
	campaign_panel_leave(e)
	if cp.has_export {
		export_destroy(&cp.export)
	}
	cp.has_export, cp.playing = true, play
	if play {
		play_begin(e, &cp.export)
	} else {
		export_begin(&cp.export, &cp.campaign, campaign_dir(cp))
	}
}

// Plays the level open, from the view: exported alone, then the game.
editor_play :: proc(e: ^Editor) {
	if !e.has_project {
		return
	}
	export_start(e, true)
}

// Where the campaign exports to.
campaign_dir :: proc(cp: ^Campaign_Panel) -> string {
	if cp.dir_typed {
		return box_text(cp.dir[:])
	}
	return campaign_default_dir(&cp.campaign, context.temp_allocator)
}

// A step of the export under way, before the frame; and the game, once it
// has quit, let go.
campaign_update :: proc(e: ^Editor, view_rows: f32) {
	cp := &e.campaign_panel
	if cp.game_on {
		if state, err := os.process_wait(cp.game, 0); err == nil && state.exited {
			cp.game_on = false
		}
	}
	if !cp.has_export || cp.export.stage == .Done {
		return
	}
	if export_step(e, &cp.export) {
		return
	}
	x := &cp.export
	failed := export_failed(x)
	switch {
	case failed && cp.playing:
		e.tab = c.int(Tab.Campaign)
		editor_message(e, "Cannot play this level yet: see the Campaign tab")
	case failed:
		editor_message(e, "Nothing exported: see the problems below")
	case cp.playing:
		play_start(e, view_rows)
	case:
		editor_message(e, "Exported %d levels to %s", len(x.campaign.levels), x.dir)
	}
}

@(private = "file")
play_start :: proc(e: ^Editor, view_rows: f32) {
	cp := &e.campaign_panel
	command := play_command(e, play_row(e, view_rows))
	if !os.exists(command[0]) {
		editor_message(e, "No game beside the editor: %s", command[0])
		return
	}
	if cp.game_on {
		_ = os.process_kill(cp.game)
		_, _ = os.process_wait(cp.game)
		cp.game_on = false
	}
	p, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		editor_message(e, "Cannot start %s", command[0])
		return
	}
	cp.game, cp.game_on = p, true
	editor_message(e, "Playing %s from row %s", e.project.level.identifier, command[len(command) - 1])
}

@(private = "file")
field_of :: proc(cp: ^Campaign_Panel, f: Campaign_Field) -> ^string {
	switch f {
	case .Name:
		return &cp.campaign.name
	case .Label:
		return &cp.campaign.label
	case .Description:
		return &cp.campaign.description
	case .Version:
		return &cp.campaign.plugin_version
	}
	unreachable()
}

// Keeps what is being typed, if anything.
campaign_panel_leave :: proc(e: ^Editor) {
	cp := &e.campaign_panel
	if cp.editing >= 0 {
		f := Campaign_Field(cp.editing)
		field_of(cp, f)^ = strings.clone(box_text(cp.buffers[f][:]), virtual.arena_allocator(cp.arena))
		cp.editing = -1
	}
	cp.path_edit, cp.dir_edit = false, false
}

campaign_typing :: proc(cp: ^Campaign_Panel) -> bool {
	return cp.editing >= 0 || cp.path_edit || cp.dir_edit
}

campaign_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32) {
	cp := &e.campaign_panel
	busy := cp.has_export && cp.export.stage != .Done
	heading(x, y, w, "Campaign")
	if rl.GuiTextBox({x, y^, w, 20}, cstring(raw_data(cp.path[:])), c.int(len(cp.path) - 1), cp.path_edit) {
		cp.path_edit = !cp.path_edit
	}
	y^ += ROW
	bw := (w - 2 * 4) / 3
	if rl.GuiButton({x, y^, bw, 20}, "Open") && !editor_dialog(e, .Campaign) {
		campaign_open_reporting(e, strings.clone(campaign_path(cp), context.temp_allocator))
	}
	if rl.GuiButton({x + bw + 4, y^, bw, 20}, "Save") {
		campaign_panel_leave(e)
		path := strings.clone(campaign_path(cp), context.temp_allocator)
		switch {
		case !strings.has_suffix(path, CAMPAIGN_SUFFIX):
			editor_message(e, "A campaign's name ends %s", CAMPAIGN_SUFFIX)
		case campaign_save_to(e, path):
			editor_message(e, "Saved %s", path)
		case:
			editor_message(e, "Cannot save %s", path)
		}
	}
	if rl.GuiButton({x + 2 * (bw + 4), y^, bw, 20}, "New") {
		campaign_new(cp)
		editor_message(e, "New campaign")
	}
	y^ += ROW
	for f in Campaign_Field {
		buf := &cp.buffers[f]
		if cp.editing != c.int(f) {
			box_set(buf[:], field_of(cp, f)^)
		}
		rl.GuiLabel({x, y^, 76, 20}, CAMPAIGN_LABELS[f])
		if rl.GuiTextBox({x + 76, y^, w - 76, 20}, cstring(raw_data(buf[:])), c.int(len(buf) - 1), cp.editing == c.int(f)) {
			if cp.editing == c.int(f) {
				campaign_panel_leave(e)
			} else {
				campaign_panel_leave(e)
				cp.editing = c.int(f)
			}
		}
		y^ += ROW
	}
	rl.GuiCheckBox({x, y^ + 2, 16, 16}, "The classic look (15-bit colour)", &cp.campaign.classic_colour)
	y^ += 22
	rl.GuiCheckBox({x, y^ + 2, 16, 16}, "Free of the originals' art", &cp.campaign.original_free)
	y^ += 22
	rl.GuiCheckBox({x, y^ + 2, 16, 16}, "On by default", &cp.campaign.default_on)
	y^ += ROW + 4

	heading(x, y, w, "Levels, in play order")
	sb := strings.builder_make(context.temp_allocator)
	open := absolute(editor_path(e), context.temp_allocator)
	for path, i in cp.campaign.levels {
		label := i < len(cp.labels) ? cp.labels[i] : ""
		if path == open {
			label = e.project.level.identifier
		}
		_, file := os.split_path(path)
		if i > 0 {
			strings.write_byte(&sb, ';')
		}
		fmt.sbprintf(&sb, "%d. %s  (%s)", i + 1, label != "" ? label : "no identifier", strings.trim_suffix(file, terrain.PROJECT_SUFFIX))
	}
	list_h := clamp(bottom - y^ - 5 * ROW - 120, 3 * 18 + 6, 8 * 18 + 6)
	if len(cp.campaign.levels) == 0 {
		rl.GuiLabel({x, y^, w, 20}, "None yet: add the level open, or one")
		rl.GuiLabel({x, y^ + 16, w, 20}, "from a file.")
		y^ += 2 * ROW
	} else {
		rl.GuiListView({x, y^, w, list_h}, strings.to_cstring(&sb), &cp.scroll, &cp.selected)
		y^ += list_h + 4
	}
	bw4 := (w - 3 * 4) / 4
	if rl.GuiButton({x, y^, 2 * bw4 + 4, 20}, "Add the level open") {
		switch {
		case !os.exists(editor_path(e)):
			editor_message(e, "Save the level first")
		case campaign_add(e, strings.clone(editor_path(e), context.temp_allocator)):
			editor_message(e, "Added %s", editor_path(e))
		}
	}
	if rl.GuiButton({x + 2 * (bw4 + 4), y^, 2 * bw4 + 4, 20}, "Add from a file") && !editor_dialog(e, .Campaign_Level) {
		editor_message(e, "No file dialog here: open the level, then add it")
	}
	y^ += ROW
	chosen := cp.selected >= 0 && int(cp.selected) < len(cp.campaign.levels)
	if rl.GuiButton({x, y^, bw4, 20}, "Up") {
		campaign_move(cp, -1)
	}
	if rl.GuiButton({x + bw4 + 4, y^, bw4, 20}, "Down") {
		campaign_move(cp, 1)
	}
	if rl.GuiButton({x + 2 * (bw4 + 4), y^, bw4, 20}, "Remove") {
		campaign_move(cp, 0, true)
	}
	if rl.GuiButton({x + 3 * (bw4 + 4), y^, bw4, 20}, "Open") && chosen && guarded(e, .Open) {
		open_reporting(e, strings.clone(cp.campaign.levels[cp.selected], context.temp_allocator))
	}
	y^ += ROW + 4

	heading(x, y, w, "Export")
	if !cp.dir_typed && !cp.dir_edit {
		box_set(cp.dir[:], campaign_dir(cp))
	}
	rl.GuiLabel({x, y^, 76, 20}, "To")
	if rl.GuiTextBox({x + 76, y^, w - 76, 20}, cstring(raw_data(cp.dir[:])), c.int(len(cp.dir) - 1), cp.dir_edit) {
		cp.dir_edit = !cp.dir_edit
		cp.dir_typed = cp.dir_typed || !cp.dir_edit
	}
	y^ += ROW
	bw2 := (w - 4) / 2
	if busy {
		rl.GuiDisable()
	}
	if rl.GuiButton({x, y^, bw2, 20}, "Export the campaign") {
		export_start(e, false)
	}
	if rl.GuiButton({x + bw2 + 4, y^, bw2, 20}, "Play this level (F5)") {
		editor_play(e)
	}
	rl.GuiEnable()
	y^ += ROW
	if cp.has_export {
		problems_draw(e, x, y, w, bottom)
	}
}

// How far the export is, then, once it is done, what was wrong.
@(private = "file")
problems_draw :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32) {
	cp := &e.campaign_panel
	ex := &cp.export
	if ex.stage != .Done {
		progress := export_progress(ex)
		what := ex.stage == .Check ? "Checking" : "Writing"
		rl.GuiProgressBar({x, y^, w, 16}, nil, nil, &progress, 0, 1)
		rl.GuiLabel({x, y^ + 18, w, 14}, fmt.ctprintf("%s level %d of %d", what, min(ex.at + 1, len(ex.campaign.levels)), len(ex.campaign.levels)))
		y^ += 36
		return
	}
	if len(ex.problems) == 0 {
		rl.GuiLabel({x, y^, w, 14}, fmt.ctprintf("%s: exported, nothing to fix", cp.playing ? "Play" : "Campaign"))
		y^ += 18
		return
	}
	for p in ex.problems {
		if y^ + 14 > bottom {
			break
		}
		colour := p.fatal ? rl.Color{240, 110, 100, 255} : rl.Color{220, 190, 120, 255}
		wrapped(x, y, w, p.text, colour, bottom)
	}
}

// Text wrapped at words to `w`, in raygui's font.
@(private = "file")
wrapped :: proc(x: f32, y: ^f32, w: f32, text: string, colour: rl.Color, bottom: f32) {
	font := rl.GuiGetFont()
	size := f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE)))
	spacing := f32(rl.GuiGetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SPACING)))
	line := strings.builder_make(context.temp_allocator)
	flush :: proc(line: ^strings.Builder, font: rl.Font, x: f32, y: ^f32, size, spacing: f32, colour: rl.Color) {
		rl.DrawTextEx(font, strings.to_cstring(line), {x, y^}, size, spacing, colour)
		y^ += size + 4
		strings.builder_reset(line)
	}
	words := strings.fields(text, context.temp_allocator)
	for word, i in words {
		was := len(line.buf)
		if was > 0 {
			strings.write_byte(&line, ' ')
		}
		strings.write_string(&line, word)
		if was > 0 && rl.MeasureTextEx(font, strings.to_cstring(&line), size, spacing).x > w {
			resize(&line.buf, was)
			flush(&line, font, x, y, size, spacing, colour)
			strings.write_string(&line, word)
		}
		if y^ + size > bottom {
			return
		}
		if i == len(words) - 1 {
			flush(&line, font, x, y, size, spacing, colour)
		}
	}
	y^ += 2
}

campaign_open_reporting :: proc(e: ^Editor, path: string) {
	if campaign_open(e, path) {
		editor_message(e, "Opened %s", path)
	} else {
		editor_message(e, "Cannot open %s", path)
	}
}
