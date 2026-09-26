package level_system

// A level's start, the game over, and the move to the next level.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/background_system"
import "dr:sim/systems/player_system"

// FUN_0041fc80: the start of a level.
level_start :: proc(s: ^sim.State) {
	sim.single(s, sim.Clock).time = 0
	acc := sim.single(s, sim.Accuracy)
	acc.targets = 0
	acc.destroyed = 0
	// FUN_004208d0: the tally resets, but not the count of levels finished
	// at 100%, nor `all_done`/`complete`, which belong to the session.
	l := sim.single(s, sim.Level_End)
	l.started, l.started_time = false, 0
	l.state, l.state_time, l.count_time = 0, 0, 0
	l.fade = 0x20
	l.percent, l.bonus, l.bonus_step = 0, 0, 0
	l.perfect, l.perfect_count = false, 0
	// A level finished at 100% accuracy earns the bonus pickup on the next
	// one, once (G_Game_GroundAccuracy_CheckForRewardThisLevel).
	acc.reward_this_level = acc.perfect_level
	acc.perfect_level = false
	sim.single(s, sim.Level_Info).played += 1
	for p in sim.players_of(s) {
		player_system.player_level_reset(s, p, 0)
	}
	sim.single(s, sim.Debris).count = 0 // G_Debris_ResetAtLevelStart
	background_system.bgnd_reset(s, sim.level_def(s))
	lifecycle.eg_reset(s, sim.level_def(s))
	background_system.bgnd_initial_spawns(s)

	// The level's title notice unit, centred in the play area.
	info := sim.single(s, sim.Level_Info)
	info.title = sim.NO_REF
	notice := s.defs.perm_objects[sim.level_number_of(s) + 9]
	if notice != sim.NONE {
		req := sim.spawn_request(notice)
		req.loc = {
			s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH] / 2,
			s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT] / 2,
		}
		info.title = lifecycle.eg_request_spawn(s, req)
	}
}

// Moves to the next level in list order once level_end.complete is true and
// this was not the last one (level_end.all_done), keeping the session's
// score/money the same way the original does: G_LevelSelect_GetStartingLevelID
// -FromUser only ever picks the *first* level of a new session
// (G_LevelSelect_IsRunning has one caller, the title flow) -- levels within a
// session always play in list order, so there is nothing to choose here.
// `defs.levels` is ordered by number and level_number is 1-based, so the next
// entry is simply the array index at the current number.
level_advance :: proc(s: ^sim.State) -> bool {
	info := sim.single(s, sim.Level_Info)
	next := int(info.number)
	if next >= len(s.defs.levels) {
		return false
	}
	info.number = s.defs.levels[next].number
	// level_start leaves `complete` alone (FUN_004208d0 does not touch it),
	// so it has to be consumed here: left set, flow_step saw the next level
	// as already complete on its very first step and chained through every
	// remaining level in as many steps. `level_ending` likewise has no reset
	// anywhere in the port, and left set it keeps players invulnerable and
	// blocks can_be_spawned_only_when_players_active units for the rest of
	// the session. Provisional: where the original clears DAT_004e4825 and
	// DAT_004e4855 between levels has not been traced -- the effect (both
	// false at the start of every level) is what a playable session needs.
	sim.single(s, sim.Level_End).complete = false
	info.ending = false
	level_start(s)
	return true
}

// What the session does after a step: carry on, game over, the next level or
// the end of the list. game_over wins over complete, see flow_step.
level_transition :: proc(s: ^sim.State) -> sim.Level_Transition {
	if sim.single(s, sim.Game_Status).game_over {
		return .Game_Over
	}
	if !sim.single(s, sim.Level_End).complete {
		return .None
	}
	return level_advance(s) ? .Advanced : .All_Complete
}

level_transition_system :: proc(s: ^sim.State, step: ^sim.Step) {
	step.transition = level_transition(s)
}

first_player_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if !sim.single(s, sim.Game_Status).player1_seen_playing && sim.player_at(s, 0).state == .Playing {
		sim.single(s, sim.Game_Status).player1_seen_playing = true
	}
}

game_over_system :: proc(s: ^sim.State, step: ^sim.Step) {
	for p in sim.players_of(s) {
		if p.active {
			return
		}
	}
	sim.single(s, sim.Game_Status).game_over = true
	// FUN_00420280 LAB_0042037a: the first step no player is left in
	// game spawns the Notice_GameOver banner (perm object 0x18) once, at
	// screen centre -- the same position formula level_end_begin uses
	// for Notice_LevelEnd/AllLevelsCompleted. Confirmed 0x18 is
	// Notice_GameOver, not guessed: assets/data/idli/gaob.json lists
	// perm objects in order, and index 0x16 Notice_LevelEnd / 0x17
	// Notice_AllLevelsCompleted / 0x18 Notice_GameOver / 0x19
	// RandomBonus_1 lines up exactly with level_end.odin's own 0x16/0x17
	// and lifecycle/destroy.odin's 0x19..0x22 RandomBonus comment. This spawn
	// draws from the RNG like any other, so a real session that runs out
	// of lives needs it for the replay to stay in sync -- no shipped
	// demo film reaches game over, so oracle:diff never exercised this
	// gap before.
	if !sim.single(s, sim.Game_Status).game_over_notice {
		notice := s.defs.perm_objects[0x18]
		if notice != sim.NONE {
			req := sim.spawn_request(notice)
			req.loc = {
				s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH] / 2,
				s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT] / 2,
			}
			lifecycle.eg_request_spawn(s, req)
		}
		sim.single(s, sim.Game_Status).game_over_notice = true
	}
}

// The G_Bgnd_Process() == 1 branch.
level_end_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if step.level_done {
		level_end_step(s, sim.single(s, sim.Clock).time)
	}
}
