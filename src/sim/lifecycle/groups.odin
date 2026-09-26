package lifecycle

// Leaving a group, and the end of G_EG_Process: deleted entities swept up
// and their slots freed.

import "dr:sim"

// What G_EG_Process does with a change of state's two out-parameters:
// delete or destroy the entity, ending its step, or carry on.
entity_carry_on :: proc(s: ^sim.State, e: sim.Entity, del, des: bool, time: i32) -> bool {
	if del {
		entity_delete(e)
		return false
	}
	if des {
		entity_destroy(s, e, -1, time)
		return false
	}
	return true
}

// Marks the entity for the sweep.
entity_delete :: proc "contextless" (e: sim.Entity) {
	e.deleted = true
	e.target_player = -1
}

// G_Entity::GetAngleFromSpriteInfo: the heading the current frame depicts.
angle_from_sprite :: proc "contextless" (s: ^sim.State, e: sim.Entity) -> i32 {
	if e.state < 0 {
		return 0
	}
	st := sim.state_of(s, e)
	if st.num_directions == 1 {
		return (360 / st.frames_per_direction) * e.frame
	}
	d := max(e.frame / st.frames_per_direction, 0)
	return (360 / st.num_directions) * d
}

// FUN_0041b2d0: remove deleted entities, and groups that have emptied.
sweep_deleted :: proc(s: ^sim.State) {
	w := sim.single(s, sim.Pool)
	walk := sim.cursor_walk(s, fixed = true)
	for e, ei in sim.cursor_next(&walk) {
		gi := walk.group
		if !e.deleted {
			continue
		}
		u := sim.unit_of(s, e)
		if u.include_in_ground_accuracy_count {
			w.ground_targets -= 1
		}
		// The wreck is burned into the map as the entity is swept up, so
		// it stays where it fell and scrolls with the ground.
		if u.destruct_draw_to_terrain {
			sim.stamp_object(s, e.obj, u.casts_shadows)
		}
		if e.destroyed {
			if sim.state_of(s, e).destroy_owner_on_destruction && sim.ref_valid(s, e.owner) {
				o := sim.entity_at(s, e.owner.index)
				if !o.deleted {
					entity_destroy(s, o, e.target_player, sim.single(s, sim.Clock).time)
				}
			}
		}
		if u.deletion_spawn != sim.NONE && !e.destroyed && can_spawn_on_media(s, e) {
			spawn_from(s, e, u.deletion_spawn)
		}
		group_emptied := remove_from_group(s, gi, e, e.destroyed, e.target_player != -1)
		sim.list_remove(&sim.group_at(s, gi).entities, sim.entity_links(s), ei, &walk.ec)
		entity_free(s, ei)
		if group_emptied && sim.group_at(s, gi).unit != sim.PERM_GROUP_UNIT {
			sim.list_remove(&w.active, sim.group_links(s), gi, &walk.gc)
			sim.group_free(s, gi)
			sim.cursor_leave_group(&walk)
		}
	}
}

// FUN_0041ae10: account for an entity leaving its group. Returns true when
// the group has no entities left (and is not PERM).
remove_from_group :: proc(s: ^sim.State, gi: i32, e: sim.Entity, destroyed, by_player: bool) -> bool {
	g := sim.group_at(s, gi)
	u := sim.unit_of(s, e)
	if e.has_spawn_info {
		if destroyed && u.destruct_destroy_children {
			children_follow(s, e, true)
		}
		if u.destruct_delete_children {
			children_follow(s, e, false)
		}
	}
	all_killed := false
	if destroyed {
		g.killed += 1
		all_killed = g.killed == g.count
	}
	if by_player && destroyed && !e.killed_by_player {
		if u.destruct_coin != sim.NONE && u.destruct_num_coins_to_release > 0 {
			for _ in 0 ..< u.destruct_num_coins_to_release {
				spawn_from(s, e, u.destruct_coin)
			}
		}
		if g.unit != sim.PERM_GROUP_UNIT && all_killed && u.destruct_coin_on_group_kill != sim.NONE {
			spawn_from(s, e, u.destruct_coin_on_group_kill)
		}
	}
	// Destroy is a no-op for an entity the sweep already marked deleted, but
	// not for a child pulled in by children_follow.
	if destroyed {
		entity_destroy(s, e, e.target_player, sim.single(s, sim.Clock).time)
	}
	e.deleted = true
	g.total -= 1
	return g.total < 1 && g.unit != sim.PERM_GROUP_UNIT
}

// FUN_0041b090 / FUN_0041b1b0: when a spawner dies or is deleted, its
// children follow if their state allows it. The group totals are decremented
// here and again when the sweep reaches the child -- as in the original.
children_follow :: proc(s: ^sim.State, parent: sim.Entity, destroyed: bool) {
	walk := sim.cursor_walk(s, fixed = true)
	for c in sim.cursor_next(&walk) {
		if c == parent || c.owner.number != parent.number {
			continue
		}
		st := sim.state_of(s, c)
		if destroyed {
			if st.can_be_destroyed_on_owner_destruction {
				remove_from_group(s, walk.group, c, true, c.target_player != -1)
			}
		} else if st.can_be_deleted_on_owner_deletion {
			remove_from_group(s, walk.group, c, false, false)
		}
	}
}

// The end of G_EG_Process.
sweep_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sweep_deleted(s)
}
