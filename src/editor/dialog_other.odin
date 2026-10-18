#+build !linux
#+build !windows
package editor

// No file dialog but Linux's and Windows': Open opens the path typed in,
// and files are dropped on the window.

File_Dialog :: struct {
	open:    bool,
	purpose: Dialog_Purpose,
}

dialog_init :: proc(d: ^File_Dialog) -> bool {
	return false
}

dialog_start :: proc(d: ^File_Dialog, purpose: Dialog_Purpose, title: string, filter: Dialog_Filter, folder: string) -> bool {
	return false
}

dialog_poll :: proc(d: ^File_Dialog) -> (path: string, done, failed: bool) {
	return
}

dialog_destroy :: proc(d: ^File_Dialog) {}
