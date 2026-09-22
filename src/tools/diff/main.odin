// Replays the shipped demo films through the simulation and compares its
// random calls with the original's, recorded by `mise run oracle:trace`.
//
//     mise run oracle:diff [trace.txt]
//
// Prints, per film, how many calls match from the start and where the first
// divergence is, named by the original's function. That call site is the next
// thing to port. Exits non-zero while any film diverges.
package diff

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "dr:data"
import "dr:oracle"
import "dr:sim"

Symbol :: struct {
	va:   u32,
	name: string,
}

// Function starts for naming call sites. Prefers the Ghidra export index,
// which also has the file-static functions the CodeView map lacks (without it
// a G_EG static reads as "G_EG_CheckIntegrity+0x2684"); falls back to
// symbols/functions.csv.
load_symbols :: proc() -> []Symbol {
	syms: [dynamic]Symbol
	index := fmt.tprintf("%s/export/index.tsv", os.get_env("DR_DECOMP", context.temp_allocator))
	if text, err := os.read_entire_file(index, context.allocator); err == nil {
		// module, va, size, name, file, status
		s := string(text)
		for line in strings.split_lines_iterator(&s) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) < 6 || f[5] != "ok" {
				continue
			}
			if va, ok := strconv.parse_uint(f[1], 0); ok {
				append(&syms, Symbol{u32(va), f[3]})
			}
		}
	}
	if len(syms) == 0 {
		// kind, section, rva, va, size, name, mangled
		text, err := os.read_entire_file(os.get_env("DR_SYMS", context.temp_allocator), context.allocator)
		if err != nil {
			return nil
		}
		s := string(text)
		for line in strings.split_lines_iterator(&s) {
			f := strings.split(line, ",", context.temp_allocator)
			if len(f) < 6 || f[1] != ".text" {
				continue
			}
			if va, ok := strconv.parse_uint(f[3], 0); ok {
				append(&syms, Symbol{u32(va), f[5]})
			}
		}
	}
	slice.sort_by(syms[:], proc(a, b: Symbol) -> bool { return a.va < b.va })
	return syms[:]
}

site_name :: proc(syms: []Symbol, site: sim.Site) -> string {
	if site == 0 {
		return "unported site"
	}
	i, _ := slice.binary_search_by(syms, u32(site), proc(s: Symbol, v: u32) -> slice.Ordering {
		return slice.cmp(s.va, v)
	})
	// binary_search_by gives the insertion point on a miss.
	if i < len(syms) && syms[i].va == u32(site) {
		return syms[i].name
	}
	if i == 0 {
		return fmt.tprintf("%#x", u32(site))
	}
	s := syms[i - 1]
	return fmt.tprintf("%s+%#x", s.name, u32(site) - s.va)
}

describe :: proc(syms: []Symbol, d: Maybe(sim.Draw)) -> string {
	v, ok := d.?
	if !ok {
		return "(nothing)"
	}
	bounds: string
	if v.kind == .Int {
		bounds = fmt.tprintf("RandomInt(%d, %d)", i32(v.a), i32(v.b))
	} else {
		bounds = fmt.tprintf("RandomFloat(%v, %v)", transmute(f32)v.a, transmute(f32)v.b)
	}
	return fmt.tprintf("%s at step %d from %s [%#x]", bounds, v.frame, site_name(syms, v.site), u32(v.site))
}

main :: proc() {
	trace_path := len(os.args) > 1 ? os.args[1] : fmt.tprintf("%s/../work/wine/traces/trace.txt", os.get_env("DR_SRC", context.temp_allocator))
	films_dir := fmt.tprintf("%s/films", os.get_env("DR_ASSETS", context.temp_allocator))
	syms := load_symbols()

	text, rerr := os.read_entire_file(trace_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("no trace at %s -- run `mise run oracle:trace` first", trace_path)
		os.exit(2)
	}
	traces, line, perr := oracle.trace_parse(string(text))
	if perr != .None {
		fmt.eprintfln("%s:%d: %v", trace_path, line, perr)
		os.exit(2)
	}

	// Index the shipped films by seed; each demo's seed is distinct.
	films: map[u32]string
	for i in 1 ..= 4 {
		name := fmt.tprintf("de%02d", i)
		bytes, ferr := os.read_entire_file(fmt.tprintf("%s/%s.film", films_dir, name), context.allocator)
		if ferr != nil {
			continue
		}
		f, err := data.film_parse(bytes)
		if err == .None {
			films[f.seed] = name
		}
	}

	provider := data.provider_open(os.get_env("DR_ORIG", context.temp_allocator))
	defs, _ := data.defs_load(&provider)
	state := new(sim.State)

	failures := 0
	seen: map[u32]bool
	for t in traces {
		if seen[t.seed] {
			continue // the menu may replay a demo; one comparison is enough
		}
		seen[t.seed] = true
		name, known := films[t.seed]
		if !known {
			fmt.printfln("seed %d: no shipped film has this seed, skipped", t.seed)
			continue
		}
		bytes, _ := os.read_entire_file(fmt.tprintf("%s/%s.film", films_dir, name), context.allocator)
		f, _ := data.film_parse(bytes)
		film := data.film_to_sim(f)

		buf := make([]sim.Draw, 2 * len(t.calls) + 1024)
		log := sim.Draw_Log{draws = buf}
		sim.replay(state, &film, &defs, &log, max_steps = 4 * len(film.frames) + 10_000)
		got := sim.draw_log_entries(&log)
		d := oracle.diff(t.calls[:], got)

		pct := d.want == 0 ? 100.0 : 100.0 * f64(d.matched) / f64(d.want)
		fmt.printfln("%s  seed %d  %d frames  %d steps traced; replay: %d steps, %d film reads",
			name, t.seed, len(film.frames), t.steps, state.frame, state.film_cursor[0])
		fmt.printfln("    calls matched %d / %d (%.1f%%), simulation made %d", d.matched, d.want, pct, d.got)
		if t.unpaired > 0 {
			fmt.printfln("    WARNING: %d rand() calls not attributed to RandomInt/RandomFloat", t.unpaired)
		}
		if log.dropped > 0 {
			fmt.printfln("    WARNING: draw log overflowed by %d", log.dropped)
		}
		div_step := max(i32)
		if div, bad := d.first.?; bad {
			if w, ok := div.want.?; ok {
				div_step = i32(w.frame)
			}
		}
		for g in state.gaps[:state.gap_count] {
			if g.step <= div_step {
				fmt.printfln("    unported before the divergence: %s [%#x] from step %d", site_name(syms, g.site), u32(g.site), g.step)
			}
		}
		if div, bad := d.first.?; bad {
			failures += 1
			fmt.printfln("    first divergence at call %d", div.index)
			fmt.printfln("      original:   %s", describe(syms, div.want))
			fmt.printfln("      simulation: %s", describe(syms, div.got))
		}
	}
	if len(seen) == 0 {
		fmt.eprintln("trace contains no films")
		os.exit(2)
	}
	if failures > 0 {
		os.exit(1)
	}
}
