package easy_mode_view

// The reward screen's screenshot scenarios (ui/shots.odin): `mise run
// menu-shot MENU=reward` and `reward_2p`. The screen is opened straight
// over the first level a couple of seconds in rather than played to its
// end. New content: a visual check. Player 1 already holds the first level
// of the first option, so its values read current -> next; in reward_2p
// both players are on the first option, player 1 locked, so the borders
// nest.


import "dr:plugins/easy_mode"
import "dr:plugins/passives"
import "dr:sim"
import "dr:ui"

@(private = "file")
reward_shot :: proc(s: ^sim.State, name: string) -> string {
	for _ in 0 ..< 60 {
		_ = sim.session_step(s, {})
	}
	if !easy_mode.reward_begin(s, {}) {
		return "no options to offer"
	}
	rw := easy_mode.reward_of(s)
	passives.levels_of(s, 0)[rw.options[0]] = 1
	if name == "reward_2p" {
		rw.cursor[1] = 0
		rw.locked[0] = true
	}
	return ""
}

register_reward_shots :: proc() {
	ui.shot_register({name = "reward", plugin = easy_mode.ID, setup = reward_shot})
	ui.shot_register({name = "reward_2p", plugin = easy_mode.ID, co_op = true, setup = reward_shot})
}

@(init)
register_reward_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/easy_mode/view register_reward_shots", register_reward_shots)
}
