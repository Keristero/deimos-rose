package game

// Stage 6: title, attract demos, level transitions, game over, pause -- the
// state machine around a session, not the session itself. Everything here is
// presentation: DR_FILM and DR_SHOT (main.odin) bypass it completely and step
// sim.State directly, exactly as before, so oracle:diff and the screenshot
// tooling never go through Flow at all.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

import "dr:data"
import "dr:net"
import "dr:prefs"
import "dr:plugins/easy_mode"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/new_weapons"
import "dr:plugins/accent"
import accent_view "dr:plugins/accent/view"
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
	extra_content: bool, // defs carries the new weapons (assets/extra)
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

	pause_menu:         Pause_Menu,
	// levels_played for the level the particles, ghosts and notices on
	// screen belong to; 0 once a new session starts (see flow_effects_sync).
	effects_level:      i32,
	netplay_was_paused: bool, // the shared pause as last seen, to notice it starting
	music_paused: bool, // whether flow_music_update last left fl.music paused
}

// The original's pause (G_GameInterface::Process_StartFrame 0x4230f0,
// CheckForPause, G_Interface_PauseGame 0x426510): Caps Lock requests a
// notice of game string 0, "Press Caps Lock", in text preset 0x31 ("gano")
// with its alignment forced to CEGA (the template at 0x4e5359, for the game
// screen's update flag 1), no delay and no fade-in. At the end of that frame
// PauseGame stops every sound, plays perm sound 8 at volume 100, pauses the
// music and idles, redrawing the frozen frame -- notice and all -- until
// Caps Lock is pressed again. It draws nothing else and darkens nothing
// (DrawBlackBorders repaints the margins, which are black already).
// Resuming plays no sound; the notice is released and fades by perm float
// 0x49 (4/32) a step.
//
// The notice's sound slot in the template is id 0 with zero pitch and
// volume: G_Notice_Process "plays" it on the first step after resuming, but
// both of U_Sound_Play's RNG calls have equal bounds and draw nothing, and
// no resource 0 exists, so there is nothing to port.
//
// The port's key is the Pause binding, Escape by default: raylib cannot
// read Caps Lock as a key (see prefs.Action).
//
// Outside classic mode a MAIN MENU button sits under the notice (new
// content). A netplay pause is a state inside the simulation both peers
// share (sim.session_step), not .Paused, but looks the same.
Pause_Menu :: struct {
	main_menu: Text_Button,
	notice:    bool, // the notice is up, or still fading after a resume
	blend:     i32, // the notice's blend, 0 opaque .. 32 gone
}

@(private = "file") PAUSE_MAIN_MENU_Y :: 262
@(private = "file") PS_PAUSE :: 8 // perm sound "incl"
@(private = "file") PF_NOTICE_FADE_OUT :: 0x49
@(private = "file") GS_PRESS_CAPS_LOCK :: 0

// Whether the pause menu's button was clicked this frame.
@(private = "file")
pause_menu_update :: proc(r: ^Renderer, m: ^Pause_Menu) -> (main_menu: bool) {
	if m.main_menu.rect.width == 0 {
		m.main_menu = text_button_at_x(r, "MAIN MENU", VIEW_X + PLAY_W / 2, PAUSE_MAIN_MENU_Y)
	}
	return text_button_update(r, &m.main_menu, menu_mouse_pos(), rl.GetFrameTime())
}

// What G_Interface_PauseGame does on the way in, and the notice going up.
@(private = "file")
pause_begin :: proc(fl: ^Flow, r: ^Renderer) {
	for _, &clip in r.textures.sounds {
		for v in clip.voices {
			rl.StopSound(v)
		}
	}
	menu_play_sound(r, fl.defs.perm_sounds[PS_PAUSE])
	fl.pause_menu.notice, fl.pause_menu.blend = true, 0
}

// One sim step of the notice fading once play has resumed.
@(private = "file")
pause_notice_step :: proc(fl: ^Flow) {
	m := &fl.pause_menu
	if m.notice && !netplay_plugin.paused(fl.state) {
		m.blend += max(sim.trunc_i32(fl.defs.perm_floats[PF_NOTICE_FADE_OUT]), 1)
		if m.blend >= 32 {
			m.notice = false
		}
	}
}

// The original's "Press Caps Lock" (game string 0) while Caps Lock is the
// key; otherwise the same words for the key bound, cased like the
// original's ("Press Escape").
@(private = "file")
pause_notice_text :: proc(fl: ^Flow, r: ^Renderer) -> string {
	for b in fl.prefs.saved.bindings {
		for k in b[.Pause] {
			if k == prefs.KEY_CAPS_LOCK {
				return game_string(r, GS_PRESS_CAPS_LOCK)
			}
			if k != prefs.KEY_NONE {
				name := transmute([]u8)strings.to_lower(key_name(k), context.temp_allocator)
				for c, i in name {
					if c >= 'a' && c <= 'z' && (i == 0 || name[i - 1] == ' ') {
						name[i] = c - 'a' + 'A'
					}
				}
				return fmt.tprintf("Press %s", string(name))
			}
		}
	}
	return game_string(r, GS_PRESS_CAPS_LOCK)
}

// G_Notice_BuildDrawList: the preset with the notice's blend added to the
// text's and its strip's, the strip dropped once that passes 32.
@(private = "file")
pause_draw :: proc(fl: ^Flow, r: ^Renderer, scale: f32, paused: bool, note: string) {
	m := &fl.pause_menu
	if m.notice {
		t := r.textures.assets.text[data.Text_Preset.Game_Notice]
		t.format = sim.Res_ID{'C', 'E', 'G', 'A'}
		t.strip_blend += m.blend
		if t.strip_blend > 32 {
			t.strip = false
		}
		text_preset_draw(r, t, pause_notice_text(fl, r), VIEW_X, scale, t.blend + m.blend)
	}
	if paused && !r.classic && m.main_menu.rect.width != 0 {
		text_button_draw(r, &m.main_menu)
		if note != "" {
			menu_draw_text(r, note, VIEW_X + PLAY_W / 2, PAUSE_MAIN_MENU_Y + 30, rl.Color{190, 190, 190, 255}, .Centre)
		}
	}
}

// The Pause binding: player 1's, and player 2's while they are in the game
// (a local 2 Player session).
@(private = "file")
pause_key_pressed :: proc(fl: ^Flow) -> bool {
	if binding_pressed(&fl.prefs.saved.bindings[0], .Pause) {
		return true
	}
	return sim.player_at(fl.state, 1).active && binding_pressed(&fl.prefs.saved.bindings[1], .Pause)
}

flow_init :: proc(fl: ^Flow, root: string, defs: ^sim.Defs, state: ^sim.State, r: ^Renderer, ps: ^Prefs_State) {
	fl.root = root
	fl.prefs = ps
	fl.defs = defs
	for &w in defs.weapons {
		fl.extra_content ||= w.extra
	}
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
			// The Pause binding pauses through the simulation itself:
			// gather_input sets the Pause input bit, so both peers pause
			// on the same frame. The notice and button appear once the
			// (shared) state says paused, whoever pressed it.
			if netplay_plugin.paused(fl.state) != fl.netplay_was_paused {
				fl.netplay_was_paused = netplay_plugin.paused(fl.state)
				if netplay_plugin.paused(fl.state) {
					pause_begin(fl, r)
				}
			}
			if netplay_plugin.paused(fl.state) {
				if pause_menu_update(r, &fl.pause_menu) {
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
			pause_begin(fl, r)
		}
	case .Paused:
		leave := !r.classic && pause_menu_update(r, &fl.pause_menu)
		if pause_key_pressed(fl) {
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
	fl.pause_menu.notice, fl.netplay_was_paused = false, false
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
		scores[i] = int(sim.player_at(fl.state, i).score)
		active[i] = fl.state.session.game_type != .Single || i == 0
	}
	if sim.level_def(fl.state) != nil {
		sector = sim.level_def(fl.state).identifier
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
// sim.single(s, sim.Game_Status).game_over { l.started = true; return }"). Reacting to game_over directly
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
			if sim.player_at(fl.state, 1).active {
				input[1] = gather_input(&fl.prefs.saved.bindings[1])
			}
			// A local session pauses through flow (.Paused, the original's
			// kind of pause), never the sim's netplay pause.
			input[0] -= {.Pause}
			input[1] -= {.Pause}
			flow_sim_step(fl, r, particles, blurs, notices, input, nil, true)
		}
		pause_notice_step(fl)
		// The step itself moved to the next level if there was one
		// (sim.session_step), so complete still being set means the list
		// is finished -- unless easy mode's reward screen is holding the
		// move back. Flow only reads the state here, never changes it:
		// in netplay, the state is the rollback session's to change.
		switch {
		case sim.single(fl.state, sim.Game_Status).game_over:
			fl.mode, fl.end_timer = .Game_Over, 0
		case sim.single(fl.state, sim.Level_End).complete && !sim.session_frozen(fl.state):
			fl.mode, fl.end_timer = .Complete, 0
		}
		// G_LevelSelect only ever raises U_Prefs slot 3 (highest reached)
		// for a session that started at level 1 -- jumping into the middle
		// via Level Select never advances it, even past the levels played
		// along the way.
		if fl.session_start_pos == 1 && int(sim.single(fl.state, sim.Level_Info).number) > fl.highest_reached {
			fl.highest_reached = int(sim.single(fl.state, sim.Level_Info).number)
			progress_save(fl.highest_reached)
		}
	case .Attract:
		// Plain sim.step: a demo that finishes its level moves on to the
		// next demo (below), not to the next level.
		flow_sim_step(fl, r, particles, blurs, notices, {}, &fl.sim_film, false)
		if sim.single(fl.state, sim.Game_Status).game_over || sim.single(fl.state, sim.Level_End).complete || sim.film_finished(fl.state, &fl.sim_film) {
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
		if sim.level_def(fl.state) != nil {
			key = sim.level_def(fl.state).id
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
		paused := fl.mode == .Paused || (fl.mode == .Playing && netplay_plugin.paused(fl.state))
		if paused != fl.music_paused {
			if paused {
				rl.PauseMusicStream(fl.music)
			} else {
				rl.ResumeMusicStream(fl.music)
			}
		}
		rl.UpdateMusicStream(fl.music)
	}
	fl.music_paused = fl.music.frameCount != 0 && (fl.mode == .Paused || (fl.mode == .Playing && netplay_plugin.paused(fl.state)))
}

@(private = "file")
flow_sim_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, input: sim.Frame_Input, film: ^sim.Film, session: bool) {
	if session {
		_ = sim.session_step(fl.state, input, film)
	} else {
		sim.step(fl.state, input, film)
	}
	flow_effects_sync(fl, particles, blurs, notices)
	flow_effects_step(fl, r, particles, blurs, notices)
	sounds_step(&r.textures, fl.state)
}

// The presentation effects' step, after a sim step. They freeze with the
// game: under the netplay pause and the reward and loadout screens, which
// all stop the sim's clock while it keeps stepping.
flow_effects_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices) {
	if sim.session_frozen(fl.state) {
		return
	}
	particles_step(particles, fl.state)
	passive_particles_step(particles, fl.state, r)
	blurs_step(blurs, fl.state)
	notices_step(notices, fl.state)
}

// After every sim.init: whatever the last session left on screen is not
// part of this one.
flow_session_began :: proc(fl: ^Flow) {
	fl.pause_menu.notice, fl.netplay_was_paused = false, false
	fl.effects_level = 0
}

// The original empties its particles, motion-blur ghosts and notices at the
// start of every level (G_Particle_ResetAtLevelStart 0x42e890,
// G_MotionBlur_ResetAtLevelStart 0x42d5b0, G_Notice_ResetAtLevelStart
// 0x42df90). They live outside sim.State here, so they are cleared when
// levels_played, which sim.level_start bumps, moves on, or a new session
// begins. Call it after a sim step and before the effects take that step's
// events, so a new level's first effects survive. flow_draw calls it too,
// for a session started with no step yet taken.
flow_effects_sync :: proc(fl: ^Flow, particles: ^Particles, blurs: ^Blurs, notices: ^Notices) {
	if fl.effects_level == sim.single(fl.state, sim.Level_Info).played {
		return
	}
	fl.effects_level = sim.single(fl.state, sim.Level_Info).played
	clear(&particles.live)
	clear(&particles.beams)
	clear(&blurs.live)
	notices^ = {}
}

// Called from the main menu's 1 Player/2 Player buttons (game/menu_main.odin).
flow_random_seed :: proc() -> u32 {
	return u32(time.to_unix_nanoseconds(time.now()))
}

// The session extras this player has on, as Start carries them: off in
// classic mode, like every extra. New Weapons also needs the new content
// to be there (assets/extra).
flow_session_flags :: proc(fl: ^Flow) -> (flags: u8) {
	if prefs_mod_on(fl.prefs, easy_mode.ID) {
		flags |= net.START_EASY
	}
	if prefs_mod_on(fl.prefs, new_weapons.ID) && fl.extra_content {
		flags |= net.START_LOADOUT
	}
	return
}

// The session plugins for Start's flags, and netplay's own in a netplay
// session.
session_from_flags :: proc(seed: u32, level: sim.Level_ID, game_type: sim.Game_Type, flags: u8, online := false) -> sim.Session {
	want: sim.Mods
	if flags & net.START_EASY != 0 {
		want += {int(easy_mode.ID)}
	}
	if flags & net.START_LOADOUT != 0 {
		want += {int(new_weapons.ID)}
	}
	if online {
		want += {int(netplay_plugin.ID)}
	}
	return {seed = seed, level_id = level, game_type = game_type, mods = sim.mods_session(sim.mods_with_deps(want))}
}

// Called once Level Select's accept pulse finishes (game/menu_level_select.odin).
// `level_index` is 0-based into fl.defs.levels (play order), matching
// Level_Select.center.
flow_start_session :: proc(fl: ^Flow, seed: u32, game_type: sim.Game_Type, level_index: int) {
	fl.session_start_pos = level_index + 1
	fl.session_named = false // a local game asks for names at the end
	level := fl.defs.levels[level_index].id
	sim.init(fl.state, session_from_flags(seed, level, game_type, flow_session_flags(fl)), fl.defs)
	flow_session_began(fl)
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
	flow_session_began(fl)
	fl.demo_index = index
	fl.mode = .Attract
	return true
}

// Once per render frame, after the fixed-step loop: builds and presents the
// current game frame (skipped at Title, which has no session yet -- state is
// zeroed, and build_frame dereferences sim.level_def(state)), then layers on whatever
// text the mode calls for. draw_text needs a built frame's layer/scale
// pipeline to draw into, which Title doesn't have, so these overlays go
// through raylib's own font directly instead -- the same shortcut
// draw_debug already takes for its dev overlay.
flow_draw :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, scale: f32) {
	if sim.level_def(fl.state) != nil {
		flow_effects_sync(fl, particles, blurs, notices)
	}
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
	r.replay = fl.mode == .Attract
	build_frame(r, fl.state, blurs, notices)
	present(r, fl.state, particles, scale)
	if fl.mode == .Playing || fl.mode == .Paused {
		reward_draw(fl, r)
		loadout_draw(fl, r)
	}
	switch fl.mode {
	case .Paused:
		pause_draw(fl, r, scale, true, "")
	case .Game_Over:
		draw_banner("GAME OVER", "")
	case .Complete:
		draw_banner("ALL LEVELS COMPLETE", "")
	case .Attract:
		if !r.classic { // the original labels a demo "REPLAY" and nothing more
			rl.DrawText("DEMO -- press any key for the title screen",
				16, SCREEN_H * WINDOW_SCALE - 28, 18, rl.Color{200, 200, 200, 200})
		}
	case .Playing:
		// Phase 8 stage 3: frozen waiting on a peer -- title == "" (link_state
		// == .Live) draws nothing, the ordinary case for every prior netplay
		// session.
		if fl.netplay_active {
			if title, sub := netplay_disconnect_banner(&fl.netplay); title != "" {
				draw_banner(title, sub)
			} else {
				pause_draw(fl, r, scale, netplay_plugin.paused(fl.state), "PAUSED FOR BOTH PLAYERS -- EITHER CAN RESUME")
			}
		} else {
			pause_draw(fl, r, scale, false, "") // the notice fading after a resume
		}
	case .Title, .Level_Select, .Credits, .High_Scores, .Score_Entry, .Preferences, .Netplay_Lobby:
	}
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
// whoever is aiming with it. In a local game each player has the hue set
// for them in Extras. Accent Colours turns the colours off; Self Outline
// is separate, and only ever rings the ship of the player at this machine.
// The plugins drawn with (Renderer.mods) are set here with them.
@(private = "file")
flow_set_accents :: proc(fl: ^Flow, r: ^Renderer) {
	r.accents = {}
	r.mods = fl.state.session.mods
	if fl.mode == .Attract || prefs_classic(fl.prefs) {
		return
	}
	colours := prefs_mod_on(fl.prefs, accent.ID)
	if colours {
		r.mods += {int(accent.ID)}
	}
	outline := setting_on(fl.prefs, accent_view.SELF_OUTLINE)
	if fl.session_named {
		local := fl.netplay_active ? fl.netplay.rs.local_player : -1
		for i in 0 ..< sim.MAX_PLAYERS {
			r.accents[i] = {
				on             = colours,
				hue            = f32(fl.session_hues[i]),
				outline        = outline && i == local,
				hide_crosshair = fl.netplay_active && i != local,
			}
		}
		return
	}
	r.accents[0] = {on = colours, hue = f32(setting_value(fl.prefs, accent_view.HUE_P1)), outline = outline}
	r.accents[1] = {on = colours, hue = f32(setting_value(fl.prefs, accent_view.HUE_P2))}
}
