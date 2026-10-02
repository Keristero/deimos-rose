package editor

// The system's file dialog, to open a level or a campaign, add a level to
// the campaign, import a model or add an image: the platform's (dialog_linux.odin, dialog_windows.odin) behind
// dialog_init, dialog_start, dialog_poll and dialog_destroy.

import "core:os"
import "core:strings"

import "dr:terrain"

// What a dialog's file is for.
Dialog_Purpose :: enum {
	Project,
	Model,
	Image,
	Campaign,
	Campaign_Level,
}

Dialog_Filter :: struct {
	name:  string,
	globs: []string,
}

@(rodata)
DIALOG_FILTERS := [Dialog_Purpose]Dialog_Filter {
	.Project        = {"Level projects", {"*" + terrain.PROJECT_SUFFIX}},
	.Model          = {"Models", {"*.glb", "*.gltf", "*.obj"}},
	.Image          = {"Images", {"*.png", "*.jpg", "*.jpeg", "*.bmp", "*.tga", "*.qoi"}},
	.Campaign       = {"Campaigns", {"*" + CAMPAIGN_SUFFIX}},
	.Campaign_Level = {"Level projects", {"*" + terrain.PROJECT_SUFFIX}},
}

@(rodata)
DIALOG_TITLES := [Dialog_Purpose]string {
	.Project        = "Open a level",
	.Model          = "Import a model",
	.Image          = "Add an image as a material",
	.Campaign       = "Open a campaign",
	.Campaign_Level = "Add a level to the campaign",
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
	return dialog_start(&e.dialog, purpose, DIALOG_TITLES[purpose], DIALOG_FILTERS[purpose], strings.clone(folder, context.temp_allocator))
}
