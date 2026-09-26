package sim

// The entity world: G_EntityGroup's groups and G_Entity's entities.
//
// The original keeps entities in a pool of 1,000 preallocated objects
// (FUN_0041d1d0) and groups in heap-allocated U_LinkedLists. Here both are
// kinds of the world's entities (ecs.odin), made with the world: pool slot i
// is the i-th Pool entity and group i the i-th Group. Which are in use, and
// the lists, are in the Pool singleton. List membership is intrusive: each
// member's Link component holds its neighbours' indices. The lists reproduce
// U_LinkedList exactly: CreateAndAddLink appends at the tail, iteration runs
// from the head, and deleting through a cursor steps the cursor back to the
// previous link so the next step continues with the following item. Every
// iteration order in the simulation -- and so every draw order -- depends on
// this.

MAX_ENTITIES :: 1000 // G_EG's pool, and its RequestSpawn limit (< 1001)
MAX_GROUPS :: 1024
NO_LINK :: -1

// First unique entity number and group id handed out at level start
// (G_EG_ResetAtLevelStart: DAT_004e0d78 = 1000, DAT_004e0d7c = 20000000).
FIRST_ENTITY_NUMBER :: 1000
FIRST_GROUP_ID :: 20_000_000

// 'PERM': the permanent group created at level start.
PERM_GROUP_UNIT :: Res_ID{'M', 'R', 'E', 'P'}

// An intrusive doubly linked list over pool indices.
List :: struct {
	head, tail: i32,
	count:      i32,
}

Link :: struct {
	prev, next: i32,
}

// U_LinkRef: the link last visited; NO_LINK before the first step.
Cursor :: struct {
	at: i32,
}

list_init :: proc "contextless" () -> List {
	return {head = NO_LINK, tail = NO_LINK}
}

// The pool's links and the groups', by index.
entity_links :: #force_inline proc "contextless" (s: ^State) -> []Link {
	return s.ecs.pool_links
}

group_links :: #force_inline proc "contextless" (s: ^State) -> []Link {
	return s.ecs.group_links
}

link_of :: #force_inline proc "contextless" (links: []Link, i: i32) -> ^Link {
	return &links[i]
}

// U_LinkedList::CreateAndAddLink.
list_append :: proc "contextless" (l: ^List, links: []Link, i: i32) {
	link_of(links, i)^ = {prev = l.tail, next = NO_LINK}
	if l.head == NO_LINK {
		l.head = i
	}
	if l.tail != NO_LINK {
		link_of(links, l.tail).next = i
	}
	l.tail = i
	l.count += 1
}

// U_LinkedList::GetNextLinkObject. Callers bound their loops by a count, as
// the original does, so running off the end is a caller bug.
list_next :: proc "contextless" (l: ^List, links: []Link, c: ^Cursor) -> i32 {
	c.at = c.at == NO_LINK ? l.head : link_of(links, c.at).next
	return c.at
}

// U_LinkedList::DeleteLink(link, ref): unlinks and steps the cursor back.
list_remove :: proc "contextless" (l: ^List, links: []Link, i: i32, c: ^Cursor = nil) {
	lk := link_of(links, i)^
	if i == l.head {
		l.head = lk.next
	} else {
		link_of(links, lk.prev).next = lk.next
	}
	if i == l.tail {
		l.tail = lk.prev
	} else {
		link_of(links, lk.next).prev = lk.prev
	}
	l.count -= 1
	if c != nil {
		c.at = i == l.head || lk.prev == NO_LINK ? NO_LINK : lk.prev
	}
	link_of(links, i)^ = {NO_LINK, NO_LINK}
}


// Every entity in the groups' lists, group by group, head to tail: the walk
// G_EG's lookups make (FUN_0041b740 and its kin), for
// `walk := walk_entities(s); for e, i in walk_next(&walk)`. Each next link
// is read as the walk moves on, so an entity appended while the walk is on
// its group's last is reached too.
Entity_Walk :: struct {
	s:       ^State,
	group:   i32,
	at:      i32,
	entered: bool, // `at` is in `group`'s list
}

walk_entities :: proc "contextless" (s: ^State) -> Entity_Walk {
	return {s = s, group = single(s, Pool).active.head, at = NO_LINK}
}

walk_next :: proc "contextless" (w: ^Entity_Walk) -> (e: Entity, index: i32, ok: bool) {
	for w.group != NO_LINK {
		if !w.entered {
			w.entered = true
			w.at = group_at(w.s, w.group).entities.head
		} else if w.at != NO_LINK {
			w.at = w.s.ecs.pool_links[w.at].next
		}
		if w.at != NO_LINK {
			return entity_at(w.s, w.at), w.at, true
		}
		w.group = w.s.ecs.group_links[w.group].next
		w.entered = false
	}
	return
}

// U_LinkedList's walk by count through cursors, as G_EG_Process and the
// sweep make it: the active groups through one cursor, each group's
// entities through another, so an entity or group deleted through them
// (list_remove) leaves the walk on the one after. For
// `walk := cursor_walk(s, fixed); for e, i in cursor_next(&walk)`.
//
// With `fixed` each count is taken as its list is entered; without, before
// every step, as G_EG_Process does, so what is appended meanwhile is
// reached.
Cursor_Walk :: struct {
	s:         ^State,
	fixed:     bool,
	gc, ec:    Cursor,
	group:     i32, // the group being walked
	in_group:  bool,
	groups:    i32, // taken so far
	entities:  i32,
	group_end: i32, // the counts, when fixed
	entity_end: i32,
}

cursor_walk :: proc "contextless" (s: ^State, fixed: bool) -> Cursor_Walk {
	return {s = s, fixed = fixed, gc = {NO_LINK}, group_end = single(s, Pool).active.count}
}

cursor_next :: proc "contextless" (w: ^Cursor_Walk) -> (e: Entity, index: i32, ok: bool) {
	pool := single(w.s, Pool)
	for {
		if w.in_group {
			entities := &group_at(w.s, w.group).entities
			if w.entities < (w.fixed ? w.entity_end : entities.count) {
				w.entities += 1
				i := list_next(entities, entity_links(w.s), &w.ec)
				return entity_at(w.s, i), i, true
			}
			w.in_group = false
		}
		if w.groups >= (w.fixed ? w.group_end : pool.active.count) {
			return
		}
		w.groups += 1
		w.group = list_next(&pool.active, group_links(w.s), &w.gc)
		w.ec = {NO_LINK}
		w.entities = 0
		w.entity_end = group_at(w.s, w.group).entities.count
		w.in_group = true
	}
}

// Leaves the rest of the group being walked, as after deleting it.
cursor_leave_group :: #force_inline proc "contextless" (w: ^Cursor_Walk) {
	w.in_group = false
}

// G_GameObject: the common base of players, groups and entities. Only the
// fields the simulation reads are kept; offsets are the original's.
Game_Object :: struct {
	loc:            Vec,    // +0x00
	vel:            Vec,    // +0x10
	// +0x18: the object moves with the background's horizontal scroll.
	// Cleared for units whose draw layer is "hud " (G_Entity::SetUnitRef).
	scrolls_sideways: bool,
	// +0x38: draws a shadow, from the unit's castsShadows_BOOL. Presentation
	// only, but it is part of the object's state, so it lives here.
	casts_shadow:   bool,
	is_air:         bool,   // +0x19  layer is "air "
	shadow_scaled:  bool,   // +0x1a  unit's adjustShadowLocForScaling
	sprite:         Res_ID, // +0x1c
	frame:          i32,    // +0x20
	dims:           [2]i32, // +0x24  width, height
	half:           [2]i32, // +0x2c
	dims_dirty:     bool,   // +0x34
	draw_to_terrain: bool,  // +0x36
	draw_layer:     Res_ID, // +0x4a
	// +0x4e holds a pointer to the current frame's encoded data. Its only
	// simulation effect is which dimension lookup CalculateDimensions uses;
	// both give the same size, so only its presence is kept.
	has_frame_ptr:  bool,
	colorise:       bool,   // +0x52
	tint:           f32,    // +0x54
	tint_target:    f32,    // +0x58
	tint_delta:     f32,    // +0x5c
	tint_color:     u16,    // +0x60
	visibility:     f32,    // +0x62
	visibility_target: f32, // +0x66
	visibility_delta:  f32, // +0x6a
	// The glow flash: +0x6e on, +0x6f falling, +0x70 blend amount (32 is
	// invisible, 4 nearly solid), +0x74 speed, +0x78 colour.
	glowing:        bool,
	glow_falling:   bool,
	glow_amount:    i32,
	glow_speed:     i32,
	glow_color:     u16,
	scale:          f32,    // +0x7a
	scale_target:   f32,    // +0x7e
	scale_delta:    f32,    // +0x82
}

// G_GameObject::SetDefaults.
object_defaults :: proc "contextless" (o: ^Game_Object) {
	o^ = Game_Object {
		scrolls_sideways  = true,
		casts_shadow      = true,
		is_air            = true,
		sprite            = NONE,
		dims_dirty        = true,
		draw_layer        = {'d', 'e', 'f', 'a'},
		visibility        = 100,
		visibility_target = 100,
		scale             = 1,
		scale_target      = 1,
	}
}

// Entity_Ref: a pointer plus the unique number it had when taken, so a stale
// reference to a reused pool slot can be detected (FUN_0041b700).
Entity_Ref :: struct {
	index:  i32,
	number: i32,
}

NO_REF :: Entity_Ref{NO_LINK, -1}

// Per-state spawn bookkeeping (G_Entity's 0x16-byte spawn info records).
Spawn_Info :: struct {
	delay:        i32,  // +0x00 rate: steps until the next volley
	last:         i32,  // +0x04 time of the last volley
	left:         i32,  // +0x08 entities left in the volley
	volley:       i32,  // +0x0c volley size
	gap:          i32,  // +0x10 delay between entities
	active:       bool, // +0x14
}

MAX_STATES :: 20 // G_Entity keeps per-state arrays of 0x14 entries
MAX_SPAWN_SETS :: 8 // the most any shipped state has is 7

// A pool entity's components. The fields keep the original G_Entity
// offsets; they are split by what reads them.

// What the entity is and where it is in its life.
Actor :: struct {
	unit:          i32,          // +0x8a index into Defs.units
	number:        i32,          // +0x92 unique entity number
	group:         i32,          // +0x96 group id
	state_time:    i32,          // +0x9a time the current state was entered
	state:         i32,          // +0x9e current state index, -1 before the first
	hittable:      bool,         // +0xa2
	appear_delay:  i32,          // +0xa4 steps before the entity starts processing
	last_hit:      i32,          // +0xa8
	timer:         i32,          // +0xac current state's duration
	killed_by_player: bool,      // +0xbe
	deleted:       bool,         // +0xbf marked for removal
	fleeing:       bool,         // +0xc0
	has_depletion_state: bool,   // +0xc1 unit has a use-on-shield-depletion state
	owner_player:  i32,          // +0xca -1, or the player that spawned it
	target_player: i32,          // +0xce
	destroyed:     bool,         // +0xd2
	hit_state_time: i32,         // +0xf4
	powerup_weapon: Res_ID,      // +0xf0
	shields:       f32,          // +0x12c
	pool_index:    i32,          // +0x140
	entry_counts:  [MAX_STATES]i32, // +0x144 times each state was entered
}

// Stepping through the state's frames.
Anim :: struct {
	anim_time:     i32,          // +0xb0 time of the last animation step
	anim_backwards: bool,        // +0xb4
	rotating:      bool,         // +0xb5
	anim_done:     bool,         // +0xb6
	animating:     bool,         // +0xbc
}

// How it moves, beyond the object's location and velocity.
Motion :: struct {
	orbit_radius:  f32,          // +0xd4
	orbit_angle:   i32,          // +0xd8
	vel_prev:      Vec,          // +0xf8
	vel_target:    Vec,          // +0x100
	vel_delta:     Vec,          // +0x108
	hunt_player:   i32,          // +0x110
	hunt_target:   Vec,          // +0x114
	heading:       i32,          // +0x130
	stationary:    bool,         // +0x134
	terrain_effects: bool,       // +0x135
}

// The entity that spawned it, and where it was.
Owned :: struct {
	owner_offset:  Vec,          // +0x11c
	owner_loc:     Vec,          // +0x124
	owner:         Entity_Ref,   // +0x138
}

// Spawning other entities.
Spawner :: struct {
	spawning:      bool,         // +0xb7
	spawn_pause:   i32,          // +0xb8
	has_spawn_info: bool,        // +0x136
	// +0x194 holds one spawn-info list per state, but the original only ever
	// reads or resets the current state's (both SpawnControl and
	// Priv_CheckSpawningAbilityAtStateChange index by +0x9e, and a state
	// change resets the new state's list), so one list is equivalent. It
	// keeps snapshots small enough to take every frame for rollback.
	spawn_info:    [MAX_SPAWN_SETS]Spawn_Info,
}

// When it last made a sound, particles, a blur or a collision spawn.
Effects :: struct {
	collision_time: i32,         // +0xc2 last collision spawn
	collision_count: i32,        // +0xc6
	sound_time:    i32,          // +0xdc last entry-sound time
	sound_count:   i32,          // +0xe0
	blur_time:     i32,          // +0xe4 last motion blur
	particle_time: i32,          // +0xe8
	particle_count: i32,         // +0xec
}

// Not the original's; all zero unless a plugin shaped the entity's weapon
// (sim/stats).
Shaped :: struct {
	shaped_by:     u8,  // the weapon, as shot_shaper gives it
	shaped_depth:  u8,  // spawners between it and the weapon
	spawn_pace:    i32, // 0, or its spawn sets' pace in hundredths of a step
	pace_acc:      i32,
	spawn_clock:   i32, // the time its spawn sets run at, when paced
}

// One pool entity: its components, as G_Entity's fields. A view, passed by
// value, found when the world is built and good for the session (ecs.odin).
Entity :: struct {
	using obj:     ^Game_Object,
	using actor:   ^Actor,
	using anim:    ^Anim,
	using motion:  ^Motion,
	using owned:   ^Owned,
	using spawner: ^Spawner,
	using effects: ^Effects,
	using shaped:  ^Shaped,
}

// Pool slot i. A slot never used this session holds its start values.
entity_at :: #force_inline proc "contextless" (s: ^State, i: i32) -> Entity {
	return s.ecs.entities[i]
}

// A group: its own component, and a Link for the active or required list.
Group :: struct {
	id:          i32,    // +0x8a
	unit:        Res_ID, // +0x8e
	loc:         Vec,    // +0x92
	count:       i32,    // +0x9a entities in this spawn
	total:       i32,    // +0x9e
	killed:      i32,    // +0xa2
	entities:    List,   // +0xa6
	heading:     i32,    // +0xaa
	stationary:  bool,   // +0xae
	terrain_effects: bool, // +0xaf
}

// Group i.
group_at :: #force_inline proc "contextless" (s: ^State, i: i32) -> ^Group {
	return s.ecs.groups[i]
}

// The pool's bookkeeping: G_EG's globals.
Pool :: struct {
	entity_used:     [MAX_ENTITIES]bool, // DAT_004e0d88, stride 10
	group_used:      [MAX_GROUPS]bool,
	used_count:      i32, // DAT_004e0d84
	free_hint:       i32, // DAT_004e0d80
	active:          List, // DAT_004e0d70
	required:        List, // DAT_004e0d6c: level placements not yet spawned
	next_entity:     i32, // DAT_004e0d78
	next_group:      i32, // DAT_004e0d7c
	ground_targets:  i32, // DAT_004e34a6
	limit_warned:    bool, // DAT_004e3499
	// Not the original's: one past the highest entity slot and group
	// handed out this session. They never go down, not even at a level's
	// start, since a freed slot keeps what its last entity left; those
	// above have never been used and still hold their start values, so
	// snapshots leave them out (ecs.odin).
	slots_touched:   i32,
	groups_touched:  i32,
}

group_alloc :: proc "contextless" (s: ^State) -> i32 {
	w := single(s, Pool)
	for used, i in w.group_used {
		if !used {
			w.group_used[i] = true
			w.groups_touched = max(w.groups_touched, i32(i) + 1)
			group_at(s, i32(i))^ = Group{entities = list_init()}
			return i32(i)
		}
	}
	return NO_LINK
}

group_free :: proc "contextless" (s: ^State, i: i32) {
	single(s, Pool).group_used[i] = false
	group_at(s, i)^ = {}
}

// G_EG_SpawnRequest. Every caller copies a static template (identical in
// G_EG, G_Game and G_Player: id "none", owner player -1, speed 1.0) and fills
// in what it needs.
Spawn_Request :: struct {
	unit:          Res_ID, // +0x00
	loc:           Vec,    // +0x04
	map_relative:  bool,   // +0x0c y is a map row; converted to screen space
	explicit_heading: bool, // +0x0d
	heading:       i32,    // +0x0e used when explicit_heading
	owner_player:  i32,    // +0x12
	place_heading: i32,    // +0x16 the placement's heading
	stationary:    bool,   // +0x1a
	terrain_effects: bool, // +0x1b
	owner:         Entity_Ref, // +0x1c
	speed_scale:   f32,    // +0x24
	// Not the original's: the weapon that shaped this spawn (see
	// shot_shaper) and how many spawners removed from the weapon it is.
	shaped_by:     u8,
	shaped_depth:  u8,
}

spawn_request :: proc "contextless" (unit: Res_ID) -> Spawn_Request {
	return {unit = unit, owner_player = -1, owner = NO_REF, speed_scale = 1}
}

// FUN_0041b700: is a reference still the entity it was taken from?
ref_valid :: proc "contextless" (s: ^State, r: Entity_Ref) -> bool {
	if r.index == NO_LINK {
		return false
	}
	e := entity_at(s, r.index)
	return r.number == e.number && !e.deleted
}

unit_index :: proc "contextless" (d: ^Defs, id: Res_ID) -> i32 {
	for &u, i in d.units {
		if u.id == id {
			return i32(i)
		}
	}
	return -1
}

unit_of :: #force_inline proc "contextless" (s: ^State, e: Entity) -> ^Unit {
	return &s.defs.units[e.unit]
}

state_of :: #force_inline proc "contextless" (s: ^State, e: Entity) -> ^Unit_State {
	return &s.defs.units[e.unit].states[e.state]
}

// Where an entity's owner is: the owning entity if it still exists, else the
// owning player if in play.
owner_loc :: proc "contextless" (s: ^State, e: Entity) -> (loc: Vec, ok: bool) {
	if ref_valid(s, e.owner) {
		return entity_at(s, e.owner.index).loc, true
	}
	if e.owner_player != -1 {
		p := player_at(s, e.owner_player)
		if p.state == .Playing {
			return p.loc, true
		}
	}
	return {}, false
}
