package globals

// Lists the package-level variables of Odin packages: what a shared
// library loaded as a plugin would get its own copy of (Phase 10,
// docs/phase-10-plugin-split.md). Parsed with core:odin/parser rather
// than grepped, so a declaration inside a `when` block, or spread over
// several lines, is found like any other.
//
//   globals <package dir>...
//
// Prints `file:line  name  attributes` for each, one per line.
//
//   globals -check <package dir>...
//
// Fails on any that a plugin's copy would hold apart from the game's: a
// mutable package-level variable that is neither `@(rodata)` nor the
// package's block (`shared_block`, `shared`), any `@(static)` local, and
// a block given an initialiser, which moves it from .bss into the
// executable (decisions.md D83). `mise run purity` runs it over every package a
// plugin can import.

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

Global :: struct {
	file:  string,
	line:  int,
	name:  string,
	attrs: string,
	local: bool, // a `@(static)` inside a procedure
	init:  bool, // given a value where it is declared
}

// The `@(static)` locals that are safe: a cache of what the shared block
// holds, which every copy fills from it.
STATIC_ALLOWED :: [?]string {
	"sim/ecs.odin:id", // component_slot: an index into the shared catalog, found by catalog_find
}

main :: proc() {
	args := os.args[1:]
	check := len(args) > 0 && args[0] == "-check"
	if check {
		args = args[1:]
	}
	found: [dynamic]Global
	for dir in args {
		pkg, ok := parser.parse_package_from_path(dir)
		if !ok {
			fmt.eprintfln("globals: %s does not parse", dir)
			os.exit(1)
		}
		for _, file in pkg.files {
			for decl in file.decls {
				collect(decl, file.fullpath, &found)
			}
		}
	}
	slice.sort_by(found[:], proc(a, b: Global) -> bool {
		return a.file < b.file || (a.file == b.file && a.line < b.line)
	})
	if !check {
		for g in found {
			fmt.printfln("%s:%d\t%s\t%s", g.file, g.line, g.name, g.attrs)
		}
		return
	}
	bad := 0
	for g in found {
		if g.name == "shared_block" && g.init {
			fmt.eprintfln("%s:%d: a block starts zeroed; an initialiser writes all of it into the executable's data", g.file, g.line)
			bad += 1
		}
		if !held_apart(g) {
			continue
		}
		if g.local {
			fmt.eprintfln("%s:%d: the static %s would be a plugin's own copy; keep it in the package's Shared block", g.file, g.line, g.name)
		} else {
			fmt.eprintfln("%s:%d: the global %s would be a plugin's own copy; put it in the package's Shared block, or make it @(rodata)", g.file, g.line, g.name)
		}
		bad += 1
	}
	if bad > 0 {
		os.exit(1)
	}
}

// Whether a plugin's copy of this variable would differ from the game's.
held_apart :: proc(g: Global) -> bool {
	if g.local {
		for allowed in STATIC_ALLOWED {
			// The parser's paths have Windows' backslashes there.
			file, _ := strings.replace_all(g.file, "\\", "/", context.temp_allocator)
			if strings.has_suffix(fmt.tprintf("%s:%s", file, g.name), allowed) {
				return false
			}
		}
		return true
	}
	if g.name == "shared_block" || g.name == "shared" {
		return false
	}
	for a in strings.split(g.attrs, ",", context.temp_allocator) {
		if a == "rodata" {
			return false
		}
	}
	return true
}

// A top-level declaration, or the declarations in a top-level `when`.
collect :: proc(stmt: ^ast.Stmt, path: string, out: ^[dynamic]Global) {
	#partial switch n in stmt.derived_stmt {
	case ^ast.Value_Decl:
		if !n.is_mutable {
			for v in n.values {
				if p, ok := v.derived_expr.(^ast.Proc_Lit); ok && p.body != nil {
					statics(p.body, path, out)
				}
			}
			return
		}
		attrs := attributes(n.attributes[:])
		for name in n.names {
			if id, ok := name.derived_expr.(^ast.Ident); ok {
				append(out, Global{path, n.pos.line, id.name, attrs, false, len(n.values) > 0})
			}
		}
	case ^ast.When_Stmt:
		collect(n.body, path, out)
		if n.else_stmt != nil {
			collect(n.else_stmt, path, out)
		}
	case ^ast.Block_Stmt:
		for s in n.stmts {
			collect(s, path, out)
		}
	}
}

// The attribute names, comma separated: `private=file,rodata`.
attributes :: proc(list: []^ast.Attribute) -> string {
	b := strings.builder_make()
	for a in list {
		for e in a.elems {
			name := e
			if fv, ok := e.derived_expr.(^ast.Field_Value); ok {
				name = fv.field
			}
			if id, ok := name.derived_expr.(^ast.Ident); ok {
				if strings.builder_len(b) > 0 {
					strings.write_byte(&b, ',')
				}
				strings.write_string(&b, id.name)
			}
		}
	}
	return strings.to_string(b)
}

// The `@(static)` locals in a procedure's body, nested procedures included.
statics :: proc(body: ^ast.Node, path: string, out: ^[dynamic]Global) {
	Found :: struct {
		path: string,
		out:  ^[dynamic]Global,
	}
	visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil {
			return nil
		}
		if n, ok := node.derived.(^ast.Value_Decl); ok && n.is_mutable {
			attrs := attributes(n.attributes[:])
			for a in strings.split(attrs, ",", context.temp_allocator) {
				if a != "static" {
					continue
				}
				f := (^Found)(v.data)
				for name in n.names {
					if id, ok2 := name.derived_expr.(^ast.Ident); ok2 {
						append(f.out, Global{f.path, n.pos.line, id.name, attrs, true, len(n.values) > 0})
					}
				}
			}
		}
		return v
	}
	f := Found{path, out}
	v := ast.Visitor{visit = visit, data = &f}
	ast.walk(&v, body)
}
