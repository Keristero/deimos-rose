package netplay_view

import "dr:blocks"

// What the lobby and its session keep between calls, in a block a plugin's
// copy of this package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	nl:        Netplay, // the lobby, its socket and the session it drives
	screen:    int, // this screen's index (game.screen_register)
	// DR_NETPLAY_END: see netplay_lobby_start_from_flag. 0 outside a test.
	test_end:  i32,
	// DR_NETPLAY_SHOT=<path>: the frame a second after play is first held
	// is saved as <path>.png, to see what the peer showed (Screen.framed).
	shot_path: string,
	shot_in:   int, // frames until that shot; 0 when none is due, -1 once taken
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/netplay/view", ptr = (^rawptr)(&shared), type = Shared})
}
