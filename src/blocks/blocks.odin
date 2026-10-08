package blocks

// One copy of every package's state, however many modules carry the
// package (Phase 10, decisions.md D83).
//
// A plugin built as a shared library compiles its own copy of every
// package it imports -- sim, data, render, other plugins -- globals
// included. Left alone, a plugin's systems would register into its copy
// of sim and the game would never see them. So a package keeps all its
// mutable state in one struct, its block, and reads it through one
// pointer:
//
//	Shared :: struct { ... }
//	@(private) shared_block: Shared
//	@(private) shared := &shared_block
//
// and declares that pointer here from an `@(init)`. Binding a plugin
// points each of its copies' `shared` at the game's block, so both read
// and write the same state. A spike on 2026-10-08 showed the binding
// works, and that typeids agree between modules (phase-10 doc).
//
// `mise run purity` fails any other mutable package-level variable
// outside `@(rodata)` (tools/globals). This package's own list is the one
// exception: it is what a module has, and so is meant to be its own.
//
// Pure, so sim/ may import it: no allocation, no I/O.

MAX_BLOCKS :: 64

Block :: struct {
	name:  string, // the package's import path, "sim" or "plugins/chaingun"
	ptr:   ^rawptr, // the package's `shared`: what binding repoints
	type:  typeid, // its Shared, which must match the game's
	// What the package made before it was bound -- sim's registration
	// steps, queued from the plugin's `@(init)`s at load -- carried into
	// the block it is bound to. nil when there is nothing to carry.
	merge: proc(local, bound: rawptr),
}

Table :: struct {
	items: [MAX_BLOCKS]Block,
	count: int,
}

// This module's blocks.
@(private)
declared: Table

// Called from `@(init)` only, once per package. contextless, as `@(init)`
// procedures are.
declare :: proc "contextless" (b: Block) {
	for d in declared.items[:declared.count] {
		if d.name == b.name {
			return
		}
	}
	if declared.count == MAX_BLOCKS {
		// Panicking here would run before any context exists; binding
		// finds the missing block instead (bind's `missing`).
		return
	}
	declared.items[declared.count] = b
	declared.count += 1
}

// This module's blocks, by the game to hand to a plugin's bind.
table :: proc "contextless" () -> ^Table {
	return &declared
}

find :: proc "contextless" (t: ^Table, name: string) -> (^Block, bool) {
	for &b in t.items[:t.count] {
		if b.name == name {
			return &b, true
		}
	}
	return nil, false
}

Bind_Error :: enum {
	None,
	Type_Mismatch, // a package's state differs from the game's: built from other sources
	Full, // the game's table has no room for the plugin's own packages
}

// Points this module's blocks at `host`'s, the game's: called in a plugin,
// with the game's table. A package the game does not have (another
// plugin's) joins the table, so the next plugin to carry it binds to this
// one's. All or nothing: a type mismatch binds no block, and names it.
bind :: proc(host: ^Table) -> (err: Bind_Error, name: string) {
	return bind_tables(&declared, host)
}

// bind's work on any two tables, so a test can bind tables of its own.
bind_tables :: proc(local, host: ^Table) -> (err: Bind_Error, name: string) {
	joining := 0
	for &b in local.items[:local.count] {
		if h, ok := find(host, b.name); ok {
			if h.type != b.type {
				return .Type_Mismatch, b.name
			}
		} else {
			joining += 1
		}
	}
	if host.count + joining > MAX_BLOCKS {
		return .Full, ""
	}
	for &b in local.items[:local.count] {
		h, ok := find(host, b.name)
		if !ok {
			host.items[host.count] = b
			host.count += 1
			continue
		}
		if h.ptr == b.ptr || h.ptr^ == b.ptr^ {
			continue // the same module, or bound already
		}
		before := b.ptr^
		b.ptr^ = h.ptr^
		if b.merge != nil {
			b.merge(before, b.ptr^)
		}
	}
	return .None, ""
}
