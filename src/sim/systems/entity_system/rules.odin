package entity_system

// A state's rules: the conditions under which an entity moves to another
// state.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/movement_system"

// G_Entity::ProcessRules: the first rule whose condition holds changes state.
//
// A rule's "action" is a state name handed to ChangeState; one that names no
// state of this unit silently does nothing, which is why most shipped actions
// look inert. Rules whose unit id is unknown are skipped (the original logs
// "FILE: Unknown Rule Unit ID" and blanks the id, with the same effect).
process_rules :: proc(s: ^sim.State, e: sim.Entity, time: i32) -> (delete, destroy: bool) {
	st := sim.state_of(s, e)
	for &r in st.rules {
		if r.unit == sim.NONE || sim.unit_index(s.defs, r.unit) < 0 || r.condition == 0 {
			continue
		}
		hit := false
		switch r.condition - 1 {
		case 0:
			hit = any_entity_of(s, r.unit, e.loc, r.range, true)
		case 1:
			hit = !any_entity_of(s, r.unit, e.loc, r.range, true)
		case 2:
			hit = any_entity_of(s, r.unit, e.loc, r.range, false)
		case 3:
			hit = !any_entity_of(s, r.unit, e.loc, r.range, false)
		case 4:
			hit = !any_destroyable(s, air = true)
		case 5:
			hit = !any_destroyable(s, air = false)
		case 6:
			hit = !any_destroyable(s, air = true) && !any_destroyable(s, air = false)
		case 7:
			hit = sim.players_in_play(s) == 0
		case 8, 9:
			// G_Entity::Priv_CheckWithinRangeOfPlayers.
			within := false
			if r.range != 0 {
				_, dist, _, found := movement_system.closest_active_player(s, e.loc)
				within = found && dist < f32(r.range)
			}
			hit = r.condition - 1 == 8 ? within : !within
		case 10:
			hit = e.anim_done
		case 11:
			hit = e.visibility == e.visibility_target
		case 12:
			hit = e.tint == e.tint_target
		case 13:
			hit = e.scale == e.scale_target
		case 14:
			hit = r.range == count_appeared(s, r.unit)
		case 15:
			hit = count_appeared(s, r.unit) < r.range
		case 16:
			hit = r.range < count_appeared(s, r.unit)
		}
		if hit {
			return lifecycle.change_state(s, e, false, r.action, time)
		}
	}
	return
}

// G_EG_RuleCondition_IsEntityActive / IsEntityTrackingPlayer: an appeared
// entity of the unit, within `range` of `from` (0 = anywhere). "Tracking"
// additionally needs the entity to be rotating towards its target.
any_entity_of :: proc "contextless" (s: ^sim.State, unit: sim.Res_ID, from: sim.Vec, range: i32, tracking: bool) -> bool {
	walk := sim.walk_entities(s)
	for o in sim.walk_next(&walk) {
		if s.defs.units[o.unit].id == unit && o.appear_delay < 1 && (!tracking || o.rotating) {
			if range == 0 || sim.distance_to(from, o.loc) <= f32(range) {
				return true
			}
		}
	}
	return false
}

// G_EG_RuleCondition_IsAnyDestroyable{Air,Ground}EntityActive: counted by
// the accuracy flags. Ground entities must also be within the game area.
any_destroyable :: proc(s: ^sim.State, air: bool) -> bool {
	walk := sim.walk_entities(s)
	for o in sim.walk_next(&walk) {
		u := &s.defs.units[o.unit]
		if air && u.include_in_air_accuracy_count {
			return true
		}
		if !air && u.include_in_ground_accuracy_count && movement_system.within_game_area(s, o) {
			return true
		}
	}
	return false
}

// G_EG_RuleCondition_GetNumEntitiesActive_ByEntityType.
count_appeared :: proc "contextless" (s: ^sim.State, unit: sim.Res_ID) -> (n: i32) {
	if unit == sim.NONE {
		return
	}
	walk := sim.walk_entities(s)
	for o in sim.walk_next(&walk) {
		if s.defs.units[o.unit].id == unit && o.appear_delay < 1 {
			n += 1
		}
	}
	return
}
