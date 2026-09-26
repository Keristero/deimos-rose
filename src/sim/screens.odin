package sim

// What the plugins' screens between play (plugins/easy_mode's rewards,
// plugins/loadout's loadout) have in common. Not the original's.
//
// A screen is part of the simulation, not the presentation, so that
// netplay needs nothing new: the choices are made with ordinary inputs,
// stepped by session_step like play, snapshotted and rolled back like play,
// and resynced on reconnect with the rest of the state.

// Steps every chooser has to have been ready for before play resumes: a
// beat to see the last choice land, and to take it back. Provisional.
SCREEN_RESUME_DELAY :: 10

// The menu's own sounds (ui/menu.odin, game/menu_level_select.odin).
SCREEN_SOUND_MOVE :: Res_ID{'m', 'b', 'r', 'o'}
SCREEN_SOUND_LOCK :: Res_ID{'l', 's', 's', 'e'}
SCREEN_SOUND_REFUSE :: Res_ID{'l', 's', 'n', 'a'}
SCREEN_SOUND_UNLOCK :: Res_ID{'i', 'n', 'c', 'l'}

// Whether a player chooses on a screen: still in the game.
screen_chooser :: #force_inline proc "contextless" (p: Player) -> bool {
	return p.active && p.state != .Gone
}

// A menu sound: no draws, played at full volume whether or not it is
// already playing (loop = true, as the weapon-switch sound does).
screen_sound :: proc "contextless" (s: ^State, id: Res_ID) {
	if s.sounds.count < MAX_SOUND_EVENTS {
		s.sounds.events[s.sounds.count] = {id, 100, 0, 1, true}
		s.sounds.count += 1
	}
}
