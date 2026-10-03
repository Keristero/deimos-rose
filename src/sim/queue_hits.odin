package sim

// Every collision that hurt something, for presentation: where, how hard it
// was meant to hit and what the target had. A plugin's view reads them after
// the step (hitstop's hold and kill cam). Like the other queues the events
// are not state: every step clears them, and snapshots and checksums leave
// them out.
Hit_Event :: struct {
	loc:              Vec,  // the target's, as the object has it
	damage:           f32,  // asked of the target
	shields:          f32,  // the target's before the hit
	scrolls_sideways: bool, // loc follows the background's sideways scroll
	killed:           bool, // the hit emptied them
	player:           bool, // the target is a player, not a unit
}

MAX_HIT_EVENTS :: 16

Hit_Queue :: struct {
	events: [MAX_HIT_EVENTS]Hit_Event,
	count:  int,
}

// A full queue drops the event: presentation only.
hit_record :: proc "contextless" (s: ^State, ev: Hit_Event) {
	q := &s.hits
	if q.count < MAX_HIT_EVENTS {
		q.events[q.count] = ev
		q.count += 1
	}
}
