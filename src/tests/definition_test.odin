package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "dr:data"

@(test)
rule_conditions_cover_the_whole_vocabulary :: proc(t: ^testing.T) {
	// 17 conditions plus the unspecified slot.
	testing.expect_value(t, len(data.RULE_CONDITION_NAMES), 18)

	c, ok := data.rule_condition_from("No Destroyable Air or Ground Entities Are Active")
	testing.expect(t, ok, "known condition")
	testing.expect_value(t, c, data.Rule_Condition.No_Destroyable_Air_Or_Ground_Entities_Are_Active)

	blank, ok2 := data.rule_condition_from("   ")
	testing.expect(t, ok2, "blank is unspecified, not an error")
	testing.expect_value(t, blank, data.Rule_Condition.Unspecified)

	_, ok3 := data.rule_condition_from("Invent A Condition")
	testing.expect(t, !ok3, "unknown condition must be rejected")

	// Every name is distinct, so the table has no accidental duplicates.
	seen := make(map[string]bool, 20, context.temp_allocator)
	for name in data.RULE_CONDITION_NAMES {
		testing.expectf(t, !(name in seen), "duplicate condition name %q", name)
		seen[name] = true
	}
}

@(private = "file")
encode_def :: proc(plain: string, allocator := context.allocator) -> []byte {
	table: [128]u8
	seen: [128]bool
	for c in 0 ..= 255 {
		v := data.tagged_decode_byte(u8(c))
		if v < 128 && !seen[v] {
			seen[v] = true
			table[v] = u8(c)
		}
	}
	out := make([]byte, len(plain), allocator)
	for i in 0 ..< len(plain) {
		out[i] = table[plain[i] & 0x7f]
	}
	return out
}

@(test)
definition_parses_nested_scopes :: proc(t: ^testing.T) {
	src := "#name_STR <Test Unit>\r#score_INT <500>\r#numStates_INT <2>\r" +
		"#stateName_STR <Wait>\r#stateMaxSpeed_FLOAT <1.5>\r" +
		"#stateNumSpawnSets_INT <1>\r" +
		"#stateSpawnSetName_STR <Volley>\r#stateSpawnSetSpawn_ID <bu01>\r" +
		"#stateSpawnSetXOffset_INT <208>\r#stateSpawnSetYOffset_INT <-100>\r" +
		"#stateSpawnSet_AbsoluteCoordinates_BOOL <TRUE>\r" +
		"#stateNumRules_INT <2>\r" +
		"#stateRuleName_STR <R1>\r#stateRuleUnit_ID <none>\r#stateRuleRange_INT <0>\r" +
		"#stateRuleCondition_STR <Is Active>\r#stateRuleAction_STR <Delete>\r" +
		"#stateRuleName_STR <R2>\r#stateRuleUnit_ID <bu01>\r#stateRuleRange_INT <40>\r" +
		"#stateRuleCondition_STR <No Players Are Active>\r#stateRuleAction_STR <Wait>\r" +
		"#stateName_STR <Fire>\r#stateNumSpawnSets_INT <0>\r#stateNumRules_INT <0>\r"

	enc := encode_def(src)
	defer delete(enc)
	def, err := data.definition_parse(data.fourcc_from("test"), enc)
	defer data.definition_destroy(&def)

	testing.expect_value(t, err, data.Def_Error.None)
	testing.expect_value(t, data.def_str(def.header, "name_STR"), "Test Unit")
	testing.expect_value(t, data.def_int(def.header, "score_INT"), 500)
	testing.expect_value(t, len(def.states), 2)

	s0 := def.states[0]
	testing.expect_value(t, s0.name, "Wait")
	testing.expect_value(t, data.def_float(s0.fields, "stateMaxSpeed_FLOAT"), 1.5)
	testing.expect_value(t, len(s0.spawn_sets), 1)
	testing.expect_value(t, s0.spawn_sets[0].x_offset, 208)
	testing.expect_value(t, s0.spawn_sets[0].y_offset, -100)
	testing.expect(t, s0.spawn_sets[0].absolute_coords, "absolute coords")

	testing.expect_value(t, len(s0.rules), 2)
	testing.expect_value(t, s0.rules[0].condition, data.Rule_Condition.Is_Active)
	testing.expect_value(t, s0.rules[0].action, "Delete")
	testing.expect_value(t, s0.rules[1].range, 40)
	testing.expect_value(t, s0.rules[1].condition, data.Rule_Condition.No_Players_Are_Active)

	testing.expect_value(t, def.states[1].name, "Fire")
	testing.expect_value(t, len(def.states[1].rules), 0)
}

@(test)
definition_rejects_a_bad_state_count :: proc(t: ^testing.T) {
	src := "#name_STR <X>\r#numStates_INT <3>\r#stateName_STR <A>\r" +
		"#stateNumSpawnSets_INT <0>\r#stateNumRules_INT <0>\r"
	enc := encode_def(src)
	defer delete(enc)
	def, err := data.definition_parse(data.fourcc_from("bad "), enc)
	defer data.definition_destroy(&def)
	testing.expect_value(t, err, data.Def_Error.State_Count_Mismatch)
}

// --- integration ----------------------------------------------------------

@(private = "file")
parse_dir :: proc(
	t: ^testing.T,
	type: string,
) -> (
	files, states, rules, spawn_sets: int,
) {
	dir := fmt.tprintf("%s/records/%s", ASSETS, type)
	handle, oerr := os.open(dir)
	if oerr != nil {
		return
	}
	defer os.close(handle)
	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for e in entries {
		if !strings.has_suffix(e.name, ".bin") {
			continue
		}
		raw, err := os.read_entire_file(
			fmt.tprintf("%s/%s", dir, e.name), context.temp_allocator)
		if err != nil {
			continue
		}
		id := strings.trim_suffix(e.name, ".bin")
		def, perr := data.definition_parse(
			data.fourcc_from(id), raw, context.temp_allocator)
		testing.expectf(t, perr == .None, "%v/%v: %v", type, id, perr)
		if perr != .None {
			continue
		}
		files += 1
		states += len(def.states)
		for s in def.states {
			rules += len(s.rules)
			spawn_sets += len(s.spawn_sets)
		}
	}
	return
}

@(test)
all_unit_definitions_reconcile :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records/unde") {
		return
	}
	files, states, rules, sets := parse_dir(t, "unde")
	// Every declared count matches its contents across the whole corpus.
	testing.expect_value(t, files, 386)
	testing.expect_value(t, states, 1167)
	testing.expect_value(t, rules, 5835)
	testing.expect_value(t, sets, 532)
}

@(test)
weapon_and_player_definitions_are_flat :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records/wede") {
		return
	}
	wf, ws, _, _ := parse_dir(t, "wede")
	testing.expect_value(t, wf, 5)
	testing.expect_value(t, ws, 0)

	pf, ps, _, _ := parse_dir(t, "plde")
	testing.expect_value(t, pf, 2)
	testing.expect_value(t, ps, 0)
}

@(test)
every_rule_condition_in_the_corpus_is_known :: proc(t: ^testing.T) {
	if !os.exists(ASSETS + "/records/unde") {
		return
	}
	dir := ASSETS + "/records/unde"
	handle, oerr := os.open(dir)
	if oerr != nil {
		return
	}
	defer os.close(handle)
	entries, _ := os.read_directory(handle, -1, context.temp_allocator)

	used: bit_set[data.Rule_Condition]
	for e in entries {
		raw, err := os.read_entire_file(
			fmt.tprintf("%s/%s", dir, e.name), context.temp_allocator)
		if err != nil {
			continue
		}
		text := data.tagged_decode(raw, context.temp_allocator)
		for tag in data.tagged_parse(text, context.temp_allocator) {
			if tag.key != "stateRuleCondition_STR" {
				continue
			}
			c, ok := data.rule_condition_from(tag.value)
			testing.expectf(t, ok, "unknown condition %q", tag.value)
			used += {c}
		}
	}
	// The campaign exercises 9 of the 17, plus the unspecified slot.
	testing.expect_value(t, card(used), 10)
}
