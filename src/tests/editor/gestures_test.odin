#+build linux
package editor_tests

// The editor's touchpad gestures under X (editor/gestures_linux.odin): what
// XInput 2 reports, and that GLFW still sees the pointer. Linux's alone, as
// the gestures are; editor_draws calls the two that need its window.

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import rl "vendor:raylib"

import "dr:editor"

// A motion's scroll axes, as XWayland's pointer has them (valuators 2
// and 3 after x and y), read as notches: the first value of each is where
// it is, and then each move is by its increment, down and right negative
// as GLFW's wheel has them. Another device's are not these.
@(test)
smooth_scroll_reads_the_axes :: proc(t: ^testing.T) {
	g: editor.Gestures
	g.axes[0] = {device = 6, number = 2, horizontal = true, increment = 10}
	g.axes[1] = {device = 6, number = 3, increment = 120}
	g.count = 2
	motion :: proc(g: ^editor.Gestures, source: c.int, mask: u8, values: ..f64) -> [2]f32 {
		m := [1]u8{mask}
		return editor.gestures_motion(g, source, m[:], raw_data(values))
	}
	// Raw motion: the values are moves, x and y's too, which are not
	// scroll.
	testing.expect_value(t, motion(&g, 6, 0b0011, 5, 7), [2]f32{})
	testing.expect_value(t, motion(&g, 6, 0b1100, 0, 0), [2]f32{})
	testing.expect(t, !g.smooth, "smooth before an axis moved")
	testing.expect_value(t, motion(&g, 6, 0b1011, 5, 7, 60), [2]f32{0, -0.5})
	testing.expect(t, g.smooth, "not smooth once an axis moved")
	testing.expect_value(t, motion(&g, 6, 0b0100, -20), [2]f32{2, 0})
	testing.expect_value(t, motion(&g, 7, 0b1100, 30, 30), [2]f32{})
	testing.expect_value(t, motion(&g, 6, 0b1100, 10, -120), [2]f32{-1, 1})
}

// Under X (xvfb-run's has XInput 2.4), the pinch and the raw motion are
// selected, and with no touchpad there is neither a pinch nor a scroll.
gestures_select :: proc(t: ^testing.T) {
	if lib, ok := dynlib.load_library("libXi.so.6"); ok {
		dynlib.unload_library(lib)
	} else {
		fmt.println("gestures_select: no libXi, skipped")
		return
	}
	g: editor.Gestures
	defer editor.gestures_destroy(&g)
	if testing.expect(t, editor.gestures_init(&g), "no gestures under X with libXi") {
		testing.expect_value(t, editor.gestures_poll(&g), editor.Gesture_Input{zoom = 1})
	}
}

// With the gestures selected, GLFW still sees the pointer: the server
// gives a pointer's event on a window to one selection, XI2's first, and
// XI_Motion selected on GLFW's window once took its motion, so raylib's
// mouse stood still and raygui's buttons went dead. The window is shown
// and the pointer warped onto it, on Xvfb only (DR_XVFB, from mise's
// test): never the desktop's pointer.
gestures_leave_glfw_the_pointer :: proc(t: ^testing.T) {
	if os.get_env("DR_XVFB", context.temp_allocator) == "" {
		fmt.println("gestures_leave_glfw_the_pointer: not on Xvfb, skipped")
		return
	}
	X :: struct {
		__handle:      dynlib.Library,
		XOpenDisplay:  proc "c" (name: cstring) -> rawptr,
		XCloseDisplay: proc "c" (d: rawptr) -> c.int,
		XWarpPointer:  proc "c" (d: rawptr, src, dest: c.ulong, sx, sy: c.int, sw, sh: c.uint, dx, dy: c.int) -> c.int,
		XSync:         proc "c" (d: rawptr, discard: b32) -> c.int,
	}
	x: X
	if n, _ := dynlib.initialize_symbols(&x, "libX11.so.6"); n != size_of(X) / size_of(rawptr) - 1 {
		fmt.println("gestures_leave_glfw_the_pointer: no libX11, skipped")
		return
	}
	defer dynlib.unload_library(x.__handle)
	display := x.XOpenDisplay(nil)
	if !testing.expect(t, display != nil) {
		return
	}
	defer x.XCloseDisplay(display)
	g: editor.Gestures
	defer editor.gestures_destroy(&g)
	if !editor.gestures_init(&g) {
		return // gestures_select says why
	}
	rl.ClearWindowState({.WINDOW_HIDDEN})
	defer rl.SetWindowState({.WINDOW_HIDDEN})
	window := (cast(^c.ulong)rl.GetWindowHandle())^
	for to in ([?][2]c.int{{20, 30}, {41, 12}}) {
		seen := false
		// Mapping the window, and the warp's events, take a moment.
		for _ in 0 ..< 100 {
			x.XWarpPointer(display, 0, window, 0, 0, 0, 0, to.x, to.y)
			x.XSync(display, false)
			rl.PollInputEvents()
			editor.gestures_poll(&g)
			if rl.GetMousePosition() == {f32(to.x), f32(to.y)} {
				seen = true
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		testing.expectf(t, seen, "the pointer at %v, raylib's at %v", to, rl.GetMousePosition())
	}
	testing.expect(t, rl.IsCursorOnScreen(), "GLFW was not told the pointer came in")
}
