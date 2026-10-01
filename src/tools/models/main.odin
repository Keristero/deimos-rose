package models_tool

// The level editor's model library (Stage 8 of notes/level-editor-plan.md),
// built from Poly Haven's models as tools/models/fetch.py caches them:
//
//   models <sources.json> <profiles.json> <cache dir> <out dir>
//
// For each of the sources' models, its 1k glTF (<cache>/<id>/<id>_1k.gltf)
// is read, its leaves' alpha put into their colour (fetch.py's note says
// why), its images made IMAGE_SIZE across and its triangles brought under
// LIBRARY_TRIANGLES (or its own count), and written to
// <out>/<file>.glb, listed in <out>/index.json with its tags and its
// authors. profiles.json, the sample brushes, is checked against the
// library and copied beside it, and CREDITS.md says whose each model is.
// `mise run models:library` writes assets/models, where the editor looks.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

LIBRARY_FORMAT :: "deimos-rising.model-library"
PROFILES_FORMAT :: "deimos-rising.brush-profiles"

// Every image is made this many texels across, as a PNG. A tree is 100
// texels across in the layer at the most (MODEL_SCALE, the largest
// profile's scale), and a leaf in its atlas a tenth of the texture, so
// even at 256 each leaf's texels are finer than the layer's, and the
// mipmaps take it down further anyway. Poly Haven's 1k JPEGs are 0.2 to
// 1.2 MB each; at 256, a PNG is about 150 KB.
IMAGE_SIZE :: 256

// The triangles a library model is brought under, unless its source says
// otherwise: a rock 20 texels across shows no more than this, and the
// library is in the repository (D29). A tree's crown wants more.
LIBRARY_TRIANGLES :: 10_000

Sources :: struct {
	models: []Source `json:"models"`,
}

Source :: struct {
	id:        string   `json:"id"`,
	tags:      []string `json:"tags"`,
	triangles: int      `json:"triangles"`, // 0 for LIBRARY_TRIANGLES
}

// Poly Haven's info.json, as much as the credits need.
Info :: struct {
	name:    string            `json:"name"`,
	authors: map[string]string `json:"authors"`,
}

// As the editor reads it (editor/models.odin's Model_Library_Item).
Item :: struct {
	file:   string   `json:"file"`,
	tags:   []string `json:"tags"`,
	source: string   `json:"source"`,
}

Index :: struct {
	format: string `json:"format"`,
	models: []Item `json:"models"`,
}

// As much of a profile as is checked: the editor reads the rest.
Profiles :: struct {
	format:   string `json:"format"`,
	profiles: []struct {
		name:    string `json:"name"`,
		entries: []struct {
			model:   string `json:"model"`,
			variant: string `json:"variant"`,
		} `json:"entries"`,
	} `json:"profiles"`,
}

main :: proc() {
	if len(os.args) != 5 {
		fmt.eprintln("usage: models <sources.json> <profiles.json> <cache dir> <out dir>")
		os.exit(2)
	}
	sources_path, profiles_path, cache, out := os.args[1], os.args[2], os.args[3], os.args[4]
	sources: Sources
	if blob, err := os.read_entire_file(sources_path, context.temp_allocator); err != nil || json.unmarshal(blob, &sources) != nil {
		fail("cannot read %s", sources_path)
	}
	rl.SetTraceLogLevel(.WARNING) // png_encode deflates through raylib
	os.make_directory_all(out)
	items := make([dynamic]Item)
	library := make(map[string]terrain.Model_File)
	credits := strings.builder_make()
	fmt.sbprint(&credits, CREDITS_HEAD)
	for s in sources.models {
		dir := fmt.aprintf("%s/%s", cache, s.id)
		gltf := fmt.tprintf("%s/%s_1k.gltf", dir, s.id)
		f, ok := terrain.model_file_read(gltf)
		if !ok {
			fail("cannot read %s (models:fetch fetches it)", gltf)
		}
		delete(f.name)
		f.name = terrain.model_name(s.id)
		merged := images_remake(&f, dir, gltf)
		before := terrain.file_triangles(f)
		terrain.model_file_simplify(&f, s.triangles > 0 ? s.triangles : LIBRARY_TRIANGLES)
		path := fmt.tprintf("%s/%s.glb", out, f.name)
		if !terrain.model_file_write(path, f) {
			fail("cannot write %s", path)
		}
		info: Info
		if blob, err := os.read_entire_file(fmt.tprintf("%s/info.json", dir), context.temp_allocator); err != nil || json.unmarshal(blob, &info) != nil {
			fail("cannot read %s/info.json (models:fetch fetches it)", dir)
		}
		authors := make([dynamic]string)
		for name in info.authors {
			append(&authors, name)
		}
		slice.sort(authors[:])
		by := strings.join(authors[:], ", ")
		link := fmt.aprintf("https://polyhaven.com/a/%s", s.id)
		append(&items, Item{f.name, s.tags, fmt.aprintf("%s by %s, Poly Haven (CC0): %s", info.name, by, link)})
		fmt.sbprintf(&credits, "- **%s** (`%s.glb`) by %s: <%s>\n", info.name, f.name, by, link)
		size := i64(0)
		if st, serr := os.stat(path, context.temp_allocator); serr == nil {
			size = st.size
		}
		fmt.printfln("%-22s %2d models  %7d -> %5d triangles  %d alpha  %5d KB", f.name, len(f.variants), before, terrain.file_triangles(f), merged, size / 1024)
		library[f.name] = f
		free_all(context.temp_allocator)
	}

	profiles_blob, err := os.read_entire_file(profiles_path, context.allocator)
	if err != nil {
		fail("cannot read %s", profiles_path)
	}
	profiles: Profiles
	if json.unmarshal(profiles_blob, &profiles) != nil || profiles.format != PROFILES_FORMAT {
		fail("%s is not the editor's profiles", profiles_path)
	}
	for pr in profiles.profiles {
		for e in pr.entries {
			f, have := library[e.model]
			if !have {
				fail("%s: %s is not in the library", pr.name, e.model)
			}
			found := e.variant == ""
			for v in f.variants {
				found ||= v.name == e.variant
			}
			if !found {
				fail("%s: %s has no model %s", pr.name, e.model, e.variant)
			}
		}
	}
	if os.write_entire_file(fmt.tprintf("%s/profiles.json", out), profiles_blob) != nil {
		fail("cannot write %s/profiles.json", out)
	}

	index, merr := json.marshal(Index{LIBRARY_FORMAT, items[:]}, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil || os.write_entire_file(fmt.tprintf("%s/index.json", out), index) != nil {
		fail("cannot write %s/index.json", out)
	}
	if os.write_entire_file(fmt.tprintf("%s/CREDITS.md", out), transmute([]u8)strings.to_string(credits)) != nil {
		fail("cannot write %s/CREDITS.md", out)
	}
	fmt.printfln("wrote %d models and %d profiles to %s", len(items), len(profiles.profiles), out)
}

CREDITS_HEAD :: `# Model library credits

Powered by Poly Haven: every model here is from https://polyhaven.com and
is CC0 (https://polyhaven.com/license), free to use for anything with no
credit required. They are credited anyway. Each is Poly Haven's 1k glTF,
its leaves' alpha merged into their colour and its triangles reduced, as
tools/models builds it (` + "`mise run models:library`" + `).

`

// Each of `f`'s images made IMAGE_SIZE across, as a PNG, and where its
// glTF's X_diff_1k.jpg has an X_alpha_1k.png beside it, that alpha merged
// in. `f` holds the JPEG's own bytes, so is matched by them. How many had
// an alpha.
images_remake :: proc(f: ^terrain.Model_File, dir, gltf: string) -> (merged: int) {
	blob, err := os.read_entire_file(gltf, context.temp_allocator)
	if err != nil {
		fail("cannot read %s", gltf)
	}
	doc: struct {
		images: []struct {
			uri: string `json:"uri"`,
		} `json:"images"`,
	}
	if json.unmarshal(blob, &doc, allocator = context.temp_allocator) != nil {
		fail("%s is not glTF", gltf)
	}
	alphas := make([]terrain.Picture, len(f.images), context.temp_allocator)
	for img in doc.images {
		if !strings.has_suffix(img.uri, "_diff_1k.jpg") {
			continue
		}
		alpha_path := fmt.tprintf("%s/%s_alpha_1k.png", dir, strings.trim_suffix(img.uri, "_diff_1k.jpg"))
		alpha_blob, aerr := os.read_entire_file(alpha_path, context.temp_allocator)
		colour_blob, cerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, img.uri), context.temp_allocator)
		if aerr != nil || cerr != nil {
			continue
		}
		for have, k in f.images {
			if slice.equal(have.data, colour_blob) {
				alpha, ok := terrain.model_image_rgba({data = alpha_blob})
				if !ok {
					fail("cannot decode %s", alpha_path)
				}
				if alphas[k].pixels == nil {
					merged += 1
				}
				alphas[k] = alpha
			}
		}
	}
	for &have, k in f.images {
		colour, ok := terrain.model_image_rgba(have)
		if !ok {
			fail("%s: cannot decode its image %d", gltf, k)
		}
		pic := image_remake(colour, alphas[k], IMAGE_SIZE)
		delete(have.data)
		delete(have.mime)
		have = {terrain.png_encode(pic), strings.clone("image/png")}
	}
	return
}

// `colour` at `size` across, box-filtered and weighted by its alpha: its
// own, or where `alpha` has pixels, that one's grey. RGB if it is opaque.
// Where it is clear its colour is its opaque pixels' mean: mipmaps blend
// toward that at a leaf's edge, not toward the black a clear pixel is in
// the JPEG.
//
// The alpha is scaled so as much of the image is over the layer's cutoff
// as was before (Castaño, "Computing Alpha Mipmaps", 2010): averaged, a
// grass blade a texel or two wide falls under it and is gone.
image_remake :: proc(colour, alpha: terrain.Picture, size: int) -> terrain.Picture {
	CUTOFF :: 0.5 // the glTF's, and the reader's for BLEND
	w := min(size, colour.width)
	h := max(1, colour.height * w / colour.width)
	out := terrain.picture_make(w, h, 4, 8, context.temp_allocator)
	alphas := make([]f64, w * h, context.temp_allocator)
	mean: [3]f64
	weight: f64
	covered := 0 // source texels over the cutoff
	for y in 0 ..< h {
		for x in 0 ..< w {
			sum: [4]f64
			x0, x1 := x * colour.width / w, (x + 1) * colour.width / w
			y0, y1 := y * colour.height / h, (y + 1) * colour.height / h
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					c := colour.pixels[(sy * colour.width + sx) * 4:][:4]
					a := f64(c[3]) / 255
					if alpha.pixels != nil {
						a = f64(alpha.pixels[((sy * alpha.height / colour.height) * alpha.width + sx * alpha.width / colour.width) * 4]) / 255
					}
					covered += int(a >= CUTOFF)
					sum += {f64(c[0]) * a, f64(c[1]) * a, f64(c[2]) * a, a}
				}
			}
			o := out.pixels[(y * w + x) * 4:][:4]
			alphas[y * w + x] = sum[3] / f64((x1 - x0) * (y1 - y0))
			if sum[3] > 0 {
				for ch in 0 ..< 3 {
					o[ch] = u8(sum[ch] / sum[3] + 0.5)
				}
				mean += sum.rgb
				weight += sum[3]
			}
		}
	}
	// The scale whose cover is the source's: cover rises with it, so by
	// halves.
	want := f64(covered) / f64(colour.width * colour.height)
	cover :: proc(alphas: []f64, scale: f64) -> f64 {
		n := 0
		for a in alphas {
			n += int(a * scale >= CUTOFF)
		}
		return f64(n) / f64(len(alphas))
	}
	// Left as it is where that is already so: an opaque image's cover is
	// all of it at any scale over the cutoff.
	scale := 1.0
	if cover(alphas, 1) != want {
		lo, hi := 0.25, 16.0
		for _ in 0 ..< 24 {
			mid := (lo + hi) / 2
			if cover(alphas, mid) < want {
				lo = mid
			} else {
				hi = mid
			}
		}
		scale = abs(cover(alphas, lo) - want) < abs(cover(alphas, hi) - want) ? lo : hi
	}
	opaque := true
	fill := weight > 0 ? mean / weight : 0
	for a, i in alphas {
		o := out.pixels[i * 4:][:4]
		o[3] = u8(clamp(a * scale, 0, 1) * 255 + 0.5)
		opaque &&= o[3] == 255
		if a == 0 {
			for ch in 0 ..< 3 {
				o[ch] = u8(fill[ch] + 0.5)
			}
		}
	}
	if opaque {
		rgb := terrain.picture_make(w, h, 3, 8, context.temp_allocator)
		for i in 0 ..< w * h {
			copy(rgb.pixels[i * 3:][:3], out.pixels[i * 4:][:3])
		}
		return rgb
	}
	return out
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("models: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
