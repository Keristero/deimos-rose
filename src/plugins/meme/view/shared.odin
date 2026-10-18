package hitstop_view

import rl "vendor:raylib"

import "dr:blocks"
import "dr:prefs"
import "dr:sim"

// This package's state, in a block a plugin's copy of this package is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	voice:            rl.Sound,
	voiced:           bool,
	boom:             rl.Sound,
	boom_made:        bool,
	// How much fire there is, 1 as designed (the COMBO FLAMES setting, kept by
	// combo_apply for the frame; 1 from registration until then).
	flame_amount:     f32,
	cam:              Cam,
	// A living ground target is on screen (set each step): the kill cam does not
	// zoom then, so the fight stays readable.
	ground_live:      bool,
	driven:           bool, // the slowdown, sound and reverb are set by the cam
	// The longest streak each player has had the kill cam for this level: it
	// shows the first time a combo level is reached, not again on the way back up.
	reached:          [sim.MAX_PLAYERS]int,
	// Each player's kill streak, the step of their last kill, and the step.
	streak:           [sim.MAX_PLAYERS]int,
	last_kill:        [sim.MAX_PLAYERS]int,
	steps:            int,
	// Kept until the next step, as a level start forgets what is already up.
	staged:           Maybe(Cam),
	staged_combo:     Maybe(int),
	staged_style:     Maybe(f32),
	horn:             rl.Sound,
	horned:           bool,
	room:             Reverb,
	wet:              f32, // what the audio thread reads
	attached:         bool,
	was_wet:          bool,
	strength:         prefs.Setting_ID, // how long a hit holds
	shake:            prefs.Setting_ID, // how hard the kill cam shakes the screen
	zoom_amount:      prefs.Setting_ID, // how far the kill cam zooms in
	slowmo:           prefs.Setting_ID, // how deep the kill cam's slow-motion goes
	reverb:           prefs.Setting_ID, // how much reverb the kill cam puts on the sound
	flames:           prefs.Setting_ID, // how much fire the combo text and meter throw
	announcer_volume: prefs.Setting_ID,
	boom_volume:      prefs.Setting_ID,
	horn_volume:      prefs.Setting_ID,
	style:            [sim.MAX_PLAYERS]Style,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/hitstop/view", ptr = (^rawptr)(&shared), type = Shared})
}
