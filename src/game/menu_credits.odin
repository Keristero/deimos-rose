package game

// Phase 7 stage 3: the Credits screen, reached from Main Menu's copyright
// text link (menu_main.odin's Text_Link case, previously inert). Traced from
// G_Credits_Display_0120e0.c (read in full) and the G_Text fade helpers it
// calls (G_Text_FadeListIn/Out_*.c) -- see docs/phase-7-faithful-menus.md's
// "Verification" section for the full research pass this is built from.
//
// The original runs this as a single blocking loop with its own nested
// blocking sub-loops for each fade; this reimplementation instead drives the
// same sequence of states (fade in -> hold -> fade out -> 1s settle pause ->
// next page) off real elapsed time each render frame, matching the original's
// pacing without literally transliterating its busy-wait structure.
//
// Per-line "start delay" staggering (G_Text_Settings offset 0x114, clamped
// against each fade's own frame counter in FadeListIn/Out) is not reproduced:
// every line drawn by any one caller shares a single G_Text_GetPermTextSetting
// preset, and nothing in the decompiled corpus pins down that field varying
// per instance, so all of a page's lines fade in and out together as one
// unit -- the visually simplest reading, and consistent with this port's
// existing practice of approximating sub-pixel/sub-frame animation nuance it
// couldn't pin down exactly (see Level Select's accept/fail tint strip).

import rl "vendor:raylib"

import "dr:render"
import "dr:sim"
import "dr:ui"

// G_Res_GetPermSoundID(2), "InterfaceClick" (idli/gaso.json) -- played once,
// on whatever input ends Credits (click, any keypress, or N specifically).
@(private = "file") CREDITS_CLICK_SOUND :: sim.Res_ID{'i', 'n', 'c', 'l'}

// The credits text itself (assets/data/stli/cred.json, PAK table "cred"):
// hand-transcribed here rather than read at runtime, matching this port's
// existing convention for .stli string tables (see menu_main.odin's website
// confirm prompt, cited from stli/inte.json the same way) -- nothing in the
// runtime asset loader (data/assets.odin) reads .stli JSON at all, only
// flli/idli/reli's perm tables. Each page's `<title>`/body lines and its
// trailing `<page NNN>` duration marker map straight to one Credits_Page.
//
// tagged_parse (data/tagged_text.odin) drops blank lines while decoding a
// resource into records -- correct for every `#key value` format, but the
// original's raw "cred" resource turns out to *use* blank .stli lines as
// vertical spacing inside a page (confirmed against a live Wine capture:
// see docs/phase-7-faithful-menus.md), so cred.json's already-decoded field
// list lost them. An empty string in `lines` below reproduces one, hand-added
// per line-up rule confirmed live rather than recovered byte-for-byte:
// always one blank line straight after the title (checked against three
// pages: Swoop Software, Additional Unit Art, Geek Support), and one more
// before a page's own trailing website URL, when it has one (checked against
// the two pages that do: Swoop Software, Additional Unit Art). Not
// individually reverified for the other seven pages.
Credits_Page :: struct {
	title: string,
	lines: []string, // "" is a blank spacing line -- advances Y, draws nothing
	ticks: int, // original's <page NNN> marker: a count of ~60Hz ticks (see below)
}

CREDITS_PAGES := []Credits_Page {
	{"Swoop Software", {"Sheryn Wareing", "David Wareing", "", "www.swoopsoftware.com"}, 200},
	{"Additional Unit Art", {"John Sledd,", "Sledd Studios", "", "www.sledd.com"}, 210},
	{"Music", {`Ben "Ferazels" Spees`}, 120},
	{"Mac OS X Support", {"Andrew Welch", "Matt Slot"}, 120},
	{
		"Geek Support",
		{
			`Matt "Pythos" Barry`,
			"Brooks Bell",
			`Hans "Vodi" Hvidsten Birkeland`,
			`Matt "EV" Burch`,
			`Paul "Fisj" Callender`,
			`Liam "Supercobra" Doughty`,
			"Bill Heineman",
			`Jeff "Oneiros" Hill`,
			`Steve "Dilvish" Ramsey`,
			"Matt Slot",
			`Ben "Handsome Harry" Spees`,
			`Nate "Lin" Trost`,
			"Andrew Welch",
			"Ed Wynne",
		},
		420,
	},
	{
		"Ambrosia Software",
		{
			"Bernard Cockhern - Money Man",
			"David Dunham - Technical Support",
			"Aaron Hunt - Operations",
			"Ed Ota - Operations",
			"Matt Slot - Bitwise Operator",
			"Andrew Welch - El Presidente",
			"",
			"www.ambrosiasw.com",
		},
		300,
	},
	{"Special Thanks", {"Andrea Martin", "Hugh Martin", "Alex Metcalf", "Jill Petersen", "John Petersen"}, 240},
	{
		"Chief Testers",
		{`Liam "Cobold" Doughty`, `Alex "Blinky Needs a Gun" Metcalf`, `Steve "Design Doc" Ramsey`},
		240,
	},
	{
		"Testers",
		{
			"Siddhartha Bajracharya",
			`Michael "Taz!" Blasco`,
			"Bruce Brejta",
			`Gordon "Crawler" Byrnes`,
			"Captain Carnotaur",
			"Dan Daranciang",
			"Derek Dohler",
			`Robert "forge" Drejer`,
			`Ty "TIE187" Hanna`,
			"Phillip Hutchings",
			"Mark Johns",
			"Michael Judkins",
			"Tim Kunkel",
		},
		420,
	},
	{
		"Testers",
		{
			"Mark Longanbach",
			"Thomas Metcalf",
			`Jeff "Merc" Nouwen`,
			"Ed O'Malley",
			"Rudy Richter",
			"Nicholas Robbins",
			"Matt Slot",
			"Stephan Somogyi",
			"Ralph Sutherland",
			`Tim "ArcAngelCounterstrike" Taylor`,
			`Aj "Slug" Williams`,
			`Stuart "h'biki" Willis`,
		},
		420,
	},
}

// U_App_GetTickCount (read in full) derives a ~60Hz tick from Win32
// GetTickCount(), distinct from the simulation's fixed 30Hz step -- Credits'
// <page NNN> durations and its U_App_Wait(0x3c) settle pause are both counted
// in this ~60Hz timebase, not sim steps or raw milliseconds.
CREDITS_TICK_HZ :: 60.0

// G_Text_FadeListIn/Out (both read in full): a fixed 32-frame ramp regardless
// of the "rate" argument they're called with -- that argument (uVar2, the
// per-frame tick spacing they busy-wait for) is round(Interface_FadeRate),
// perm float 0xa0 = 1.0, i.e. one animation frame per tick.
CREDITS_FADE_SECONDS :: 32.0 / CREDITS_TICK_HZ

// U_App_Wait(0x3c): 60 ticks, the blank-background pause between a page's
// fade-out and the next page's fade-in (also paid once, up front, before the
// very first page).
CREDITS_WAIT_SECONDS :: 60.0 / CREDITS_TICK_HZ

CREDITS_TITLE_Y :: 130.0 // Credits_TitleYLoc, perm float 0x4a
CREDITS_LINE_GAP :: 16.0 // Credits_VerticalGap, perm float 0x4b

// Left edge of the text column, measured against a live Wine capture (see
// docs/phase-7-faithful-menus.md) -- title and body lines share this same X,
// left-aligned, not centred (G_Text_GetRect/GetPermTextSetting's own X field
// was not recovered from the decompiled corpus; column-position measurement
// was the only way to pin this down, the same method LOGO_Y/BTN_FIRST_ROW_Y
// in menu_main.odin used).
CREDITS_X :: 121

// Solid fill colours sampled directly from that same capture -- title (0,
// 255, 189), body plain white -- since G_Text_GetPermTextSetting(8)/(9)'s
// colour fields were likewise not recovered from the decompiled corpus.
// [3]u8, not rl.Color, since credits_draw needs to substitute its own fade
// alpha in for the 4th channel each frame.
CREDITS_TITLE_RGB :: [3]u8{0, 255, 189}
CREDITS_BODY_RGB :: [3]u8{255, 255, 255}

Credits_State :: enum {
	Fading_In,
	Holding,
	Fading_Out,
	Waiting,
}

Credits :: struct {
	page:     int, // -1 until the initial settle pause finishes; then an index into CREDITS_PAGES
	state:    Credits_State,
	t:        f32, // seconds elapsed in the current state
	exiting:  bool, // this fade-out (or the settle pause after it) ends Credits rather than advancing
	new_game: bool, // 'N' was pressed -- start a new 1-player game instead of returning to Title
}

// G_Credits_Display's own first outer-tick: local_270 (page duration) starts
// at 0, so it immediately treats itself as "elapsed" and runs a transition --
// fading out nothing, then paying the settle pause -- before building page 0.
// Reproduced here as starting in .Waiting with page -1, so the same
// credits_update transition logic plays out that pause for the first page too.
credits_init :: proc(c: ^Credits) {
	c^ = Credits {
		page = -1,
		state = .Waiting,
	}
}

// Called once per render frame from flow_handle_input's .Credits case.
credits_update :: proc(fl: ^Flow, r: ^render.Renderer, c: ^Credits) {
	dt := rl.GetFrameTime()
	c.t += dt

	switch c.state {
	case .Holding:
		// U_App_Event_GetNext, polled only while holding -- the fade/wait
		// transitions in between are their own blocking sub-loops in the
		// original with no event polling at all.
		if credits_poll_exit(r, c) {
			return
		}
		hold_seconds := f32(CREDITS_PAGES[c.page].ticks) / CREDITS_TICK_HZ
		if c.t >= hold_seconds {
			c.exiting = c.page == len(CREDITS_PAGES) - 1
			c.state, c.t = .Fading_Out, 0
		}

	case .Fading_Out:
		if c.t >= CREDITS_FADE_SECONDS {
			if c.exiting {
				credits_finish(fl, c)
				return
			}
			c.state, c.t = .Waiting, 0
		}

	case .Waiting:
		if c.t >= CREDITS_WAIT_SECONDS {
			c.page += 1
			c.state, c.t = .Fading_In, 0
		}

	case .Fading_In:
		if c.t >= CREDITS_FADE_SECONDS {
			c.state, c.t = .Holding, 0
		}
	}
}

// event type 1 (click/close) or 2/3 (keypress, cStack_275 holding the key) --
// any of them plays the click sound and jumps to the exit/cleanup path; 'N'
// additionally asks that path to start a new game instead of just returning
// to Title. There is no "advance to next page" input at all.
@(private = "file")
credits_poll_exit :: proc(r: ^render.Renderer, c: ^Credits) -> bool {
	key := rl.GetKeyPressed()
	clicked := rl.IsMouseButtonPressed(.LEFT)
	if key == .KEY_NULL && !clicked {
		return false
	}
	ui.menu_play_sound(r, CREDITS_CLICK_SOUND)
	if key == .N {
		c.new_game = true
	}
	c.exiting = true
	c.state, c.t = .Fading_Out, 0
	return true
}

@(private = "file")
credits_finish :: proc(fl: ^Flow, c: ^Credits) {
	if c.new_game {
		flow_start_session(fl, flow_random_seed(), .Single, 0)
	} else {
		fl.mode = .Title
	}
}

credits_draw :: proc(r: ^render.Renderer, c: ^Credits) {
	ui.menu_draw_background(r, "back")

	page := c.page
	alpha: f32
	switch c.state {
	case .Fading_In:
		alpha = clamp(c.t / CREDITS_FADE_SECONDS, 0, 1)
	case .Holding:
		alpha = 1
	case .Fading_Out:
		alpha = 1 - clamp(c.t / CREDITS_FADE_SECONDS, 0, 1)
	case .Waiting:
		return // list already cleared; background only, same as the original
	}
	if page < 0 || page >= len(CREDITS_PAGES) {
		return
	}
	a := u8(alpha * 255)

	y := f32(CREDITS_TITLE_Y)
	p := &CREDITS_PAGES[page]
	title_color := rl.Color{CREDITS_TITLE_RGB[0], CREDITS_TITLE_RGB[1], CREDITS_TITLE_RGB[2], a}
	ui.menu_draw_text(r, p.title, CREDITS_X, i32(y), title_color)
	// A blank .stli line always follows the title in the original's raw
	// "cred" resource (see the Credits_Page comment above) -- tagged_parse
	// drops blank lines, so this one extra gap is applied directly here
	// rather than as a "" entry in every page's own `lines`.
	y += CREDITS_LINE_GAP * 2
	body_color := rl.Color{CREDITS_BODY_RGB[0], CREDITS_BODY_RGB[1], CREDITS_BODY_RGB[2], a}
	for line in p.lines {
		if line != "" {
			ui.menu_draw_text(r, line, CREDITS_X, i32(y), body_color)
		}
		y += CREDITS_LINE_GAP
	}
}
