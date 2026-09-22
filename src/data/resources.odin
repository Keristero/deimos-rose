package data

import "core:os"
import "core:strings"

// Resource lookup with the original's precedence.
//
// U_Pak_BuildTagIndex walks fifteen `Data/Local/<type>/` directories first and
// only then the archives in `Data/Paks/`, appending every tag it finds to one
// list. U_Pak_GetPtrToTagData scans that list and takes the first match, so
// a loose file in Data/Local shadows the same id inside a PAK.
//
// The fifteen types below are the loop's `case 0 .. 14`, and match the fifteen
// directories the shipped game creates under Data/Local exactly.

RESOURCE_TYPES := []string {
	"coli", "film", "flli", "idli", "im08", "im16", "leve",
	"plde", "pref", "reli", "soun", "stli", "tefo", "unde", "wede",
}

Res_Key :: struct {
	type: FourCC,
	id:   FourCC,
}

Res_Origin :: enum u8 {
	Local,
	Pak,
}

Res_Entry :: struct {
	key:    Res_Key,
	origin: Res_Origin,
	// Local
	path: string,
	// Pak
	pak:   int,
	entry: Zip_Entry,
}

Resource_Provider :: struct {
	entries: [dynamic]Res_Entry,
	index:   map[Res_Key]int,
	paks:    [dynamic]Zip,
	root:    string,
}

Res_Error :: enum {
	None,
	Not_Found,
	Read_Failed,
	Crc_Mismatch,
}

// Open the provider over an extracted install directory. Missing pieces are
// skipped rather than fatal, so a partial tree still yields what it has.
provider_open :: proc(
	root: string,
	allocator := context.allocator,
) -> (
	p: Resource_Provider,
) {
	p.root = strings.clone(root, allocator)
	p.entries = make([dynamic]Res_Entry, 0, 1024, allocator)
	p.index = make(map[Res_Key]int, 1024, allocator)
	p.paks = make([dynamic]Zip, 0, 4, allocator)

	// 1. Data/Local, in the order the original scans it.
	for type in RESOURCE_TYPES {
		dir := strings.concatenate({root, "/ Data/Local/", type}, context.temp_allocator)
		handle, oerr := os.open(dir)
		if oerr != nil {
			continue
		}
		defer os.close(handle)
		infos, rerr := os.read_directory(handle, -1, context.temp_allocator)
		if rerr != nil {
			continue
		}
		for info in infos {
			rn, ok := parse_res_name(info.name)
			if !ok {
				continue
			}
			add(&p, Res_Key{fourcc_from(type), fourcc_from(rn.fourcc)}, Res_Entry{
				origin = .Local,
				path   = strings.clone(
					strings.concatenate({dir, "/", info.name}, context.temp_allocator),
					allocator,
				),
			}, allocator)
		}
	}

	// 2. Then the archives.
	for name in ([]string{"Audio.pak", "Game.pak", "Interface.pak", "Music.pak"}) {
		path := strings.concatenate({root, "/ Data/Paks/", name}, context.temp_allocator)
		z, zerr := zip_open(path, allocator)
		if zerr != .None {
			continue
		}
		append(&p.paks, z)
		pak_index := len(p.paks) - 1

		files := zip_files(&p.paks[pak_index], context.temp_allocator)
		for e in files {
			rn, ok := parse_res_name(e.name)
			if !ok {
				continue
			}
			// Flat archives (Audio, Music) carry no type directory; their
			// entries are sound resources.
			type := rn.dir if rn.dir != "" else "soun"
			add(&p, Res_Key{fourcc_from(type), fourcc_from(rn.fourcc)}, Res_Entry{
				origin = .Pak,
				pak    = pak_index,
				entry  = e,
			}, allocator)
		}
	}
	return p
}

@(private = "file")
add :: proc(p: ^Resource_Provider, key: Res_Key, e: Res_Entry, allocator := context.allocator) {
	entry := e
	entry.key = key
	append(&p.entries, entry)
	// First writer wins: Local is scanned before the PAKs.
	if !(key in p.index) {
		p.index[key] = len(p.entries) - 1
	}
}

provider_close :: proc(p: ^Resource_Provider, allocator := context.allocator) {
	for e in p.entries {
		if e.origin == .Local {
			delete(e.path, allocator)
		}
	}
	for i in 0 ..< len(p.paks) {
		zip_close(&p.paks[i], allocator)
	}
	delete(p.paks)
	delete(p.entries)
	delete(p.index)
	delete(p.root, allocator)
	p^ = {}
}

resource_exists :: proc(p: ^Resource_Provider, type, id: string) -> bool {
	return Res_Key{fourcc_from(type), fourcc_from(id)} in p.index
}

// Where a given id would actually be read from.
resource_origin :: proc(p: ^Resource_Provider, type, id: string) -> (Res_Origin, bool) {
	i, ok := p.index[Res_Key{fourcc_from(type), fourcc_from(id)}]
	if !ok {
		return .Pak, false
	}
	return p.entries[i].origin, true
}

// Fetch a resource body. PAK entries return a view into the archive buffer;
// Local entries are read fresh and owned by the caller.
resource_get :: proc(
	p: ^Resource_Provider,
	type, id: string,
	allocator := context.allocator,
) -> (
	data: []byte,
	owned: bool,
	err: Res_Error,
) {
	i, ok := p.index[Res_Key{fourcc_from(type), fourcc_from(id)}]
	if !ok {
		return nil, false, .Not_Found
	}
	e := p.entries[i]
	if e.origin == .Local {
		blob, rerr := os.read_entire_file(e.path, allocator)
		if rerr != nil {
			return nil, false, .Read_Failed
		}
		return blob, true, .None
	}
	body, zerr := zip_read(&p.paks[e.pak], e.entry)
	if zerr == .Crc_Mismatch {
		return body, false, .Crc_Mismatch
	} else if zerr != .None {
		return nil, false, .Read_Failed
	}
	return body, false, .None
}

resource_count :: proc(p: ^Resource_Provider) -> int {
	return len(p.index)
}
