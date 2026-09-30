package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import net "dr:net"
import "dr:plugins/new_weapons"
import "dr:sim"

// The other player's Discharge Beam in netplay. The beam does not
// auto-repeat, so every pulse is a new press, which the peer's prediction
// (the last buttons it had) never guesses: the step that fires it is one a
// rollback replays, once the latency is longer than the wind-up. The view draws the beams kept in the session's
// Beam_Log (plugins/new_weapons/beam.odin), so after the replay the host
// must hold the guest's beams, fired on the same steps as the guest's own.
// Before they were kept, the host never drew them. Skipped without the
// assets tree.
@(test)
netplay_peer_keeps_the_other_players_beams :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") || !os.exists("plugins/new_weapons/data") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	context.allocator = alloc // the states' worlds go in the arena too
	defs, _ := data.assets_defs_load("assets", alloc)
	if _, ok := data.extra_defs_load(&defs, alloc); !testing.expect(t, ok) {
		return
	}
	db := -1
	for &w, i in defs.weapons {
		if w.id == sim.res_id("aidb") {
			db = i
		}
	}
	if !testing.expect(t, db >= 0, "no Discharge Beam in plugins/new_weapons") {
		return
	}

	session := sim.Session{seed = 9, level_id = defs.levels[0].id, game_type = .Co_Op, mods = session_mods(false, true, online = true)}
	states: [2]^sim.State
	rs: [2]net.Rollback_Session
	for k in 0 ..< 2 {
		states[k] = new(sim.State, alloc)
		sim.init(states[k], session, &defs)
		// Both ships in play, the guest's (player 2) with the beam and
		// unable to die, the same on both peers.
		for i := 0; i < 300 && sim.player_at(states[k], 1).state != .Playing; i += 1 {
			sim.session_step(states[k], {})
		}
		p := sim.player_at(states[k], 1)
		p.weapons.air.weapon = i32(db)
		p.invulnerable_always, p.invulnerable = true, true
		net.rollback_session_init(&rs[k], states[k], k, alloc)
	}
	testing.expect(t, sim.player_at(states[0], 1).state == .Playing, "the guest's ship must be in play")

	Delivery :: struct {
		at:  int,
		buf: [128]byte,
		n:   int,
	}
	// Longer than the pulse's wind-up: the pulse fires windup steps after
	// its press, and a press the host has by then fires on its newest step
	// without a replay.
	LATENCY :: 8
	FRAMES :: 240
	queues: [2][dynamic]Delivery // to host, to guest
	queues[0] = make([dynamic]Delivery, alloc)
	queues[1] = make([dynamic]Delivery, alloc)
	newest_step := 0
	for tick in 0 ..< FRAMES {
		for &q, k in queues {
			w := 0
			for &d in q {
				if d.at > tick {
					q[w] = d
					w += 1
				} else if pkt, ok := net.decode_input(d.buf[:d.n]); ok {
					net.rollback_session_receive(&rs[k], pkt)
				}
			}
			resize(&q, w)
		}
		// The guest taps fire-air, a step down in every twelve; the host
		// does nothing. Not on the first steps: a rollback restores the
		// step before the one it replays, which a session begun mid-level
		// has not saved. Nor on the last: the host must have every press
		// by the end, for the checksums to agree.
		guest: sim.Buttons
		if tick % 12 == 6 && tick < FRAMES - 2 * LATENCY {
			guest = {.Fire_Air}
		}
		net.rollback_session_advance(&rs[0], {})
		net.rollback_session_advance(&rs[1], guest)
		// What the host drew before: only its newest step's beams.
		for ev in new_weapons.beam_shots(states[0]) {
			if ev.player == 1 {
				newest_step += 1
			}
		}
		for k in 0 ..< 2 {
			win: [8]sim.Buttons
			start, count := net.rollback_session_local_window(&rs[k], len(win), win[:])
			if count > 0 {
				d := Delivery{at = tick + LATENCY}
				d.n = net.encode_input(d.buf[:], u8(k), start, win[:count])
				append(&queues[1 - k], d)
			}
		}
	}

	host, guest := new_weapons.beam_log_of(states[0]), new_weapons.beam_log_of(states[1])
	fired := 0
	for ev in guest.events {
		if ev.width > 0 && ev.player == 1 {
			fired += 1
		}
	}
	testing.expect(t, fired > 0, "the guest must have fired the beam")
	testing.expect_value(t, sim.checksum(states[0]), sim.checksum(states[1]))
	testing.expect(t, host^ == guest^, "the host must hold the guest's beams as the guest does")
	testing.expect_value(t, newest_step, 0) // never on the step drawn: the bug
	testing.expect(t, rs[0].rollback_count > 0, "the guest's presses must have been replayed on the host")
}
