package game

// Stage 6: title, attract demos, level transitions, game over, pause -- the
// state machine around a session, not the session itself. Everything here is
// presentation: DR_FILM and DR_SHOT (main.odin) bypass it completely and step
// sim.State directly, exactly as before, so oracle:diff and the screenshot
// tooling never go through Flow at all.

import "core:fmt"
import "core:os"
import "core:time"

import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

Flow_Mode :: enum {
	Title,
	Level_Select,
	Credits,
	Playing,
	Paused,
	Game_Over,
	Complete,
	Attract,
}

DEMO_COUNT :: 4 // assets/films/de01.film .. de04.film

// How long the Game_Over/Complete screen holds before returning to Title, in
// steps. Borrows Game_GameOverNoticeDuration (perm float 0xd, 110 steps):
// FUN_00420280 only ever reads that value through DAT_004e4824
// (G_Game_IsPlaying), whose one caller (G_Interface_PauseGame) makes it
// presentation-only. There is no simulated behaviour to match, just the
// original's own pacing reused for the same purpose here.
END_SCREEN_STEPS :: 110

Flow :: struct {
	mode:       Flow_Mode,
	quit:       bool, // Escape at the title screen; see main.odin's SetExitKey(.KEY_NULL)
	root:       string,
	defs:       ^sim.Defs,
	state:      ^sim.State,
	demo_index: int,       // which of de01..de04 is playing, only set in .Attract
	film:       data.Film, // owns film.frames; film_destroy before loading another
	has_film:   bool,
	sim_film:   sim.Film,     // aliases film.frames; what sim.step actually reads
	end_timer:  i32,          // steps spent on the current Game_Over/Complete screen
	last_level: sim.Level_ID, // the level music_track was last started for
	main_menu:  Main_Menu,    // Phase 7: the faithfully-recreated title screen

	// Phase 7 stage 2: Level Select. pending_game_type is stashed by
	// menu_main.odin's One_Player/Two_Player when it hands off to
	// .Level_Select (Level Select itself, per G_LevelSelect_GetStartingLevelID
	// -FromUser, is player-count-agnostic -- the count is only needed again
	// once a level is actually chosen). session_start_pos is the 1-based level
	// list position the *current* session started at (set by
	// flow_start_session), and highest_reached is the highest 1-based
	// position unlocked so far -- global, not per sim.Game_Type (confirmed
	// against FUN_00426d80.c's post-session U_Prefs_SetInt(3, ...) call, which
	// loops both player slots regardless of Game_Type). Persisted across runs
	// via progress_load/progress_save (game/progress.odin), the reimplementation's
	// stand-in for the original's U_Prefs slot 3 (Win32 registry-backed).
	pending_game_type: sim.Game_Type,
	session_start_pos: int,
	highest_reached:   int,
	level_select:      Level_Select,

	// Phase 7 stage 3: Credits (game/menu_credits.odin), reached from Main
	// Menu's copyright link.
	credits: Credits,
}

flow_init :: proc(fl: ^Flow, root: string, defs: ^sim.Defs, state: ^sim.State, r: ^Renderer) {
	fl.root = root
	fl.defs = defs
	fl.state = state
	fl.mode = .Title
	fl.highest_reached = progress_load()
	main_menu_init(&fl.main_menu, &r.textures)
}

flow_destroy :: proc(fl: ^Flow) {
	if fl.has_film {
		data.film_destroy(&fl.film)
		fl.has_film = false
	}
}

// Once per render frame, ahead of the fixed-step loop below: discrete key
// presses only. flow_step (which runs 0-4 times per frame, MAX_STEPS_PER_FRAME)
// never reads input, so a slow frame catching up on several steps can't fire
// the same transition twice.
flow_handle_input :: proc(fl: ^Flow, r: ^Renderer) {
	switch fl.mode {
	case .Title:
		// Mouse-driven, like the original's own button list -- see
		// main_menu_update (game/menu_main.odin).
		main_menu_update(fl, r, &fl.main_menu)
	case .Level_Select:
		level_select_update(fl, r, &fl.level_select)
	case .Credits:
		credits_update(fl, r, &fl.credits)
	case .Playing:
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.P) {
			fl.mode = .Paused
			flow_set_music_paused(fl, r, true)
		}
	case .Paused:
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.P) {
			fl.mode = .Playing
			flow_set_music_paused(fl, r, false)
		}
	case .Attract:
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) {
			fl.mode = .Title
		}
	case .Game_Over, .Complete:
		if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) {
			fl.mode = .Title
		}
	}
}

@(private = "file")
flow_set_music_paused :: proc(fl: ^Flow, r: ^Renderer, paused: bool) {
	if fl.state.level == nil {
		return
	}
	music, ok := music_track(&r.textures, fl.state.level.id)
	if !ok {
		return
	}
	if paused {
		rl.PauseMusicStream(music)
	} else {
		rl.ResumeMusicStream(music)
	}
}

// Inside the fixed-step accumulator loop: steps the simulation when the mode
// calls for it, and reacts to what that step produced.
//
// game_over is checked ahead of level_end.complete because FUN_00420280 sets
// it the instant the last player leaves play, independent of whether the
// level has finished scrolling -- level_end_step only learns about it once
// the background does report scroll-complete, and then just short-circuits
// straight to `complete` with no tally to show (level_end.odin: "if
// s.game_over { l.started = true; return }"). Reacting to game_over directly
// means the game-over screen appears the moment play actually ends, rather
// than only after (and if) the level happens to finish scrolling.
flow_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices) {
	switch fl.mode {
	case .Title, .Level_Select, .Credits, .Paused:
	// nothing to step
	case .Playing:
		flow_sim_step(fl, r, particles, blurs, notices, gather_input(), nil)
		if fl.state.game_over {
			fl.mode, fl.end_timer = .Game_Over, 0
		} else if fl.state.level_end.complete {
			if sim.level_advance(fl.state) {
				// G_LevelSelect only ever raises U_Prefs slot 3 (highest
				// reached) for a session that started at level 1 -- jumping
				// into the middle via Level Select never advances it, even
				// past the levels played along the way.
				if fl.session_start_pos == 1 && int(fl.state.level_number) > fl.highest_reached {
					fl.highest_reached = int(fl.state.level_number)
					progress_save(fl.highest_reached)
				}
			} else {
				fl.mode, fl.end_timer = .Complete, 0
			}
		}
	case .Attract:
		flow_sim_step(fl, r, particles, blurs, notices, {}, &fl.sim_film)
		if fl.state.game_over || fl.state.level_end.complete || sim.film_finished(fl.state, &fl.sim_film) {
			flow_load_demo(fl, (fl.demo_index + 1) % DEMO_COUNT)
		}
	case .Game_Over, .Complete:
		fl.end_timer += 1
		if fl.end_timer > END_SCREEN_STEPS {
			fl.mode = .Title
		}
	}
	flow_sync_music(fl, r)
}

// A session start, level_advance or demo load can all change fl.state.level;
// rather than call rl.PlayMusicStream at each of those sites, just notice the
// level id changing here and (re)start whatever track it names. A no-op
// every other step, since the id then stays the same until the next change.
@(private = "file")
flow_sync_music :: proc(fl: ^Flow, r: ^Renderer) {
	if fl.state.level == nil || fl.state.level.id == fl.last_level {
		return
	}
	fl.last_level = fl.state.level.id
	if music, ok := music_track(&r.textures, fl.state.level.id); ok {
		rl.PlayMusicStream(music)
	}
}

@(private = "file")
flow_sim_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, input: sim.Frame_Input, film: ^sim.Film) {
	sim.step(fl.state, input, film)
	particles_step(particles, fl.state)
	blurs_step(blurs, fl.state)
	notices_step(notices, fl.state)
	sounds_step(&r.textures, fl.state)
}

// Called from the main menu's 1 Player/2 Player buttons (game/menu_main.odin).
flow_random_seed :: proc() -> u32 {
	return u32(time.to_unix_nanoseconds(time.now()))
}

// Called once Level Select's accept pulse finishes (game/menu_level_select.odin).
// `level_index` is 0-based into fl.defs.levels (play order), matching
// Level_Select.center.
flow_start_session :: proc(fl: ^Flow, seed: u32, game_type: sim.Game_Type, level_index: int) {
	fl.session_start_pos = level_index + 1
	level := fl.defs.levels[level_index].id
	sim.init(fl.state, sim.Session{seed = seed, level_id = level, game_type = game_type}, fl.defs)
	fl.mode = .Playing
}

// Loads assets/films/de<index+1>.film and starts replaying it. Attract mode
// cycles through all four in list order and wraps back to the first rather
// than stopping after one lap ("Clicking DEMOS again plays the next film",
// phase-4-sim.md) -- nothing in the original bounds how long the attract
// loop is left running.
// Called from the main menu's Play Demo button (game/menu_main.odin) and
// Attract's own advance-to-next-demo.
flow_load_demo :: proc(fl: ^Flow, index: int) -> bool {
	path := fmt.tprintf("%s/films/de%02d.film", fl.root, index + 1)
	bytes, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		fl.mode = .Title
		return false
	}
	f, err := data.film_parse(bytes)
	if err != .None {
		fl.mode = .Title
		return false
	}
	if fl.has_film {
		data.film_destroy(&fl.film)
	}
	fl.film = f
	fl.has_film = true
	fl.sim_film = data.film_to_sim(fl.film)
	sim.init(fl.state, fl.sim_film.session, fl.defs)
	fl.demo_index = index
	fl.mode = .Attract
	return true
}

// Once per render frame, after the fixed-step loop: builds and presents the
// current game frame (skipped at Title, which has no session yet -- state is
// zeroed, and build_frame dereferences state.level), then layers on whatever
// text the mode calls for. draw_text needs a built frame's layer/scale
// pipeline to draw into, which Title doesn't have, so these overlays go
// through raylib's own font directly instead -- the same shortcut
// draw_debug already takes for its dev overlay.
flow_draw :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, scale: f32) {
	switch fl.mode {
	case .Title:
		main_menu_draw(r, &fl.main_menu)
		return
	case .Level_Select:
		level_select_draw(r, fl, &fl.level_select)
		return
	case .Credits:
		credits_draw(r, &fl.credits)
		return
	case .Playing, .Paused, .Game_Over, .Complete, .Attract:
	}
	build_frame(r, fl.state, blurs, notices)
	present(r, fl.state, particles, scale)
	switch fl.mode {
	case .Paused:
		// G_Interface_PauseGame (read in full) draws no on-screen text at
		// all -- stop sound, pause music, darken the borders, idle. D21:
		// matched exactly rather than adding a label the original never had.
		draw_paused_borders()
	case .Game_Over:
		draw_banner("GAME OVER", "")
	case .Complete:
		draw_banner("ALL LEVELS COMPLETE", "")
	case .Attract:
		rl.DrawText("DEMO -- press any key for the title screen",
			16, SCREEN_H * WINDOW_SCALE - 28, 18, rl.Color{200, 200, 200, 200})
	case .Title, .Level_Select, .Credits, .Playing:
	}
}

// U_Display::DrawBlackBorders (read in full) blacks out two perm-float-sized
// strips rather than the whole screen; the exact rects depend on perm floats
// 0x34/0x35/0x3b whose border-specific semantics weren't pinned down here.
// Approximated as a full-screen dim, which gives the same "the game froze
// and darkened" read without claiming pixel-exact border geometry -- refine
// if a live screenshot comparison calls for it.
@(private = "file")
draw_paused_borders :: proc() {
	rl.DrawRectangle(0, 0, SCREEN_W * WINDOW_SCALE, SCREEN_H * WINDOW_SCALE, rl.Color{0, 0, 0, 120})
}

@(private = "file")
draw_banner :: proc(line, sub: cstring) {
	tw := rl.MeasureText(line, 40)
	cx := i32(SCREEN_W * WINDOW_SCALE / 2)
	cy := i32(SCREEN_H * WINDOW_SCALE / 2)
	rl.DrawRectangle(0, cy - 50, SCREEN_W * WINDOW_SCALE, 100, rl.Color{0, 0, 0, 160})
	rl.DrawText(line, cx - tw / 2, cy - 30, 40, rl.Color{255, 255, 255, 255})
	if sub != "" {
		sw := rl.MeasureText(sub, 18)
		rl.DrawText(sub, cx - sw / 2, cy + 16, 18, rl.Color{200, 200, 200, 255})
	}
}
