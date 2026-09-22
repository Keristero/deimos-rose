package sim

// An optional log of the simulation's own events, mirroring what
// tools/oracle/trace.py records from the original in detail mode. Diffing the
// two streams says *which* entity diverged, where the draw log only says that
// the random calls stopped matching. nil in normal play.

Event_Kind :: enum u8 {
	Spawn,   // G_EG_RequestSpawn accepted a request
	State,   // G_Entity::ChangeState entered a state
	Destroy, // G_Entity::Destroy
	Delete,  // marked for removal
	Sound,   // U_Sound_Play
	Burst,   // G_Particle_NewGroup
	Spawn_Control, // G_Entity::SpawnControl entered
}

Event :: struct {
	kind:   Event_Kind,
	unit:   Res_ID, // unit or sound id
	number: i32,    // unique entity number, where there is one
	state:  string, // the state name a State event asked for
	loc:    Vec,
	frame:  u32, // film reads so far, matching the trace's step numbers
}

Event_Log :: struct {
	events:  []Event,
	count:   int,
	dropped: int,
}

event_log_entries :: proc "contextless" (l: ^Event_Log) -> []Event {
	return l.events[:l.count]
}

@(private)
record_event :: proc "contextless" (s: ^State, e: Event) {
	l := s.events
	if l == nil {
		return
	}
	if l.count == len(l.events) {
		l.dropped += 1
		return
	}
	ev := e
	ev.frame = u32(s.film_cursor[0])
	l.events[l.count] = ev
	l.count += 1
}
