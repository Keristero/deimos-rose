package netplay_view

// The lobby as a plugin's screen (game/screens.odin, D86): the main menu's
// NETPLAY item opens it while the plugin is on, and a session it starts is
// one it drives, through its rollback session, in place of this machine's
// input. The game keeps the rest: the shared pause's menu, the banner while
// the peer is lost, the end of the session and its high scores.

import "core:os"
import "core:strconv"

import "dr:game"
import netplay_plugin "dr:plugins/netplay"
import "dr:prefs"
import "dr:render"
import "dr:sim"

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/netplay/view register_screen", register_screen)
}

@(private = "file")
register_screen :: proc() {
	shared.screen = game.screen_register({
		plugin       = netplay_plugin.id(),
		label        = "NETPLAY",
		open         = proc(fl: ^game.Flow, r: ^render.Renderer) {netplay_lobby_init(&shared.nl, r)},
		update       = proc(fl: ^game.Flow, r: ^render.Renderer) {netplay_lobby_update(fl, r, &shared.nl)},
		draw         = proc(fl: ^game.Flow, r: ^render.Renderer) {netplay_lobby_draw(fl, r, &shared.nl)},
		launch       = launch,
		shot         = menu_shot,
		close        = proc() {netplay_reset(&shared.nl)}, // no-op if no socket was ever opened
		framed       = framed,
		poll         = proc(fl: ^game.Flow, r: ^render.Renderer) {netplay_playing_poll(fl, r, &shared.nl)},
		step         = proc(fl: ^game.Flow, r: ^render.Renderer, fx: ^render.Effects) {netplay_playing_step(fl, r, fx, &shared.nl)},
		banner       = proc() -> (title, sub: cstring) {return netplay_disconnect_banner(&shared.nl)},
		local_player = proc() -> int {return shared.nl.rs.local_player},
		release      = release,
		pause_note   = "PAUSED FOR BOTH PLAYERS -- EITHER CAN RESUME",
		stats        = proc() -> (ping_ms: f32, rollbacks: int) {return shared.nl.ping_ms, shared.nl.rs.rollback_count},
	})
}

// Whether this screen drives the session in play.
active :: proc(fl: ^game.Flow) -> bool {
	return fl.driven && fl.screen == shared.screen
}

// The player here left the session (goodbye: the peer sees a Goodbye and
// freezes, able to continue alone), or it ended or is played on alone.
@(private = "file")
release :: proc(goodbye: bool) {
	if goodbye {
		netplay_disconnect(&shared.nl)
	} else {
		netplay_reset(&shared.nl)
	}
}

// DR_NETPLAY=host or DR_NETPLAY=join:<address> starts the game in the lobby
// already hosting or joining -- see netplay_lobby_start_from_flag's comment
// for why (a scripted test driving two instances at once,
// tools/netplay/loopback_check.sh).
@(private = "file")
launch :: proc(fl: ^game.Flow, r: ^render.Renderer) {
	flag := os.get_env("DR_NETPLAY", context.temp_allocator)
	if flag == "" {
		return
	}
	if end, ok := strconv.parse_int(os.get_env("DR_NETPLAY_END", context.temp_allocator)); ok && end > 0 {
		shared.test_end = i32(end)
	}
	shared.shot_path = os.get_env("DR_NETPLAY_SHOT", context.allocator)
	game.screen_show(fl, r, shared.screen)
	netplay_lobby_start_from_flag(&shared.nl, &fl.prefs.saved, flag)
}

@(private = "file")
framed :: proc(r: ^render.Renderer) {
	if netplay_shot_due() {
		game.canvas_save(r.canvas, shared.shot_path)
	}
}

// The lobby's menu shots (`mise run menu-shot MENU=netplay_lobby...`). New
// content, no original to compare against -- a visual smoke check of the
// lobby's screens, not an oracle:menu-shot comparison. They cover
// Netplay_Phase's visually distinct states, plus (Phase 8 stage 2) the
// host's and guest's differing views of .Connected once level select is in
// the mix. None opens a real socket (netplay_lobby_init's netplay_reset
// already zeroed nl.have_sock): the fields netplay_lobby_draw reads are set
// directly instead, since a shot only ever draws once and never polls.
// Named menu_shot, and its cases one name each, so tools/refs/menu_shots.sh
// finds them, as it does run_menu_shot's.
@(private = "file")
menu_shot :: proc(fl: ^game.Flow, r: ^render.Renderer, name: string) -> bool {
	nl := &shared.nl
	switch name {
	case "netplay_lobby":
		netplay_lobby_init(nl, r)
	case "diagnostics":
		// game/diagnostics.odin's overlay over the connected lobby, the one
		// screen with a ping to show.
		netplay_lobby_init(nl, r)
		nl.role = .Guest
		nl.phase = .Connected
		nl.ping_ms = 42
	case "netplay_lobby_name":
		netplay_lobby_init(nl, r)
		nl.phase = .Enter_Name
		prefs.name_set(&nl.local_name, "Keristero")
		nl.local_hue = 30
	case "netplay_lobby_join":
		netplay_lobby_init(nl, r)
		nl.phase = .Enter_Address
		nl.addr_len = copy(nl.addr_buf[:], "127.0.0.1")
		nl.addr_default = true
	case "netplay_lobby_connecting":
		netplay_lobby_init(nl, r)
		nl.role = .Host
		nl.phase = .Connecting
	case "netplay_lobby_connected":
		netplay_lobby_init(nl, r)
		nl.role = .Guest
		nl.phase = .Connected
		nl.ping_ms = 42 // sample value -- ping_ms is only ever set from a real Pong in netplay_tick_ping
		nl.remote_ready = true // local not ready yet, so the Ready button still draws beside the peer's READY
		prefs.name_set(&nl.local_name, "Keristero") // sample names, normally from each side's Hello
		prefs.name_set(&nl.peer_name, "Supercobra")
		nl.local_hue, nl.peer_hue = 30, 280
	case "netplay_lobby_connected_host":
		// Phase 8 stage 2: the host's own view -- level-select arrows above
		// an enabled Ready (highest_reached forced high enough that
		// level_index 0 reads as unlocked regardless of this machine's real
		// save file).
		netplay_lobby_init(nl, r)
		nl.role = .Host
		nl.phase = .Connected
		nl.ping_ms = 17
		fl.highest_reached = 12
	case "netplay_lobby_connected_host_locked":
		// Same, but level_index parked on a level past highest_reached --
		// "NO ACCESS" in red, Ready greyed out, matching Level Select's own
		// locked-slot language (game/menu_level_select.odin).
		netplay_lobby_init(nl, r)
		nl.role = .Host
		nl.phase = .Connected
		nl.ping_ms = 17
		fl.highest_reached = 1
		nl.level_index = 3
	case "netplay_lobby_campaigns":
		// The host's view with every campaign plugin on (D53), on the last
		// one: the campaign row and its arrows over the level's.
		ps := fl.prefs
		ps.saved.classic, ps.launch.classic, r.classic = false, false, false
		for i in 1 ..< len(sim.registered_plugins()) {
			if len(sim.campaign_levels(fl.defs, sim.Plugin_ID(i))) > 0 {
				ps.saved.mods += {i}
			}
		}
		offered := game.flow_campaigns(fl)
		game.flow_campaign_set(fl, offered[len(offered) - 1])
		netplay_lobby_init(nl, r)
		nl.role = .Host
		nl.phase = .Connected
		nl.campaign = fl.campaign // netplay_lobby_update's mirror
		nl.ping_ms = 17
		fl.highest_reached = 12
	case:
		return false
	}
	return true
}
