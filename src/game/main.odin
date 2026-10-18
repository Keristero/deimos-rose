package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/level_system"
import "dr:ui"

// A stall (window drag, breakpoint, GC pause) must not make the simulation
// try to catch up all at once; cap how many steps one render frame can run.
MAX_STEPS_PER_FRAME :: 4

main :: proc() {
	settings := settings_parse(os.args)
	if settings.plugins != "" {
		data.plugins_root_add(settings.plugins)
	}
	// The code plugins, each a library in its folder (D85); their
	// registration steps join the game's before register_all.
	_, lib_problems := plugin_libs_load(data.plugins_roots())
	for p in lib_problems {
		fmt.eprintfln("plugins: %s: %s", p.path, p.reason)
	}
	// Plugin folders with a plugin.json and no code (D52): registered
	// after the code plugins, by name.
	declared, problems := data.plugins_discover(data.plugins_roots())
	for p in problems {
		fmt.eprintfln("plugins: %s: %s", p.dir, p.reason)
	}
	sim.plugins_declare(declared)
	// Every registry filled, in the same order on every platform.
	sim.register_all()
	// Saved preferences, with this run's launch flags layered on top.
	// Headless captures use the defaults instead, so a player's own
	// settings can never change what a comparison shot shows; the flags
	// still apply (-mod for the site's screenshots).
	ps := Prefs_State{saved = prefs.defaults(), launch = settings, launch_mods = prefs.launch_mods(settings.args)}

	// Everything comes out of the extracted assets tree. The original
	// install is needed only to produce it, and by the oracle tooling.
	root := os.get_env("DR_ASSETS", context.temp_allocator)
	if root == "" {
		root = "assets"
	}
	defs, report := data.assets_defs_load(root)
	// New content (plugins/<name>/data) rides after the originals; only a New
	// Weapons session reaches it (docs/new-weapons.md).
	data.extra_defs_load(&defs)
	// Peers with different plugin content refuse each other (D52).
	data.plugins_digest()
	if settings.list_plugins {
		plugins_list(len(lib_problems) == 0, defs.content)
	}
	if len(defs.levels) == 0 {
		fmt.eprintfln("no level definitions under %v -- run `mise run assets:all`", root)
		os.exit(1)
	}

	// DR_SHOT and DR_MENU_SHOT (below) drive every headless capture --
	// oracle:shot's compare, the shots:compare task and menu_compare.sh all
	// run under xvfb-run with no PulseAudio session behind it, and nothing is
	// there to hear it either way, so skip the audio device and asset loading
	// entirely rather than let raylib log device-init failures every run.
	headless := os.get_env("DR_SHOT", context.temp_allocator) != "" ||
		os.get_env("DR_MENU_SHOT", context.temp_allocator) != ""

	menu_shot_name := os.get_env("DR_MENU_SHOT", context.temp_allocator)
	if !headless {
		ps = prefs_state_load(settings)
	}

	// A menu capture draws into its own render texture (run_menu_shot), so
	// its window never needs to be seen.
	flags := rl.ConfigFlags{.VSYNC_HINT, .WINDOW_RESIZABLE}
	if menu_shot_name != "" || os.get_env("DR_SHOT_FIND", context.temp_allocator) != "" {
		flags += {.WINDOW_HIDDEN}
	}
	rl.SetConfigFlags(flags)
	rl.InitWindow(render.SCREEN_W * render.WINDOW_SCALE, render.SCREEN_H * render.WINDOW_SCALE, "Deimos Rising")
	defer rl.CloseWindow()

	// DR_NO_AUDIO=1 plays silently otherwise as usual, for a scripted run
	// on a machine someone is using (tools/netplay/level_end_check.sh):
	// no device, and no sounds loaded, as for a shot.
	audio := !headless && os.get_env("DR_NO_AUDIO", context.temp_allocator) == ""
	if audio {
		rl.InitAudioDevice()
	}
	defer if audio {
		rl.CloseAudioDevice()
	}

	// FPS_MaxRate (perm float 0x20) is 30.0 in the shipped data:
	// G_GameInterface::Draw steps once, draws, then busy-waits on FPS_Delay
	// (0x21, in ~16.66ms ticks) before the next step. The original runs at
	// 30 FPS, not 60 -- an unconditional SetTargetFPS(60) here previously
	// ran the whole simulation at double speed.
	step_hz := defs.perm_floats[0x20]
	rl.SetTargetFPS(i32(step_hz)) // the interactive loop retargets per the high refresh rate setting

	renderer: render.Renderer
	render.renderer_init(&renderer, root, prefs_classic(&ps), audio)
	defer render.renderer_destroy(&renderer)

	fx: render.Effects
	render.effects_init(&fx)
	defer render.effects_destroy(&fx)

	state := new(sim.State)
	defer free(state)
	defer sim.destroy(state)

	// DR_MENU_SHOT=<name> renders one named menu screen and writes a single
	// PNG to DR_SHOT, then exits -- the menu equivalent of DR_SHOT below, for
	// tools/oracle/menu_compare.sh. A menu has no simulation to step, so
	// there is exactly one frame to capture, not a series of them.
	if menu_shot_name != "" {
		run_menu_shot(&renderer, &defs, state, root, menu_shot_name, os.get_env("DR_SHOT", context.temp_allocator), &ps)
		return
	}

	// DR_FILM=de01 replays a shipped demo instead of taking input, so a
	// screenshot can be compared with the original stopped at the same step.
	film: sim.Film
	playing_film := false
	if name := os.get_env("DR_FILM", context.temp_allocator); name != "" {
		bytes, ferr := os.read_entire_file(fmt.tprintf("%s/films/%s.film", root, name), context.allocator)
		f, perr := data.film_parse(bytes)
		if ferr != nil || perr != .None {
			fmt.eprintfln("cannot read film %v: %v/%v", name, ferr, perr)
			os.exit(1)
		}
		film = data.film_to_sim(f)
		playing_film = true
		sim.init(state, film.session, &defs)
	}

	shot := os.get_env("DR_SHOT", context.temp_allocator)
	if shot != "" && !playing_film {
		// DR_SHOT with no DR_FILM shoots the same fixed-seed default session
		// this always started with, before Flow made a fresh interactive run
		// defer sim.init to the title screen -- preserved so existing
		// DR_SHOT-only invocations keep seeing the same frames.
		level := defs.levels[0].id // play order: Lucena is level 1
		campaign := sim.CORE
		// -campaign, -level and -row pick another, as they would play it.
		if settings.campaign != "" || settings_play_now(settings) {
			c, index, ok := launch_level(&defs, settings)
			if !ok {
				os.exit(1)
			}
			campaign, level = c, sim.campaign_levels(&defs, c)[index].id
		}
		sim.init(state, sim.Session{seed = 0x1234_5678, level_id = level, game_type = .Single, campaign = campaign}, &defs)
		if settings.row > 0 {
			level_system.level_start_at_row(state, i32(settings.row))
		}
	}

	// DR_SHOT=<path> renders DR_SHOT_AT steps (comma-separated) and writes a
	// PNG of each, then exits. Running the real thing is the only way to see
	// whether the compositing is right, and this makes that reviewable
	// without a desktop session.
	if shot != "" {
		// DR_SHOT_ACCENTS=<hue>,<hue> draws each player with a netplay
		// accent (flow_draw's r.accents), to check them without a session.
		accents := os.get_env("DR_SHOT_ACCENTS", context.temp_allocator)
		for field, i in strings.split(accents, ",", context.temp_allocator) {
			if hue, ok := strconv.parse_int(strings.trim_space(field)); ok && i < sim.MAX_PLAYERS {
				renderer.accents[i] = {on = true, hue = f32(prefs.hue_wrap(hue))}
			}
		}
		run_shots(&renderer, state, &fx, playing_film ? &film : nil, shot,
			os.get_env("DR_SHOT_AT", context.temp_allocator))
		return
	}

	// Interactive: Flow owns the session lifecycle from here on (Title until
	// the player starts one, then Playing/Paused/Game_Over/Complete/Attract),
	// so state stays zeroed until flow_start_session or flow_load_demo runs.
	flow: Flow
	flow_init(&flow, root, &defs, state, &renderer, &ps)
	defer flow_destroy(&flow)
	if !flow_launch(&flow, settings) {
		os.exit(1)
	}

	// Every frame is drawn into this fixed 1280x960 canvas, then scaled to
	// fit the window, letterboxed -- which is what lets fullscreen (and a
	// resized window) show the whole game rather than its top-left corner.
	renderer.canvas = rl.LoadRenderTexture(render.SCREEN_W * render.WINDOW_SCALE, render.SCREEN_H * render.WINDOW_SCALE)

	// A plugin's screen may show itself at startup: netplay's, for
	// DR_NETPLAY=host or join:<address> (tools/netplay/loopback_check.sh).
	for sc in registered_screens() {
		if sc.launch != nil {
			sc.launch(&flow, &renderer)
		}
	}

	// Escape means pause/resume/back everywhere in Flow, not an instant quit
	// (raylib's own default exit key is Escape); flow.quit below is the only
	// path left that closes the window on Escape, from the title screen.
	rl.SetExitKey(.KEY_NULL)

	diagnostics: Diagnostics

	// Fixed-step: the simulation advances in slices of step_dt regardless of
	// how often the frame is actually presented, so a plugin's frame rate (or a
	// slow/fast monitor, or a stall) changes how smoothly the game is shown,
	// never how fast it plays.
	step_dt := 1.0 / f64(step_hz)
	accumulator: f64 = 0
	show_debug := false

	// High refresh rate: the state as it was before the latest step, which
	// the renderer draws each frame interpolated towards the current one
	// (render.odin's interp). Copied only while the setting is on. Purely
	// presentation: nothing ever reads it back into the simulation, so it
	// cannot change gameplay, films, netplay or a checksum -- at the cost of
	// drawing up to one step (~33 ms) behind the newest state.
	interp_prev := new(render.Interp_Prev)
	defer free(interp_prev)
	fps_pacer: Maybe(int)
	for !rl.WindowShouldClose() && !flow.quit {
		// Preferences edits ps in place; apply whatever it holds now.
		renderer.classic = prefs_classic(&ps)
		renderer.textures.quicktime_gamma = renderer.classic
		// The menus' own; a game in play sets them with its session's.
		renderer.textures.mods = prefs_mods(&ps)
		diagnostics.enabled = prefs_diagnostics(&ps)
		renderer.textures.sfx_volume = f32(ps.saved.sfx_volume) / 100
		renderer.textures.music_volume = f32(ps.saved.music_volume) / 100
		if prefs_fullscreen(&ps) != rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {
			rl.ToggleBorderlessWindowed()
		}
		// A plugin that is on may ask for another frame rate
		// (render.frame_rate_register); otherwise one frame a step.
		pacer := -1
		for fr, i in render.registered_frame_rates() {
			if prefs_mod_on(&ps, fr.plugin) {
				pacer = i
				break
			}
		}
		if applied, ok := fps_pacer.?; !ok || applied != pacer {
			fps := i32(step_hz)
			if pacer >= 0 {
				fps = render.registered_frame_rates()[pacer].fps()
			}
			rl.SetTargetFPS(fps)
			fps_pacer = pacer
		}
		between := pacer >= 0 // frames drawn between steps, interpolated
		dst := canvas_fit(renderer.canvas)
		// Mouse positions come back in canvas pixels, so every menu's
		// hit-testing (menu_mouse_pos) is unaffected by the scaling.
		rl.SetMouseOffset(-i32(dst.x), -i32(dst.y))
		rl.SetMouseScale(f32(renderer.canvas.texture.width) / dst.width, f32(renderer.canvas.texture.height) / dst.height)

		if rl.IsKeyPressed(.F1) {
			show_debug = !show_debug
		}
		if rl.IsKeyPressed(.F2) {
			renderer.shadows = !renderer.shadows
		}
		flow_handle_input(&flow, &renderer)
		accumulator += f64(rl.GetFrameTime()) * flow_speed(&flow, &renderer)
		for steps := 0; accumulator >= step_dt && steps < MAX_STEPS_PER_FRAME; steps += 1 {
			was_playing := flow.mode == .Playing
			if between {
				render.interp_capture(interp_prev, state) // before this step; a step that changes nothing leaves them equal
			}
			if flow_held(&flow, &renderer) {
				accumulator -= step_dt
				continue
			}
			flow_step(&flow, &renderer, &fx)
			if was_playing {
				diagnostics_note_update(&diagnostics)
			}
			accumulator -= step_dt
		}
		flow_music_update(&flow, &renderer)
		// How far the render is between the last step and the next.
		renderer.interp_prev = between ? interp_prev : nil
		renderer.interp_alpha = between ? f32(clamp(accumulator / step_dt, 0, 1)) : 1
		driven, ping_ms, rollbacks := flow_stats(&flow)
		diagnostics_tick(&diagnostics, rl.GetFrameTime(), rollbacks)

		rl.BeginTextureMode(renderer.canvas)
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		flow_draw(&flow, &renderer, &fx, render.WINDOW_SCALE)
		if show_debug && sim.level_def(state) != nil {
			draw_debug(state, &report)
		}
		diagnostics_draw(&diagnostics, driven, ping_ms)
		rl.EndTextureMode()
		for sc in registered_screens() {
			if sc.framed != nil {
				sc.framed(&renderer)
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		// Nearest-neighbour at a whole-number scale keeps the pixels exact
		// (the ordinary 1280x960 window is 1:1); anything else is smoothed
		// rather than drawn with uneven pixel widths.
		whole := dst.width == f32(i32(dst.width / f32(renderer.canvas.texture.width))) * f32(renderer.canvas.texture.width)
		rl.SetTextureFilter(renderer.canvas.texture, whole ? .POINT : .BILINEAR)
		src := rl.Rectangle{0, 0, f32(renderer.canvas.texture.width), -f32(renderer.canvas.texture.height)} // render textures are bottom-up
		// Premultiplied: the canvas's colour is already composited, but
		// blending left its alpha below 255 under anything translucent, and
		// ordinary alpha blending would darken those pixels a second time.
		rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
		rl.DrawTexturePro(renderer.canvas.texture, src, dst, {0, 0}, 0, rl.WHITE)
		rl.EndBlendMode()
		rl.EndDrawing()
	}
}

// The canvas as <path>.png.
canvas_save :: proc(canvas: rl.RenderTexture2D, path: string) {
	img := rl.LoadImageFromTexture(canvas.texture)
	rl.ImageFlipVertical(&img) // render textures are bottom-up
	// Blending leaves the texture's alpha below 255 wherever something
	// translucent was drawn; its colour is already composited, so drop it.
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
	out := fmt.ctprintf("%s.png", path)
	rl.ExportImage(img, out)
	rl.UnloadImage(img)
	fmt.printfln("wrote %s", out)
}

// Where the canvas goes in the window: as large as fits without cropping,
// centred, keeping the 4:3 shape.
canvas_fit :: proc(canvas: rl.RenderTexture2D) -> rl.Rectangle {
	cw, ch := f32(canvas.texture.width), f32(canvas.texture.height)
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	scale := min(sw / cw, sh / ch)
	w, h := cw * scale, ch * scale
	return {f32(i32((sw - w) / 2)), f32(i32((sh - h) / 2)), w, h}
}

// One named menu screen, drawn once and exported to <path>.png. See
// docs/phase-7-faithful-menus.md's "Verification" section and
// tools/oracle/menu_shot.sh/menu_compare.sh, which drive this to compare
// against the original. Each menu screen is a case below.
run_menu_shot :: proc(r: ^render.Renderer, defs: ^sim.Defs, state: ^sim.State, root, name, path: string, ps: ^Prefs_State) {
	flow: Flow
	flow_init(&flow, root, defs, state, r, ps)
	// Real (empty) presentation effects, for the cases that draw a game
	// frame behind the menu.
	fx: render.Effects
	render.effects_init(&fx)
	defer render.effects_destroy(&fx)
	name := name
	if ms, ok := ui.menu_shot_find(name); ok {
		// A plugin's view of one of the screens below (ui.Menu_Shot). Not
		// saved: a screenshot leaves the player's preferences alone.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		ps.saved.mods = sim.mods_switch_on(ps.saved.mods, {int(ms.plugin)})
		if ms.setup != nil {
			ms.setup(&ps.saved)
		}
		name = ms.screen
	}
	switch name {
	case "main":
		flow.mode = .Title
	case "level_select":
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		level_select_init(&flow, &flow.level_select)
	case "level_select_campaigns":
		// Outside classic mode, with every campaign plugin on (D53): the
		// campaign switch above the level number, on the last campaign
		// offered. With none but Classic Levels installed it is the plain
		// screen; see the menu-shot task.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		for i in 1 ..< len(sim.registered_plugins()) {
			if len(sim.campaign_levels(defs, sim.Plugin_ID(i))) > 0 {
				ps.saved.mods += {i}
			}
		}
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		offered := flow_campaigns(&flow)
		flow_campaign_set(&flow, offered[len(offered) - 1])
		level_select_init(&flow, &flow.level_select)
	case "main_netplay":
		// The main menu once its first update has built the links and the
		// Netplay item -- "main" above is kept exactly as the oracle
		// comparison has always seen it.
		flow.mode = .Title
		main_menu_update(&flow, r, &flow.main_menu)
	case "preferences":
		// New content, no original to compare against: a visual check.
		flow.mode = .Preferences
		preferences_init(&flow.preferences)
		preferences_update(&flow, r, &flow.preferences) // lays the buttons out
	case "paused":
		// Single-player pause over a level a couple of seconds in: the
		// pause notice, and outside classic mode the button.
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
		for _ in 0 ..< 60 {
			_ = sim.session_step(state, {})
		}
		flow.mode = .Paused
		flow.pause_menu.notice = true
		flow_handle_input(&flow, r) // builds the pause menu's buttons
	case "restarted":
		// The check for effects outliving a session: play until particles
		// are on screen, quit to the menu, start a new game. The shot must
		// show none of the old game's, and the counts are printed.
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
		for i := 0; i < 2000 && (i < 300 || len(fx.particles.live) == 0); i += 1 {
			_ = sim.session_step(state, {{.Fire_Air, .Fire_Ground}, {}})
			render.effects_step(&fx, state)
		}
		fmt.eprintfln("before quitting: %d particles, %d ghosts", len(fx.particles.live), len(fx.blurs.live))
		flow.mode = .Title // quitting to the menu
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
	case "interpolated":
		// High refresh rate interpolation's own check: a level a few
		// seconds in, drawn DR_INTERP_ALPHA (default 0.5) of the way from
		// one step to the next. 0 should match the step before, 1 the step
		// after; anything between, lie between them.
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
		for _ in 0 ..< 90 {
			_ = sim.session_step(state, {})
		}
		prev := new(render.Interp_Prev, context.temp_allocator)
		render.interp_capture(prev, state)
		_ = sim.session_step(state, {})
		flow.mode = .Playing
		r.interp_prev = prev
		r.interp_alpha = 0.5
		if a, ok := strconv.parse_f32(os.get_env("DR_INTERP_ALPHA", context.temp_allocator)); ok {
			r.interp_alpha = a
		}
	case "playing":
		// A level a few seconds in, firing, outside classic mode with only
		// what the launch flags turn on: -mod <name>, and -campaign and
		// -level for where. The plain scene a plugin with no scenario of
		// its own is pictured in, a data plugin's textures or levels (the
		// site's screenshots, site:shots).
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		ps.saved.mods = {}
		campaign, index, ok := launch_level(defs, ps.launch)
		if !ok {
			os.exit(1)
		}
		flow_campaign_set(&flow, campaign)
		flow_start_session(&flow, 0x1234_5678, .Single, index)
		flow_effects_sync(&flow, &fx)
		flow_set_accents(&flow, r)
		// Fire tapped, as held it would only charge.
		for i in 0 ..< 300 {
			input := i % 6 < 3 ? sim.Frame_Input{{.Fire_Air, .Fire_Ground}, {}} : {}
			_ = sim.session_step(state, input)
			render.particles_step(&fx.particles, state)
			render.effect_systems_step(r, state, &fx.particles)
		}
		flow.mode = .Playing
	case "credits":
		flow.mode = .Credits
		credits_init(&flow.credits)
		// Skip the initial 1s settle pause and page 0's own fade-in --
		// run_menu_shot draws exactly one static frame, so start already
		// settled on page 0 at full opacity rather than a blank background.
		flow.credits.page = 0
		flow.credits.state = .Holding
	case "high_scores":
		flow.mode = .High_Scores
		high_scores_view_init(&flow.high_scores, defs.levels)
		// Skip the fade-in -- run_menu_shot draws exactly one static frame,
		// so start already settled at full opacity rather than mid-fade.
		flow.high_scores.state = .Holding
	case "score_entry":
		// No real gameplay session to trigger this from in a headless shot --
		// stands up a synthetic qualifying score (single player) the same way
		// flow_finish_session does, for a quick visual smoke check rather
		// than an oracle comparison (the original screen needs an actual
		// completed session with a high enough score, which isn't practical
		// to script through xdotool -- see docs/phase-7-faithful-menus.md's
		// Stage 4 notes).
		score_entry_start(&flow.score_entry, defs.levels, {99999, 0}, {true, false}, "Mariner Valley")
		flow.mode = .Score_Entry
		flow.score_entry.state = .Editing
	case "extras":
		// The Extras page as saved; plugins' menu shots (ui.Menu_Shot) set
		// what it shows.
		flow.mode = .Preferences
		flow.preferences.page = .Extras
	case "preferences_mods":
		// The Mods page as a new player finds it.
		flow.mode = .Preferences
		flow.preferences.page = .Mods
	case "preferences_mods_end":
		// Its last rows: where data plugins list (D52), which
		// DR_PLUGINS=$PWD/tests/fixtures/plugins shows with the fixtures.
		flow.mode = .Preferences
		flow.preferences.page = .Mods
		mods_page_scroll_end(&flow.preferences.mods)
	case:
		// A plugin screen's own (screens.odin): netplay's lobby, and the
		// diagnostics overlay over it, the one screen with a ping to show.
		if shot_screen(&flow, r, name) {
			break
		}
		// A plugin's own scenario (ui/shots.odin).
		sh, ok := ui.shot_find(name)
		if !ok {
			fmt.eprintfln("unknown menu %v (see run_menu_shot and ui.shot_register)", name)
			os.exit(1)
		}
		// Not saved: a screenshot leaves the player's preferences alone.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		others := sh.alone ? sim.Mods{} : prefs.defaults().mods
		ps.saved.mods = sim.mods_switch_on(others, {int(sh.plugin)})
		// -campaign <name> plays the scenario on that campaign's level.
		if id, found := launch_campaign(ps.launch); found && id != sim.CORE {
			ps.saved.mods = sim.mods_switch_on(ps.saved.mods, {int(id)})
			flow_campaign_set(&flow, id)
		}
		flow_start_session(&flow, 0x1234_5678, sh.co_op ? .Co_Op : .Single, sh.level)
		if err := sh.setup(state, name); err != "" {
			fmt.eprintfln("%s: %s", name, err)
			os.exit(1)
		}
		if len(sh.phases) > 0 {
			// Taken now, so drawing a shot does not clear the effects below
			// as a new level's.
			flow_effects_sync(&flow, &fx)
		}
		// The plugins drawn with, which the effect systems step by.
		flow_set_accents(&flow, r)
		for ph in sh.phases {
			for _ in 0 ..< ph.steps {
				_ = sim.session_step(state, ph.input)
				render.particles_step(&fx.particles, state)
				render.effect_systems_step(r, state, &fx.particles)
			}
		}
		flow.mode = .Playing
	}
	// game/diagnostics.odin's overlay: this menu name doubles as its visual
	// smoke check (there's no baseline to compare against, just a look).
	// A screen readies it -- netplay's connected lobby, the one with a ping
	// to show -- as if it drove a session; run_menu_shot draws one static
	// frame, so the numbers are hand-set, not measured by diagnostics_tick.
	diag: Diagnostics
	if name == "diagnostics" {
		diag.enabled = true
		diag.updates_per_sec = 30.0
		diag.rollbacks_per_sec = 1.2
		flow.driven = true
	}
	// Drawn into a render texture rather than read back from the window,
	// which is hidden (main) -- a hidden window's back buffer is not
	// guaranteed to hold anything. r.canvas lets build_frame's terrain
	// drawing return to it (resume_canvas); renderer_destroy unloads it.
	r.canvas = rl.LoadRenderTexture(render.SCREEN_W * render.WINDOW_SCALE, render.SCREEN_H * render.WINDOW_SCALE)
	rl.BeginTextureMode(r.canvas)
	rl.ClearBackground(rl.Color{0, 0, 0, 255})
	r.textures.mods += prefs_mods(ps) // as the main loop sets them
	flow_draw(&flow, r, &fx, render.WINDOW_SCALE)
	driven, ping_ms, _ := flow_stats(&flow)
	diagnostics_draw(&diag, driven, ping_ms)
	if name == "restarted" {
		fmt.eprintfln("new game drawn with: %d particles, %d ghosts", len(fx.particles.live), len(fx.blurs.live))
	}
	rl.EndTextureMode()
	canvas_save(r.canvas, path)
}

// Steps the simulation, capturing the frame at each requested step.
run_shots :: proc(r: ^render.Renderer, s: ^sim.State, fx: ^render.Effects, film: ^sim.Film, path, at: string) {
	steps := make([dynamic]int, context.temp_allocator)
	rest := at == "" ? "120" : at
	for field in strings.split_iterator(&rest, ",") {
		if v, ok := strconv.parse_int(strings.trim_space(field)); ok {
			append(&steps, v)
		}
	}
	slice.sort(steps[:])
	last := len(steps) == 0 ? 0 : steps[len(steps) - 1]
	next := 0
	dump := os.get_env("DR_DUMP", context.temp_allocator) != ""
	// DR_SHOT_FIND=<text>: no images, just the steps (up to the last
	// DR_SHOT_AT) where some draw's DR_DUMP line contains <text> -- e.g.
	// "pbta frame 1" for a locked crosshair. One run, first 20 steps shown.
	r.find = os.get_env("DR_SHOT_FIND", context.temp_allocator)
	r.replay = true // a demo film, as the original labels one
	found := 0
	for i in 0 ..= last {
		if r.find != "" {
			r.find_hits = 0
			render.build_frame(r, s, &fx.blurs, &fx.notices)
			if r.find_hits > 0 {
				found += 1
				if found <= 20 {
					fmt.printfln("step %v: %v match(es)", i, r.find_hits)
				}
			}
			sim.step(s, {}, film)
			render.effects_step(fx, s)
			continue
		}
		r.dump = dump && next < len(steps) && steps[next] == i
		if r.dump {
			fmt.printfln("step %v draw list:", i)
		}
		render.build_frame(r, s, &fx.blurs, &fx.notices)
		// Only a frame that is saved is presented: EndDrawing waits for
		// vsync, which made a shot a few thousand steps in take minutes.
		// Twice, so both swap buffers hold it -- the read-back below reads
		// whichever one the swap left, and a skipped frame leaves it stale.
		if next < len(steps) && steps[next] == i {
			for _ in 0 ..< 2 {
				rl.BeginDrawing()
				rl.ClearBackground(rl.Color{0, 0, 0, 255})
				render.present(r, s, &fx.particles, render.WINDOW_SCALE)
				rl.EndDrawing()
			}
		}
		if r.dump {
			r.dump = false
		}
		for next < len(steps) && steps[next] == i {
			img := rl.LoadImageFromScreen()
			name := fmt.ctprintf("%s-%04d.png", path, i)
			rl.ExportImage(img, name)
			rl.UnloadImage(img)
			fmt.printfln("wrote %s  (step %v, %v entities)", name, i, sim.single(s, sim.Pool).used_count)
			next += 1
		}
		sim.step(s, {}, film)
		render.effects_step(fx, s)
		render.sounds_step(&r.textures, s)
	}
	if r.find != "" {
		fmt.printfln("%q: %v of %v steps", r.find, found, last + 1)
	}
}

draw_debug :: proc(s: ^sim.State, report: ^data.Defs_Report) {
	rl.DrawText(
		fmt.ctprintf(
			"frame %v  time %v  entities %v  scroll %v\nplayer shields %.0f lives %v score %v\ndefs: %v units %v sprites %v levels",
			sim.frame_of(s), sim.single(s, sim.Clock).time, sim.single(s, sim.Pool).used_count, sim.single(s, sim.Bgnd).view_top,
			sim.player_at(s, 0).shields, sim.player_at(s, 0).lives, sim.player_at(s, 0).score,
			report.units, report.sprites, report.levels,
		),
		8, 8, 14, rl.Color{150, 230, 150, 255},
	)
	for used, i in sim.single(s, sim.Pool).entity_used {
		if !used {
			continue
		}
		b := lifecycle.object_bounds(sim.entity_at(s, i32(i)).obj)
		rl.DrawRectangleLines((b.left + render.VIEW_X) * render.WINDOW_SCALE, b.top * render.WINDOW_SCALE,
			(b.right - b.left) * render.WINDOW_SCALE, (b.bottom - b.top) * render.WINDOW_SCALE,
			rl.Color{220, 170, 90, 120})
	}
	b := lifecycle.object_bounds(sim.player_at(s, 0).obj)
	rl.DrawRectangleLines((b.left + render.VIEW_X) * render.WINDOW_SCALE, b.top * render.WINDOW_SCALE,
		(b.right - b.left) * render.WINDOW_SCALE, (b.bottom - b.top) * render.WINDOW_SCALE,
		rl.Color{120, 200, 255, 160})
}
