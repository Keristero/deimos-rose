package game

// Phase 7 stage 6 / Phase 6 stage 5: the netplay lobby, and the glue that
// wires a connected session into Flow's .Playing mode. There is no original
// screen to trace here -- Phase 6's design note (docs/phase-6-netplay.md)
// deferred building this until Phase 7 established a menu visual language,
// so it borrows that language (Text_Button, menu_draw_text, the shared
// "back" background) without claiming to reproduce any specific original
// screen. New content only, per D21/mise.toml's --classic flag: reached
// from Main Menu's own Netplay item, shown only when !r.classic (see
// menu_main.odin, D30).
//
// Handshake: net/reliable.odin's stop-and-wait channel already carries
// Hello/Ready/Goodbye; this adds a fourth reliable message, Start (host ->
// guest, carries the session seed and level), so the guest never begins
// simulating before it knows what the host is about to simulate. The host
// waits for Start's own Ack (reliable_tick's rc.pending going false) before
// beginning itself, so by the time the host's first redundant Input packet
// reaches the guest, the guest has already (within a frame or two) set up
// its own Rollback_Session at frame 0 -- well inside the input window's own
// loss-tolerance margin, so no genuine frame is ever unrecoverably dropped
// by the asymmetric start.
//
// Live play: net/session.odin's Rollback_Session already separates a silent
// resimulation (rollback_to only ever calls sim.step + snapshot_save) from
// the one call per real tick that reaches a new "current" frame
// (rollback_session_advance) -- so presentation side effects (particles,
// blurs, notices, sound) only need to run once per tick, after that one
// call, exactly mirroring the single-player path in flow.odin. A
// misprediction's already-played sound/particles from the wrong guess are
// not undone (the standard rollback-netcode trade-off; GGPO does the same) --
// only the simulation state itself is ever corrected.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import core_net "core:net"
import rl "vendor:raylib"

import "dr:data"
import "dr:net"
import "dr:prefs"
import "dr:sim"

// Chosen from IANA's dynamic/private port range (49152-65535) to avoid
// colliding with a registered service; both peers just need to agree on the
// same number, which "both compiled from the same source" already gives us.
NETPLAY_PORT :: 60902

NETPLAY_PING_INTERVAL :: 1.0 // seconds between RTT probes once connected
NETPLAY_INPUT_WINDOW :: 8    // matches tests/rollback_session_test.odin's own WINDOW
NETPLAY_CHECKSUM_LAG :: 20   // frames behind "now" a checksum is reported at; matches the test, comfortably under ROLLBACK_DEPTH (64)
// A pause-menu Resume click holds the Pause bit for this many ticks, then
// releases it: one press, as the sim's edge detection sees it.
NETPLAY_PAUSE_PULSE_TICKS :: 2

NETPLAY_ADDR_MAX :: 260 // a 253-character hostname plus ":65535"

// Phase 8 stage 3/4: pause on disconnect + reconnect.
NETPLAY_LIVE_TIMEOUT :: 3 * time.Second  // silence from a known peer during .Playing before freezing
STATE_CHUNK_BURST :: 64                  // chunks (<= 64KB) sent per frame while transferring -- loopback/LAN handles this trivially; unacked ones just get resent next frame, so this is a sliding window with "one render frame" as its retry granularity, not a per-chunk timer
STATE_RESYNC_TIMEOUT :: 10 * time.Second // give up if a transfer makes no further progress at all for this long (not a per-chunk retry count -- see STATE_CHUNK_BURST)

// Phase 8 stage 5 (provisional -- see docs/decisions.md D26): synchronised
// pausing. The notes admit an exact scheme is "hard to measure who is
// behind"; this is a simple linear throttle, not GGPO's own more elaborate
// one, and is expected to need retuning against a real (non-loopback)
// playtest with real latency.
NETPLAY_SYNC_STALL_THRESHOLD :: 5 // frames of lead over the peer's last confirmed input before this client starts stalling ticks to let them catch up
NETPLAY_SYNC_MIN_STALL_EVERY :: 2 // even at a huge lead, stall no more often than every-other-tick -- keeps local input responsive instead of freezing solid

Netplay_Phase :: enum {
	Menu,          // choose Host or Join
	Enter_Name,    // either side, after choosing: the name high scores are recorded under
	Enter_Address, // guest only: typing "host" or "host:port"
	Resolving,     // guest only: Enter pressed; one frame of "RESOLVING..." before the blocking lookup
	Connecting,    // Hello sent (guest) or awaited (host), not yet both-ways confirmed
	Connected,     // handshake done; ready-up + ping display
	Starting,      // host: Start sent, waiting for its Ack before beginning
}

Netplay_Role :: enum {
	Host,
	Guest,
}

// Phase 8 stage 3/4. Live is the ordinary state a session is in for its
// entire duration up through Phase 6/7 -- it is also the zero value, so a
// freshly-started session needs no explicit initialisation to be considered
// live. The other three only ever apply once fl.mode == .Playing has already
// been reached once and a peer is then lost:
//
//   Live -> (peer goes quiet for NETPLAY_LIVE_TIMEOUT) -> Waiting_Reconnect
//   Waiting_Reconnect -> (fresh Hello arrives) -> Resync_Sending (survivor)
//                                              -> Resync_Receiving (rejoiner, via its ordinary Join flow)
//   Resync_Sending / Resync_Receiving -> (transfer completes) -> Live
Link_State :: enum {
	Live,
	Waiting_Reconnect,
	Resync_Sending,
	Resync_Receiving,
}

Netplay :: struct {
	phase: Netplay_Phase,
	role:  Netplay_Role,
	error: string,

	sock:      net.Socket,
	have_sock: bool,
	rc:        net.Reliable_Channel,
	have_peer: bool,
	peer:      core_net.Endpoint,

	sent_own_hello: bool,
	got_peer_hello: bool,
	local_ready:    bool,
	remote_ready:   bool,

	// This machine's player's name (prefilled from, and saved back to,
	// Prefs.netplay_name) and the peer's, from its Hello. Flow copies both
	// into session_names when a session starts, so the high scores can be
	// recorded under them once it ends (flow_finish_session).
	local_name: prefs.Name,
	peer_name:  prefs.Name,
	// Accent hues (degrees) the same way: this machine's from Prefs, the
	// peer's from its Hello. Copied into Flow.session_hues with the names.
	local_hue: int,
	peer_hue:  int,
	// The lobby's hue slider changed local_hue and the peer has not been told
	// yet: it goes as a fresh Hello, which the peer takes as an update, once
	// the stop-and-wait channel is free. A Ready pressed meanwhile waits
	// behind it (ready_unsent), so neither overwrites the other in flight.
	hue_dirty:    bool,
	ready_unsent: bool,
	name_role:  Netplay_Role, // what Enter_Name goes on to: hosting, or the address prompt

	addr_buf:     [NETPLAY_ADDR_MAX]u8,
	addr_len:     int,
	addr_default: bool, // addr_buf still holds the untouched prefill, which the first edit replaces

	ping_nonce:    u64,
	ping_timer:    f32,
	awaiting_pong: bool,
	ping_sent_at:  time.Time,
	ping_ms:       f32,

	pause_pulse:   int,  // ticks left of a Resume click's Pause bit (NETPLAY_PAUSE_PULSE_TICKS)
	pending_start: bool, // set by netplay_poll on an accepted Start; consumed once per frame
	start_seed:    u32,
	start_level:   u8,

	// Phase 8 stage 2: level_index is host-authoritative (the host's own
	// nav buttons change it; the guest only ever receives it via inbound
	// Level_Choice packets in netplay_poll) but lives in one shared field
	// either way, since only one side at a time ever writes it.
	level_index: int,

	menu_host:  Text_Button,
	menu_join:  Text_Button,
	menu_back:  Text_Button,
	level_prev: Text_Button,
	level_next: Text_Button,
	ready_btn:  Text_Button,
	buttons_at: f32, // cy the above were last built for; rebuilt if it ever needs to change

	// Live session, once both sides are Playing (see Flow.netplay_active).
	rs:            net.Rollback_Session,
	desync:        net.Desync_Monitor,
	warned_desync: bool,

	// Phase 8 stage 3/4: pause on disconnect + reconnect.
	link_state:     Link_State,
	last_peer_seen: time.Time, // last packet accepted from nl.peer while link_state == .Live

	// Resync sender (the survivor). resync_buf is a one-off heap copy of
	// fl.state, made only for the duration of the transfer -- embedding a
	// permanent size_of(sim.State) array in Netplay would bloat every Flow
	// for a buffer almost never in use. resync_acked is a per-chunk bitmap
	// (bool per chunk, not literal bits -- 655 chunks costs 655 bytes, not
	// worth a bit_set): netplay_resync_send_tick (re)sends every unacked
	// chunk up to STATE_CHUNK_BURST per frame rather than waiting for one
	// chunk's ack before sending the next, so the transfer isn't bottlenecked
	// on one network round trip per chunk.
	resync_peer:          core_net.Endpoint,
	resync_buf:           []byte,
	resync_total:         int,
	resync_chunks:        int, // ceil(resync_total / STATE_CHUNK_SIZE)
	resync_acked:         []bool,
	resync_acked_count:   int,
	resync_last_progress: time.Time,

	// Resync receiver (the reconnecting client). recv_got mirrors
	// resync_acked's shape -- chunks can arrive out of order since the
	// sender now bursts several per frame instead of one at a time.
	recv_buf:              []byte,
	recv_total:            int,
	recv_chunks:           int,
	recv_got:              []bool,
	recv_got_count:        int,
	recv_assigned_player:  u8,
	recv_last_progress:    time.Time,
	pending_resync_start:  bool, // set by netplay_poll on an accepted Resync_Start; consumed once per frame, mirrors pending_start
	resync_incoming_total:  u32, // stashed from the Resync_Start until pending_resync_start is consumed
	resync_incoming_player: u8,
}

// Closes the socket (if any) and zeroes every other field. Package-visible
// (not file-private) since flow.odin's flow_finish_session calls this too,
// to clean up a netplay match that ended normally rather than via Escape
// (netplay_disconnect) or a peer Goodbye (netplay_poll).
netplay_reset :: proc(nl: ^Netplay) {
	if nl.have_sock {
		net.close(&nl.sock)
	}
	delete(nl.resync_buf) // no-op for any that were never allocated (nil slice)
	delete(nl.resync_acked)
	delete(nl.recv_buf)
	delete(nl.recv_got)
	nl^ = {}
}

netplay_lobby_init :: proc(nl: ^Netplay, r: ^Renderer) {
	netplay_reset(nl)
	netplay_build_buttons(nl, r)
}

@(private = "file")
netplay_build_buttons :: proc(nl: ^Netplay, r: ^Renderer) {
	nl.menu_host = text_button_at(r, "HOST GAME", 220)
	nl.menu_join = text_button_at(r, "JOIN GAME", 250)
	nl.menu_back = text_button_at(r, "BACK", 300)
	nl.level_prev = text_button_at_x(r, "<", SCREEN_W / 2 - 110, 262)
	nl.level_next = text_button_at_x(r, ">", SCREEN_W / 2 + 110, 262)
	nl.ready_btn = text_button_at(r, "READY", 300)
}

// Called once per render frame from flow_handle_input's .Netplay_Lobby case.
netplay_lobby_update :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	if nl.have_sock {
		netplay_poll(fl, r, nl)
	}

	switch nl.phase {
	case .Menu:
		netplay_update_menu(fl, r, nl)
	case .Enter_Name:
		netplay_update_enter_name(fl, nl)
	case .Enter_Address:
		netplay_update_enter_address(nl, r)
	case .Resolving:
		// Drawn as "RESOLVING..." last frame, so the window says what it is
		// doing while net.resolve blocks on a hostname lookup.
		nl.phase = .Enter_Address // where a failed join leaves the player
		netplay_join(nl, string(nl.addr_buf[:nl.addr_len]))
	case .Connecting:
		netplay_update_connecting(nl, r)
	case .Connected:
		netplay_update_connected(fl, nl, r)
	case .Starting:
		netplay_update_starting(nl)
	}

	// A Start accepted by netplay_poll (guest) fires regardless of which
	// phase the switch above just ran, since it can arrive the instant the
	// host sends it -- possibly the same frame this side reaches Connected.
	if nl.pending_start {
		nl.pending_start = false
		netplay_begin_session(fl, nl, nl.start_seed, int(nl.start_level))
	}
	// Same reasoning as pending_start above, for a reconnecting client's
	// inbound Resync_Start (Phase 8 stage 4).
	if nl.pending_resync_start {
		nl.pending_resync_start = false
		netplay_begin_resync_receive(nl)
	}
}

@(private = "file")
netplay_update_menu :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	if text_button_update(r, &nl.menu_host, mouse, dt) {
		netplay_begin_name_entry(fl, nl, .Host)
	}
	if text_button_update(r, &nl.menu_join, mouse, dt) {
		netplay_begin_name_entry(fl, nl, .Guest)
	}
	if text_button_update(r, &nl.menu_back, mouse, dt) || rl.IsKeyPressed(.ESCAPE) {
		fl.mode = .Title
	}
}

// The name comes first, for hosting and joining alike, so both players'
// scores can be recorded under their names when the game ends. The last
// name used is offered again.
@(private = "file")
netplay_begin_name_entry :: proc(fl: ^Flow, nl: ^Netplay, role: Netplay_Role) {
	nl.phase = .Enter_Name
	nl.name_role = role
	nl.local_name = fl.prefs.saved.netplay_name
	nl.local_hue = extra_value(fl.prefs, .Accent_Hue)
	nl.error = ""
}

// The lobby's accent hue slider, under the players' names: the same setting
// as Preferences' Extras page (player 1's hue), so a colour picked in either
// place is the one used.
@(private = "file") ACCENT_SLIDER_W :: 256
@(private = "file") ACCENT_SLIDER_Y :: 410

@(private = "file")
accent_slider_rect :: proc() -> rl.Rectangle {
	return {SCREEN_W / 2 - ACCENT_SLIDER_W / 2, ACCENT_SLIDER_Y, ACCENT_SLIDER_W, HUE_SLIDER_H}
}

@(private = "file")
netplay_update_enter_name :: proc(fl: ^Flow, nl: ^Netplay) {
	n := &nl.local_name
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if c >= 0x20 && c <= 0x7e && n.len < prefs.NAME_MAX {
			n.buf[n.len] = u8(c)
			n.len += 1
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && n.len > 0 {
		n.len -= 1
		n.buf[n.len] = 0
	}
	if rl.IsKeyPressed(.ESCAPE) {
		nl.phase = .Menu
		nl.error = ""
		return
	}
	if !(rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
		return
	}
	prefs.name_set(n, prefs.name_string(n)) // trims surrounding spaces
	if n.len == 0 {
		nl.error = "enter a name first"
		return
	}
	nl.error = ""
	if fl.prefs.saved.netplay_name != n^ {
		fl.prefs.saved.netplay_name = n^
		prefs_state_save(fl.prefs)
	}
	switch nl.name_role {
	case .Host:
		netplay_start_hosting(nl)
	case .Guest:
		nl.phase = .Enter_Address
		nl.addr_len = copy(nl.addr_buf[:], "127.0.0.1") // loopback default -- the only peer this port can verify without a second machine
		nl.addr_default = true
	}
}

@(private = "file")
netplay_start_hosting :: proc(nl: ^Netplay) {
	sock, ok := net.open(NETPLAY_PORT)
	if !ok {
		nl.error = "could not open a socket on the netplay port"
		return
	}
	nl.sock, nl.have_sock = sock, true
	nl.role = .Host
	nl.phase = .Connecting
	// have_peer stays false until a Hello arrives -- a host does not know
	// who is joining ahead of time.
}

// Skips the Menu/Enter_Address phases and their mouse/keyboard-driven UI,
// going straight to hosting or joining. Used by main.odin's DR_NETPLAY hook
// (tools/netplay/loopback_check.sh) so a scripted two-instance test only
// has to drive xdotool through the one truly interactive step left -- each
// side's own Ready button -- instead of also guessing Main Menu/lobby
// button pixel coordinates blindly. `mode` is "host" or "join:<address>".
// The saved name and accent are used as they are, or "Player 1"/"Player 2"
// without a name.
netplay_lobby_start_from_flag :: proc(nl: ^Netplay, saved: ^prefs.Prefs, mode: string) {
	nl.local_name = saved.netplay_name
	nl.local_hue = saved.extras[.Accent_Hue]
	if nl.local_name.len == 0 {
		prefs.name_set(&nl.local_name, high_scores_default_last_name(mode == "host" ? 0 : 1))
	}
	if mode == "host" {
		netplay_start_hosting(nl)
		return
	}
	if len(mode) > 5 && mode[:5] == "join:" {
		netplay_join(nl, mode[5:])
	}
}

@(private = "file")
netplay_update_enter_address :: proc(nl: ^Netplay, r: ^Renderer) {
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		netplay_addr_append(nl, c)
	}
	// Ctrl+V (Cmd+V on macOS) and Shift+Insert. GLFW sends no character
	// event for a Ctrl/Cmd chord, so the 'v' never reaches the loop above.
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) ||
		rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if (ctrl && rl.IsKeyPressed(.V)) || (shift && rl.IsKeyPressed(.INSERT)) {
		netplay_addr_paste(nl, string(rl.GetClipboardText()))
	}
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
		if nl.addr_default {
			nl.addr_len, nl.addr_default = 0, false
		} else if nl.addr_len > 0 {
			nl.addr_len -= 1
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		nl.phase = .Menu
		nl.error = ""
		return
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		if nl.addr_len == 0 {
			nl.error = "enter an address first"
		} else {
			nl.phase, nl.error = .Resolving, ""
		}
	}
}

// Typing or pasting over the untouched prefill replaces it, as if it were
// selected -- otherwise a pasted address lands after "127.0.0.1".
@(private = "file")
netplay_addr_take_default :: proc(nl: ^Netplay) {
	if nl.addr_default {
		nl.addr_len, nl.addr_default = 0, false
	}
}

@(private = "file")
netplay_addr_append :: proc(nl: ^Netplay, c: rune) {
	if c < 0x20 || c > 0x7e {
		return
	}
	netplay_addr_take_default(nl)
	if nl.addr_len < NETPLAY_ADDR_MAX {
		nl.addr_buf[nl.addr_len] = u8(c)
		nl.addr_len += 1
	}
}

// Surrounding whitespace is dropped -- a copied address usually brings a
// trailing newline -- and anything still not printable ASCII is skipped.
// Text that will not fit is refused whole rather than silently truncated
// into a different address.
@(private = "file")
netplay_addr_paste :: proc(nl: ^Netplay, clip: string) {
	text := strings.trim_space(clip)
	if text == "" {
		return
	}
	room := nl.addr_default ? NETPLAY_ADDR_MAX : NETPLAY_ADDR_MAX - nl.addr_len
	if len(text) > room {
		nl.error = "pasted text is too long for an address"
		return
	}
	for i in 0 ..< len(text) {
		netplay_addr_append(nl, rune(text[i]))
	}
	nl.error = ""
}

@(private = "file")
netplay_join :: proc(nl: ^Netplay, text: string) {
	ep, rerr := net.resolve(text)
	switch rerr {
	case .None:
	case .Bad_Address:
		nl.error = "that is not a valid address or hostname"
		return
	case .No_IP4:
		nl.error = "IPv6 is not supported -- use an IPv4 address or hostname"
		return
	case .Not_Found:
		nl.error = "could not find that host"
		return
	}
	if ep.port == 0 {
		ep.port = NETPLAY_PORT // "host" with no port -- assume the same fixed port every host binds to
	}
	sock, sok := net.open(0) // ephemeral local port; only the host needs a fixed, agreed one
	if !sok {
		nl.error = "could not open a socket"
		return
	}
	nl.sock, nl.have_sock = sock, true
	nl.role = .Guest
	nl.peer, nl.have_peer = ep, true
	net.reliable_init(&nl.rc, ep)
	net.send_hello(&nl.rc, &nl.sock, 1, u16(nl.local_hue), prefs.name_string(&nl.local_name)) // guest is always player 1; see netplay_start_hosting/netplay_poll for the host's player 0
	nl.sent_own_hello = true
	nl.phase = .Connecting
	nl.error = ""
}

@(private = "file")
netplay_update_connecting :: proc(nl: ^Netplay, r: ^Renderer) {
	// Cancels hosting (still waiting for anyone) or joining, back to the
	// lobby menu -- the screen has always said "ESC TO CANCEL", but nothing
	// read it. Same exit as the Connected screen's Escape; the Goodbye only
	// goes out if there is a peer to tell.
	if rl.IsKeyPressed(.ESCAPE) {
		netplay_disconnect(nl)
		netplay_build_buttons(nl, r)
		return
	}
	if nl.have_peer {
		if !net.reliable_tick(&nl.rc, &nl.sock) {
			netplay_fail(nl, "connection timed out")
			return
		}
	}
	handshake_done := nl.have_peer && nl.got_peer_hello && nl.sent_own_hello && !nl.rc.pending
	if handshake_done {
		nl.phase = .Connected
		fmt.eprintfln("netplay: connected as %v, playing with %q (accent hue %d)", nl.role, prefs.name_string(&nl.peer_name), nl.peer_hue) // tools/netplay/loopback_check.sh greps for "netplay: connected as"
	}
}

@(private = "file")
netplay_update_connected :: proc(fl: ^Flow, nl: ^Netplay, r: ^Renderer) {
	if !net.reliable_tick(&nl.rc, &nl.sock) {
		netplay_fail(nl, "connection timed out")
		return
	}
	netplay_tick_ping(nl)

	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()

	// Host picks the level; the guest only ever mirrors nl.level_index via
	// an inbound Level_Choice (netplay_poll). "Readying locks in any options
	// the client has made" (notes/netcode-enhancements.md) -- once
	// local_ready is set, the nav buttons stop responding.
	if nl.role == .Host && !nl.local_ready {
		n := len(fl.defs.levels)
		if text_button_update(r, &nl.level_prev, mouse, dt) {
			nl.level_index = (nl.level_index - 1 + n) % n
		}
		if text_button_update(r, &nl.level_next, mouse, dt) {
			nl.level_index = (nl.level_index + 1) % n
		}
	}
	if nl.role == .Host {
		buf: [2]byte
		lcn := net.encode_level_choice(buf[:], u8(nl.level_index))
		net.send(&nl.sock, nl.peer, buf[:lcn])
	}

	// Host can't ready up on a level it hasn't unlocked (own local progress
	// -- notes/netcode-enhancements.md). The guest is not gated by its own
	// progress on the host's chosen level: the notes only specify the host
	// side of this, and a guest playing ahead of its own single-player
	// progress in a co-op session the host already vouches for is not a new
	// problem this stage needs to solve.
	host_locked := nl.role == .Host && nl.level_index >= fl.highest_reached
	if !nl.local_ready && hue_slider_update(&nl.local_hue, accent_slider_rect(), true) {
		nl.hue_dirty = true
	}
	if !nl.local_ready && !host_locked && text_button_update(r, &nl.ready_btn, mouse, dt) {
		nl.local_ready = true
		nl.ready_unsent = true
	}
	if !nl.rc.pending {
		if nl.hue_dirty {
			nl.hue_dirty = false
			net.send_hello(&nl.rc, &nl.sock, nl.role == .Host ? 0 : 1, u16(nl.local_hue), prefs.name_string(&nl.local_name))
			if extra_value(fl.prefs, .Accent_Hue) != nl.local_hue {
				fl.prefs.saved.extras[.Accent_Hue] = nl.local_hue
				prefs_state_save(fl.prefs)
			}
		} else if nl.ready_unsent {
			nl.ready_unsent = false
			net.send_ready(&nl.rc, &nl.sock)
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		net.send_goodbye(&nl.rc, &nl.sock)
		netplay_reset(nl)
		netplay_build_buttons(nl, r)
		return
	}

	if nl.role == .Host && nl.local_ready && !nl.ready_unsent && nl.remote_ready && !nl.rc.pending {
		seed := flow_random_seed()
		nl.start_seed, nl.start_level = seed, u8(nl.level_index)
		net.send_start(&nl.rc, &nl.sock, seed, nl.start_level)
		nl.phase = .Starting
	}
}

@(private = "file")
netplay_update_starting :: proc(nl: ^Netplay) {
	if !net.reliable_tick(&nl.rc, &nl.sock) {
		netplay_fail(nl, "peer vanished before the session could start")
		return
	}
	netplay_tick_ping(nl)
	// Host only reaches this phase. It already knows the seed/level it
	// picked (nl.start_seed/start_level, set in netplay_update_connected),
	// so it does not wait to *receive* a Start the way the guest does in
	// netplay_poll -- it just waits for its own Start to be acked
	// (rc.pending going false) before setting the same pending_start flag
	// the guest's inbound-Start handling sets, so both sides begin through
	// the one netplay_begin_session call site in netplay_lobby_update.
	if !nl.rc.pending {
		nl.pending_start = true
	}
}

@(private = "file")
netplay_tick_ping :: proc(nl: ^Netplay) {
	nl.ping_timer += rl.GetFrameTime()
	if nl.ping_timer < NETPLAY_PING_INTERVAL || nl.awaiting_pong {
		return
	}
	nl.ping_timer = 0
	nl.ping_nonce += 1
	buf: [9]byte
	n := net.encode_ping(buf[:], nl.ping_nonce)
	net.send(&nl.sock, nl.peer, buf[:n])
	nl.ping_sent_at = time.now()
	nl.awaiting_pong = true
}

@(private = "file")
netplay_fail :: proc(nl: ^Netplay, msg: string) {
	netplay_reset(nl)
	nl.error = msg
}

// Drains every packet waiting on the socket, regardless of nl.phase -- a
// Ready or Start sent by the peer the instant it reaches Connected/Starting
// must not be lost just because this side has not reached that phase yet
// (net/reliable.odin's stop-and-wait would otherwise keep retrying it until
// this side finally polls for it, which works, but only if polling itself
// is unconditional).
@(private = "file")
netplay_poll :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	// Sized for the biggest packet on the wire, State_Chunk's 3-byte header
	// plus a full STATE_CHUNK_SIZE payload (Phase 8 stage 4) -- everything
	// else fits in a fraction of this.
	buf: [net.STATE_CHUNK_SIZE + 16]byte
	for {
		n, from, ok := net.poll_recv(&nl.sock, buf[:])
		if !ok {
			break
		}
		if nl.have_peer && from != nl.peer {
			continue // a stray packet from anyone but our one peer
		}
		if nl.have_peer {
			nl.last_peer_seen = time.now() // Phase 8 stage 3: any packet at all counts as proof of life
		}
		kind, kok := net.peek_kind(buf[:n])
		if !kok {
			continue
		}
		switch kind {
		case .Hello:
			seq, _, peer_hue, peer_name, hok := net.decode_hello(buf[:n]) // the peer's player index isn't needed: role/local_player are fixed by who hosted vs. joined, or -- reconnecting -- by Resync_Start's assigned_player
			if !hok {
				continue
			}
			// Phase 8 stage 4: a Hello arriving while Waiting_Reconnect is a
			// fresh peer reconnecting, exactly like the very first Hello a
			// listening host ever sees -- same have_peer/reliable_init setup,
			// just possibly later in the program's life.
			reconnecting := nl.link_state == .Waiting_Reconnect
			if !nl.have_peer {
				nl.peer, nl.have_peer = from, true
				net.reliable_init(&nl.rc, from)
			}
			is_new := net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq)
			if is_new {
				nl.got_peer_hello = true
				prefs.name_set(&nl.peer_name, peer_name)
				nl.peer_hue = prefs.hue_wrap(int(peer_hue))
				if reconnecting {
					// Whoever rejoins takes over the vacated player, and
					// their score is recorded under their own name.
					fl.session_names[1 - nl.rs.local_player] = nl.peer_name
					fl.session_hues[1 - nl.rs.local_player] = nl.peer_hue
				}
			}
			if (nl.role == .Host || reconnecting) && !nl.sent_own_hello {
				net.send_hello(&nl.rc, &nl.sock, 0, u16(nl.local_hue), prefs.name_string(&nl.local_name)) // unused by the receiver either way -- see the comment above
				nl.sent_own_hello = true
			}
			if reconnecting && is_new {
				netplay_begin_resync_send(fl, nl)
			}
		case .Ack:
			net.reliable_handle_ack(&nl.rc, buf[:n])
		case .Ready:
			seq, rok := net.decode_ready(buf[:n])
			if !rok || !nl.have_peer {
				continue
			}
			if net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq) {
				nl.remote_ready = true
			}
		case .Start:
			seq, seed, level, sok := net.decode_start(buf[:n])
			if !sok || !nl.have_peer {
				continue
			}
			if net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq) {
				nl.pending_start = true
				nl.start_seed, nl.start_level = seed, level
			}
		case .Goodbye:
			seq, gok := net.decode_goodbye(buf[:n])
			if !gok || !nl.have_peer {
				continue
			}
			_ = net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq)
			// Phase 8 stage 3: a clean Goodbye mid-session (peer chose to
			// leave, rather than just going quiet) freezes exactly like a
			// timeout would -- same "pause on disconnect", just noticed
			// immediately instead of after NETPLAY_LIVE_TIMEOUT. A Goodbye
			// from the lobby (never reached .Playing) is unchanged: still a
			// full reset back to the lobby menu.
			if fl.netplay_active {
				netplay_enter_waiting_reconnect(nl)
				nl.error = "peer disconnected"
				return
			}
			netplay_reset(nl)
			nl.error = "peer disconnected"
			netplay_build_buttons(nl, r)
			return
		case .Level_Choice:
			if idx, lok := net.decode_level_choice(buf[:n]); lok {
				nl.level_index = int(idx)
			}
		case .Resync_Start:
			seq, assigned, total, rok := net.decode_resync_start(buf[:n])
			if !rok || !nl.have_peer {
				continue
			}
			if net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq) {
				nl.resync_incoming_total = total
				nl.resync_incoming_player = assigned
				nl.pending_resync_start = true
			}
		case .State_Chunk:
			if nl.link_state != .Resync_Receiving {
				continue
			}
			pkt, cok := net.decode_state_chunk(buf[:n])
			if !cok || int(pkt.chunk_index) >= nl.recv_chunks {
				continue
			}
			// Chunks can arrive out of order now that the sender bursts
			// several per frame instead of waiting on one ack at a time
			// (see netplay_resync_send_tick) -- accept any not-yet-applied
			// index rather than only the next in-sequence one.
			if !nl.recv_got[pkt.chunk_index] {
				off := int(pkt.chunk_index) * net.STATE_CHUNK_SIZE
				copy(nl.recv_buf[off:], pkt.payload[:pkt.length])
				nl.recv_got[pkt.chunk_index] = true
				nl.recv_got_count += 1
				nl.recv_last_progress = time.now()
			}
			// Ack regardless of whether this was new or a resend of a chunk
			// already applied -- the sender only clears a chunk from its
			// unacked set once, so a duplicate ack is simply a no-op there.
			ackbuf: [3]byte
			an := net.encode_state_chunk_ack(ackbuf[:], pkt.chunk_index)
			net.send(&nl.sock, from, ackbuf[:an])
			if nl.recv_got_count >= nl.recv_chunks {
				netplay_finish_resync_receive(fl, nl)
			}
		case .State_Chunk_Ack:
			if nl.link_state != .Resync_Sending {
				continue
			}
			idx, aok := net.decode_state_chunk_ack(buf[:n])
			if !aok || int(idx) >= nl.resync_chunks {
				continue
			}
			if !nl.resync_acked[idx] {
				nl.resync_acked[idx] = true
				nl.resync_acked_count += 1
				nl.resync_last_progress = time.now()
			}
			if nl.resync_acked_count >= nl.resync_chunks {
				netplay_finish_resync_send(nl)
			}
		case .Ping:
			nonce, pok := net.decode_ping(buf[:n])
			if !pok {
				continue
			}
			pbuf: [9]byte
			pn := net.encode_pong(pbuf[:], nonce)
			net.send(&nl.sock, from, pbuf[:pn])
		case .Pong:
			nonce, pok := net.decode_pong(buf[:n])
			if !pok || !nl.awaiting_pong || nonce != nl.ping_nonce {
				continue
			}
			nl.ping_ms = f32(time.duration_milliseconds(time.since(nl.ping_sent_at)))
			nl.awaiting_pong = false
		case .Input:
			if fl.netplay_active {
				if pkt, iok := net.decode_input(buf[:n]); iok {
					net.rollback_session_receive(&nl.rs, pkt)
				}
			}
		case .Checksum:
			if fl.netplay_active {
				if frame, sum, cok := net.decode_checksum(buf[:n]); cok {
					net.desync_monitor_receive(&nl.desync, frame, sum)
					if nl.desync.desynced && !nl.warned_desync {
						nl.warned_desync = true
						fmt.eprintfln("netplay: desync detected at frame %v", nl.desync.desync_frame)
					}
				}
			}
		}
	}
}

@(private = "file")
netplay_begin_session :: proc(fl: ^Flow, nl: ^Netplay, seed: u32, level_index: int) {
	level_index := level_index
	if level_index < 0 || level_index >= len(fl.defs.levels) {
		level_index = 0
	}
	level := fl.defs.levels[level_index].id
	sim.init(fl.state, sim.Session{seed = seed, level_id = level, game_type = .Co_Op}, fl.defs)
	local_player := nl.role == .Host ? 0 : 1
	net.rollback_session_init(&nl.rs, fl.state, local_player)
	netplay_name_session(fl, nl, local_player)
	nl.desync = {}
	nl.warned_desync = false
	nl.link_state = .Live
	nl.last_peer_seen = time.now()
	fl.session_start_pos = level_index + 1
	fl.netplay_active = true
	fl.mode = .Playing
	fmt.eprintfln("netplay: session started as player %d, seed %d, level %d", local_player, seed, level_index) // tools/netplay/loopback_check.sh greps for this
}

// Which name each player's score is recorded under at the end.
@(private = "file")
netplay_name_session :: proc(fl: ^Flow, nl: ^Netplay, local_player: int) {
	fl.session_names[local_player] = nl.local_name
	fl.session_names[1 - local_player] = nl.peer_name
	fl.session_hues[local_player] = nl.local_hue
	fl.session_hues[1 - local_player] = nl.peer_hue
	fl.session_named = true
}

// Phase 8 stage 3: the peer has gone quiet mid-session. Rather than tearing
// the session down, rebind to the well-known NETPLAY_PORT (regardless of
// whether this side was originally Host or Guest -- see docs/decisions.md)
// so a reconnecting client can always just use the ordinary "Join Game" flow
// against this machine's address, with no special foreknowledge of who
// survived. The Rollback_Session and fl.state are left completely alone:
// net/session.odin operates purely in terms of state.frame, so simulation
// can resume exactly where it was once a peer reappears, with no rewind.
@(private = "file")
netplay_enter_waiting_reconnect :: proc(nl: ^Netplay) {
	if nl.have_sock {
		net.close(&nl.sock)
	}
	nl.have_sock = false
	if sock, ok := net.open(NETPLAY_PORT); ok {
		nl.sock, nl.have_sock = sock, true
	}
	nl.have_peer = false
	nl.got_peer_hello = false
	nl.sent_own_hello = false
	nl.rc = {}
	nl.link_state = .Waiting_Reconnect
	fmt.eprintfln("netplay: peer lost, waiting for a reconnect on port %d", NETPLAY_PORT)
}

// Phase 8 stage 4, survivor side: a fresh Hello arrived while
// Waiting_Reconnect. Snapshots fl.state as raw bytes (its pointer fields --
// defs, level, events -- travel as garbage and are fixed up on the other end
// from values that do survive the copy, session.level_id chief among them;
// see netplay_finish_resync_receive) and starts streaming it over as
// State_Chunk packets.
@(private = "file")
netplay_begin_resync_send :: proc(fl: ^Flow, nl: ^Netplay) {
	nl.resync_peer = nl.peer
	assigned := u8(1 - nl.rs.local_player)
	nl.resync_total = size_of(sim.State)
	nl.resync_buf = make([]byte, nl.resync_total)
	mem.copy(raw_data(nl.resync_buf), fl.state, nl.resync_total)
	nl.resync_chunks = (nl.resync_total + net.STATE_CHUNK_SIZE - 1) / net.STATE_CHUNK_SIZE
	nl.resync_acked = make([]bool, nl.resync_chunks)
	nl.resync_acked_count = 0
	nl.resync_last_progress = time.now()
	nl.link_state = .Resync_Sending
	net.send_resync_start(&nl.rc, &nl.sock, assigned, u32(nl.resync_total))
	// The first burst goes out right away rather than waiting for
	// netplay_playing_poll's next call -- see netplay_resync_send_tick.
	netplay_resync_send_tick(nl)
}

@(private = "file")
netplay_send_chunk :: proc(nl: ^Netplay, index: int) {
	start := index * net.STATE_CHUNK_SIZE
	end := min(start + net.STATE_CHUNK_SIZE, nl.resync_total)
	buf: [3 + net.STATE_CHUNK_SIZE]byte
	n := net.encode_state_chunk(buf[:], u16(index), nl.resync_buf[start:end])
	net.send(&nl.sock, nl.resync_peer, buf[:n])
}

// Called every render frame while link_state == .Resync_Sending
// (netplay_playing_poll). Rather than one chunk per round trip (which
// bottlenecks a 655-chunk transfer on the frame rate, taking tens of
// seconds even on loopback -- measured during this stage's own smoke test),
// resends every still-unacked chunk, capped at STATE_CHUNK_BURST per call:
// a lost or slow-to-ack chunk just gets included again next frame, so "one
// render frame" is this scheme's retry interval rather than a per-chunk
// timer. Redundant sends for a chunk whose ack simply hasn't arrived yet are
// harmless -- the receiver already has that byte range and just re-acks it.
@(private = "file")
netplay_resync_send_tick :: proc(nl: ^Netplay) {
	if time.since(nl.resync_last_progress) > STATE_RESYNC_TIMEOUT {
		// No ack at all in a long time -- the rejoining client vanished too;
		// give up this attempt and keep waiting for another.
		netplay_enter_waiting_reconnect(nl)
		return
	}
	sent := 0
	for i in 0 ..< nl.resync_chunks {
		if nl.resync_acked[i] {
			continue
		}
		netplay_send_chunk(nl, i)
		sent += 1
		if sent >= STATE_CHUNK_BURST {
			break
		}
	}
}

@(private = "file")
netplay_finish_resync_send :: proc(nl: ^Netplay) {
	delete(nl.resync_buf)
	nl.resync_buf = nil
	delete(nl.resync_acked)
	nl.resync_acked = nil
	nl.peer = nl.resync_peer
	nl.have_peer = true
	nl.link_state = .Live
	nl.last_peer_seen = time.now()
	fmt.eprintfln("netplay: resync sent, resuming as player %d", nl.rs.local_player)
}

// Phase 8 stage 4, reconnecting side: a Resync_Start was accepted
// (netplay_poll), consumed here from netplay_lobby_update the same way
// pending_start is. fl.mode stays .Netplay_Lobby -- see netplay_lobby_draw's
// Resync_Receiving status line -- until the transfer completes.
@(private = "file")
netplay_begin_resync_receive :: proc(nl: ^Netplay) {
	nl.link_state = .Resync_Receiving
	nl.recv_total = int(nl.resync_incoming_total)
	nl.recv_chunks = (nl.recv_total + net.STATE_CHUNK_SIZE - 1) / net.STATE_CHUNK_SIZE
	nl.recv_got = make([]bool, nl.recv_chunks)
	nl.recv_got_count = 0
	nl.recv_assigned_player = nl.resync_incoming_player
	nl.recv_buf = make([]byte, nl.recv_total)
	nl.recv_last_progress = time.now()
}

// Raw byte-for-byte restore of fl.state, then the pointer fixup: defs is
// this process's own (never sent), level is re-resolved from the
// session.level_id value that *did* survive the copy (sim.level_by_id --
// the same lookup sim.init itself uses), and events (debug-only, always nil
// in normal play) is force-nilled rather than trusted as a live pointer from
// the sender's address space.
@(private = "file")
netplay_finish_resync_receive :: proc(fl: ^Flow, nl: ^Netplay) {
	mem.copy(fl.state, raw_data(nl.recv_buf), nl.recv_total)
	fl.state.defs = fl.defs
	fl.state.level = sim.level_by_id(fl.defs, fl.state.session.level_id)
	fl.state.events = nil
	delete(nl.recv_buf)
	nl.recv_buf = nil
	delete(nl.recv_got)
	nl.recv_got = nil

	net.rollback_session_init(&nl.rs, fl.state, int(nl.recv_assigned_player))
	netplay_name_session(fl, nl, int(nl.recv_assigned_player))
	nl.desync = {}
	nl.warned_desync = false
	fl.netplay_active = true
	fl.mode = .Playing
	nl.link_state = .Live
	nl.last_peer_seen = time.now()
	fmt.eprintfln("netplay: reconnected as player %d at frame %d", nl.recv_assigned_player, fl.state.frame) // tools/netplay/loopback_check.sh-style marker for a future reconnect smoke check
}

// Phase 8 stage 3: bottom-right/banner text for a frozen .Playing session --
// title == "" means link_state == .Live and the caller should draw nothing.
// Kept here rather than in flow.odin so flow.odin does not need to import
// dr:net purely to read a progress percentage.
netplay_disconnect_banner :: proc(nl: ^Netplay) -> (title, sub: cstring) {
	switch nl.link_state {
	case .Live, .Resync_Receiving: // Resync_Receiving never applies to a .Playing session -- see netplay_begin_resync_receive
		return "", ""
	case .Waiting_Reconnect:
		return "DISCONNECTED", "WAITING FOR CONNECTIONS -- ESC TO EXIT, F5 TO CONTINUE ALONE"
	case .Resync_Sending:
		pct := nl.resync_chunks > 0 ? nl.resync_acked_count * 100 / nl.resync_chunks : 0
		return "RECONNECTING PEER", fmt.ctprintf("SENDING GAME STATE... %d%% -- ESC TO EXIT, F5 TO CONTINUE ALONE", pct)
	}
	return "", ""
}

// Called from flow_handle_input's .Playing case, every render frame,
// whenever Flow.netplay_active -- network I/O runs at render rate exactly
// like the lobby's own polling, independent of how many (0-4) fixed sim
// steps flow_step runs this frame.
netplay_playing_poll :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	netplay_poll(fl, r, nl)
	switch nl.link_state {
	case .Live:
		// Phase 8 stage 3: no packet (Input, Checksum, Ping/Pong, ...) from
		// the peer in NETPLAY_LIVE_TIMEOUT means it's gone -- freeze rather
		// than let rollback's prediction window run out and desync forward.
		if time.since(nl.last_peer_seen) > NETPLAY_LIVE_TIMEOUT {
			netplay_enter_waiting_reconnect(nl)
		}
	case .Waiting_Reconnect:
	// Nothing to drive here -- reliable_tick only matters once a fresh
	// Hello has set up a Resync_Start to retry (Resync_Sending, below).
	case .Resync_Sending:
		if !net.reliable_tick(&nl.rc, &nl.sock) {
			// Resync_Start itself never got acked -- this reconnect attempt
			// is dead too; keep waiting for another.
			netplay_enter_waiting_reconnect(nl)
		} else {
			netplay_resync_send_tick(nl)
		}
	case .Resync_Receiving:
	// Never reached here -- see netplay_begin_resync_receive's comment.
	}
}

// Phase 8 stage 5: true on a tick this client should sit out entirely (no
// sim advance, no input/checksum send) so the peer's simulation -- confirmed
// behind via net.rollback_session_frame_advantage -- gets a chance to close
// the gap rather than the rollback prediction window (and with it,
// misprediction risk) growing without bound. Skipping a tick outright rather
// than inserting a real-time sleep keeps this in the same fixed-step
// accumulator flow.odin already drives, at the cost of this client's
// simulation rate visibly dipping while it stalls -- exactly the "increase
// the duration of its updates" the notes ask for. The actual threshold/
// throttle math lives in net.rollback_session_should_stall so it can be unit
// tested without a live socket or render loop.
@(private = "file")
netplay_should_stall :: proc(nl: ^Netplay) -> bool {
	return net.rollback_session_should_stall(&nl.rs, NETPLAY_SYNC_STALL_THRESHOLD, NETPLAY_SYNC_MIN_STALL_EVERY)
}

// Called from flow.odin's .Playing branch of flow_step, once per fixed sim
// tick, instead of the single-player gather_input()+sim.step path.
netplay_playing_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, nl: ^Netplay) {
	if netplay_should_stall(nl) {
		return
	}

	local := gather_input(&fl.prefs.saved.bindings[0]) // this machine's player, whichever slot it plays
	// Pause is an input bit (sim.session_step), so it reaches the peer
	// like any button and both sides pause on the same frame. Held while
	// the key is, or for a Resume click's short pulse.
	if rl.IsKeyDown(.ESCAPE) || nl.pause_pulse > 0 { // plus the Pause binding, via gather_input
		local += {.Pause}
	}
	nl.pause_pulse = max(nl.pause_pulse - 1, 0)
	net.rollback_session_advance(&nl.rs, local)
	// While paused nothing moves; existing particles and ghosts freeze too.
	if !fl.state.paused {
		particles_step(particles, fl.state)
		blurs_step(blurs, fl.state)
		notices_step(notices, fl.state)
	}
	sounds_step(&r.textures, fl.state)

	win: [NETPLAY_INPUT_WINDOW]sim.Buttons
	start, count := net.rollback_session_local_window(&nl.rs, NETPLAY_INPUT_WINDOW, win[:])
	if count > 0 {
		buf: [8 + NETPLAY_INPUT_WINDOW * 2]byte
		n := net.encode_input(buf[:], u8(nl.rs.local_player), start, win[:count])
		net.send(&nl.sock, nl.peer, buf[:n])
	}

	if fl.state.frame >= NETPLAY_CHECKSUM_LAG {
		cf := fl.state.frame - NETPLAY_CHECKSUM_LAG
		if sum, ok := net.rollback_session_checksum_at(&nl.rs, cf); ok {
			net.desync_monitor_record(&nl.desync, cf, sum)
			buf: [13]byte
			n := net.encode_checksum(buf[:], cf, sum)
			net.send(&nl.sock, nl.peer, buf[:n])
		}
	}
}

// Escape during a live netplay session (flow_handle_input's .Playing case):
// unlike single-player, there is no local-only pause -- freezing this
// machine's rendering would not stop input still arriving from the peer,
// so Escape disconnects outright rather than pretending to pause a session
// the other side is still playing.
netplay_disconnect :: proc(nl: ^Netplay) {
	if nl.have_sock && nl.have_peer {
		net.send_goodbye(&nl.rc, &nl.sock)
	}
	netplay_reset(nl)
}

netplay_lobby_draw :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	menu_draw_background(r, "back") // no original screen to match; reused purely for visual consistency with the rest of this menu family
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	bad := rl.Color{230, 90, 90, 255}

	menu_draw_text(r, "NETPLAY", SCREEN_W / 2, 130, white, .Centre)

	// Phase 8 stage 4: a reconnecting client's chunk transfer runs while
	// nl.phase is still whatever the ordinary handshake left it at
	// (typically .Connected) -- shown here instead of the phase switch below
	// so it overrides that screen rather than drawing underneath it.
	if nl.link_state == .Resync_Receiving {
		pct := nl.recv_chunks > 0 ? nl.recv_got_count * 100 / nl.recv_chunks : 0
		menu_draw_text(r, fmt.tprintf("RECONNECTING -- RECEIVING GAME STATE... %d%%", pct), SCREEN_W / 2, 220, white, .Centre)
		return
	}

	switch nl.phase {
	case .Menu:
		text_button_draw(r, &nl.menu_host)
		text_button_draw(r, &nl.menu_join)
		text_button_draw(r, &nl.menu_back)
		if nl.error != "" {
			menu_draw_text(r, nl.error, SCREEN_W / 2, 340, bad, .Centre)
		}
	case .Enter_Name:
		menu_draw_text(r, "ENTER YOUR NAME, THEN PRESS ENTER", SCREEN_W / 2, 200, dim, .Centre)
		menu_draw_text(r, "HIGH SCORES ARE RECORDED UNDER IT", SCREEN_W / 2, 215, dim, .Centre)
		name := prefs.name_string(&nl.local_name)
		if nl.local_name.len < prefs.NAME_MAX && int(rl.GetTime() * 2) % 2 == 0 {
			name = fmt.tprintf("%s_", name)
		}
		menu_draw_text(r, name, SCREEN_W / 2, 240, accent_color(nl.local_hue), .Centre)
		menu_draw_text(r, "ESC TO CANCEL", SCREEN_W / 2, 270, dim, .Centre)
		if nl.error != "" {
			menu_draw_text(r, nl.error, SCREEN_W / 2, 340, bad, .Centre)
		}
	case .Enter_Address:
		menu_draw_text(r, "JOIN -- ENTER HOST ADDRESS, THEN PRESS ENTER", SCREEN_W / 2, 200, dim, .Centre)
		menu_draw_text(r, string(nl.addr_buf[:nl.addr_len]), SCREEN_W / 2, 230, nl.addr_default ? dim : white, .Centre)
		menu_draw_text(r, "CTRL+V TO PASTE -- ESC TO CANCEL", SCREEN_W / 2, 300, dim, .Centre)
		if nl.error != "" {
			menu_draw_text(r, nl.error, SCREEN_W / 2, 340, bad, .Centre)
		}
	case .Resolving:
		menu_draw_text(r, "RESOLVING", SCREEN_W / 2, 200, dim, .Centre)
		menu_draw_text(r, string(nl.addr_buf[:nl.addr_len]), SCREEN_W / 2, 230, white, .Centre)
	case .Connecting:
		msg := nl.role == .Host ? "WAITING FOR A PLAYER TO CONNECT..." : "CONNECTING..."
		menu_draw_text(r, msg, SCREEN_W / 2, 220, white, .Centre)
		if nl.role == .Host {
			menu_draw_text(r, fmt.tprintf("GIVE THIS MACHINE'S ADDRESS AND PORT %d TO THE OTHER PLAYER", NETPLAY_PORT),
				SCREEN_W / 2, 250, dim, .Centre)
		}
		menu_draw_text(r, "ESC TO CANCEL", SCREEN_W / 2, 300, dim, .Centre)
	case .Connected, .Starting:
		menu_draw_text(r, "CONNECTED", SCREEN_W / 2, 220, white, .Centre)
		if nl.ping_ms > 0 {
			menu_draw_text(r, fmt.tprintf("PING %.0f MS", nl.ping_ms), SCREEN_W / 2, 245, dim, .Centre)
		}

		host_locked := nl.role == .Host && nl.level_index >= fl.highest_reached
		level := fl.defs.levels[nl.level_index]
		media := data.assets_level_media(&r.textures.assets, level.id)
		level_name := media != nil ? media.name : "?"
		level_label: string
		switch {
		case host_locked:
			level_label = "LEVEL: NO ACCESS"
		case nl.role == .Host:
			level_label = fmt.tprintf("LEVEL: %s", level_name)
		case:
			level_label = fmt.tprintf("HOST HAS CHOSEN: %s", level_name)
		}
		menu_draw_text(r, level_label, SCREEN_W / 2, 262, host_locked ? bad : white, .Centre)
		if nl.role == .Host && !nl.local_ready {
			text_button_draw(r, &nl.level_prev)
			text_button_draw(r, &nl.level_next)
		}

		you := fmt.tprintf("%s (YOU): %s", prefs.name_string(&nl.local_name), nl.local_ready ? "READY" : "NOT READY")
		them := fmt.tprintf("%s: %s", prefs.name_string(&nl.peer_name), nl.remote_ready ? "READY" : "NOT READY")
		// Each name in its player's accent, so the colours can be told
		// apart before the game starts.
		menu_draw_text(r, you, SCREEN_W / 2, 335, accent_color(nl.local_hue), .Centre)
		menu_draw_text(r, them, SCREEN_W / 2, 355, accent_color(nl.peer_hue), .Centre)
		if !nl.local_ready {
			menu_draw_text(r, "YOUR ACCENT COLOUR -- DRAG, OR LEFT/RIGHT", SCREEN_W / 2, ACCENT_SLIDER_Y - 18, dim, .Centre)
			hue_slider_draw(nl.local_hue, accent_slider_rect())
		}
		if !nl.local_ready {
			text_button_draw(r, &nl.ready_btn, !host_locked)
		} else if nl.phase == .Starting {
			menu_draw_text(r, "STARTING...", SCREEN_W / 2, 375, dim, .Centre)
		}
	}
}
