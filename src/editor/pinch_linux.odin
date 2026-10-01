package editor

// A touchpad's pinch, on Linux. raylib's GLFW (3.4, X11 only in Odin's
// vendor build, so XWayland under Wayland) tells of no gestures at all,
// but X does: XInput 2.4's pinch events, which XWayland makes from the
// compositor's (since 22.1) and libXi decodes (since 1.8). So the editor
// opens an X connection of its own beside GLFW's, asks it for 2.4 and
// selects the pinch on GLFW's window. A connection's XI version and
// selections are its own: GLFW's, at 2.0, sees nothing new.
//
// libX11 and libXi are loaded when the editor starts, not linked: the
// build stays as raylib's is, and without them there is just no pinch.
//
// Evidence: the event's layout below is libXi 1.8.3's, as a C probe built
// against its headers printed it (x86-64); with Xvfb 21.1 a second
// connection is given 2.4 although GLFW's asked for 2.0, and selecting
// the pinch on GLFW's window from it succeeds. The pinch itself cannot be
// made headless (Xvfb has no touchpad), so its delivery is untested here.

import "core:c"
import "core:dynlib"
import "core:fmt"

import rl "vendor:raylib"

Pinch :: struct {
	x11:     X11,
	xi:      Xi,
	display: rawptr,
	opcode:  c.int, // XInput's, which its events carry
	last:    f64, // the pinch's scale so far, from its beginning
}

@(private)
X11 :: struct {
	__handle:         dynlib.Library,
	XOpenDisplay:     proc "c" (name: cstring) -> rawptr,
	XCloseDisplay:    proc "c" (d: rawptr) -> c.int,
	XQueryExtension:  proc "c" (d: rawptr, name: cstring, opcode, event, error: ^c.int) -> b32,
	XSync:            proc "c" (d: rawptr, discard: b32) -> c.int,
	XSetErrorHandler: proc "c" (handler: Error_Handler) -> Error_Handler,
	XPending:         proc "c" (d: rawptr) -> c.int,
	XNextEvent:       proc "c" (d: rawptr, event: ^XEvent) -> c.int,
	XGetEventData:    proc "c" (d: rawptr, cookie: ^XGenericEventCookie) -> b32,
	XFreeEventData:   proc "c" (d: rawptr, cookie: ^XGenericEventCookie),
}

@(private)
Xi :: struct {
	__handle:       dynlib.Library,
	XIQueryVersion: proc "c" (d: rawptr, major, minor: ^c.int) -> c.int,
	XISelectEvents: proc "c" (d: rawptr, window: c.ulong, masks: ^XIEventMask, count: c.int) -> c.int,
}

@(private = "file")
Error_Handler :: proc "c" (d: rawptr, event: rawptr) -> c.int

// Xlib's and XInput2.h's.
@(private = "file")
GENERIC_EVENT :: 35
@(private = "file")
XI_ALL_MASTER_DEVICES :: 1
@(private = "file")
XI_GESTURE_PINCH_BEGIN :: 27
@(private = "file")
XI_GESTURE_PINCH_UPDATE :: 28
@(private = "file")
XI_GESTURE_PINCH_END :: 29
@(private = "file")
XI_LASTEVENT :: XI_GESTURE_PINCH_END + 3 // XI_GestureSwipeEnd, 32

// Xlib's union: 24 longs.
@(private = "file")
XEvent :: struct {
	pad: [24]c.long,
}

@(private = "file")
XGenericEventCookie :: struct {
	type:       c.int,
	serial:     c.ulong,
	send_event: b32,
	display:    rawptr,
	extension:  c.int,
	evtype:     c.int,
	cookie:     c.uint,
	data:       rawptr,
}

@(private = "file")
XIEventMask :: struct {
	deviceid: c.int,
	mask_len: c.int,
	mask:     [^]u8,
}

@(private = "file")
XIGesturePinchEvent :: struct {
	type:            c.int,
	serial:          c.ulong,
	send_event:      b32,
	display:         rawptr,
	extension:       c.int,
	evtype:          c.int,
	time:            c.ulong,
	deviceid:        c.int,
	sourceid:        c.int,
	detail:          c.int,
	root:            c.ulong,
	event:           c.ulong,
	child:           c.ulong,
	root_x:          f64,
	root_y:          f64,
	event_x:         f64,
	event_y:         f64,
	delta_x:         f64,
	delta_y:         f64,
	delta_unaccel_x: f64,
	delta_unaccel_y: f64,
	scale:           f64,
	delta_angle:     f64,
	flags:           c.int,
	mods:            [4]c.int,
	group:           [4]c.int,
}

#assert(size_of(XEvent) == 192)
#assert(offset_of(XGenericEventCookie, extension) == 32 && offset_of(XGenericEventCookie, data) == 48)
#assert(size_of(XIEventMask) == 16)
#assert(offset_of(XIGesturePinchEvent, evtype) == 36 && offset_of(XIGesturePinchEvent, event_x) == 104)
#assert(offset_of(XIGesturePinchEvent, scale) == 152 && offset_of(XIGesturePinchEvent, flags) == 168)
#assert(size_of(XIGesturePinchEvent) == 208)

// An X error on our connection, in pinch_init: Xlib's own handler would
// end the process, as GLFW guards against too (x11_init.c).
@(private = "file")
x_error: bool

@(private = "file")
on_x_error :: proc "c" (d: rawptr, event: rawptr) -> c.int {
	x_error = true
	return 0
}

// Selects the pinch on the editor's window, after InitWindow. False, and
// why on stderr, where there is none: then pinch_poll is always 1.
pinch_init :: proc(p: ^Pinch) -> bool {
	fail :: proc(p: ^Pinch, why: string) -> bool {
		fmt.eprintfln("deimos-editor: no touchpad pinch (%s): zoom with Ctrl and the wheel", why)
		pinch_destroy(p)
		return false
	}
	if n, _ := dynlib.initialize_symbols(&p.x11, "libX11.so.6"); n != size_of(X11) / size_of(rawptr) - 1 {
		return fail(p, "no libX11")
	}
	if n, _ := dynlib.initialize_symbols(&p.xi, "libXi.so.6"); n != size_of(Xi) / size_of(rawptr) - 1 {
		return fail(p, "no libXi 1.8")
	}
	handle := rl.GetWindowHandle()
	if handle == nil {
		return fail(p, "no window")
	}
	// raylib's GetWindowHandle, on X11, is a pointer to its window's id.
	window := (cast(^c.ulong)handle)^
	p.display = p.x11.XOpenDisplay(nil)
	if p.display == nil {
		return fail(p, "no X display")
	}
	event, error: c.int
	if !p.x11.XQueryExtension(p.display, "XInputExtension", &p.opcode, &event, &error) {
		return fail(p, "no XInput")
	}
	major, minor := c.int(2), c.int(4)
	if p.xi.XIQueryVersion(p.display, &major, &minor) != 0 || major < 2 || major == 2 && minor < 4 {
		return fail(p, fmt.tprintf("XInput %d.%d, not 2.4", major, minor))
	}
	mask: [(XI_LASTEVENT >> 3) + 1]u8
	for e in ([?]int{XI_GESTURE_PINCH_BEGIN, XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END}) {
		mask[e >> 3] |= 1 << uint(e & 7)
	}
	masks := XIEventMask{XI_ALL_MASTER_DEVICES, c.int(len(mask)), raw_data(mask[:])}
	x_error = false
	old := p.x11.XSetErrorHandler(on_x_error)
	selected := p.xi.XISelectEvents(p.display, window, &masks, 1) == 0
	p.x11.XSync(p.display, false)
	p.x11.XSetErrorHandler(old)
	if !selected || x_error {
		return fail(p, "the window refused it")
	}
	p.last = 1
	return true
}

// The zoom's factor the pinch made since the last poll: 1 for none.
pinch_poll :: proc(p: ^Pinch) -> f32 {
	if p.display == nil {
		return 1
	}
	factor := f64(1)
	for p.x11.XPending(p.display) > 0 {
		event: XEvent
		p.x11.XNextEvent(p.display, &event)
		cookie := cast(^XGenericEventCookie)&event
		if cookie.type != GENERIC_EVENT || cookie.extension != p.opcode || !p.x11.XGetEventData(p.display, cookie) {
			continue
		}
		pinch := cast(^XIGesturePinchEvent)cookie.data
		// The scale is the fingers' spread over theirs at the beginning.
		switch cookie.evtype {
		case XI_GESTURE_PINCH_BEGIN:
			p.last = 1
		case XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END:
			if pinch.scale > 0 && p.last > 0 {
				factor *= pinch.scale / p.last
			}
			p.last = pinch.scale
		}
		p.x11.XFreeEventData(p.display, cookie)
	}
	return f32(factor)
}

pinch_destroy :: proc(p: ^Pinch) {
	if p.display != nil {
		p.x11.XCloseDisplay(p.display)
	}
	if p.xi.__handle != nil {
		dynlib.unload_library(p.xi.__handle)
	}
	if p.x11.__handle != nil {
		dynlib.unload_library(p.x11.__handle)
	}
	p^ = {}
}
