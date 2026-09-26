package simbench

// Times the simulation alone, with nothing drawn: the four demo replays,
// random-input co-op sessions on every level, and rollback's snapshot,
// restore and checksum. Each figure is the best of REPS runs, so noise
// from the rest of the machine shows as little as it can. Needs the
// extracted assets (mise run extract); `mise run bench` runs it.

import "core:fmt"
import "core:os"
import "core:time"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:sim"
import _ "dr:sim/core"

best :: proc(ds: []time.Duration) -> time.Duration {
	b := ds[0]
	for d in ds {
		b = min(b, d)
	}
	return b
}

main :: proc() {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	defs, _ := data.assets_defs_load("assets")
	data.extra_defs_load("assets", &defs)
	REPS :: 5

	// 1. The four demos, replayed from their films.
	films: [4]sim.Film
	for name, i in ([4]string{"de01", "de02", "de03", "de04"}) {
		bytes, _ := os.read_entire_file(fmt.tprintf("assets/films/%s.film", name), context.allocator)
		f, _ := data.film_parse(bytes)
		films[i] = data.film_to_sim(f)
	}
	demo_steps := 0
	demo_t: [REPS]time.Duration
	for rep in 0 ..< REPS {
		demo_steps = 0
		t := time.now()
		for &film in films {
			fl := film
			s := new(sim.State)
			sim.init(s, fl.session, &defs)
			for !sim.film_finished(s, &fl) {
				sim.step(s, {}, &fl)
				demo_steps += 1
			}
		}
		demo_t[rep] = time.since(t)
	}
	d := best(demo_t[:])
	fmt.printfln("demos      %d steps  %.2f ms  %.2f us/step", demo_steps, time.duration_milliseconds(d), time.duration_microseconds(d) / f64(demo_steps))

	// 2. Every level, co-op, random input, both ships kept alive.
	STEPS :: 6000
	sess_t: [REPS]time.Duration
	sess_steps := 0
	for rep in 0 ..< REPS {
		sess_steps = 0
		t := time.now()
		for lv in 0 ..< len(defs.levels) {
			s := new(sim.State)
			sim.init(s, sim.Session{seed = u32(100 + lv), level_id = defs.levels[lv].id, game_type = .Co_Op}, &defs)
			pad := sim.rand_init(u32(lv) ~ 0x5eed)
			input: sim.Frame_Input
			for n in 0 ..< STEPS {
				if n % 6 == 0 {
					for k in 0 ..< sim.MAX_PLAYERS {
						b := sim.Buttons{}
						for btn in sim.Button {
							if btn != .Pause && sim.random_int(&pad, 0, 3, 0) == 0 {
								b += {btn}
							}
						}
						input[k] = b
					}
				}
				// Both ships kept alive, so every step has the full load.
				for p in sim.players_of(s) {
					p.invulnerable_always = true
					p.invulnerable = true
				}
				sim.session_step(s, input)
				sess_steps += 1
			}
		}
		sess_t[rep] = time.since(t)
	}
	d = best(sess_t[:])
	fmt.printfln("sessions   %d steps  %.2f ms  %.2f us/step", sess_steps, time.duration_milliseconds(d), time.duration_microseconds(d) / f64(sess_steps))

	// 3. Rollback: a snapshot every step, then a restore and a checksum.
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 7, level_id = defs.levels[5].id, game_type = .Co_Op}, &defs)
	for _ in 0 ..< 2000 {
		sim.session_step(s, {})
	}
	ring: sim.Snapshot_Ring
	sim.snapshot_ring_init(&ring, 16)
	N :: 2000
	save_t, rest_t, sum_t: [REPS]time.Duration
	acc: u64
	for rep in 0 ..< REPS {
		t := time.now()
		for _ in 0 ..< N {
			sim.snapshot_save(&ring, s)
		}
		save_t[rep] = time.since(t)
		f := sim.frame_of(s)
		t = time.now()
		for _ in 0 ..< N {
			_ = sim.snapshot_restore(&ring, s, f)
		}
		rest_t[rep] = time.since(t)
		t = time.now()
		for _ in 0 ..< N {
			acc ~= sim.checksum(s)
		}
		sum_t[rep] = time.since(t)
	}
	fmt.printfln("world bytes %d", sim.ecs_written_size(s.ecs))
	fmt.printfln("snapshot   %.2f us   restore %.2f us   checksum %.2f us  (%x)",
		time.duration_microseconds(best(save_t[:])) / N, time.duration_microseconds(best(rest_t[:])) / N,
		time.duration_microseconds(best(sum_t[:])) / N, acc & 0xff)
}
