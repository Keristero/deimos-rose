// Reference traces of the original game, recorded under gdb by
// tools/oracle/trace.py while it plays its demo films.
//
// The original's RNG is reproduced exactly (sim/rand.odin), so its state at
// any point is fixed by the seed and the number of draws. A trace therefore
// records *who* drew and with what bounds, and the simulation is correct up to
// the point where its own Draw_Log stops agreeing. That point, named by the
// original's call-site address, is where porting work continues.
package oracle

import "core:strconv"
import "core:strings"

import "dr:sim"

// One film's worth of trace: everything from its srand to the next.
Film_Trace :: struct {
	seed:  u32,
	// G_Film::GetInputs calls for player 1. A film of N frames shows N + 1:
	// the last call is the one that finds the film exhausted.
	steps: u32,
	calls: [dynamic]sim.Draw,
	// rand() steps seen. Every call with unequal bounds must account for
	// exactly one; `unpaired` counts any that did not, i.e. direct rand()
	// callers the trace does not attribute. Nonzero means the trace hooks
	// are incomplete.
	draws:    int,
	unpaired: int,
}

Trace_Error :: enum {
	None,
	Malformed_Line,
}

// Parses a trace. Lines from threads other than the one that called srand are
// ignored: the RNG state is thread-local in MSL, so they cannot affect the
// film's sequence. Lines before the first srand (the title menu) are dropped.
trace_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	films: [dynamic]Film_Trace,
	line_no: int,
	err: Trace_Error,
) {
	films = make([dynamic]Film_Trace, allocator)
	cur: ^Film_Trace
	film_tid := ""
	pending := false // an N/F call is waiting for its rand()

	text := text
	for line in strings.split_lines_iterator(&text) {
		line_no += 1
		if len(line) == 0 {
			continue
		}
		f: [5]string
		n := 0
		rest := line
		for field in strings.fields_iterator(&rest) {
			if n == len(f) {
				return films, line_no, .Malformed_Line
			}
			f[n] = field
			n += 1
		}
		if n < 2 {
			return films, line_no, .Malformed_Line
		}
		kind, tid := f[0], f[1]

		if kind == "S" {
			if n != 3 {
				return films, line_no, .Malformed_Line
			}
			seed, ok := strconv.parse_uint(f[2], 10)
			if !ok {
				return films, line_no, .Malformed_Line
			}
			append(&films, Film_Trace{seed = u32(seed), calls = make([dynamic]sim.Draw, allocator)})
			cur = &films[len(films) - 1]
			film_tid = tid
			pending = false
			continue
		}
		if cur == nil || tid != film_tid {
			continue
		}

		switch kind {
		case "D":
			cur.draws += 1
			if pending {
				pending = false
			} else {
				cur.unpaired += 1
			}
		case "N", "F":
			if n != 5 {
				return films, line_no, .Malformed_Line
			}
			site, ok1 := strconv.parse_uint(f[2], 0)
			d := sim.Draw{site = sim.Site(site), frame = cur.steps}
			ok2, ok3: bool
			if kind == "N" {
				d.kind = .Int
				lo, hi: int
				lo, ok2 = strconv.parse_int(f[3], 10)
				hi, ok3 = strconv.parse_int(f[4], 10)
				d.a, d.b = u32(i32(lo)), u32(i32(hi))
			} else {
				d.kind = .Float
				a, b: uint
				a, ok2 = strconv.parse_uint(f[3], 16)
				b, ok3 = strconv.parse_uint(f[4], 16)
				d.a, d.b = u32(a), u32(b)
			}
			if !(ok1 && ok2 && ok3) {
				return films, line_no, .Malformed_Line
			}
			append(&cur.calls, d)
			pending = d.a != d.b
		case "I":
			if n != 4 {
				return films, line_no, .Malformed_Line
			}
			if f[2] == "0" {
				cur.steps += 1
			}
		case:
			return films, line_no, .Malformed_Line
		}
	}
	return films, line_no, .None
}

trace_destroy :: proc(films: [dynamic]Film_Trace) {
	for f in films {
		delete(f.calls)
	}
	delete(films)
}
