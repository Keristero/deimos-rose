package sim

// This step's new notices (notice_system), for presentation to show.

Notice_Event :: struct {
	text: string,
}

MAX_NOTICE_EVENTS :: 8

Notice_Queue :: struct {
	events: [MAX_NOTICE_EVENTS]Notice_Event,
	count:  int,
}
