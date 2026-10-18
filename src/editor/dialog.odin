package editor

// The system's file dialog, to open a level or a campaign, add a level to
// the campaign, or import a model, an image or music: the platform's
// (dialog_linux.odin, dialog_windows.odin) behind dialog_init,
// dialog_start, dialog_poll and dialog_destroy.

import "core:os"
import "core:strings"

// What a dialog's file is for.
Dialog_Purpose :: enum {
	Project,
	Model,
	Image,
	Campaign,
	Campaign_Level,
	Audio,
}

Dialog_Filter :: struct {
	name:  string,
	globs: []string,
}

// The files a dialog for `purpose` offers: those editor_import takes as
// that kind (assets.odin).
dialog_filter :: proc(purpose: Dialog_Purpose) -> Dialog_Filter {
	name: string
	kind: File_Kind
	switch purpose {
	case .Project, .Campaign_Level:
		name, kind = "Level projects", .Project
	case .Campaign:
		name, kind = "Campaigns", .Campaign
	case .Model:
		name, kind = "Models", .Model
	case .Image:
		name, kind = "Images", .Image
	case .Audio:
		name, kind = "Music", .Audio
	}
	exts := FILE_EXTENSIONS[kind]
	globs := make([]string, len(exts), context.temp_allocator)
	for ext, i in exts {
		globs[i] = strings.concatenate({"*", ext}, context.temp_allocator)
	}
	return {name, globs}
}

@(rodata)
DIALOG_TITLES := [Dialog_Purpose]string {
	.Project        = "Open a level",
	.Model          = "Import a model",
	.Image          = "Add an image as a material",
	.Campaign       = "Open a campaign",
	.Campaign_Level = "Add a level to the campaign",
	.Audio          = "Import music for the level",
}

// Shows the dialog for `purpose`, starting in the open project's folder.
// False where there is none, or one is open already.
editor_dialog :: proc(e: ^Editor, purpose: Dialog_Purpose) -> bool {
	folder, _ := os.split_path(editor_path(e))
	if folder == "" {
		folder = "."
	}
	if abs, err := os.get_absolute_path(folder, context.temp_allocator); err == nil {
		folder = abs
	}
	if !os.is_dir(folder) {
		folder = ""
	}
	return dialog_start(&e.dialog, purpose, DIALOG_TITLES[purpose], dialog_filter(purpose), strings.clone(folder, context.temp_allocator))
}
