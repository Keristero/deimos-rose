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

// A demo is over when its session is: the game is lost, the level's tally
// has finished, or the film has run out. The original starts the next demo
// at the first of these. Its traces of the players' films (mise run
// assets:films) show it: pd01's session makes its last film read, 4490, on
// the step our Level_End.complete is set, 20 frames before the film ends,
// and the next session's nag draw (G_Game_Play+0x26) follows at once. pd02,
// pd03, pd04 and dl01 stop on the same step as complete, too.
demo_over :: proc "contextless" (s: ^State, film: ^Film) -> bool {
	return single(s, Game_Status).game_over || single(s, Level_End).complete || film_finished(s, film)
}

// Replay a film into `s` (State is large: callers own it, usually on the heap).
// `max_steps` bounds a replay that never finishes, e.g. one that has diverged.
replay :: proc(s: ^State, film: ^Film, defs: ^Defs, log: ^Draw_Log = nil, max_steps := 1_000_000, events: ^Event_Log = nil) {
	init(s, film.session, defs, log, events)
	for i := 0; i < max_steps && !film_finished(s, film); i += 1 {
		step(s, {}, film)
	}
}
