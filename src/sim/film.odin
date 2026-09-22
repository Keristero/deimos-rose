package sim

// In-memory replay. The original G_Film stores a seed, a level id, a game type
// and one input word per player per frame -- see G_Film::GetRandomSeed,
// ::GetLevelID, ::GetGameType and ::GetInputs in symbols/functions.csv.
//
// Parsing the on-disk v10005 format is data/'s job; this package only holds the
// decoded result so that sim/ stays free of I/O.
Film :: struct {
	session: Session,
	frames:  []Frame_Input,
}

// Replay a film from frame zero, invoking `observe` after each step. Returns
// the final state. Used by the regression harness to diff against recorded
// traces.
replay :: proc(film: Film, observe: proc(s: ^State) = nil) -> State {
	s: State
	init(&s, film.session)
	for input in film.frames {
		step(&s, input)
		if observe != nil {
			observe(&s)
		}
	}
	return s
}
