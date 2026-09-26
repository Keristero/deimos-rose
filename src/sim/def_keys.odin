package sim

// Definition keys a plugin adds to the original's weapon definitions: new
// content's own settings (`x_...` in assets/extra, docs/new-weapons.md),
// which the original never reads. The plugin that gives a key its meaning
// registers it, and the loader (data/assets.odin) fills every registered
// key of every weapon without knowing what any of them is for, so a new
// setting needs no change outside its plugin.
//
// A key's type is its name's suffix, as in the original's own keys: _BOOL,
// _INT, _FLOAT or _ID. The values are kept in a fixed array on the Weapon,
// four bytes each, so a definition stays a plain value like the rest.

MAX_WEAPON_KEYS :: 16

// A registered key, by index into Weapon.keys.
Weapon_Key :: distinct u8

Def_Key_Kind :: enum u8 {
	Bool,
	Int,
	Float,
	Id,
}

Def_Key :: struct {
	name: string,
	kind: Def_Key_Kind,
}

@(private = "file")
weapon_keys: Registry(Def_Key, MAX_WEAPON_KEYS)

// Called from `@(init)` procedures only. `name` must outlive the call (a
// string literal does).
weapon_key_register :: proc(name: string) -> Weapon_Key {
	kind: Def_Key_Kind
	switch {
	case has_suffix(name, "_BOOL"):
		kind = .Bool
	case has_suffix(name, "_INT"):
		kind = .Int
	case has_suffix(name, "_FLOAT"):
		kind = .Float
	case has_suffix(name, "_ID"):
		kind = .Id
	case:
		panic("sim: a definition key's name ends in its type: _BOOL, _INT, _FLOAT or _ID")
	}
	return Weapon_Key(registry_add(&weapon_keys, Def_Key{name, kind}))
}

registered_weapon_keys :: proc "contextless" () -> []Def_Key {
	return registry_items(&weapon_keys)
}

@(private = "file")
has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// What a weapon without the key holds: false, 0, or NONE for an id.
def_key_default :: proc "contextless" (kind: Def_Key_Kind) -> u32 {
	return kind == .Id ? transmute(u32)NONE : 0
}

weapon_bool :: #force_inline proc "contextless" (w: ^Weapon, k: Weapon_Key) -> bool {
	return w.keys[k] != 0
}

weapon_int :: #force_inline proc "contextless" (w: ^Weapon, k: Weapon_Key) -> i32 {
	return i32(w.keys[k])
}

weapon_float :: #force_inline proc "contextless" (w: ^Weapon, k: Weapon_Key) -> f32 {
	return transmute(f32)w.keys[k]
}

weapon_id :: #force_inline proc "contextless" (w: ^Weapon, k: Weapon_Key) -> Res_ID {
	return transmute(Res_ID)w.keys[k]
}

// Sets a key's value: the loader's, and a test's that edits a definition.
weapon_key_set :: proc "contextless" (w: ^Weapon, k: Weapon_Key, value: $T) {
	when T == bool || T == i32 {
		w.keys[k] = u32(value)
	} else {
		#assert(size_of(T) == 4, "a definition key's value is four bytes")
		w.keys[k] = transmute(u32)value
	}
}
