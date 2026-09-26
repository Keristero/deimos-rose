package sim

import ecs "dr:third_party/odecs"

// The entity world: G_EntityGroup's groups and G_Entity's entities.
//
// The original keeps entities in a pool of 1,000 preallocated objects
// (FUN_0041d1d0) and groups in heap-allocated U_LinkedLists. Here both are
// fixed ranges of the world's entities (ecs.odin): pool slot i is
// pool_entity(i) and group i is group_entity(i). Which are in use, and the
// lists, are in the Pool singleton. List membership is intrusive: each
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

// The Link components of one range of the world's entities, by index from
// the range's first.
Links :: struct {
	ecs:   ^Ecs,
	first: i32,
}

entity_links :: #force_inline proc "contextless" (s: ^State) -> Links {
	return {s.ecs, FIRST_POOL_ENTITY}
}

group_links :: #force_inline proc "contextless" (s: ^State) -> Links {
	return {s.ecs, FIRST_GROUP_ENTITY}
}

// Member i's link. The lists take plain slices too, for tests.
link_of :: proc {
	link_in_world,
	link_in_slice,
}

link_in_world :: #force_inline proc "contextless" (links: Links, i: i32) -> ^Link {
	return get(links.ecs, ecs.EntityID(links.first + i), Link)
}

link_in_slice :: #force_inline proc "contextless" (links: []Link, i: i32) -> ^Link {
	return &links[i]
}

// U_LinkedList::CreateAndAddLink.
list_append :: proc "contextless" (l: ^List, links: $L, i: i32) {
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
list_next :: proc "contextless" (l: ^List, links: $L, c: ^Cursor) -> i32 {
	c.at = c.at == NO_LINK ? l.head : link_of(links, c.at).next
	return c.at
}

// U_LinkedList::DeleteLink(link, ref): unlinks and steps the cursor back.
list_remove :: proc "contextless" (l: ^List, links: $L, i: i32, c: ^Cursor = nil) {
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

list_nth :: proc "contextless" (l: ^List, links: $L, n: i32) -> i32 {
	i := l.head
	for _ in 0 ..< n {
		i = link_of(links, i).next
	}
	return i
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
// (stats.odin).
Shaped :: struct {
	shaped_by:     u8,  // the weapon, as shot_shaper gives it
	shaped_depth:  u8,  // spawners between it and the weapon
	spawn_pace:    i32, // 0, or its spawn sets' pace in hundredths of a step
	pace_acc:      i32,
	spawn_clock:   i32, // the time its spawn sets run at, when paced
}

// One pool entity: its components, as G_Entity's fields. A view, passed by
// value; its pointers stay good for the session, since a pool slot keeps
// its components (entity_alloc).
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

// Every pool entity's components. Its list membership is a Link.
pool_components :: proc "contextless" () -> Component_Mask {
	return {
		component_id(Game_Object),
		component_id(Actor),
		component_id(Anim),
		component_id(Motion),
		component_id(Owned),
		component_id(Spawner),
		component_id(Effects),
		component_id(Shaped),
		component_id(Link),
	}
}

// Pool slot i, which must have held an entity this session.
entity_at :: #force_inline proc "contextless" (s: ^State, i: i32) -> Entity {
	id := pool_entity(i)
	return {
		obj     = get(s.ecs, id, Game_Object),
		actor   = get(s.ecs, id, Actor),
		anim    = get(s.ecs, id, Anim),
		motion  = get(s.ecs, id, Motion),
		owned   = get(s.ecs, id, Owned),
		spawner = get(s.ecs, id, Spawner),
		effects = get(s.ecs, id, Effects),
		shaped  = get(s.ecs, id, Shaped),
	}
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

group_components :: proc "contextless" () -> Component_Mask {
	return {component_id(Group), component_id(Link)}
}

// Group i, which must have been allocated this session.
group_at :: #force_inline proc "contextless" (s: ^State, i: i32) -> ^Group {
	return get(s.ecs, group_entity(i), Group)
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
}

// A group slot gets its components the first time it is used and keeps
// them, so no allocation moves another group's (a group is allocated while
// others are being walked).
group_alloc :: proc(s: ^State) -> i32 {
	w := single(s, Pool)
	for used, i in w.group_used {
		if !used {
			w.group_used[i] = true
			id := group_entity(i32(i))
			if !has(s.ecs, id, Group) {
				ecs_set_components(s.ecs, id, group_components())
			}
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
