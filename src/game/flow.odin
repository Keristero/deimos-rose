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
import "dr:prefs"
import "dr:sim"

Flow_Mode :: enum {
	Title,
	Level_Select,
	Credits,
	High_Scores,
	Score_Entry,
	Preferences,
	Netplay_Lobby,
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
	music_key:  sim.Res_ID,   // what flow_music_update last started: a level id, or MENU_MUSIC_KEY
	music:      rl.Music,     // the stream it started (zero if none)
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

	// Phase 7 stage 4: the High Scores viewer (game/menu_high_scores.odin,
	// reached from Main Menu's button) and the post-game name-entry prompt
	// (game/menu_high_score_entry.odin, reached automatically from Game
	// Over/Complete when a player's score qualifies -- see
	// flow_finish_session).
	high_scores: High_Scores,
	score_entry: Score_Entry,

	// Phase 7 stage 6 / Phase 6 stage 5: the netplay lobby
	// (game/netplay.odin, reached from Main Menu's Netplay item when
	// !r.classic -- see menu_main.odin and mise.toml's --classic flag).
	// netplay_active distinguishes a netplay .Playing session (stepped via
	// netplay_playing_step, net.Rollback_Session-driven) from the ordinary
	// local one (flow_sim_step, gather_input()) -- both share every other
	// Flow_Mode.
	netplay:        Netplay,
	netplay_active: bool,
	// The names both players entered in the netplay lobby, by player slot.
	// While session_named, the end of the session records their scores
	// under these names instead of asking (flow_finish_session). Kept here,
	// not in Netplay, because leaving a session resets Netplay before it
	// finishes, and "continue alone" keeps the session going without it.
	session_names: [sim.MAX_PLAYERS]prefs.Name,
	session_named: bool,
	// Each player's accent hue from the lobby, drawn while session_named
	// (build_frame's accents, set in flow_draw).
	session_hues: [sim.MAX_PLAYERS]int,

	// Saved preferences plus this run's launch flags (game/prefs.odin),
	// owned by main.odin; the Preferences screen edits them in place.
	prefs:       ^Prefs_State,
	preferences: Preferences,

	pause_menu:   Pause_Menu,
	music_paused: bool, // whether flow_music_update last left fl.music paused
}

// Resume / Main Menu, shown while paused -- new content: the original's
// G_Interface_PauseGame draws no text at all (D21), so classic mode keeps
// that and shows neither. The same menu serves a netplay pause, which is a
// state inside the simulation both peers share (sim.session_step), not
// .Paused.
Pause_Menu :: struct {
	resume:    Text_Button,
	main_menu: Text_Button,
}

@(private = "file") PAUSE_TITLE_Y :: 200
@(private = "file") PAUSE_RESUME_Y :: 232
@(private = "file") PAUSE_MAIN_MENU_Y :: 262

// Returns which button was clicked this frame, if any.
@(private = "file")
pause_menu_update :: proc(r: ^Renderer, m: ^Pause_Menu) -> (resume, main_menu: bool) {
	if m.resume.rect.width == 0 {
		m.resume = text_button_at(r, "RESUME", PAUSE_RESUME_Y)
		m.main_menu = text_button_at(r, "MAIN MENU", PAUSE_MAIN_MENU_Y)
	}
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	resume = text_button_update(r, &m.resume, mouse, dt)
	main_menu = text_button_update(r, &m.main_menu, mouse, dt)
	return
}

@(private = "file")
pause_menu_draw :: proc(r: ^Renderer, m: ^Pause_Menu, note: string) {
	if m.resume.rect.width == 0 {
		return // not built until the first update
	}
	rl.DrawRectangle(0, (PAUSE_TITLE_Y - 14) * WINDOW_SCALE, SCREEN_W * WINDOW_SCALE, 116 * WINDOW_SCALE, rl.Color{0, 0, 0, 170})
	menu_draw_text(r, "PAUSED", SCREEN_W / 2, PAUSE_TITLE_Y, rl.Color{255, 255, 255, 255}, .Centre)
	text_button_draw(r, &m.resume)
	text_button_draw(r, &m.main_menu)
	if note != "" {
		menu_draw_text(r, note, SCREEN_W / 2, PAUSE_MAIN_MENU_Y + 30, rl.Color{190, 190, 190, 255}, .Centre)
	}
}

// Escape always pauses (it cannot be bound); so does each player's own
// Pause binding (Preferences; P for player 1 by default). Player 2's only
// counts while they are in the game -- a local 2 Player session. Netplay's
// held Pause bit comes from gather_input's bindings plus Escape
// (netplay_playing_step).
@(private = "file")
pause_key_pressed :: proc(fl: ^Flow) -> bool {
	if rl.IsKeyPressed(.ESCAPE) || binding_pressed(&fl.prefs.saved.bindings[0], .Pause) {
		return true
	}
	return fl.state.players[1].active && binding_pressed(&fl.prefs.saved.bindings[1], .Pause)
}

flow_init :: proc(fl: ^Flow, root: string, defs: ^sim.Defs, state: ^sim.State, r: ^Renderer, ps: ^Prefs_State) {
	fl.root = root
	fl.prefs = ps
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
	netplay_reset(&fl.netplay) // no-op if no socket was ever opened
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
	case .High_Scores:
		high_scores_view_update(fl, r, &fl.high_scores)
	case .Score_Entry:
		score_entry_update(fl, r, &fl.score_entry)
	case .Preferences:
		preferences_update(fl, r, &fl.preferences)
	case .Netplay_Lobby:
		netplay_lobby_update(fl, r, &fl.netplay)
	case .Playing:
		if fl.netplay_active {
			netplay_playing_poll(fl, r, &fl.netplay)
			// Escape/P pause through the simulation itself: netplay_
			// playing_step turns them into the Pause input bit, so both
			// peers pause on the same frame. The menu below appears once
			// the (shared) state says paused, whoever pressed it.
			if fl.state.paused {
				resume, leave := pause_menu_update(r, &fl.pause_menu)
				if resume {
					fl.netplay.pause_pulse = NETPLAY_PAUSE_PULSE_TICKS
				} else if leave {
					// The peer sees a Goodbye and freezes, able to continue
					// alone (F5) -- the same as any mid-game disconnect.
					netplay_disconnect(&fl.netplay)
					flow_finish_session(fl)
				}
			} else if fl.netplay.link_state != .Live && rl.IsKeyPressed(.ESCAPE) {
				// Frozen on a lost peer (the banner's "ESC TO EXIT"). The
				// sim is not stepping, so Escape cannot reach it as a
				// Pause bit -- it leaves instead, as it always did here.
				netplay_disconnect(&fl.netplay)
				flow_finish_session(fl)
			} else if fl.netplay.link_state != .Live && rl.IsKeyPressed(.F5) {
				// Phase 8 stage 3: "F5 to continue alone"
				// (notes/netcode-enhancements.md), only while frozen waiting
				// on a peer. Dropping netplay_active is the entire change
				// needed -- flow_step's non-netplay branch below fills
				// player 1's input from this machine's player 2 keys, so the
				// vacated player sits idle rather than vanishing (or is
				// flown locally, if someone here takes those keys).
				netplay_reset(&fl.netplay)
				fl.netplay_active = false
			}
		} else if pause_key_pressed(fl) {
			fl.mode = .Paused
		}
	case .Paused:
		resume, leave := false, false
		if !r.classic {
			resume, leave = pause_menu_update(r, &fl.pause_menu)
		}
		if resume || pause_key_pressed(fl) {
			fl.mode = .Playing
		} else if leave {
			// Through the usual end of a session, so a score good enough
			// for the table still gets its name entered.
			flow_finish_session(fl)
		}
	case .Attract:
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) {
			fl.mode = .Title
		}
	case .Game_Over, .Complete:
		if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) {
			flow_finish_session(fl)
		}
	}
}

// Ends a Game Over/Complete screen, whether by the player skipping ahead
// (flow_handle_input above) or the hold timer running out (flow_step below).
// G_Scores_IsAHighScore/G_Scores_GetPlayerNamesAndDisplay (see
// game/highscores.odin, game/menu_high_score_entry.odin) run at exactly this
// point in the original -- FUN_00426d80.c (read in full): once the
// post-session fade-back-to-menu finishes, it checks every active player's
// G_Res_GetPermScore result against G_Scores_IsAHighScore and, if any
// qualifies, opens the name-entry screen before finally returning to the
// menu.
@(private = "file")
flow_finish_session :: proc(fl: ^Flow) {
	if fl.netplay_active {
		// A netplay match ending normally (not a mid-game disconnect, which
		// netplay_poll's Goodbye handling already clears this on) -- close
		// the socket so a later single-player session doesn't find
		// netplay_active still set and try to step through a dead one.
		netplay_reset(&fl.netplay)
		fl.netplay_active = false
	}
	scores := [sim.MAX_PLAYERS]int{}
	active := [sim.MAX_PLAYERS]bool{}
	sector := ""
	// Who took part, not who is still `active`: a player out of lives is
	// no longer active, and game_over is only set once neither is, so
	// reading `active` here skipped every score after a Game Over. The
	// original reports both slots from G_Game_Play (0x41e690) whatever
	// their state, an unused one with its score of 0.
	for i in 0 ..< sim.MAX_PLAYERS {
		scores[i] = int(fl.state.players[i].score)
		active[i] = fl.state.session.game_type != .Single || i == 0
	}
	if fl.state.level != nil {
		sector = fl.state.level.identifier
	}
	if fl.session_named {
		// Netplay: both names are already known, so there is nothing to
		// type -- each qualifying score goes straight into the table, which
		// is then shown.
		fl.session_named = false
		if high_scores_record(scores, active, fl.session_names, sector) {
			high_scores_view_init(&fl.high_scores)
			fl.mode = .High_Scores
		} else {
			fl.mode = .Title
		}
		return
	}
	if score_entry_start(&fl.score_entry, scores, active, sector) {
		fl.mode = .Score_Entry
	} else {
		fl.mode = .Title
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
	case .Title, .Level_Select, .Credits, .High_Scores, .Score_Entry, .Preferences, .Netplay_Lobby, .Paused:
	// nothing to step
	case .Playing:
		if fl.netplay_active {
			// Phase 8 stage 3: frozen (Waiting_Reconnect/Resync_Sending)
			// means don't step -- matches .Paused above, which also still
			// draws the last frame without advancing it.
			if fl.netplay.link_state == .Live {
				netplay_playing_step(fl, r, particles, blurs, notices, &fl.netplay)
			}
		} else {
			// Player 2 is only in play in a local 2 Player session
			// (player_setup: `game_type != .Single || number == 0`), and
			// had no keys at all until Preferences gave them bindings.
			input := sim.Frame_Input{gather_input(&fl.prefs.saved.bindings[0]), {}}
			if fl.state.players[1].active {
				input[1] = gather_input(&fl.prefs.saved.bindings[1])
			}
			// A local session pauses through flow (.Paused, the original's
			// kind of pause), never the sim's netplay pause.
			input[0] -= {.Pause}
			input[1] -= {.Pause}
			flow_sim_step(fl, r, particles, blurs, notices, input, nil, true)
		}
		// The step itself moved to the next level if there was one
		// (sim.session_step), so complete still being set means the list
		// is finished. Flow only reads the state here, never changes it:
		// in netplay, the state is the rollback session's to change.
		switch {
		case fl.state.game_over:
			fl.mode, fl.end_timer = .Game_Over, 0
		case fl.state.level_end.complete:
			fl.mode, fl.end_timer = .Complete, 0
		}
		// G_LevelSelect only ever raises U_Prefs slot 3 (highest reached)
		// for a session that started at level 1 -- jumping into the middle
		// via Level Select never advances it, even past the levels played
		// along the way.
		if fl.session_start_pos == 1 && int(fl.state.level_number) > fl.highest_reached {
			fl.highest_reached = int(fl.state.level_number)
			progress_save(fl.highest_reached)
		}
	case .Attract:
		// Plain sim.step: a demo that finishes its level moves on to the
		// next demo (below), not to the next level.
		flow_sim_step(fl, r, particles, blurs, notices, {}, &fl.sim_film, false)
		if fl.state.game_over || fl.state.level_end.complete || sim.film_finished(fl.state, &fl.sim_film) {
			flow_load_demo(fl, (fl.demo_index + 1) % DEMO_COUNT)
		}
	case .Game_Over, .Complete:
		fl.end_timer += 1
		if fl.end_timer > END_SCREEN_STEPS {
			flow_finish_session(fl)
		}
	}
}

@(private = "file")
MENU_MUSIC_KEY :: sim.Res_ID{'i', 'n', 'm', 'u'}

// Once per render frame (main.odin): menus play the interface music loop,
// a session (or demo) its level's track. A session start, level_advance or
// demo load can all change the level, and any menu can hand over to a
// session, so rather than start music at each of those sites this notices
// what *should* be playing change and restarts from the top -- stopping the
// old stream first, so a level's track no longer carries on under the title
// screen after a game.
flow_music_update :: proc(fl: ^Flow, r: ^Renderer) {
	key: sim.Res_ID
	want: rl.Music
	ok: bool
	switch fl.mode {
	case .Title, .Level_Select, .Credits, .High_Scores, .Score_Entry, .Preferences, .Netplay_Lobby:
		key = MENU_MUSIC_KEY
		want, ok = music_load(&r.textures, MENU_MUSIC)
	case .Playing, .Paused, .Game_Over, .Complete, .Attract:
		if fl.state.level != nil {
			key = fl.state.level.id
			want, ok = music_track(&r.textures, key)
		}
	}
	if key != fl.music_key {
		if fl.music.frameCount != 0 {
			rl.StopMusicStream(fl.music)
		}
		fl.music_key, fl.music = key, {}
		if ok {
			fl.music = want
			rl.PlayMusicStream(want)
		}
	}
	if fl.music.frameCount != 0 {
		// Either pause: local (.Paused) or a netplay pause in the state.
		paused := fl.mode == .Paused || (fl.mode == .Playing && fl.state.paused)
		if paused != fl.music_paused {
			if paused {
				rl.PauseMusicStream(fl.music)
			} else {
				rl.ResumeMusicStream(fl.music)
			}
		}
		rl.UpdateMusicStream(fl.music)
	}
	fl.music_paused = fl.music.frameCount != 0 && (fl.mode == .Paused || (fl.mode == .Playing && fl.state.paused))
}

@(private = "file")
flow_sim_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, input: sim.Frame_Input, film: ^sim.Film, session: bool) {
	if session {
		_ = sim.session_step(fl.state, input, film)
	} else {
		sim.step(fl.state, input, film)
	}
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
	fl.session_named = false // a local game asks for names at the end
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
	case .High_Scores:
		high_scores_view_draw(r, &fl.high_scores)
		return
	case .Score_Entry:
		score_entry_draw(r, &fl.score_entry)
		return
	case .Preferences:
		preferences_draw(r, &fl.preferences, fl.prefs)
		return
	case .Netplay_Lobby:
		netplay_lobby_draw(fl, r, &fl.netplay)
		return
	case .Playing, .Paused, .Game_Over, .Complete, .Attract:
	}
	flow_set_accents(fl, r)
	build_frame(r, fl.state, blurs, notices)
	present(r, fl.state, particles, scale)
	switch fl.mode {
	case .Paused:
		// G_Interface_PauseGame (read in full) draws no on-screen text at
		// all -- stop sound, pause music, darken the borders, idle. D21:
		// classic mode matches that exactly; otherwise the pause menu sits
		// on top, since without it there was no way back to the title.
		draw_paused_borders()
		if !r.classic {
			pause_menu_draw(r, &fl.pause_menu, "")
		}
	case .Game_Over:
		draw_banner("GAME OVER", "")
	case .Complete:
		draw_banner("ALL LEVELS COMPLETE", "")
	case .Attract:
		rl.DrawText("DEMO -- press any key for the title screen",
			16, SCREEN_H * WINDOW_SCALE - 28, 18, rl.Color{200, 200, 200, 200})
	case .Playing:
		// Phase 8 stage 3: frozen waiting on a peer -- title == "" (link_state
		// == .Live) draws nothing, the ordinary case for every prior netplay
		// session.
		if fl.netplay_active {
			if title, sub := netplay_disconnect_banner(&fl.netplay); title != "" {
				draw_banner(title, sub)
			} else if fl.state.paused {
				draw_paused_borders()
				pause_menu_draw(r, &fl.pause_menu, "PAUSED FOR BOTH PLAYERS -- EITHER CAN RESUME")
			}
		}
	case .Title, .Level_Select, .Credits, .High_Scores, .Score_Entry, .Preferences, .Netplay_Lobby:
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

// Who is drawn with an accent this frame (Extras; nothing in classic mode or
// a demo). In netplay both players have one, each the colour its owner
// picked, and the other player's crosshair is left out: it only helps
// whoever is aiming with it. Otherwise it is this machine's colour on
// player 1, the only player whose colour we know. Self Outline only ever
// rings the ship of the player at this machine.
@(private = "file")
flow_set_accents :: proc(fl: ^Flow, r: ^Renderer) {
	r.accents = {}
	if fl.mode == .Attract || !extra_on(fl.prefs, .Accent_Hue) {
		return
	}
	outline := extra_on(fl.prefs, .Self_Outline)
	if fl.session_named {
		local := fl.netplay_active ? fl.netplay.rs.local_player : -1
		for i in 0 ..< sim.MAX_PLAYERS {
			r.accents[i] = {
				on             = true,
				hue            = f32(fl.session_hues[i]),
				outline        = outline && i == local,
				hide_crosshair = fl.netplay_active && i != local,
			}
		}
		return
	}
	r.accents[0] = {on = true, hue = f32(extra_value(fl.prefs, .Accent_Hue)), outline = outline}
}
