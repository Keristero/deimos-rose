package game

// The launch flags that play a level straight away (D54): -campaign, -level
// and -row, for testing a level without the menus. The level editor's Play
// runs the game with them.

import "core:fmt"
import "core:strings"

import "dr:data"
import "dr:sim"
import "dr:sim/systems/level_system"

// The campaign -campaign names: the originals for none, or for their
// plugin's name.
launch_campaign :: proc(s: Settings) -> (sim.Plugin_ID, bool) {
	if s.campaign == "" || s.campaign == data.CLASSIC_LEVELS {
		return sim.CORE, true
	}
	return sim.plugin_find(s.campaign)
}

// Applies the launch flags to a Flow just initialised. False, having said
// why, when they name a campaign or level that is not installed.
flow_launch :: proc(fl: ^Flow, s: Settings) -> bool {
	if s.campaign == "" && !settings_play_now(s) {
		return true
	}
	campaign, ok := launch_campaign(s)
	if !ok || len(sim.campaign_levels(fl.defs, campaign)) == 0 {
		fmt.eprintfln("-campaign %s: no campaign of that name is installed", s.campaign)
		return false
	}
	if campaign != sim.CORE && prefs_classic(fl.prefs) {
		fmt.eprintln("-campaign: classic mode plays only the original levels")
		return false
	}
	flow_campaign_set(fl, campaign)
	if !settings_play_now(s) {
		return true
	}
	index, found := 0, s.level == ""
	for l, i in flow_levels(fl) {
		if !found && (strings.equal_fold(l.identifier, s.level) || (len(s.level) == 4 && l.id == sim.res_id(s.level))) {
			index, found = i, true
		}
	}
	if !found {
		fmt.eprintfln("-level %s: not a level of this campaign", s.level)
		return false
	}
	fl.pending_game_type = .Single
	flow_start_session(fl, flow_random_seed(), .Single, index)
	if s.row > 0 {
		level_system.level_start_at_row(fl.state, i32(s.row))
	}
	return true
}
