package sim

// Plugins' presentation events: what a plugin's systems leave for its view
// to draw, this step only, as the core's queues (sounds, particles, blurs,
// notices) do for the core's effects. A plugin registers each kind of event
// with the type it carries, pushes values of that type, and its view reads
// them back after the step (render/render_systems.odin's effect systems).
// Like the other queues, the events are not state: every step clears them,
// and snapshots and checksums leave them out.

MAX_EFFECT_KINDS :: 16
MAX_EFFECT_EVENTS :: 16
EFFECT_BYTES :: 32

// A registered kind of event, by index.
Effect_Kind :: distinct u8

Effect_Event :: struct {
	kind: Effect_Kind,
	data: [EFFECT_BYTES / 8]u64, // the value, as its kind's type; u64 for alignment
}

Effect_Queue :: struct {
	events: [MAX_EFFECT_EVENTS]Effect_Event,
	count:  int,
}

@(private = "file")
effect_kinds: Registry(typeid, MAX_EFFECT_KINDS)

// Called from `@(init)` procedures only.
effect_kind_register :: proc($T: typeid) -> Effect_Kind {
	#assert(size_of(T) <= EFFECT_BYTES, "an effect event's value is at most EFFECT_BYTES")
	return Effect_Kind(registry_add(&effect_kinds, T))
}

// Adds this step's event of `kind`. A full queue drops it: presentation
// only, so the step goes on the same.
effect_push :: proc "contextless" (s: ^State, kind: Effect_Kind, value: $T) {
	assert_contextless(registry_items(&effect_kinds)[kind] == T, "sim: an effect event of another kind's type")
	q := &s.effects
	if q.count >= MAX_EFFECT_EVENTS {
		return
	}
	ev := &q.events[q.count]
	ev.kind = kind
	ev.data = {}
	(^T)(&ev.data)^ = value
	q.count += 1
}

// This step's events of `kind`, in the order they were pushed.
Effect_Walk :: struct($T: typeid) {
	s:    ^State,
	kind: Effect_Kind,
	at:   int,
}

effects_of :: proc "contextless" (s: ^State, kind: Effect_Kind, $T: typeid) -> Effect_Walk(T) {
	return {s, kind, 0}
}

effects_next :: proc "contextless" (w: ^Effect_Walk($T)) -> (value: T, ok: bool) {
	q := &w.s.effects
	for w.at < q.count {
		ev := &q.events[w.at]
		w.at += 1
		if ev.kind == w.kind {
			return (^T)(&ev.data)^, true
		}
	}
	return
}
