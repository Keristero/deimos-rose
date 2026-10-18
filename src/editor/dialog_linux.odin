package editor

// The system's file dialog, on Linux: the desktop portal's (XDG Desktop
// Portal, org.freedesktop.portal.FileChooser), so it is the desktop's own,
// KDE's or GNOME's, and works from a sandbox too. It is asked over D-Bus:
// OpenFile answers at once with a request, and the request's Response
// signal comes when the dialog is closed, with the file. Both are read off
// the connection each frame, so the editor keeps drawing meanwhile.
//
// libdbus is loaded when the editor starts, not linked, as libX11 is
// (gestures_linux.odin): without it, or without a portal, the dialog is
// not there, and Open opens the path typed in instead.
//
// Evidence: the layouts below are dbus/dbus-message.h's and
// dbus/dbus-errors.h's (libdbus 1.x, whose ABI is stable), for x86-64;
// the portal's method, options and signal are its documented API (version
// 1 and later), and tests/editor plays the portal on a private bus. KDE's
// portal on the developer's machine answers OpenFile (version 4).

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

File_Dialog :: struct {
	dbus:       Dbus,
	connection: rawptr,
	serial:     u32, // OpenFile's, which its reply carries
	request:    string, // the request's path, whose Response is awaited
	open:       bool,
	purpose:    Dialog_Purpose,
}

// libdbus's procedures, as tests/editor uses them too.
Dbus :: struct {
	__handle:                          dynlib.Library,
	dbus_error_init:                   proc "c" (e: ^Dbus_Error),
	dbus_error_free:                   proc "c" (e: ^Dbus_Error),
	dbus_bus_get_private:              proc "c" (bus: c.int, e: ^Dbus_Error) -> rawptr,
	dbus_bus_get_unique_name:          proc "c" (conn: rawptr) -> cstring,
	dbus_bus_add_match:                proc "c" (conn: rawptr, rule: cstring, e: ^Dbus_Error),
	dbus_bus_request_name:             proc "c" (conn: rawptr, name: cstring, flags: c.uint, e: ^Dbus_Error) -> c.int,
	dbus_bus_release_name:             proc "c" (conn: rawptr, name: cstring, e: ^Dbus_Error) -> c.int,
	dbus_connection_set_exit_on_disconnect: proc "c" (conn: rawptr, exit: b32),
	dbus_connection_close:             proc "c" (conn: rawptr),
	dbus_connection_unref:             proc "c" (conn: rawptr),
	dbus_connection_send:              proc "c" (conn: rawptr, msg: rawptr, serial: ^u32) -> b32,
	dbus_connection_flush:             proc "c" (conn: rawptr),
	dbus_connection_read_write:        proc "c" (conn: rawptr, timeout_ms: c.int) -> b32,
	dbus_connection_pop_message:       proc "c" (conn: rawptr) -> rawptr,
	dbus_message_new_method_call:      proc "c" (dest, path, iface, method: cstring) -> rawptr,
	dbus_message_new_method_return:    proc "c" (call: rawptr) -> rawptr,
	dbus_message_new_signal:           proc "c" (path, iface, name: cstring) -> rawptr,
	dbus_message_unref:                proc "c" (msg: rawptr),
	dbus_message_get_type:             proc "c" (msg: rawptr) -> c.int,
	dbus_message_get_reply_serial:     proc "c" (msg: rawptr) -> u32,
	dbus_message_get_path:             proc "c" (msg: rawptr) -> cstring,
	dbus_message_get_sender:           proc "c" (msg: rawptr) -> cstring,
	dbus_message_get_error_name:       proc "c" (msg: rawptr) -> cstring,
	dbus_message_is_signal:            proc "c" (msg: rawptr, iface, name: cstring) -> b32,
	dbus_message_is_method_call:       proc "c" (msg: rawptr, iface, method: cstring) -> b32,
	dbus_message_has_signature:        proc "c" (msg: rawptr, signature: cstring) -> b32,
	dbus_message_iter_init:            proc "c" (msg: rawptr, iter: ^Dbus_Iter) -> b32,
	dbus_message_iter_init_append:     proc "c" (msg: rawptr, iter: ^Dbus_Iter),
	dbus_message_iter_append_basic:    proc "c" (iter: ^Dbus_Iter, type: c.int, value: rawptr) -> b32,
	dbus_message_iter_append_fixed_array: proc "c" (iter: ^Dbus_Iter, type: c.int, value: rawptr, count: c.int) -> b32,
	dbus_message_iter_open_container:  proc "c" (iter: ^Dbus_Iter, type: c.int, signature: cstring, sub: ^Dbus_Iter) -> b32,
	dbus_message_iter_close_container: proc "c" (iter: ^Dbus_Iter, sub: ^Dbus_Iter) -> b32,
	dbus_message_iter_get_arg_type:    proc "c" (iter: ^Dbus_Iter) -> c.int,
	dbus_message_iter_get_basic:       proc "c" (iter: ^Dbus_Iter, value: rawptr),
	dbus_message_iter_next:            proc "c" (iter: ^Dbus_Iter) -> b32,
	dbus_message_iter_recurse:         proc "c" (iter: ^Dbus_Iter, sub: ^Dbus_Iter),
}

Dbus_Error :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    c.uint, // five one-bit fields
	padding1: rawptr,
}

Dbus_Iter :: struct {
	dummy1:  rawptr,
	dummy2:  rawptr,
	dummy3:  u32,
	dummy4:  [8]c.int,
	pad1:    c.int,
	pad2:    rawptr,
	pad3:    rawptr,
}

#assert(size_of(Dbus_Error) == 32 && size_of(Dbus_Iter) == 72)

// dbus-protocol.h's and dbus-shared.h's.
DBUS_BUS_SESSION :: 0
DBUS_MESSAGE_TYPE_METHOD_RETURN :: 2
DBUS_MESSAGE_TYPE_ERROR :: 3
DBUS_TYPE_ARRAY :: 'a'
DBUS_TYPE_BOOLEAN :: 'b'
DBUS_TYPE_BYTE :: 'y'
DBUS_TYPE_DICT_ENTRY :: 'e'
DBUS_TYPE_OBJECT_PATH :: 'o'
DBUS_TYPE_STRING :: 's'
DBUS_TYPE_STRUCT :: 'r'
DBUS_TYPE_UINT32 :: 'u'
DBUS_TYPE_VARIANT :: 'v'

PORTAL_NAME :: "org.freedesktop.portal.Desktop"
PORTAL_PATH :: "/org/freedesktop/portal/desktop"
PORTAL_FILE_CHOOSER :: "org.freedesktop.portal.FileChooser"
PORTAL_REQUEST :: "org.freedesktop.portal.Request"

// libdbus, loaded; false where it is not there.
dbus_load :: proc(d: ^Dbus) -> bool {
	n, _ := dynlib.initialize_symbols(d, "libdbus-1.so.3")
	return n == size_of(Dbus) / size_of(rawptr) - 1
}

// Connects to the session bus, where the portal is. False, and why on
// stderr, where it cannot.
dialog_init :: proc(d: ^File_Dialog) -> bool {
	if !dbus_load(&d.dbus) {
		fmt.eprintln("deimos-editor: no file dialog (no libdbus): Open opens the path typed in")
		dialog_destroy(d)
		return false
	}
	e: Dbus_Error
	d.dbus.dbus_error_init(&e)
	d.connection = d.dbus.dbus_bus_get_private(DBUS_BUS_SESSION, &e)
	if d.connection == nil {
		fmt.eprintfln("deimos-editor: no file dialog (no session bus: %s): Open opens the path typed in", e.message)
		d.dbus.dbus_error_free(&e)
		dialog_destroy(d)
		return false
	}
	// libdbus's default for a bus is to end the process when it goes.
	d.dbus.dbus_connection_set_exit_on_disconnect(d.connection, false)
	return true
}

// Shows the dialog, to open a file of `filter`'s, starting in `folder`
// (absolute, or "" for the portal's choice). False where there is no
// dialog; otherwise dialog_poll has the file when it closes.
dialog_start :: proc(d: ^File_Dialog, purpose: Dialog_Purpose, title: string, filter: Dialog_Filter, folder: string) -> bool {
	if d.connection == nil || d.open {
		return false
	}
	db := &d.dbus
	// The request's path is the portal's to choose, but since version 0.9
	// it is this, from our name and a token of ours: the match goes in
	// before the call, so the Response cannot come before it.
	@(static) tokens: int
	tokens += 1
	token := fmt.tprintf("deimos%d", tokens)
	sender, _ := strings.replace_all(strings.trim_prefix(string(db.dbus_bus_get_unique_name(d.connection)), ":"), ".", "_", context.temp_allocator)
	delete(d.request)
	d.request = fmt.aprintf("%s/request/%s/%s", PORTAL_PATH, sender, token)
	dialog_match(d, d.request)

	msg := db.dbus_message_new_method_call(PORTAL_NAME, PORTAL_PATH, PORTAL_FILE_CHOOSER, "OpenFile")
	if msg == nil {
		return false
	}
	defer db.dbus_message_unref(msg)
	args, options: Dbus_Iter
	db.dbus_message_iter_init_append(msg, &args)
	append_string(db, &args, dialog_parent())
	append_string(db, &args, title)
	db.dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &options)
	{
		entry, value: Dbus_Iter
		option_open(db, &options, "handle_token", "s", &entry, &value)
		append_string(db, &value, token)
		option_close(db, &options, &entry, &value)
	}
	{
		entry, value: Dbus_Iter
		option_open(db, &options, "modal", "b", &entry, &value)
		yes := b32(true)
		db.dbus_message_iter_append_basic(&value, DBUS_TYPE_BOOLEAN, &yes)
		option_close(db, &options, &entry, &value)
	}
	{
		// [(name, [(0, glob)...])]: 0 is a glob, 1 a MIME type.
		entry, value: Dbus_Iter
		option_open(db, &options, "filters", "a(sa(us))", &entry, &value)
		filters, one, globs: Dbus_Iter
		db.dbus_message_iter_open_container(&value, DBUS_TYPE_ARRAY, "(sa(us))", &filters)
		db.dbus_message_iter_open_container(&filters, DBUS_TYPE_STRUCT, nil, &one)
		append_string(db, &one, filter.name)
		db.dbus_message_iter_open_container(&one, DBUS_TYPE_ARRAY, "(us)", &globs)
		for g in filter.globs {
			pair: Dbus_Iter
			db.dbus_message_iter_open_container(&globs, DBUS_TYPE_STRUCT, nil, &pair)
			glob := u32(0)
			db.dbus_message_iter_append_basic(&pair, DBUS_TYPE_UINT32, &glob)
			append_string(db, &pair, g)
			db.dbus_message_iter_close_container(&globs, &pair)
		}
		db.dbus_message_iter_close_container(&one, &globs)
		db.dbus_message_iter_close_container(&filters, &one)
		db.dbus_message_iter_close_container(&value, &filters)
		option_close(db, &options, &entry, &value)
	}
	if folder != "" {
		// Bytes, with their NUL.
		entry, value: Dbus_Iter
		option_open(db, &options, "current_folder", "ay", &entry, &value)
		bytes: Dbus_Iter
		db.dbus_message_iter_open_container(&value, DBUS_TYPE_ARRAY, "y", &bytes)
		path := strings.clone_to_cstring(folder, context.temp_allocator)
		at := rawptr(path)
		db.dbus_message_iter_append_fixed_array(&bytes, DBUS_TYPE_BYTE, &at, c.int(len(folder) + 1))
		db.dbus_message_iter_close_container(&value, &bytes)
		option_close(db, &options, &entry, &value)
	}
	db.dbus_message_iter_close_container(&args, &options)
	if !db.dbus_connection_send(d.connection, msg, &d.serial) {
		return false
	}
	db.dbus_connection_flush(d.connection)
	d.open, d.purpose = true, purpose
	return true
}

// The file chosen, once the dialog has closed: `done`, and `path` "" if
// it was cancelled, or there was no portal after all (`failed`). The path
// is in temp memory.
dialog_poll :: proc(d: ^File_Dialog) -> (path: string, done, failed: bool) {
	if !d.open {
		return
	}
	db := &d.dbus
	if !db.dbus_connection_read_write(d.connection, 0) {
		d.open = false
		return "", true, true
	}
	for {
		msg := db.dbus_connection_pop_message(d.connection)
		if msg == nil {
			break
		}
		defer db.dbus_message_unref(msg)
		type := db.dbus_message_get_type(msg)
		switch {
		case type == DBUS_MESSAGE_TYPE_ERROR && db.dbus_message_get_reply_serial(msg) == d.serial:
			// Most likely no portal: org.freedesktop.DBus.Error.ServiceUnknown.
			fmt.eprintfln("deimos-editor: no file dialog: %s", db.dbus_message_get_error_name(msg))
			d.open = false
			return "", true, true
		case type == DBUS_MESSAGE_TYPE_METHOD_RETURN && db.dbus_message_get_reply_serial(msg) == d.serial:
			// An older portal's own path for the request.
			args: Dbus_Iter
			if db.dbus_message_iter_init(msg, &args) && db.dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_OBJECT_PATH {
				handle: cstring
				db.dbus_message_iter_get_basic(&args, &handle)
				if string(handle) != d.request {
					delete(d.request)
					d.request = strings.clone(string(handle))
					dialog_match(d, d.request)
				}
			}
		case bool(db.dbus_message_is_signal(msg, PORTAL_REQUEST, "Response")) && string(db.dbus_message_get_path(msg)) == d.request:
			d.open = false
			return response_path(db, msg), true, false
		}
	}
	return
}

dialog_destroy :: proc(d: ^File_Dialog) {
	if d.connection != nil {
		d.dbus.dbus_connection_close(d.connection)
		d.dbus.dbus_connection_unref(d.connection)
	}
	if d.dbus.__handle != nil {
		dynlib.unload_library(d.dbus.__handle)
	}
	delete(d.request)
	d^ = {}
}

// A file:// URI's path, its %XX bytes decoded; "" for any other URI.
dialog_uri_path :: proc(uri: string, allocator := context.temp_allocator) -> string {
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9':
			return int(c - '0')
		case 'a' ..= 'f':
			return int(c - 'a') + 10
		case 'A' ..= 'F':
			return int(c - 'A') + 10
		}
		return -1
	}
	if !strings.has_prefix(uri, "file://") {
		return ""
	}
	rest := uri[len("file://"):]
	// file://host/path: only the local host's is a path here.
	if !strings.has_prefix(rest, "/") {
		slash := strings.index_byte(rest, '/')
		if slash < 0 || rest[:slash] != "localhost" {
			return ""
		}
		rest = rest[slash:]
	}
	b := strings.builder_make(allocator)
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '%' && i + 2 < len(rest) && hex(rest[i + 1]) >= 0 && hex(rest[i + 2]) >= 0 {
			strings.write_byte(&b, u8(hex(rest[i + 1]) * 16 + hex(rest[i + 2])))
			i += 2
		} else {
			strings.write_byte(&b, rest[i])
		}
	}
	return strings.to_string(b)
}

// The dialog's parent, "x11:<window id>", so it opens over the editor;
// "" with no window.
@(private = "file")
dialog_parent :: proc() -> string {
	if !rl.IsWindowReady() {
		return ""
	}
	handle := rl.GetWindowHandle()
	if handle == nil {
		return ""
	}
	// raylib's GetWindowHandle, on X11, is a pointer to its window's id.
	return fmt.tprintf("x11:%x", (cast(^c.ulong)handle)^)
}

@(private = "file")
dialog_match :: proc(d: ^File_Dialog, path: string) {
	rule := fmt.ctprintf("type='signal',interface='%s',member='Response',path='%s'", PORTAL_REQUEST, path)
	// No error to fill: it is sent, not waited on.
	d.dbus.dbus_bus_add_match(d.connection, rule, nil)
}

// The Response's file: (u response, a{sv} results), 0 for chosen, the
// results' "uris" an array of strings.
@(private = "file")
response_path :: proc(db: ^Dbus, msg: rawptr) -> string {
	args: Dbus_Iter
	if !db.dbus_message_has_signature(msg, "ua{sv}") || !db.dbus_message_iter_init(msg, &args) {
		return ""
	}
	response: u32
	db.dbus_message_iter_get_basic(&args, &response)
	if response != 0 || !db.dbus_message_iter_next(&args) {
		return ""
	}
	results: Dbus_Iter
	db.dbus_message_iter_recurse(&args, &results)
	for db.dbus_message_iter_get_arg_type(&results) == DBUS_TYPE_DICT_ENTRY {
		entry, value, uris: Dbus_Iter
		db.dbus_message_iter_recurse(&results, &entry)
		key: cstring
		db.dbus_message_iter_get_basic(&entry, &key)
		db.dbus_message_iter_next(&entry)
		db.dbus_message_iter_recurse(&entry, &value)
		if key == "uris" && db.dbus_message_iter_get_arg_type(&value) == DBUS_TYPE_ARRAY {
			db.dbus_message_iter_recurse(&value, &uris)
			if db.dbus_message_iter_get_arg_type(&uris) == DBUS_TYPE_STRING {
				uri: cstring
				db.dbus_message_iter_get_basic(&uris, &uri)
				return dialog_uri_path(string(uri))
			}
		}
		db.dbus_message_iter_next(&results)
	}
	return ""
}

@(private = "file")
append_string :: proc(db: ^Dbus, iter: ^Dbus_Iter, s: string) {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	db.dbus_message_iter_append_basic(iter, DBUS_TYPE_STRING, &cs)
}

// An a{sv}'s entry, open at its value, a variant of `signature`. Each
// iterator is the caller's, not copied: libdbus's are its to move.
@(private = "file")
option_open :: proc(db: ^Dbus, options: ^Dbus_Iter, key: string, signature: cstring, entry, value: ^Dbus_Iter) {
	db.dbus_message_iter_open_container(options, DBUS_TYPE_DICT_ENTRY, nil, entry)
	append_string(db, entry, key)
	db.dbus_message_iter_open_container(entry, DBUS_TYPE_VARIANT, signature, value)
}

@(private = "file")
option_close :: proc(db: ^Dbus, options, entry, value: ^Dbus_Iter) {
	db.dbus_message_iter_close_container(entry, value)
	db.dbus_message_iter_close_container(options, entry)
}
