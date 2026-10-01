#+build linux
package editor_tests

// The file dialog's D-Bus side (editor/dialog_linux.odin), with this test
// as the desktop portal: OpenFile asked as the portal's API has it, and
// its Response read for the file, or for none when cancelled. Only on a
// bus of its own, which mise run test starts (dbus-run-session, and
// DR_PRIVATE_BUS): on the desktop's the real portal would show a dialog.
// Not the case with no portal at all: a private bus would start the real
// one, being able to.

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "dr:editor"

@(test)
dialog_asks_the_portal :: proc(t: ^testing.T) {
	if os.get_env("DR_PRIVATE_BUS", context.temp_allocator) == "" {
		fmt.println("dialog_asks_the_portal: not on a private bus (mise run test), skipped")
		return
	}
	db: editor.Dbus
	if !editor.dbus_load(&db) {
		fmt.println("dialog_asks_the_portal: no libdbus, skipped")
		return
	}
	defer dynlib.unload_library(db.__handle)
	err: editor.Dbus_Error
	db.dbus_error_init(&err)
	portal := db.dbus_bus_get_private(editor.DBUS_BUS_SESSION, &err)
	if portal == nil {
		fmt.println("dialog_asks_the_portal: no session bus, skipped:", err.message)
		db.dbus_error_free(&err)
		return
	}
	db.dbus_connection_set_exit_on_disconnect(portal, false)
	defer {
		db.dbus_connection_close(portal)
		db.dbus_connection_unref(portal)
	}
	DO_NOT_QUEUE :: 4
	PRIMARY_OWNER :: 1
	if !testing.expect(t, db.dbus_bus_request_name(portal, editor.PORTAL_NAME, DO_NOT_QUEUE, &err) == PRIMARY_OWNER, "the private bus has a portal already") {
		return
	}
	defer db.dbus_bus_release_name(portal, editor.PORTAL_NAME, nil)

	d: editor.File_Dialog
	if !testing.expect(t, editor.dialog_init(&d)) {
		return
	}
	defer editor.dialog_destroy(&d)
	path, done, failed := ask(t, &db, portal, &d, 0, "file:///tmp/a%20level/le07.drproj.json")
	testing.expect(t, done && !failed, "no answer")
	testing.expect_value(t, path, "/tmp/a level/le07.drproj.json")
	path, done, failed = ask(t, &db, portal, &d, 1, "")
	testing.expect(t, done && !failed && path == "", "a cancel is not none")
}

// Asks for a project, and answers as the portal does with `response` and,
// for 0, `uri`; what the dialog then has.
@(private = "file")
ask :: proc(t: ^testing.T, db: ^editor.Dbus, portal: rawptr, d: ^editor.File_Dialog, response: u32, uri: string) -> (path: string, done, failed: bool) {
	if !testing.expect(t, editor.dialog_start(d, .Project, "Open a level", editor.DIALOG_FILTERS[.Project], "/tmp")) {
		return
	}
	testing.expect(t, d.open)
	deadline := time.tick_now()
	asked := false
	for time.tick_since(deadline) < 5 * time.Second {
		if path, done, failed = editor.dialog_poll(d); done {
			break
		}
		db.dbus_connection_read_write(portal, 10)
		msg := db.dbus_connection_pop_message(portal)
		if msg == nil {
			continue
		}
		defer db.dbus_message_unref(msg)
		if !db.dbus_message_is_method_call(msg, editor.PORTAL_FILE_CHOOSER, "OpenFile") {
			continue
		}
		asked = true
		if !testing.expect(t, bool(db.dbus_message_has_signature(msg, "ssa{sv}")), "OpenFile's arguments are not ssa{sv}") {
			return
		}
		token, filters, folder := options(db, msg)
		testing.expect(t, token != "", "no handle_token")
		testing.expect_value(t, filters, "Level projects: *.drproj.json")
		testing.expect_value(t, folder, "/tmp")
		sender, _ := strings.replace_all(strings.trim_prefix(string(db.dbus_message_get_sender(msg)), ":"), ".", "_", context.temp_allocator)
		request := fmt.ctprintf("%s/request/%s/%s", editor.PORTAL_PATH, sender, token)

		reply := db.dbus_message_new_method_return(msg)
		args: editor.Dbus_Iter
		db.dbus_message_iter_init_append(reply, &args)
		db.dbus_message_iter_append_basic(&args, editor.DBUS_TYPE_OBJECT_PATH, &request)
		db.dbus_connection_send(portal, reply, nil)
		db.dbus_message_unref(reply)

		signal := db.dbus_message_new_signal(request, editor.PORTAL_REQUEST, "Response")
		results, entry, value, uris: editor.Dbus_Iter
		db.dbus_message_iter_init_append(signal, &args)
		r := response
		db.dbus_message_iter_append_basic(&args, editor.DBUS_TYPE_UINT32, &r)
		db.dbus_message_iter_open_container(&args, editor.DBUS_TYPE_ARRAY, "{sv}", &results)
		if response == 0 {
			key, file := cstring("uris"), strings.clone_to_cstring(uri, context.temp_allocator)
			db.dbus_message_iter_open_container(&results, editor.DBUS_TYPE_DICT_ENTRY, nil, &entry)
			db.dbus_message_iter_append_basic(&entry, editor.DBUS_TYPE_STRING, &key)
			db.dbus_message_iter_open_container(&entry, editor.DBUS_TYPE_VARIANT, "as", &value)
			db.dbus_message_iter_open_container(&value, editor.DBUS_TYPE_ARRAY, "s", &uris)
			db.dbus_message_iter_append_basic(&uris, editor.DBUS_TYPE_STRING, &file)
			db.dbus_message_iter_close_container(&value, &uris)
			db.dbus_message_iter_close_container(&entry, &value)
			db.dbus_message_iter_close_container(&results, &entry)
		}
		db.dbus_message_iter_close_container(&args, &results)
		db.dbus_connection_send(portal, signal, nil)
		db.dbus_message_unref(signal)
		db.dbus_connection_flush(portal)
	}
	testing.expect(t, asked, "the portal was not asked")
	return
}

// OpenFile's options: its token, its filters as "name: glob glob", and
// its folder.
@(private = "file")
options :: proc(db: ^editor.Dbus, msg: rawptr) -> (token, filters, folder: string) {
	args, opts: editor.Dbus_Iter
	db.dbus_message_iter_init(msg, &args)
	db.dbus_message_iter_next(&args)
	db.dbus_message_iter_next(&args)
	db.dbus_message_iter_recurse(&args, &opts)
	for db.dbus_message_iter_get_arg_type(&opts) == editor.DBUS_TYPE_DICT_ENTRY {
		entry, value: editor.Dbus_Iter
		db.dbus_message_iter_recurse(&opts, &entry)
		key: cstring
		db.dbus_message_iter_get_basic(&entry, &key)
		db.dbus_message_iter_next(&entry)
		db.dbus_message_iter_recurse(&entry, &value)
		switch key {
		case "handle_token":
			s: cstring
			db.dbus_message_iter_get_basic(&value, &s)
			token = strings.clone(string(s), context.temp_allocator)
		case "filters":
			b := strings.builder_make(context.temp_allocator)
			list, one, globs: editor.Dbus_Iter
			db.dbus_message_iter_recurse(&value, &list)
			db.dbus_message_iter_recurse(&list, &one)
			name: cstring
			db.dbus_message_iter_get_basic(&one, &name)
			strings.write_string(&b, string(name))
			strings.write_string(&b, ":")
			db.dbus_message_iter_next(&one)
			db.dbus_message_iter_recurse(&one, &globs)
			for db.dbus_message_iter_get_arg_type(&globs) == editor.DBUS_TYPE_STRUCT {
				pair: editor.Dbus_Iter
				db.dbus_message_iter_recurse(&globs, &pair)
				kind: u32
				glob: cstring
				db.dbus_message_iter_get_basic(&pair, &kind)
				db.dbus_message_iter_next(&pair)
				db.dbus_message_iter_get_basic(&pair, &glob)
				fmt.sbprintf(&b, " %s%s", kind == 0 ? "" : "mime:", glob)
				db.dbus_message_iter_next(&globs)
			}
			filters = strings.to_string(b)
		case "current_folder":
			bytes: editor.Dbus_Iter
			db.dbus_message_iter_recurse(&value, &bytes)
			b := strings.builder_make(context.temp_allocator)
			for db.dbus_message_iter_get_arg_type(&bytes) == editor.DBUS_TYPE_BYTE {
				y: u8
				db.dbus_message_iter_get_basic(&bytes, &y)
				if y != 0 {
					strings.write_byte(&b, y)
				}
				db.dbus_message_iter_next(&bytes)
			}
			folder = strings.to_string(b)
		}
		db.dbus_message_iter_next(&opts)
	}
	return
}

// A portal's file:// URIs, as paths.
@(test)
dialog_uri_paths :: proc(t: ^testing.T) {
	testing.expect_value(t, editor.dialog_uri_path("file:///home/me/le07.drproj.json"), "/home/me/le07.drproj.json")
	testing.expect_value(t, editor.dialog_uri_path("file:///home/me/my%20levels/%C3%A9t%C3%A9.drproj.json"), "/home/me/my levels/été.drproj.json")
	testing.expect_value(t, editor.dialog_uri_path("file://localhost/tmp/a%2"), "/tmp/a%2")
	testing.expect_value(t, editor.dialog_uri_path("file://elsewhere/tmp/a"), "")
	testing.expect_value(t, editor.dialog_uri_path("https://example.com/a"), "")
}
