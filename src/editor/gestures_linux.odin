package editor

// A touchpad's pinch and its two-finger scroll, on Linux. raylib's GLFW
// (3.4, X11 only in Odin's vendor build, so XWayland under Wayland) tells
// of no gestures at all, and of scrolling only as the core protocol's
// wheel clicks, a whole notch each: a touchpad's scroll in steps. X tells
// of both: XInput 2.4's pinch events, which XWayland makes from the
// compositor's (since 22.1) and libXi decodes (since 1.8), and XInput
// 2.1's smooth scrolling, a pointer's scroll axes moving by fractions of a
// notch in its motion events. So the editor opens an X connection of its
// own beside GLFW's, asks it for 2.4 and selects the pinch and the motion
// on GLFW's window. A connection's XI version and selections are its own:
// GLFW's, at 2.0, sees nothing new, and still gets the clicks, which the
// editor then leaves unread (gestures_poll's `smooth`).
//
// libX11 and libXi are loaded when the editor starts, not linked: the
// build stays as raylib's is, and without them there is just GLFW's.
//
// Evidence: the layouts below are libXi 1.8.3's, as C probes built
// against its headers printed them (x86-64); with Xvfb 21.1 a second
// connection is given 2.4 although GLFW's asked for 2.0, and selecting on
// GLFW's window from it succeeds. Xvfb has no touchpad, and its pointers
// no scroll axes, so neither the pinch nor the smooth scroll can be made
// headless: what they deliver is untested here, but the reading of a
// motion's axes is (tests/editor).

import "core:c"
import "core:dynlib"
import "core:fmt"

import rl "vendor:raylib"

// The scroll axes kept: a pointer has two, and XWayland's pointers are
// few.
SCROLL_AXES_MAX :: 16

Gestures :: struct {
	x11:     X11,
	xi:      Xi,
	display: rawptr,
	opcode:  c.int, // XInput's, which its events carry
	last:    f64, // the pinch's scale so far, from its beginning
	axes:    [SCROLL_AXES_MAX]Scroll_Axis,
	count:   int,
	// A scroll axis has moved: the wheel is read from them from then on,
	// not from GLFW's clicks, which would count it twice.
	smooth:  bool,
}

// A device's scroll axis, and where it was last.
Scroll_Axis :: struct {
	device:     c.int,
	number:     c.int, // its valuator
	horizontal: bool,
	increment:  f64, // a notch, in the axis's units
	at:         f64,
	known:      bool, // `at` is: after the pointer comes in, it is not
}

// One frame's: the zoom's factor, 1 for none, and the wheel in notches as
// GLFW's are, +y up and +x left; `smooth` when the wheel is this, not
// GLFW's.
Gesture_Input :: struct {
	zoom:   f32,
	scroll: [2]f32,
	smooth: bool,
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
	__handle:         dynlib.Library,
	XIQueryVersion:   proc "c" (d: rawptr, major, minor: ^c.int) -> c.int,
	XISelectEvents:   proc "c" (d: rawptr, window: c.ulong, masks: ^XIEventMask, count: c.int) -> c.int,
	XIQueryDevice:    proc "c" (d: rawptr, device: c.int, count: ^c.int) -> [^]XIDeviceInfo,
	XIFreeDeviceInfo: proc "c" (info: [^]XIDeviceInfo),
}

@(private = "file")
Error_Handler :: proc "c" (d: rawptr, event: rawptr) -> c.int

// Xlib's and XInput2.h's.
@(private = "file")
GENERIC_EVENT :: 35
@(private = "file")
XI_ALL_DEVICES :: 0
@(private = "file")
XI_ALL_MASTER_DEVICES :: 1
@(private = "file")
XI_SCROLL_CLASS :: 3
@(private = "file")
XI_SCROLL_TYPE_HORIZONTAL :: 2
@(private = "file")
XI_DEVICE_CHANGED :: 1
@(private = "file")
XI_MOTION :: 6
@(private = "file")
XI_ENTER :: 7
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

// The head every XI2 event shares; XIEnterEvent and XIDeviceChangedEvent
// are no more than this to us.
@(private = "file")
XIEvent :: struct {
	type:       c.int,
	serial:     c.ulong,
	send_event: b32,
	display:    rawptr,
	extension:  c.int,
	evtype:     c.int,
	time:       c.ulong,
	deviceid:   c.int,
	sourceid:   c.int,
}

@(private = "file")
XIDeviceEvent :: struct {
	using head: XIEvent,
	detail:     c.int,
	root:       c.ulong,
	event:      c.ulong,
	child:      c.ulong,
	root_x:     f64,
	root_y:     f64,
	event_x:    f64,
	event_y:    f64,
	flags:      c.int,
	buttons:    struct {
		mask_len: c.int,
		mask:     [^]u8,
	},
	valuators:  struct {
		mask_len: c.int,
		mask:     [^]u8,
		values:   [^]f64, // one for each bit set in the mask, in order
	},
	mods:       [4]c.int,
	group:      [4]c.int,
}

@(private = "file")
XIGesturePinchEvent :: struct {
	using head:      XIEvent,
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

@(private)
XIDeviceInfo :: struct {
	deviceid:    c.int,
	name:        cstring,
	use:         c.int,
	attachment:  c.int,
	enabled:     b32,
	num_classes: c.int,
	classes:     [^]^XIAnyClassInfo,
}

@(private)
XIAnyClassInfo :: struct {
	type:     c.int,
	sourceid: c.int,
}

@(private = "file")
XIScrollClassInfo :: struct {
	using any:   XIAnyClassInfo,
	number:      c.int,
	scroll_type: c.int,
	increment:   f64,
	flags:       c.int,
}

#assert(size_of(XEvent) == 192)
#assert(offset_of(XGenericEventCookie, extension) == 32 && offset_of(XGenericEventCookie, data) == 48)
#assert(size_of(XIEventMask) == 16)
#assert(offset_of(XIEvent, evtype) == 36 && offset_of(XIEvent, sourceid) == 52)
#assert(offset_of(XIDeviceEvent, event_x) == 104 && offset_of(XIDeviceEvent, valuators) == 144)
#assert(offset_of(XIDeviceEvent, mods) == 168 && size_of(XIDeviceEvent) == 200)
#assert(offset_of(XIGesturePinchEvent, event_x) == 104)
#assert(offset_of(XIGesturePinchEvent, scale) == 152 && offset_of(XIGesturePinchEvent, flags) == 168)
#assert(size_of(XIGesturePinchEvent) == 208)
#assert(offset_of(XIDeviceInfo, num_classes) == 28 && offset_of(XIDeviceInfo, classes) == 32 && size_of(XIDeviceInfo) == 40)
#assert(offset_of(XIScrollClassInfo, number) == 8 && offset_of(XIScrollClassInfo, increment) == 16 && size_of(XIScrollClassInfo) == 32)

// An X error on our connection, in gestures_init: Xlib's own handler
// would end the process, as GLFW guards against too (x11_init.c).
@(private = "file")
x_error: bool

@(private = "file")
on_x_error :: proc "c" (d: rawptr, event: rawptr) -> c.int {
	x_error = true
	return 0
}

// Selects the pinch and the motion on the editor's window, after
// InitWindow. False, and why on stderr, where they cannot be: then
// gestures_poll has nothing, and the wheel is GLFW's.
gestures_init :: proc(g: ^Gestures) -> bool {
	fail :: proc(g: ^Gestures, why: string) -> bool {
		fmt.eprintfln("deimos-editor: no touchpad pinch or smooth scroll (%s): zoom with Ctrl and the wheel", why)
		gestures_destroy(g)
		return false
	}
	if n, _ := dynlib.initialize_symbols(&g.x11, "libX11.so.6"); n != size_of(X11) / size_of(rawptr) - 1 {
		return fail(g, "no libX11")
	}
	if n, _ := dynlib.initialize_symbols(&g.xi, "libXi.so.6"); n != size_of(Xi) / size_of(rawptr) - 1 {
		return fail(g, "no libXi 1.8")
	}
	handle := rl.GetWindowHandle()
	if handle == nil {
		return fail(g, "no window")
	}
	// raylib's GetWindowHandle, on X11, is a pointer to its window's id.
	window := (cast(^c.ulong)handle)^
	g.display = g.x11.XOpenDisplay(nil)
	if g.display == nil {
		return fail(g, "no X display")
	}
	event, error: c.int
	if !g.x11.XQueryExtension(g.display, "XInputExtension", &g.opcode, &event, &error) {
		return fail(g, "no XInput")
	}
	major, minor := c.int(2), c.int(4)
	if g.xi.XIQueryVersion(g.display, &major, &minor) != 0 || major < 2 || major == 2 && minor < 4 {
		return fail(g, fmt.tprintf("XInput %d.%d, not 2.4", major, minor))
	}
	mask: [(XI_LASTEVENT >> 3) + 1]u8
	for e in ([?]int{XI_DEVICE_CHANGED, XI_MOTION, XI_ENTER, XI_GESTURE_PINCH_BEGIN, XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END}) {
		mask[e >> 3] |= 1 << uint(e & 7)
	}
	masks := XIEventMask{XI_ALL_MASTER_DEVICES, c.int(len(mask)), raw_data(mask[:])}
	x_error = false
	old := g.x11.XSetErrorHandler(on_x_error)
	selected := g.xi.XISelectEvents(g.display, window, &masks, 1) == 0
	g.x11.XSync(g.display, false)
	g.x11.XSetErrorHandler(old)
	if !selected || x_error {
		return fail(g, "the window refused it")
	}
	g.last = 1
	gestures_axes(g)
	return true
}

// The devices' scroll axes, where none is known yet.
@(private = "file")
gestures_axes :: proc(g: ^Gestures) {
	g.count = 0
	n: c.int
	info := g.xi.XIQueryDevice(g.display, XI_ALL_DEVICES, &n)
	if info == nil {
		return
	}
	defer g.xi.XIFreeDeviceInfo(info)
	for d in info[:n] {
		for k in 0 ..< d.num_classes {
			class := d.classes[k]
			if class.type != XI_SCROLL_CLASS || g.count == SCROLL_AXES_MAX {
				continue
			}
			s := cast(^XIScrollClassInfo)class
			if s.increment != 0 {
				g.axes[g.count] = {
					device     = d.deviceid,
					number     = s.number,
					horizontal = s.scroll_type == XI_SCROLL_TYPE_HORIZONTAL,
					increment  = s.increment,
				}
				g.count += 1
			}
		}
	}
}

// What the pinch and the scroll axes did since the last poll.
gestures_poll :: proc(g: ^Gestures) -> Gesture_Input {
	out := Gesture_Input {
		zoom = 1,
	}
	if g.display == nil {
		return out
	}
	zoom := f64(1)
	for g.x11.XPending(g.display) > 0 {
		event: XEvent
		g.x11.XNextEvent(g.display, &event)
		cookie := cast(^XGenericEventCookie)&event
		if cookie.type != GENERIC_EVENT || cookie.extension != g.opcode || !g.x11.XGetEventData(g.display, cookie) {
			continue
		}
		head := cast(^XIEvent)cookie.data
		switch cookie.evtype {
		case XI_MOTION:
			m := cast(^XIDeviceEvent)cookie.data
			v := m.valuators
			out.scroll += gestures_motion(g, m.sourceid, v.mask[:max(v.mask_len, 0)], v.values)
		case XI_ENTER:
			// Its axes moved while it was elsewhere, as far as we know.
			for &a in g.axes[:g.count] {
				if a.device == head.sourceid {
					a.known = false
				}
			}
		case XI_DEVICE_CHANGED:
			gestures_axes(g)
		// The scale is the fingers' spread over theirs at the beginning.
		case XI_GESTURE_PINCH_BEGIN:
			g.last = 1
		case XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END:
			pinch := cast(^XIGesturePinchEvent)cookie.data
			if pinch.scale > 0 && g.last > 0 {
				zoom *= pinch.scale / g.last
			}
			g.last = pinch.scale
		}
		g.x11.XFreeEventData(g.display, cookie)
	}
	out.zoom, out.smooth = f32(zoom), g.smooth
	return out
}

// A motion's scroll, in notches as GLFW's are: `values` holds one value
// for each valuator set in `mask`, and those that are `source`'s scroll
// axes moved from where they were, by increments; down and right are up
// the axes, as X's buttons 5 and 7. An axis's first value is where it is,
// not a move.
gestures_motion :: proc(g: ^Gestures, source: c.int, mask: []u8, values: [^]f64) -> (notches: [2]f32) {
	k := 0
	for byte, i in mask {
		for b in 0 ..< 8 {
			if byte & (1 << uint(b)) == 0 {
				continue
			}
			value := values[k]
			k += 1
			for &a in g.axes[:g.count] {
				if a.device != source || int(a.number) != i * 8 + b {
					continue
				}
				if a.known && value != a.at {
					notches[a.horizontal ? 0 : 1] -= f32((value - a.at) / a.increment)
					g.smooth = true
				}
				a.at, a.known = value, true
			}
		}
	}
	return
}

gestures_destroy :: proc(g: ^Gestures) {
	if g.display != nil {
		g.x11.XCloseDisplay(g.display)
	}
	if g.xi.__handle != nil {
		dynlib.unload_library(g.xi.__handle)
	}
	if g.x11.__handle != nil {
		dynlib.unload_library(g.x11.__handle)
	}
	g^ = {}
}
