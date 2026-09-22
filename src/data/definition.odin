package data

import "core:strings"

// Unit, weapon and player definitions (`unde`, `wede`, `plde`).
//
// All three are tagged text. Weapon and player definitions are flat. Unit
// definitions nest: a header, then `numStates_INT` states, each of which
// declares `stateNumSpawnSets_INT` spawn sets and `stateNumRules_INT` rules.
//
// Parsing is scope-driven rather than positional. A positional reader matches
// 359 of the 386 unit definitions and then fails: 27 records carry optional
// extra fields -- `stateFleeNorth_BOOL` among them -- inside the state block.
// Keying on the field name and using `stateName_STR`, `stateSpawnSetName_STR`
// and `stateRuleName_STR` as scope openers handles those, and all 386 records
// then reconcile exactly against their declared counts: 1,167 states, 5,835
// rules and 532 spawn sets.

Def_Error :: enum {
	None,
	Missing_State_Count,
	State_Count_Mismatch,
	Spawn_Set_Count_Mismatch,
	Rule_Count_Mismatch,
}

// The complete rule-condition vocabulary, read from a 17-entry table of 64-byte
// strings in the executable at file offset 805379 (a second identical copy sits
// at 903169). The shipped campaign exercises 9 of the 17.
Rule_Condition :: enum u8 {
	Unspecified = 0,
	Is_Tracking_Player,
	Is_Not_Tracking_Player,
	Is_Active,
	Is_Not_Active,
	No_Destroyable_Air_Entities_Are_Active,
	No_Destroyable_Ground_Entities_Are_Active,
	No_Destroyable_Air_Or_Ground_Entities_Are_Active,
	No_Players_Are_Active,
	Within_Range_Of_A_Player,
	Not_Within_Range_Of_A_Player,
	Animation_Has_Stopped,
	Visibility_Is_At_Required_Level,
	Tint_Is_At_Required_Level,
	Scale_Is_At_Required_Level,
	Number_Of_This_Type_Of_Entity_Active,
	Are_Fewer_Of_These_Entities_Active,
	Are_More_Of_These_Entities_Active,
}

// Verbatim table order, so the index matches the executable's dispatch order.
RULE_CONDITION_NAMES := [Rule_Condition]string {
	.Unspecified                                      = "",
	.Is_Tracking_Player                               = "Is Tracking Player",
	.Is_Not_Tracking_Player                           = "Is Not Tracking Player",
	.Is_Active                                        = "Is Active",
	.Is_Not_Active                                    = "Is Not Active",
	.No_Destroyable_Air_Entities_Are_Active           = "No Destroyable Air Entities Are Active",
	.No_Destroyable_Ground_Entities_Are_Active        = "No Destroyable Ground Entities Are Active",
	.No_Destroyable_Air_Or_Ground_Entities_Are_Active = "No Destroyable Air or Ground Entities Are Active",
	.No_Players_Are_Active                            = "No Players Are Active",
	.Within_Range_Of_A_Player                         = "This Entity is Within Range of a Player",
	.Not_Within_Range_Of_A_Player                     = "This Entity is Not Within Range of a Player",
	.Animation_Has_Stopped                            = "This Entity's Animation Has Stopped",
	.Visibility_Is_At_Required_Level                  = "This Entity's Visibility is at Required Level",
	.Tint_Is_At_Required_Level                        = "This Entity's Tint is at Required Level",
	.Scale_Is_At_Required_Level                       = "This Entity's Scale is at Required Level",
	.Number_Of_This_Type_Of_Entity_Active             = "Number of This Type of Entity Active",
	.Are_Fewer_Of_These_Entities_Active               = "Are Fewer of These Entities Active",
	.Are_More_Of_These_Entities_Active                = "Are More of These Entities Active",
}

rule_condition_from :: proc(s: string) -> (Rule_Condition, bool) {
	t := strings.trim_space(s)
	if t == "" {
		return .Unspecified, true
	}
	for name, c in RULE_CONDITION_NAMES {
		if name == t {
			return c, true
		}
	}
	return .Unspecified, false
}

Def_Rule :: struct {
	name:      string,
	unit:      FourCC, // "none"/"NULL" where the rule targets nothing
	range:     int,
	condition: Rule_Condition,
	// The raw action text. It is neither an engine verb nor reliably a state
	// name: only 118 of 2,974 actions name a state in their own record, and
	// none name one in the targeted unit. Kept verbatim until the dispatch is
	// understood -- see docs/phase-3-data.md.
	action: string,
}

Def_Spawn_Set :: struct {
	name:               string,
	spawn:              FourCC,
	x_offset, y_offset: int,
	absolute_coords:    bool,
	repeat_spawns:      bool,
	rate_min, rate_max: int,
	fields:             []Tag,
}

Def_State :: struct {
	name:       string,
	fields:     []Tag,
	spawn_sets: []Def_Spawn_Set,
	rules:      []Def_Rule,
}

// A parsed definition. Typed views sit on top; `header` and each scope's
// `fields` keep every tag verbatim so nothing is lost to an incomplete schema.
Definition :: struct {
	id:     FourCC,
	header: []Tag,
	states: []Def_State,
	text:   []byte, // owns the decoded text the strings alias
	tags:   []Tag,
}

// --- field lookup ---------------------------------------------------------

def_find :: proc(fields: []Tag, key: string) -> (string, bool) {
	for f in fields {
		if f.key == key {
			return f.value, true
		}
	}
	return "", false
}

def_str :: proc(fields: []Tag, key: string, fallback := "") -> string {
	v, ok := def_find(fields, key)
	return ok ? v : fallback
}

def_int :: proc(fields: []Tag, key: string, fallback := 0) -> int {
	if v, ok := def_find(fields, key); ok {
		if n, good := tag_int(v); good {
			return n
		}
	}
	return fallback
}

def_float :: proc(fields: []Tag, key: string, fallback := 0.0) -> f64 {
	if v, ok := def_find(fields, key); ok {
		if n, good := tag_float(v); good {
			return n
		}
	}
	return fallback
}

def_bool :: proc(fields: []Tag, key: string, fallback := false) -> bool {
	if v, ok := def_find(fields, key); ok {
		if b, good := tag_bool(v); good {
			return b
		}
	}
	return fallback
}

def_fourcc :: proc(fields: []Tag, key: string) -> FourCC {
	if v, ok := def_find(fields, key); ok {
		if f, good := tag_fourcc(v); good {
			return f
		}
	}
	return fourcc_from("none")
}

// --- parsing --------------------------------------------------------------

@(private = "file")
STATE_OPEN :: "stateName_STR"
@(private = "file")
SPAWN_OPEN :: "stateSpawnSetName_STR"
@(private = "file")
RULE_OPEN :: "stateRuleName_STR"

definition_parse :: proc(
	id: FourCC,
	encoded: []byte,
	allocator := context.allocator,
) -> (
	def: Definition,
	err: Def_Error,
) {
	def.id = id
	def.text = tagged_decode(encoded, allocator)
	def.tags = tagged_parse(def.text, allocator)

	header := make([dynamic]Tag, 0, 128, allocator)
	states := make([dynamic]Def_State, 0, 8, allocator)

	declared_states := -1
	in_states := false

	// Per-state accumulators.
	cur_fields: [dynamic]Tag
	cur_spawn: [dynamic]Def_Spawn_Set
	cur_rules: [dynamic]Def_Rule
	cur_name: string
	declared_spawn, declared_rules := -1, -1

	// Innermost open sub-scope, so trailing fields land in the right place.
	spawn_fields: [dynamic]Tag
	rule_open := false
	rule: Def_Rule

	flush_rule :: proc(rules: ^[dynamic]Def_Rule, r: ^Def_Rule, open: ^bool) {
		if open^ {
			append(rules, r^)
			r^ = {}
			open^ = false
		}
	}
	flush_spawn :: proc(sets: ^[dynamic]Def_Spawn_Set, fields: ^[dynamic]Tag) {
		if len(sets^) == 0 || fields^ == nil {
			return
		}
		s := &sets^[len(sets^) - 1]
		s.fields = fields^[:]
		s.spawn = def_fourcc(s.fields, "stateSpawnSetSpawn_ID")
		s.x_offset = def_int(s.fields, "stateSpawnSetXOffset_INT")
		s.y_offset = def_int(s.fields, "stateSpawnSetYOffset_INT")
		s.absolute_coords = def_bool(s.fields, "stateSpawnSet_AbsoluteCoordinates_BOOL")
		s.repeat_spawns = def_bool(s.fields, "stateSpawnSetRepeatSpawns_BOOL")
		s.rate_min = def_int(s.fields, "stateSpawnSetRateMin_INT")
		s.rate_max = def_int(s.fields, "stateSpawnSetRateMax_INT")
		fields^ = nil
	}

	close_state := proc(
		states: ^[dynamic]Def_State,
		name: string,
		fields: ^[dynamic]Tag,
		spawn: ^[dynamic]Def_Spawn_Set,
		rules: ^[dynamic]Def_Rule,
	) {
		if fields^ == nil && spawn^ == nil && rules^ == nil && name == "" {
			return
		}
		append(states, Def_State{
			name       = name,
			fields     = fields^ == nil ? nil : fields^[:],
			spawn_sets = spawn^ == nil ? nil : spawn^[:],
			rules      = rules^ == nil ? nil : rules^[:],
		})
		fields^, spawn^, rules^ = nil, nil, nil
	}

	for t in def.tags {
		switch t.key {
		case "numStates_INT":
			declared_states, _ = tag_int(t.value)
			in_states = true
			continue

		case STATE_OPEN:
			flush_rule(&cur_rules, &rule, &rule_open)
			flush_spawn(&cur_spawn, &spawn_fields)
			if len(states) > 0 || cur_name != "" || cur_fields != nil {
				// Validate the state we are closing.
				if declared_spawn >= 0 && declared_spawn != len(cur_spawn) {
					return def, .Spawn_Set_Count_Mismatch
				}
				if declared_rules >= 0 && declared_rules != len(cur_rules) {
					return def, .Rule_Count_Mismatch
				}
			}
			close_state(&states, cur_name, &cur_fields, &cur_spawn, &cur_rules)
			cur_name = t.value
			cur_fields = make([dynamic]Tag, 0, 96, allocator)
			cur_spawn = make([dynamic]Def_Spawn_Set, 0, 2, allocator)
			cur_rules = make([dynamic]Def_Rule, 0, 8, allocator)
			declared_spawn, declared_rules = -1, -1
			continue

		case "stateNumSpawnSets_INT":
			declared_spawn, _ = tag_int(t.value)
			continue

		case SPAWN_OPEN:
			flush_spawn(&cur_spawn, &spawn_fields)
			append(&cur_spawn, Def_Spawn_Set{name = t.value})
			spawn_fields = make([dynamic]Tag, 0, 24, allocator)
			append(&spawn_fields, t)
			continue

		case "stateNumRules_INT":
			flush_spawn(&cur_spawn, &spawn_fields)
			declared_rules, _ = tag_int(t.value)
			continue

		case RULE_OPEN:
			flush_rule(&cur_rules, &rule, &rule_open)
			rule = Def_Rule{name = t.value}
			rule_open = true
			continue

		case "stateRuleUnit_ID":
			if rule_open {
				rule.unit, _ = tag_fourcc(t.value)
				continue
			}
		case "stateRuleRange_INT":
			if rule_open {
				rule.range, _ = tag_int(t.value)
				continue
			}
		case "stateRuleCondition_STR":
			if rule_open {
				rule.condition, _ = rule_condition_from(t.value)
				continue
			}
		case "stateRuleAction_STR":
			if rule_open {
				rule.action = t.value
				continue
			}
		}

		switch {
		case !in_states:
			append(&header, t)
		case spawn_fields != nil:
			append(&spawn_fields, t)
		case cur_fields != nil:
			append(&cur_fields, t)
		case:
			append(&header, t)
		}
	}

	flush_rule(&cur_rules, &rule, &rule_open)
	flush_spawn(&cur_spawn, &spawn_fields)
	if declared_spawn >= 0 && declared_spawn != len(cur_spawn) {
		return def, .Spawn_Set_Count_Mismatch
	}
	if declared_rules >= 0 && declared_rules != len(cur_rules) {
		return def, .Rule_Count_Mismatch
	}
	close_state(&states, cur_name, &cur_fields, &cur_spawn, &cur_rules)

	def.header = header[:]
	def.states = states[:]

	if declared_states < 0 {
		// Flat definitions (wede, plde) declare no states at all.
		if len(def.states) != 0 {
			return def, .Missing_State_Count
		}
	} else if declared_states != len(def.states) {
		return def, .State_Count_Mismatch
	}
	return def, .None
}

definition_destroy :: proc(d: ^Definition, allocator := context.allocator) {
	for s in d.states {
		for ss in s.spawn_sets {
			delete(ss.fields, allocator)
		}
		delete(s.spawn_sets, allocator)
		delete(s.rules, allocator)
		delete(s.fields, allocator)
	}
	delete(d.states, allocator)
	delete(d.header, allocator)
	delete(d.tags, allocator)
	delete(d.text, allocator)
	d^ = {}
}
