package game

// Phase 7 stage 6 / Phase 6 stage 5: the netplay lobby, and the glue that
// wires a connected session into Flow's .Playing mode. There is no original
// screen to trace here -- Phase 6's design note (docs/phase-6-netplay.md)
// deferred building this until Phase 7 established a menu visual language,
// so it borrows that language (Text_Button, menu_draw_text, the shared
// "back" background) without claiming to reproduce any specific original
// screen. New content only, per D21/mise.toml's --classic flag: reached
// from Main Menu's Preferences button, and only when !r.classic (see
// menu_main.odin).
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
import "core:time"

import core_net "core:net"
import rl "vendor:raylib"

import "dr:data"
import "dr:net"
import "dr:sim"

// Chosen from IANA's dynamic/private port range (49152-65535) to avoid
// colliding with a registered service; both peers just need to agree on the
// same number, which "both compiled from the same source" already gives us.
NETPLAY_PORT :: 54217

NETPLAY_PING_INTERVAL :: 1.0 // seconds between RTT probes once connected
NETPLAY_INPUT_WINDOW :: 8    // matches tests/rollback_session_test.odin's own WINDOW
NETPLAY_CHECKSUM_LAG :: 20   // frames behind "now" a checksum is reported at; matches the test, comfortably under ROLLBACK_DEPTH (64)
NETPLAY_ADDR_MAX :: 63

Netplay_Phase :: enum {
	Menu,          // choose Host or Join
	Enter_Address, // guest only: typing "host" or "host:port"
	Connecting,    // Hello sent (guest) or awaited (host), not yet both-ways confirmed
	Connected,     // handshake done; ready-up + ping display
	Starting,      // host: Start sent, waiting for its Ack before beginning
}

Netplay_Role :: enum {
	Host,
	Guest,
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

	addr_buf: [NETPLAY_ADDR_MAX]u8,
	addr_len: int,

	ping_nonce:    u64,
	ping_timer:    f32,
	awaiting_pong: bool,
	ping_sent_at:  time.Time,
	ping_ms:       f32,

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
}

// Closes the socket (if any) and zeroes every other field. Package-visible
// (not file-private) since flow.odin's flow_finish_session calls this too,
// to clean up a netplay match that ended normally rather than via Escape
// (netplay_disconnect) or a peer Goodbye (netplay_poll).
netplay_reset :: proc(nl: ^Netplay) {
	if nl.have_sock {
		net.close(&nl.sock)
	}
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
	case .Enter_Address:
		netplay_update_enter_address(nl, r)
	case .Connecting:
		netplay_update_connecting(nl)
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
}

@(private = "file")
netplay_update_menu :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	if text_button_update(&nl.menu_host, mouse, dt) {
		netplay_start_hosting(nl)
	}
	if text_button_update(&nl.menu_join, mouse, dt) {
		nl.phase = .Enter_Address
		nl.addr_len = copy(nl.addr_buf[:], "127.0.0.1") // loopback default -- the only peer this port can verify without a second machine
	}
	if text_button_update(&nl.menu_back, mouse, dt) || rl.IsKeyPressed(.ESCAPE) {
		fl.mode = .Title
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
netplay_lobby_start_from_flag :: proc(nl: ^Netplay, mode: string) {
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
		if c < 0x20 || c > 0x7e {
			continue
		}
		if nl.addr_len < NETPLAY_ADDR_MAX {
			nl.addr_buf[nl.addr_len] = u8(c)
			nl.addr_len += 1
		}
	}
	if rl.IsKeyPressed(.BACKSPACE) && nl.addr_len > 0 {
		nl.addr_len -= 1
	}
	if rl.IsKeyPressed(.ESCAPE) {
		nl.phase = .Menu
		nl.error = ""
		return
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		netplay_join(nl, string(nl.addr_buf[:nl.addr_len]))
	}
}

@(private = "file")
netplay_join :: proc(nl: ^Netplay, text: string) {
	ep, ok := net.resolve(text)
	if !ok {
		nl.error = "could not resolve that address"
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
	net.send_hello(&nl.rc, &nl.sock, 1) // guest is always player 1; see netplay_start_hosting/netplay_poll for the host's player 0
	nl.sent_own_hello = true
	nl.phase = .Connecting
	nl.error = ""
}

@(private = "file")
netplay_update_connecting :: proc(nl: ^Netplay) {
	if nl.have_peer {
		if !net.reliable_tick(&nl.rc, &nl.sock) {
			netplay_fail(nl, "connection timed out")
			return
		}
	}
	handshake_done := nl.have_peer && nl.got_peer_hello && nl.sent_own_hello && !nl.rc.pending
	if handshake_done {
		nl.phase = .Connected
		fmt.eprintfln("netplay: connected as %v", nl.role) // tools/netplay/loopback_check.sh greps for this
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
		if text_button_update(&nl.level_prev, mouse, dt) {
			nl.level_index = (nl.level_index - 1 + n) % n
		}
		if text_button_update(&nl.level_next, mouse, dt) {
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
	if !nl.local_ready && !host_locked && text_button_update(&nl.ready_btn, mouse, dt) {
		nl.local_ready = true
		net.send_ready(&nl.rc, &nl.sock)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		net.send_goodbye(&nl.rc, &nl.sock)
		netplay_reset(nl)
		netplay_build_buttons(nl, r)
		return
	}

	if nl.role == .Host && nl.local_ready && nl.remote_ready && !nl.rc.pending {
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
	buf: [256]byte
	for {
		n, from, ok := net.poll_recv(&nl.sock, buf[:])
		if !ok {
			break
		}
		if nl.have_peer && from != nl.peer {
			continue // a stray packet from anyone but our one peer
		}
		kind, kok := net.peek_kind(buf[:n])
		if !kok {
			continue
		}
		switch kind {
		case .Hello:
			seq, _, hok := net.decode_hello(buf[:n]) // the peer's player index isn't needed: role/local_player are fixed by who hosted vs. joined
			if !hok {
				continue
			}
			if !nl.have_peer {
				// Only a listening host reaches this: the first Hello it
				// ever sees names its peer's address and player slot.
				nl.peer, nl.have_peer = from, true
				net.reliable_init(&nl.rc, from)
			}
			is_new := net.reliable_accept(&nl.rc, &nl.sock, nl.peer, seq)
			if is_new {
				nl.got_peer_hello = true
			}
			if nl.role == .Host && !nl.sent_own_hello {
				net.send_hello(&nl.rc, &nl.sock, 0) // host is always player 0
				nl.sent_own_hello = true
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
			was_playing := fl.netplay_active
			netplay_reset(nl)
			nl.error = "peer disconnected"
			if was_playing {
				fl.netplay_active = false
				fl.mode = .Title
			} else {
				netplay_build_buttons(nl, r)
			}
			return
		case .Level_Choice:
			if idx, lok := net.decode_level_choice(buf[:n]); lok {
				nl.level_index = int(idx)
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
	nl.desync = {}
	nl.warned_desync = false
	fl.session_start_pos = level_index + 1
	fl.netplay_active = true
	fl.mode = .Playing
	fmt.eprintfln("netplay: session started as player %d, seed %d, level %d", local_player, seed, level_index) // tools/netplay/loopback_check.sh greps for this
}

// Called from flow_handle_input's .Playing case, every render frame,
// whenever Flow.netplay_active -- network I/O runs at render rate exactly
// like the lobby's own polling, independent of how many (0-4) fixed sim
// steps flow_step runs this frame.
netplay_playing_poll :: proc(fl: ^Flow, r: ^Renderer, nl: ^Netplay) {
	netplay_poll(fl, r, nl)
}

// Called from flow.odin's .Playing branch of flow_step, once per fixed sim
// tick, instead of the single-player gather_input()+sim.step path.
netplay_playing_step :: proc(fl: ^Flow, r: ^Renderer, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, nl: ^Netplay) {
	local := gather_input()
	net.rollback_session_advance(&nl.rs, local)
	particles_step(particles, fl.state)
	blurs_step(blurs, fl.state)
	notices_step(notices, fl.state)
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
	good := rl.Color{110, 220, 140, 255}

	menu_draw_text(r, "NETPLAY", SCREEN_W / 2, 130, white, .Centre)

	switch nl.phase {
	case .Menu:
		text_button_draw(r, &nl.menu_host)
		text_button_draw(r, &nl.menu_join)
		text_button_draw(r, &nl.menu_back)
		if nl.error != "" {
			menu_draw_text(r, nl.error, SCREEN_W / 2, 340, bad, .Centre)
		}
	case .Enter_Address:
		menu_draw_text(r, "JOIN -- ENTER HOST ADDRESS, THEN PRESS ENTER", SCREEN_W / 2, 200, dim, .Centre)
		menu_draw_text(r, string(nl.addr_buf[:nl.addr_len]), SCREEN_W / 2, 230, white, .Centre)
		menu_draw_text(r, "ESC TO CANCEL", SCREEN_W / 2, 300, dim, .Centre)
		if nl.error != "" {
			menu_draw_text(r, nl.error, SCREEN_W / 2, 340, bad, .Centre)
		}
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

		you := nl.local_ready ? "YOU: READY" : "YOU: NOT READY"
		them := nl.remote_ready ? "OTHER PLAYER: READY" : "OTHER PLAYER: NOT READY"
		menu_draw_text(r, you, SCREEN_W / 2, 335, nl.local_ready ? good : dim, .Centre)
		menu_draw_text(r, them, SCREEN_W / 2, 355, nl.remote_ready ? good : dim, .Centre)
		if !nl.local_ready {
			text_button_draw(r, &nl.ready_btn, !host_locked)
		} else if nl.phase == .Starting {
			menu_draw_text(r, "STARTING...", SCREEN_W / 2, 375, dim, .Centre)
		}
	}
}
