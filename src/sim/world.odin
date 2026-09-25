package sim

// The entity world: G_EntityGroup's groups and G_Entity's entities.
//
// The original keeps entities in a pool of 1,000 preallocated objects
// (FUN_0041d1d0) and groups in heap-allocated U_LinkedLists. Here both are
// fixed pools inside State, so a snapshot for rollback is a plain copy, and
// list membership is intrusive (prev/next indices). The lists reproduce
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

// U_LinkedList::CreateAndAddLink.
list_append :: proc "contextless" (l: ^List, links: []Link, i: i32) {
	links[i] = {prev = l.tail, next = NO_LINK}
	if l.head == NO_LINK {
		l.head = i
	}
	if l.tail != NO_LINK {
		links[l.tail].next = i
	}
	l.tail = i
	l.count += 1
}

// U_LinkedList::GetNextLinkObject. Callers bound their loops by a count, as
// the original does, so running off the end is a caller bug.
list_next :: proc "contextless" (l: ^List, links: []Link, c: ^Cursor) -> i32 {
	c.at = c.at == NO_LINK ? l.head : links[c.at].next
	return c.at
}

// U_LinkedList::DeleteLink(link, ref): unlinks and steps the cursor back.
list_remove :: proc "contextless" (l: ^List, links: []Link, i: i32, c: ^Cursor = nil) {
	lk := links[i]
	if i == l.head {
		l.head = lk.next
	} else {
		links[lk.prev].next = lk.next
	}
	if i == l.tail {
		l.tail = lk.prev
	} else {
		links[lk.next].prev = lk.prev
	}
	l.count -= 1
	if c != nil {
		c.at = i == l.head || lk.prev == NO_LINK ? NO_LINK : lk.prev
	}
	links[i] = {NO_LINK, NO_LINK}
}

list_nth :: proc "contextless" (l: ^List, links: []Link, n: i32) -> i32 {
	i := l.head
	for _ in 0 ..< n {
		i = links[i].next
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

Entity :: struct {
	using obj:     Game_Object,
	link:          Link,         // membership of its group's list
	unit:          i32,          // +0x8a index into Defs.units
	number:        i32,          // +0x92 unique entity number
	group:         i32,          // +0x96 group id
	state_time:    i32,          // +0x9a time the current state was entered
	state:         i32,          // +0x9e current state index, -1 before the first
	hittable:      bool,         // +0xa2
	appear_delay:  i32,          // +0xa4 steps before the entity starts processing
	last_hit:      i32,          // +0xa8
	timer:         i32,          // +0xac current state's duration
	anim_time:     i32,          // +0xb0 time of the last animation step
	anim_backwards: bool,        // +0xb4
	rotating:      bool,         // +0xb5
	anim_done:     bool,         // +0xb6
	spawning:      bool,         // +0xb7
	spawn_pause:   i32,          // +0xb8
	animating:     bool,         // +0xbc
	killed_by_player: bool,      // +0xbe
	deleted:       bool,         // +0xbf marked for removal
	fleeing:       bool,         // +0xc0
	has_depletion_state: bool,   // +0xc1 unit has a use-on-shield-depletion state
	collision_time: i32,         // +0xc2 last collision spawn
	collision_count: i32,        // +0xc6
	owner_player:  i32,          // +0xca -1, or the player that spawned it
	target_player: i32,          // +0xce
	destroyed:     bool,         // +0xd2
	orbit_radius:  f32,          // +0xd4
	orbit_angle:   i32,          // +0xd8
	sound_time:    i32,          // +0xdc last entry-sound time
	sound_count:   i32,          // +0xe0
	blur_time:     i32,          // +0xe4 last motion blur
	particle_time: i32,          // +0xe8
	particle_count: i32,         // +0xec
	hit_state_time: i32,         // +0xf4
	powerup_weapon: Res_ID,      // +0xf0
	vel_prev:      Vec,          // +0xf8
	vel_target:    Vec,          // +0x100
	vel_delta:     Vec,          // +0x108
	hunt_player:   i32,          // +0x110
	hunt_target:   Vec,          // +0x114
	owner_offset:  Vec,          // +0x11c
	owner_loc:     Vec,          // +0x124
	shields:       f32,          // +0x12c
	heading:       i32,          // +0x130
	stationary:    bool,         // +0x134
	terrain_effects: bool,       // +0x135
	has_spawn_info: bool,        // +0x136
	owner:         Entity_Ref,   // +0x138
	pool_index:    i32,          // +0x140
	entry_counts:  [MAX_STATES]i32, // +0x144 times each state was entered
	// +0x194 holds one spawn-info list per state, but the original only ever
	// reads or resets the current state's (both SpawnControl and
	// Priv_CheckSpawningAbilityAtStateChange index by +0x9e, and a state
	// change resets the new state's list), so one list is equivalent. It
	// keeps State small enough to snapshot every frame for rollback.
	spawn_info:    [MAX_SPAWN_SETS]Spawn_Info,
	// Not the original's; all zero unless a passive shaped the entity.
	passive_tag:   u8,  // the weapon passive (see passive_tag)
	passive_depth: u8,  // spawners between it and the weapon
	spawn_pace:    i32, // 0, or its spawn sets' pace in hundredths of a step
	pace_acc:      i32,
	spawn_clock:   i32, // the time its spawn sets run at, when paced
}

Group :: struct {
	link:        Link,
	used:        bool,
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

World :: struct {
	entities:        [MAX_ENTITIES]Entity,
	entity_used:     [MAX_ENTITIES]bool, // DAT_004e0d88, stride 10
	entity_links:    [MAX_ENTITIES]Link,
	used_count:      i32, // DAT_004e0d84
	free_hint:       i32, // DAT_004e0d80

	groups:          [MAX_GROUPS]Group,
	group_links:     [MAX_GROUPS]Link,
	active:          List, // DAT_004e0d70
	required:        List, // DAT_004e0d6c: level placements not yet spawned

	next_entity:     i32, // DAT_004e0d78
	next_group:      i32, // DAT_004e0d7c
	ground_targets:  i32, // DAT_004e34a6
	limit_warned:    bool, // DAT_004e3499
}

group_alloc :: proc "contextless" (w: ^World) -> i32 {
	for &g, i in w.groups {
		if !g.used {
			g = Group{used = true, entities = list_init()}
			return i32(i)
		}
	}
	return NO_LINK
}

group_free :: proc "contextless" (w: ^World, i: i32) {
	w.groups[i] = {}
}
