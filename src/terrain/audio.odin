package terrain

// The audio a level brings (D77): what the editor imports as its music,
// kept as the file it was, under audio/ beside the project. A level names
// one by its id (level.music); export copies it into the plugin's audio/,
// where the game reads .wav, .ogg and .mp3 alike (data.AUDIO_EXTENSIONS).

import "core:os"
import "core:strings"

import "dr:data"

Audio_File :: struct {
	id:    string, // what the level calls it, the file's name without its extension
	ext:   string, // one of data.AUDIO_EXTENSIONS
	bytes: []u8,   // the file as it was imported
}

// Where an audio file is kept, from the project's directory.
audio_file_path :: proc(f: Audio_File, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"audio/", f.id, f.ext}, allocator)
}

// The place in p.audio of the file `id`, or -1.
audio_find :: proc(p: ^Project, id: string) -> int {
	for f, k in p.audio {
		if f.id == id {
			return k
		}
	}
	return -1
}

// The extension of `path` if the game plays it, lower case, else "".
audio_extension :: proc(path: string) -> string {
	lower := strings.to_lower(path, context.temp_allocator)
	for ext in data.AUDIO_EXTENSIONS {
		if strings.has_suffix(lower, ext) {
			return ext
		}
	}
	return ""
}

// An audio id from a file's name: lower case letters, digits, - and _,
// the rest as -, so it is the same file name everywhere.
audio_name :: proc(path: string, allocator := context.allocator) -> string {
	base := path
	if i := strings.last_index_any(base, "/\\"); i >= 0 {
		base = base[i + 1:]
	}
	if ext := audio_extension(base); ext != "" {
		base = base[:len(base) - len(ext)]
	}
	b := strings.builder_make(0, len(base), allocator)
	for r in strings.to_lower(base, context.temp_allocator) {
		ok := r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_'
		strings.write_rune(&b, ok ? r : '-')
	}
	if strings.builder_len(b) == 0 {
		strings.write_string(&b, "music")
	}
	return strings.to_string(b)
}

@(private)
audio_file_read :: proc(dir, name: string, allocator := context.allocator) -> (f: Audio_File, ok: bool) {
	ext := audio_extension(name)
	if ext == "" || !strings.has_prefix(name, "audio/") {
		return
	}
	id := name[len("audio/"):len(name) - len(ext)]
	if id == "" || id != audio_name(id, context.temp_allocator) {
		return // a name as audio_name makes it, so it names no file elsewhere
	}
	bytes, err := os.read_entire_file(strings.concatenate({dir, "/", name}, context.temp_allocator), allocator)
	if err != nil {
		return
	}
	return {strings.clone(id, allocator), ext, bytes}, true
}
