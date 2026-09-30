package editor

// The level editor (Stages 7 and 8 of notes/level-editor-plan.md): sculpt
// a level project's terrain, light it, set its water and wind, place its
// units, and save it.
//
//   deimos-editor [<project>] [-new=ROWS] [-shot=OUT.png] [-size=WxH] [-row=N] [-zoom=1|2] [-tilt=DEGREES] [-tab=terrain|light|water|view|units] [-select=N] [-unlit]
//
// With no project it starts a new level, 480 wide and -new rows long
// (3600 by default). -shot draws one frame in a hidden window, writes it
// and exits: `mise run editor:shot`. The other flags set up the view, for
// shots above all. The units come from the assets tree, $DR_ASSETS or
// ./assets, and the data plugins beside it.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"
import "dr:terrain"

// The build's version, as the game's (game/menu_main.odin): set by the
// build tasks.
EDITOR_VERSION :: #config(DR_VERSION, "dev")

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 900

USAGE :: "usage: deimos-editor [<project>] [-new=ROWS] [-shot=OUT.png] [-size=WxH] [-row=N] [-zoom=1|2] [-tilt=DEGREES] [-tab=terrain|light|water|view|units] [-select=N] [-unlit]"

main :: proc() {
	flags := make(map[string]string, context.temp_allocator)
	plain := make([dynamic]string, context.temp_allocator)
	for a in os.args[1:] {
		if strings.has_prefix(a, "-") {
			k, _, v := strings.partition(a[1:], "=")
			flags[k] = v
		} else {
			append(&plain, a)
		}
	}
	if len(plain) > 1 || "help" in flags || "h" in flags {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	number :: proc(flags: map[string]string, name: string, fallback: int) -> int {
		v, given := flags[name]
		if !given {
			return fallback
		}
		n, ok := strconv.parse_int(v)
		if !ok {
			fmt.eprintfln("deimos-editor: -%s=%s is not a number", name, v)
			os.exit(2)
		}
		return n
	}
	width, height := WINDOW_WIDTH, WINDOW_HEIGHT
	if size, given := flags["size"]; given {
		ws, _, hs := strings.partition(size, "x")
		w, wok := strconv.parse_int(ws)
		h, hok := strconv.parse_int(hs)
		if !wok || !hok || w < 640 || h < 480 {
			fmt.eprintfln("deimos-editor: -size=%s is not WxH, at least 640x480", size)
			os.exit(2)
		}
		width, height = w, h
	}
	shot := flags["shot"] or_else ""

	// The units a level can place: the originals' and the data plugins'
	// (D52). No compiled plugin is in the editor, so none of theirs.
	declared, problems := data.plugins_discover(data.plugins_roots())
	for p in problems {
		fmt.eprintfln("plugins: %s: %s", p.dir, p.reason)
	}
	sim.plugins_declare(declared)
	// Every registry filled, as every main that touches the simulation does.
	sim.register_all()
	root := os.get_env("DR_ASSETS", context.temp_allocator)
	if root == "" {
		root = "assets"
	}

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags(shot != "" ? {.WINDOW_HIDDEN} : {.WINDOW_RESIZABLE})
	rl.InitWindow(i32(width), i32(height), "Deimos Rising level editor")
	if !rl.IsWindowReady() {
		fmt.eprintln("deimos-editor: no window (for a shot, run it under xvfb-run)")
		os.exit(1)
	}
	defer rl.CloseWindow()
	rl.SetWindowMinSize(640, 480)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)

	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	catalogue_load(&e.units, root)
	if len(e.units.palette) == 0 {
		fmt.eprintfln("deimos-editor: no units under %s: placing them needs `mise run assets:all`", root)
	}
	if len(plain) == 1 {
		if !editor_open(&e, plain[0]) {
			fmt.eprintfln("deimos-editor: cannot open %s", plain[0])
			os.exit(1)
		}
	} else if !editor_new(&e, number(flags, "new", NEW_LENGTH), "untitled" + terrain.PROJECT_SUFFIX) {
		fmt.eprintln("deimos-editor: -new wants a length in rows")
		os.exit(2)
	}
	e.new_length = i32(e.project.length)
	if "row" in flags {
		e.row = f32(number(flags, "row", 0))
	}
	e.zoom = clamp(number(flags, "zoom", 1), 1, 2)
	if "tilt" in flags {
		e.tilted, e.tilt = true, f32(number(flags, "tilt", 45))
	}
	e.live_light = !("unlit" in flags)
	// The level's Nth unit selected, and the view on it.
	if "select" in flags {
		n := number(flags, "select", 0)
		if n < 0 || n >= len(e.project.placements) {
			fmt.eprintfln("deimos-editor: -select=%d: the level has %d units", n, len(e.project.placements))
			os.exit(2)
		}
		e.selected = n
		at := placement_point(&e.units, e.project.placements[n])
		area := layout(f32(width), f32(height)).view
		e.row = at.y - view_rows(&e.view, area) / 2
		e.left = at.x - area.width / f32(2 * e.zoom)
	}
	if tab, given := flags["tab"]; given {
		found := false
		for t in Tab {
			if strings.equal_fold(fmt.tprint(t), tab) {
				e.tab, found = i32(t), true
			}
		}
		if !found {
			fmt.eprintfln("deimos-editor: no tab %s", tab)
			os.exit(2)
		}
	}

	if shot != "" {
		img := editor_shot(&e, width, height)
		defer rl.UnloadImage(img)
		if !rl.ExportImage(img, strings.clone_to_cstring(shot, context.temp_allocator)) {
			fmt.eprintfln("deimos-editor: cannot write %s", shot)
			os.exit(1)
		}
		fmt.println("wrote", shot)
		return
	}

	for !rl.WindowShouldClose() {
		title := fmt.ctprintf("%s%s - Deimos Rising level editor %s", editor_path(&e), e.dirty ? " *" : "", EDITOR_VERSION)
		rl.SetWindowTitle(title)
		editor_frame(&e)
		free_all(context.temp_allocator)
	}
	// raylib cannot take back a close, so unsaved work is kept beside the
	// project rather than asked about.
	if e.dirty {
		path := strings.concatenate({strings.trim_suffix(editor_path(&e), terrain.PROJECT_SUFFIX), ".unsaved", terrain.PROJECT_SUFFIX}, context.temp_allocator)
		if terrain.project_save(&e.project, path) {
			fmt.println("deimos-editor: unsaved changes kept in", path)
		} else {
			fmt.eprintln("deimos-editor: unsaved changes lost: cannot write", path)
		}
	}
}
