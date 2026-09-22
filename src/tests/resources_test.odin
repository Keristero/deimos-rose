package tests

import "core:os"
import "core:testing"

import "dr:data"

// The provider needs the extracted original install, which is not
// redistributed; these skip cleanly without it.
@(private = "file")
ORIG :: "../game"

@(test)
provider_indexes_every_resource :: proc(t: ^testing.T) {
	if !os.exists(ORIG + "/ Data/Paks/Game.pak") {
		return
	}
	p := data.provider_open(ORIG)
	defer data.provider_close(&p)

	// 871 archive entries, of which two are shadowed by Data/Local, plus the
	// two ids that exist only locally.
	testing.expect_value(t, data.resource_count(&p), 873)
	testing.expect_value(t, len(p.entries), 875)
}

@(test)
local_resources_shadow_the_archives :: proc(t: ^testing.T) {
	if !os.exists(ORIG + "/ Data/Local") {
		return
	}
	p := data.provider_open(ORIG)
	defer data.provider_close(&p)

	// Both of these also exist inside a PAK, and Data/Local must win.
	for c in ([][2]string{{"im08", "TESM"}, {"stli", "cred"}}) {
		origin, ok := data.resource_origin(&p, c[0], c[1])
		testing.expectf(t, ok, "%v/%v should resolve", c[0], c[1])
		testing.expectf(t, origin == .Local, "%v/%v must come from Data/Local", c[0], c[1])
	}

	// Present only in Data/Local.
	for c in ([][2]string{{"film", "last"}, {"pref", "pref"}}) {
		origin, ok := data.resource_origin(&p, c[0], c[1])
		testing.expectf(t, ok, "%v/%v should resolve", c[0], c[1])
		testing.expect_value(t, origin, data.Res_Origin.Local)
	}

	// Present only in a PAK.
	for c in ([][2]string{{"film", "de01"}, {"leve", "le01"}, {"unde", "01b1"}}) {
		origin, ok := data.resource_origin(&p, c[0], c[1])
		testing.expectf(t, ok, "%v/%v should resolve", c[0], c[1])
		testing.expect_value(t, origin, data.Res_Origin.Pak)
	}
}

@(test)
provider_reads_bodies_from_both_sources :: proc(t: ^testing.T) {
	if !os.exists(ORIG + "/ Data/Paks/Game.pak") {
		return
	}
	p := data.provider_open(ORIG)
	defer data.provider_close(&p)

	// From a PAK: a level, parsed through the real loader.
	body, owned, err := data.resource_get(&p, "leve", "le01")
	testing.expect_value(t, err, data.Res_Error.None)
	testing.expect(t, !owned, "pak bodies are views, not copies")
	lv, lerr := data.level_parse(body, context.temp_allocator)
	testing.expect_value(t, lerr, data.Level_Error.None)
	testing.expect_value(t, lv.name, "Kepler Massif")
	testing.expect_value(t, len(lv.placements), 46)

	// From Data/Local: the saved replay, which is the full fixed film size.
	film_body, film_owned, ferr := data.resource_get(&p, "film", "last")
	defer if film_owned do delete(film_body)
	testing.expect_value(t, ferr, data.Res_Error.None)
	testing.expect(t, film_owned, "local bodies are freshly read and owned")
	testing.expect_value(t, len(film_body), data.FILM_SIZE)

	// The Windows build wrote this one, so it is little-endian.
	f, perr := data.film_parse(film_body, context.temp_allocator)
	testing.expect_value(t, perr, data.Film_Error.None)
	testing.expect(t, !f.big_endian, "Last Film is little-endian")

	_, _, missing := data.resource_get(&p, "leve", "zzzz")
	testing.expect_value(t, missing, data.Res_Error.Not_Found)
}
