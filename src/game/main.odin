package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import accent_view "dr:plugins/accent/view"
import "dr:plugins/easy_mode"
import "dr:plugins/fps_unlock"
import "dr:plugins/loadout"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/player_system"
import "dr:sim/systems/weapon_system"

// A stall (window drag, breakpoint, GC pause) must not make the simulation
// try to catch up all at once; cap how many steps one render frame can run.
MAX_STEPS_PER_FRAME :: 4

main :: proc() {
	settings := settings_parse(os.args)
	// Saved preferences, with this run's launch flags layered on top.
	// Headless captures use the defaults instead, so a player's own
	// settings can never change what a comparison shot shows.
	ps := Prefs_State{saved = prefs.defaults(), launch = settings}

	// Everything comes out of the extracted assets tree. The original
	// install is needed only to produce it, and by the oracle tooling.
	root := os.get_env("DR_ASSETS", context.temp_allocator)
	if root == "" {
		root = "assets"
	}
	defs, report := data.assets_defs_load(root)
	// New content (assets/extra) rides after the originals; only a New
	// Weapons session reaches it (docs/new-weapons.md).
	data.extra_defs_load(root, &defs)
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

	if !headless {
		rl.InitAudioDevice()
	}
	defer if !headless {
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
	render.renderer_init(&renderer, root, prefs_classic(&ps), !headless)
	defer render.renderer_destroy(&renderer)

	particles: render.Particles
	render.particles_init(&particles)
	defer render.particles_destroy(&particles)

	blurs: render.Blurs
	render.blurs_init(&blurs)
	defer render.blurs_destroy(&blurs)

	notices: render.Notices

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
		sim.init(state, sim.Session{seed = 0x1234_5678, level_id = level, game_type = .Single}, &defs)
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
		run_shots(&renderer, state, &particles, &blurs, &notices, playing_film ? &film : nil, shot,
			os.get_env("DR_SHOT_AT", context.temp_allocator))
		return
	}

	// Interactive: Flow owns the session lifecycle from here on (Title until
	// the player starts one, then Playing/Paused/Game_Over/Complete/Attract),
	// so state stays zeroed until flow_start_session or flow_load_demo runs.
	flow: Flow
	flow_init(&flow, root, &defs, state, &renderer, &ps)
	defer flow_destroy(&flow)

	// Every frame is drawn into this fixed 1280x960 canvas, then scaled to
	// fit the window, letterboxed -- which is what lets fullscreen (and a
	// resized window) show the whole game rather than its top-left corner.
	renderer.canvas = rl.LoadRenderTexture(render.SCREEN_W * render.WINDOW_SCALE, render.SCREEN_H * render.WINDOW_SCALE)

	// DR_NETPLAY=host or DR_NETPLAY=join:<address> jumps straight into the
	// netplay lobby already hosting/joining -- see
	// netplay_lobby_start_from_flag's comment for why (a scripted test
	// driving two instances at once, tools/netplay/loopback_check.sh).
	if netplay_flag := os.get_env("DR_NETPLAY", context.temp_allocator); netplay_flag != "" {
		netplay_lobby_init(&flow.netplay, &renderer)
		flow.mode = .Netplay_Lobby
		netplay_lobby_start_from_flag(&flow.netplay, &ps.saved, netplay_flag)
	}

	// Escape means pause/resume/back everywhere in Flow, not an instant quit
	// (raylib's own default exit key is Escape); flow.quit below is the only
	// path left that closes the window on Escape, from the title screen.
	rl.SetExitKey(.KEY_NULL)

	diagnostics: Diagnostics

	// Fixed-step: the simulation advances in slices of step_dt regardless of
	// how often the frame is actually presented, so -highrefreshrate (or a
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
	fps_high: Maybe(bool)
	for !rl.WindowShouldClose() && !flow.quit {
		// Preferences edits ps in place; apply whatever it holds now.
		renderer.classic = prefs_classic(&ps)
		renderer.textures.quicktime_gamma = renderer.classic
		diagnostics.enabled = prefs_diagnostics(&ps)
		renderer.textures.sfx_volume = f32(ps.saved.sfx_volume) / 100
		renderer.textures.music_volume = f32(ps.saved.music_volume) / 100
		if prefs_fullscreen(&ps) != rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {
			rl.ToggleBorderlessWindowed()
		}
		high := prefs_mod_on(&ps, fps_unlock.ID)
		if applied, ok := fps_high.?; !ok || applied != high {
			fps := i32(step_hz)
			if high {
				rate := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
				fps = rate > 0 ? rate : 60
			}
			rl.SetTargetFPS(fps)
			fps_high = high
		}
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
		accumulator += f64(rl.GetFrameTime())
		for steps := 0; accumulator >= step_dt && steps < MAX_STEPS_PER_FRAME; steps += 1 {
			was_playing := flow.mode == .Playing
			if high {
				render.interp_capture(interp_prev, state) // before this step; a step that changes nothing leaves them equal
			}
			flow_step(&flow, &renderer, &particles, &blurs, &notices)
			if was_playing {
				diagnostics_note_update(&diagnostics)
			}
			accumulator -= step_dt
		}
		flow_music_update(&flow, &renderer)
		// How far the render is between the last step and the next.
		renderer.interp_prev = high ? interp_prev : nil
		renderer.interp_alpha = high ? f32(clamp(accumulator / step_dt, 0, 1)) : 1
		diagnostics_tick(&diagnostics, rl.GetFrameTime(), flow.netplay_active ? flow.netplay.rs.rollback_count : 0)

		rl.BeginTextureMode(renderer.canvas)
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		flow_draw(&flow, &renderer, &particles, &blurs, &notices, render.WINDOW_SCALE)
		if show_debug && sim.level_def(state) != nil {
			draw_debug(state, &report)
		}
		diagnostics_draw(&diagnostics, flow.netplay_active, flow.netplay.ping_ms)
		rl.EndTextureMode()

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
// against the original. Flow's Title branch (the only menu mode so far)
// returns before touching particles/blurs/notices, so nil is safe here; add
// a case as each later stage (Level Select, Credits, High Scores) lands.
run_menu_shot :: proc(r: ^render.Renderer, defs: ^sim.Defs, state: ^sim.State, root, name, path: string, ps: ^Prefs_State) {
	flow: Flow
	flow_init(&flow, root, defs, state, r, ps)
	// Real (empty) presentation buffers, for the cases that draw a game
	// frame behind the menu.
	particles: render.Particles
	render.particles_init(&particles)
	defer render.particles_destroy(&particles)
	blurs: render.Blurs
	render.blurs_init(&blurs)
	defer render.blurs_destroy(&blurs)
	notices: render.Notices
	switch name {
	case "main":
		flow.mode = .Title
	case "level_select":
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		level_select_init(&flow.level_select)
	case "level_select_easy":
		// Outside classic mode, with the Easy Mode toggle on.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		ps.saved.mods = sim.mods_with_deps(ps.saved.mods + {int(easy_mode.ID)})
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		level_select_init(&flow.level_select)
	case "reward", "reward_2p":
		// Easy mode's reward screen (plugins/easy_mode/view), opened straight over
		// a level a couple of seconds in rather than played to its end. New
		// content: a visual check. Player 1 already holds the first level
		// of the first option, so its values read current -> next; in
		// reward_2p both players are on the first option, player 1 locked,
		// so the borders nest.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		ps.saved.mods = sim.mods_with_deps(ps.saved.mods + {int(easy_mode.ID)})
		two := name == "reward_2p"
		flow_start_session(&flow, 0x1234_5678, two ? .Co_Op : .Single, 0)
		for _ in 0 ..< 60 {
			_ = sim.session_step(state, {})
		}
		if !easy_mode.reward_begin(state, {}) {
			fmt.eprintln("reward: no options to offer")
			os.exit(1)
		}
		passives.levels_of(state, 0)[easy_mode.reward_of(state).options[0]] = 1
		if two {
			easy_mode.reward_of(state).cursor[1] = 0
			easy_mode.reward_of(state).locked[0] = true
		}
		flow.mode = .Playing
	case "loadout", "loadout_2p", "loadout_placed":
		// New Weapons' loadout screen (plugins/loadout/view), played until the
		// stage's title fades and the screen opens. New content: a visual
		// check.
		// - loadout: Level Select's stage 7, where the Chaingun unlocks. Five
		//   weapons for a loadout of three, so two wait in the new row; the
		//   cursor is on the Chaingun.
		// - loadout_2p: the same for two. Player 1 has picked up a new weapon
		//   and moved onto the loadout; player 2 is on READY, which is refused.
		// - loadout_placed: stage 2, with the Bacta Gun taken away first, so
		//   it comes back as new, straight into the free slot.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		prefs_mod_set(ps, new_weapons.ID, true)
		two := name == "loadout_2p"
		placed := name == "loadout_placed"
		flow_start_session(&flow, 0x1234_5678, two ? .Co_Op : .Single, placed ? 1 : 6)
		if placed {
			loadout.slots_of(state, 0).loadout[1] = sim.NO_WEAPON
		}
		for i := 0; i < 2000 && !loadout.loadout_open(state); i += 1 {
			_ = sim.session_step(state, {})
		}
		if !loadout.loadout_open(state) {
			fmt.eprintln("loadout: the screen never opened (is assets/extra there?)")
			os.exit(1)
		}
		if !placed {
			loadout.loadout_of(state).boards[0].col = 1
		}
		if two {
			b := &loadout.loadout_of(state).boards[0]
			b.holding, b.hold_row, b.hold_col = true, .Fresh, 0
			b.row, b.col = .Slots, 1
			loadout.loadout_of(state).boards[1].row = .Ready
		}
		flow.mode = .Playing
	case "chaingun", "chaingun_charge", "discharge", "discharge_charge":
		// A new weapon in play (docs/new-weapons.md) once its stage's
		// enemies are about: the Chaingun on stage 7, the Discharge Beam on
		// stage 10. In chaingun, the burst a moment after a press; in
		// chaingun_charge, the aimed volleys a moment after a charge is let
		// go. In discharge, a pulse as it fades; in discharge_charge, the
		// charged beam the step after it is let go. Player 1 is handed the
		// weapon and the loadout screen is skipped. New content: a visual
		// check.
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		prefs_mod_set(ps, new_weapons.ID, true)
		beam := strings.has_prefix(name, "discharge")
		flow_start_session(&flow, 0x1234_5678, .Single, beam ? 9 : 6)
		loadout.loadout_of(state).shown = sim.single(state, sim.Level_Info).played
		p := sim.player_at(state, 0)
		for &w, i in defs.weapons {
			if w.id == sim.res_id(beam ? "aidb" : "aicg") {
				loadout.slots_of(state, 0).loadout[0] = i32(i)
				weapon_system.change_weapon(state, p.weapons, sim.WEP_AIR, i32(i))
				player_system.player_sprite_from_weapon(state, p)
			}
		}
		// An idle ship is shot down about 220 steps in.
		warm, hold, after := 180, 4, 6
		switch name {
		case "chaingun_charge":
			warm, hold, after = 120, 70, 12
		case "discharge":
			warm, hold, after = 180, 1, 1
		case "discharge_charge":
			warm, hold, after = 120, 90, 1
		}
		for _ in 0 ..< warm {
			_ = sim.session_step(state, {})
		}
		// Taken now, so drawing the shot does not clear the effects below
		// as a new level's.
		flow_effects_sync(&flow, &particles, &blurs, &notices)
		for _ in 0 ..< hold {
			_ = sim.session_step(state, {{.Fire_Air}, {}})
			render.particles_step(&particles, state)
		}
		for _ in 0 ..< after {
			_ = sim.session_step(state, {})
			render.particles_step(&particles, state)
		}
		flow.mode = .Playing
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
		for i := 0; i < 2000 && (i < 300 || len(particles.live) == 0); i += 1 {
			_ = sim.session_step(state, {{.Fire_Air, .Fire_Ground}, {}})
			render.particles_step(&particles, state)
			render.blurs_step(&blurs, state)
		}
		fmt.eprintfln("before quitting: %d particles, %d ghosts", len(particles.live), len(blurs.live))
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
		high_scores_view_init(&flow.high_scores)
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
		score_entry_start(&flow.score_entry, {99999, 0}, {true, false}, "Lucena")
		flow.mode = .Score_Entry
		flow.score_entry.state = .Editing
	case "netplay_lobby":
		// New content, no original to compare against (see game/netplay.odin's
		// file header) -- this is a visual smoke check of the lobby's own
		// menu screens, not an oracle:menu-shot comparison. The cases below
		// cover Netplay_Phase's visually distinct states, plus (Phase 8
		// stage 2) the host's and guest's differing views of .Connected once
		// level select is in the mix; none open a real socket
		// (netplay_lobby_init's netplay_reset already zeroed nl.have_sock)
		// -- the fields netplay_lobby_draw actually reads are set directly
		// instead, since this only ever draws once and never polls.
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
	case "preferences_extras":
		// The Extras page with a colour and Self Outline on, so both
		// previews show what they do.
		flow.mode = .Preferences
		flow.preferences.page = .Extras
		// DR_SHOT_HUE picks the hue: 63 should match player 2's gold.
		ps.saved.settings[accent_view.HUE_P1] = 30
		if hue, ok := strconv.parse_int(os.get_env("DR_SHOT_HUE", context.temp_allocator)); ok {
			ps.saved.settings[accent_view.HUE_P1] = prefs.hue_wrap(hue)
		}
		ps.saved.settings[accent_view.SELF_OUTLINE] = 1
	case "preferences_mods":
		// The Mods page as a new player finds it.
		flow.mode = .Preferences
		flow.preferences.page = .Mods
	case "netplay_lobby_name":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.phase = .Enter_Name
		prefs.name_set(&flow.netplay.local_name, "Keristero")
		flow.netplay.local_hue = 30
	case "netplay_lobby_join":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.phase = .Enter_Address
		flow.netplay.addr_len = copy(flow.netplay.addr_buf[:], "127.0.0.1")
		flow.netplay.addr_default = true
	case "netplay_lobby_connecting":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connecting
	case "netplay_lobby_connected":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Guest
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 42 // sample value -- ping_ms is only ever set from a real Pong in netplay_tick_ping
		flow.netplay.remote_ready = true // local not ready yet, so the Ready button still draws beside the peer's READY
		prefs.name_set(&flow.netplay.local_name, "Keristero") // sample names, normally from each side's Hello
		prefs.name_set(&flow.netplay.peer_name, "Supercobra")
		flow.netplay.local_hue, flow.netplay.peer_hue = 30, 280
	case "netplay_lobby_connected_host":
		// Phase 8 stage 2: the host's own view -- level-select arrows above
		// an enabled Ready (highest_reached forced high enough that
		// level_index 0 reads as unlocked regardless of this machine's real
		// save file).
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 17
		flow.highest_reached = 12
	case "netplay_lobby_connected_host_locked":
		// Same, but level_index parked on a level past highest_reached --
		// "NO ACCESS" in red, Ready greyed out, matching Level Select's own
		// locked-slot language (game/menu_level_select.odin).
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 17
		flow.highest_reached = 1
		flow.netplay.level_index = 3
	case "diagnostics":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Guest
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 42
	case:
		fmt.eprintfln("unknown menu %v (see run_menu_shot)", name)
		os.exit(1)
	}
	// game/diagnostics.odin's overlay: this menu name doubles as its visual
	// smoke check (there's no baseline to compare against, just a look --
	// same idea as netplay_lobby_connected above). Piggybacks on the
	// connected-lobby screen since that's the one case with a ping to show;
	// run_menu_shot draws one static frame, so the numbers are hand-set, not
	// measured by diagnostics_tick.
	diag: Diagnostics
	if name == "diagnostics" {
		diag.enabled = true
		diag.updates_per_sec = 30.0
		diag.rollbacks_per_sec = 1.2
		flow.netplay_active = true
	}
	// Drawn into a render texture rather than read back from the window,
	// which is hidden (main) -- a hidden window's back buffer is not
	// guaranteed to hold anything. r.canvas lets build_frame's terrain
	// drawing return to it (resume_canvas); renderer_destroy unloads it.
	r.canvas = rl.LoadRenderTexture(render.SCREEN_W * render.WINDOW_SCALE, render.SCREEN_H * render.WINDOW_SCALE)
	rl.BeginTextureMode(r.canvas)
	rl.ClearBackground(rl.Color{0, 0, 0, 255})
	flow_draw(&flow, r, &particles, &blurs, &notices, render.WINDOW_SCALE)
	diagnostics_draw(&diag, flow.netplay_active, flow.netplay.ping_ms)
	if name == "restarted" {
		fmt.eprintfln("new game drawn with: %d particles, %d ghosts", len(particles.live), len(blurs.live))
	}
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(r.canvas.texture)
	rl.ImageFlipVertical(&img) // render textures are bottom-up
	// Blending leaves the texture's alpha below 255 wherever something
	// translucent was drawn; its colour is already composited, so drop it.
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
	out := fmt.ctprintf("%s.png", path)
	rl.ExportImage(img, out)
	rl.UnloadImage(img)
	fmt.printfln("wrote %s", out)
}

// Steps the simulation, capturing the frame at each requested step.
run_shots :: proc(r: ^render.Renderer, s: ^sim.State, particles: ^render.Particles, blurs: ^render.Blurs, notices: ^render.Notices, film: ^sim.Film, path, at: string) {
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
			render.build_frame(r, s, blurs, notices)
			if r.find_hits > 0 {
				found += 1
				if found <= 20 {
					fmt.printfln("step %v: %v match(es)", i, r.find_hits)
				}
			}
			sim.step(s, {}, film)
			render.particles_step(particles, s)
			render.blurs_step(blurs, s)
			render.notices_step(notices, s)
			continue
		}
		r.dump = dump && next < len(steps) && steps[next] == i
		if r.dump {
			fmt.printfln("step %v draw list:", i)
		}
		render.build_frame(r, s, blurs, notices)
		// Only a frame that is saved is presented: EndDrawing waits for
		// vsync, which made a shot a few thousand steps in take minutes.
		// Twice, so both swap buffers hold it -- the read-back below reads
		// whichever one the swap left, and a skipped frame leaves it stale.
		if next < len(steps) && steps[next] == i {
			for _ in 0 ..< 2 {
				rl.BeginDrawing()
				rl.ClearBackground(rl.Color{0, 0, 0, 255})
				render.present(r, s, particles, render.WINDOW_SCALE)
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
		render.particles_step(particles, s)
		render.blurs_step(blurs, s)
		render.notices_step(notices, s)
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
