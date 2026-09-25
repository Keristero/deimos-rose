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

// A film is finished once every player in it has read past its last frame
// (G_Film::IsFinished), i.e. made frames + 1 reads.
film_finished :: proc "contextless" (s: ^State, film: ^Film) -> bool {
	return int(single(s, Film_Cursor).reads[0]) > len(film.frames)
}

// Replay a film into `s` (State is large: callers own it, usually on the heap).
// `max_steps` bounds a replay that never finishes, e.g. one that has diverged.
replay :: proc(s: ^State, film: ^Film, defs: ^Defs, log: ^Draw_Log = nil, max_steps := 1_000_000, events: ^Event_Log = nil) {
	init(s, film.session, defs, log, events)
	for i := 0; i < max_steps && !film_finished(s, film); i += 1 {
		step(s, {}, film)
	}
}
