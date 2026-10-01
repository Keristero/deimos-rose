#+build !linux
package editor

// No gestures but Linux's (gestures_linux.odin): Windows' precision
// touchpads send their pinch as Ctrl and the wheel, which zooms anyway,
// and their scroll as the wheel in fractions of a notch, which GLFW
// passes on as it is.

Gestures :: struct {}

Gesture_Input :: struct {
	zoom:   f32,
	scroll: [2]f32,
	smooth: bool,
}

gestures_init :: proc(g: ^Gestures) -> bool {
	return false
}

gestures_poll :: proc(g: ^Gestures) -> Gesture_Input {
	return {zoom = 1}
}

gestures_destroy :: proc(g: ^Gestures) {}
