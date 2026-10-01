#+build !linux
package editor

// No pinch but Linux's (pinch_linux.odin): Windows' precision touchpads
// send theirs as Ctrl and the wheel, which zooms anyway; elsewhere, that
// is the zoom.

Pinch :: struct {}

pinch_init :: proc(p: ^Pinch) -> bool {
	return false
}

pinch_poll :: proc(p: ^Pinch) -> f32 {
	return 1
}

pinch_destroy :: proc(p: ^Pinch) {}
