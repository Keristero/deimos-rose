package editor

// The system's file dialog, on Windows: the common Open dialog. It runs
// its own message loop until it closes, so dialog_start waits for it and
// dialog_poll then has the file at once.

import "core:strings"
import win "core:sys/windows"

import rl "vendor:raylib"

File_Dialog :: struct {
	open:    bool,
	path:    string, // the file chosen, "" if none
	purpose: Dialog_Purpose,
}

dialog_init :: proc(d: ^File_Dialog) -> bool {
	return true
}

dialog_start :: proc(d: ^File_Dialog, purpose: Dialog_Purpose, title: string, filter: Dialog_Filter, folder: string) -> bool {
	if d.open {
		return false
	}
	// "name\0glob;glob\0\0".
	spec := strings.concatenate({filter.name, "\x00", strings.join(filter.globs, ";", context.temp_allocator), "\x00"}, context.temp_allocator)
	file := make([]u16, win.MAX_PATH_WIDE, context.temp_allocator)
	ofn := win.OPENFILENAMEW {
		lStructSize     = size_of(win.OPENFILENAMEW),
		hwndOwner       = rl.IsWindowReady() ? win.HWND(rl.GetWindowHandle()) : nil,
		lpstrFilter     = win.utf8_to_wstring(spec),
		nFilterIndex    = 1,
		lpstrFile       = cstring16(raw_data(file)),
		nMaxFile        = u32(len(file)),
		lpstrInitialDir = folder != "" ? win.utf8_to_wstring(folder) : nil,
		lpstrTitle      = win.utf8_to_wstring(title),
		// NOCHANGEDIR: else the dialog moves the process into the folder
		// the file was in, and the assets are found from where it started.
		Flags           = win.OFN_PATHMUSTEXIST | win.OFN_FILEMUSTEXIST | win.OFN_NOCHANGEDIR | win.OFN_EXPLORER,
	}
	d.path = ""
	if win.GetOpenFileNameW(&ofn) {
		path, _ := win.utf16_to_utf8(file, context.allocator)
		d.path = strings.trim_right_null(path)
	}
	d.open, d.purpose = true, purpose
	return true
}

dialog_poll :: proc(d: ^File_Dialog) -> (path: string, done, failed: bool) {
	if !d.open {
		return
	}
	d.open = false
	path = strings.clone(d.path, context.temp_allocator)
	delete(d.path)
	d.path = ""
	return path, true, false
}

dialog_destroy :: proc(d: ^File_Dialog) {
	delete(d.path)
	d^ = {}
}
