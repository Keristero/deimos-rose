package preview_fit

// Fits the look of the originals' level previews (Stage 9 of
// notes/level-editor-plan.md), for terrain.preview_make:
//
//   preview_fit [-classic=plugins/classic_levels] [-out=terrain/preview_look.odin] [-shots=DIR]
//
// Each original preview is a 438x918 crop of its map downscaled 3x, then
// given a vignette and a warmer, softer tone (notes/
// headless-3d-to-2d-findings.md). This finds each crop by template
// matching, then fits, over the previews that match well, the look
// terrain.Preview_Look describes: a blur, a colour mix, a tone curve for
// each channel and a vignette across and down,
//
//   out_c = across(|x|) * down(|y|) * tone_c(mix(blur(crop / 3))_c)
//
// and writes it as terrain/preview_look.odin. It prints each preview's
// match and how near the fitted look comes to it; -shots writes each
// original beside the look's preview, to see. CPU only, under a minute.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "dr:terrain"

PREVIEW_W :: terrain.PREVIEW_WIDTH
PREVIEW_H :: terrain.PREVIEW_HEIGHT
DOWN :: terrain.PREVIEW_DOWNSCALE
// A preview whose best match scores less was cut from another render of
// its map (jup2, jup3 in the findings) and is left out of the fit. The
// first fit put le07 (jup2) at 0.921 and the rest at 0.963 or more.
MATCH_MIN :: 0.95
TONE_KNOTS :: terrain.PREVIEW_TONE_KNOTS
VIGNETTE_KNOTS :: terrain.PREVIEW_VIGNETTE_KNOTS
BLURS :: [?]f32{0, 0.35, 0.5, 0.65, 0.8, 1.0}

Level :: struct {
	id, map_name, preview_name: string,
	m, p:                        terrain.Picture,
	x, y:                        int, // the crop's top left, in map pixels
	score:                       f32,
}

Sample :: struct {
	src: [3]f32, // the crop downscaled, before the look
	dst: [3]f32, // the original's preview
	d:   [2]f32, // terrain.preview_distance
}

main :: proc() {
	classic := "plugins/classic_levels"
	out := "terrain/preview_look.odin"
	shots := ""
	for a in os.args[1:] {
		k, _, v := strings.partition(strings.trim_left(a, "-"), "=")
		switch k {
		case "classic":
			classic = v
		case "out":
			out = v
		case "shots":
			shots = v
		case:
			fmt.eprintln("usage: preview_fit [-classic=DIR] [-out=FILE] [-shots=DIR]")
			os.exit(2)
		}
	}
	levels := levels_load(classic)
	if len(levels) == 0 {
		fmt.eprintfln("preview_fit: no levels with a map and a preview in %s", classic)
		os.exit(1)
	}
	for &l in levels {
		l.x, l.y, l.score = locate(l.m, l.p)
	}

	look, rmse := fit_all(levels)
	fmt.printfln("blur sigma %.2f, rmse %.2f over the previews that match", look.blur, rmse)
	fmt.println("level  crop (x, y)   match  look's rmse  look's correlation")
	for &l in levels {
		gen := terrain.preview_make_with(l.m, {l.x, l.y}, look)
		defer terrain.picture_destroy(&gen)
		e, c := compare(gen, l.p)
		if shots != "" {
			shot_write(fmt.tprintf("%s/%s.png", shots, l.id), l.p, gen)
		}
		fmt.printfln("%s  %3d, %4d of %4d  %.3f  %6.2f       %.3f%s", l.id, l.x, l.y, l.m.height, l.score, e, c, l.score < MATCH_MIN ? "  (left out)" : "")
	}
	if !write_look(out, look, levels, rmse) {
		fmt.eprintfln("preview_fit: cannot write %s", out)
		os.exit(1)
	}
	fmt.println("wrote", out)
}

levels_load :: proc(classic: string) -> []Level {
	Record :: struct {
		id, background_image, preview_image: string,
	}
	paths, _ := filepath.glob(fmt.tprintf("%s/data/levels/*.json", classic), context.temp_allocator)
	slice.sort(paths)
	levels := make([dynamic]Level)
	for path in paths {
		blob, err := os.read_entire_file(path, context.temp_allocator)
		r: Record
		if err != nil || json.unmarshal(blob, &r, allocator = context.temp_allocator) != nil {
			continue
		}
		m, mok := terrain.picture_load(fmt.tprintf("%s/images/im16/%s.png", classic, r.background_image), 3)
		p, pok := terrain.picture_load(fmt.tprintf("%s/images/im16/%s.png", classic, r.preview_image), 3)
		if !mok || !pok || p.width != PREVIEW_W || p.height != PREVIEW_H {
			fmt.eprintfln("%s: no map or preview, left out", r.id)
			continue
		}
		append(&levels, Level{id = r.id, map_name = r.background_image, preview_name = r.preview_image, m = m, p = p})
	}
	return levels[:]
}

luma :: proc(px: []u8) -> f32 {
	return 0.299 * f32(px[0]) + 0.587 * f32(px[1]) + 0.114 * f32(px[2])
}

// The preview's place in the map: the best normalised correlation of its
// luminance with the map's, downscaled 3x at each of the 9 phases, over
// the preview's middle, where the vignette is faint. A coarse pass on
// every third pixel, then the best few again on all of them.
locate :: proc(m, p: terrain.Picture) -> (x, y: int, score: f32) {
	Candidate :: struct {
		x, y:  int,
		score: f32,
	}
	Point :: struct {
		x, y: int,
		v:    f32,
	}
	points :: proc(p: terrain.Picture, step: int) -> []Point {
		out := make([dynamic]Point, context.temp_allocator)
		mean: f32
		for y := 0; y < p.height; y += step {
			for x := 0; x < p.width; x += step {
				if d := terrain.preview_distance(x, y); d.x < 0.6 && d.y < 0.6 {
					v := luma(p.pixels[(y * p.width + x) * 3:])
					append(&out, Point{x, y, v})
					mean += v
				}
			}
		}
		mean /= f32(len(out))
		norm: f32
		for &q in out {
			q.v -= mean
			norm += q.v * q.v
		}
		norm = math.sqrt(norm)
		for &q in out {
			q.v /= norm
		}
		return out[:]
	}
	// The map's luminance downscaled at phase (px, py).
	Small :: struct {
		w, h: int,
		v:    []f32,
	}
	full := make([]f32, m.width * m.height, context.temp_allocator)
	for i in 0 ..< len(full) {
		full[i] = luma(m.pixels[i * 3:])
	}
	smalls: [DOWN][DOWN]Small
	for py in 0 ..< DOWN {
		for px in 0 ..< DOWN {
			s := &smalls[py][px]
			s.w, s.h = (m.width - px) / DOWN, (m.height - py) / DOWN
			s.v = make([]f32, s.w * s.h, context.temp_allocator)
			for row in 0 ..< s.h {
				for col in 0 ..< s.w {
					sum: f32
					for dy in 0 ..< DOWN {
						for dx in 0 ..< DOWN {
							sum += full[(py + row * DOWN + dy) * m.width + px + col * DOWN + dx]
						}
					}
					s.v[row * s.w + col] = sum / (DOWN * DOWN)
				}
			}
		}
	}
	ncc :: proc(s: ^Small, pts: []Point, ox, oy: int) -> f32 {
		mean, dot, sq: f32
		for q in pts {
			mean += s.v[(oy + q.y) * s.w + ox + q.x]
		}
		mean /= f32(len(pts))
		for q in pts {
			v := s.v[(oy + q.y) * s.w + ox + q.x] - mean
			dot += v * q.v
			sq += v * v
		}
		return sq > 0 ? dot / math.sqrt(sq) : 0
	}
	coarse := points(p, 3)
	fine := points(p, 1)
	best := make([dynamic]Candidate, context.temp_allocator)
	for py in 0 ..< DOWN {
		for px in 0 ..< DOWN {
			s := &smalls[py][px]
			for oy in 0 ..= s.h - PREVIEW_H {
				for ox in 0 ..= s.w - PREVIEW_W {
					c := ncc(s, coarse, ox, oy)
					if len(best) < 8 || c > best[len(best) - 1].score {
						append(&best, Candidate{px + ox * DOWN, py + oy * DOWN, c})
						slice.sort_by(best[:], proc(a, b: Candidate) -> bool {return a.score > b.score})
						if len(best) > 8 {
							pop(&best)
						}
					}
				}
			}
		}
	}
	score = -1
	for c in best {
		s := &smalls[c.y % DOWN][c.x % DOWN]
		if f := ncc(s, fine, c.x / DOWN, c.y / DOWN); f > score {
			x, y, score = c.x, c.y, f
		}
	}
	return
}

// The look fitted to the well matched previews at each blur, and the best.
fit_all :: proc(levels: []Level) -> (best: terrain.Preview_Look, rmse: f32) {
	rmse = max(f32)
	samples := make([dynamic]Sample)
	defer delete(samples)
	for b in BLURS {
		clear(&samples)
		for l in levels {
			if l.score < MATCH_MIN {
				continue
			}
			src := terrain.preview_crop(l.m, {l.x, l.y}, b)
			defer delete(src)
			for y in 0 ..< PREVIEW_H {
				for x in 0 ..< PREVIEW_W {
					i := y * PREVIEW_W + x
					s := Sample{d = terrain.preview_distance(x, y)}
					for c in 0 ..< 3 {
						s.src[c] = src[i * 3 + c]
						s.dst[c] = f32(l.p.pixels[i * 3 + c])
					}
					append(&samples, s)
				}
			}
		}
		look := fit(samples[:])
		look.blur = b
		e := residual(samples[:], &look)
		fmt.printfln("  blur %.2f: rmse %.3f", b, e)
		if e < rmse {
			best, rmse = look, e
		}
	}
	return
}

// The hat functions of a piecewise linear curve with `n` knots over
// [0, top]: the two weights at `v`, and the first's knot.
hat :: proc(v, top: f32, n: int) -> (k: int, w0, w1: f32) {
	t := clamp(v / top, 0, 1) * f32(n - 1)
	k = min(int(t), n - 2)
	w1 = t - f32(k)
	return k, 1 - w1, w1
}

// The normal equations of least squares on a piecewise linear curve's
// knots, each sample `target` ~ `scale` * curve(v).
Normal :: struct {
	a, b: []f64,
	n:    int,
}

normal_make :: proc(n: int) -> Normal {
	return {make([]f64, n * n, context.temp_allocator), make([]f64, n, context.temp_allocator), n}
}

normal_add :: proc(eq: ^Normal, v, top, scale, target: f32) {
	k, w0, w1 := hat(v, top, eq.n)
	ws := [2]f64{f64(w0 * scale), f64(w1 * scale)}
	for i in 0 ..< 2 {
		for j in 0 ..< 2 {
			eq.a[(k + i) * eq.n + k + j] += ws[i] * ws[j]
		}
		eq.b[k + i] += ws[i] * f64(target)
	}
}

// The knots, with a penalty on their second differences `smooth` times
// the data's mean weight per knot: a knot few samples reach follows the
// line of its neighbours rather than chasing them, or falling to 0 as
// the first fit's top tone knots did.
normal_solve :: proc(eq: ^Normal, smooth: f64, out: []f32) {
	n := eq.n
	weight: f64
	for i in 0 ..< n {
		weight += eq.a[i * n + i]
	}
	weight *= smooth / f64(n)
	for k in 1 ..< n - 1 {
		d := [3]f64{1, -2, 1}
		for i in 0 ..< 3 {
			for j in 0 ..< 3 {
				eq.a[(k - 1 + i) * n + k - 1 + j] += weight * d[i] * d[j]
			}
		}
	}
	solve(eq.a, eq.b, n)
	for i in 0 ..< n {
		out[i] = f32(eq.b[i])
	}
}

// Solves the normal equations `a` x = `b` (n x n) in place.
solve :: proc(a: []f64, b: []f64, n: int) {
	for i in 0 ..< n {
		a[i * n + i] += 1e-9
		p := a[i * n + i]
		for j in 0 ..< n {
			a[i * n + j] /= p
		}
		b[i] /= p
		for r in 0 ..< n {
			if r == i {
				continue
			}
			f := a[r * n + i]
			for j in 0 ..< n {
				a[r * n + j] -= f * a[i * n + j]
			}
			b[r] -= f * b[i]
		}
	}
}

// The tone curve's slope at `v`, 0 off its ends, where it is flat.
slope :: proc(knots: []f32, v: f32) -> f32 {
	if v < 0 || v > 255 {
		return 0
	}
	k, _, _ := hat(v, 255, len(knots))
	return (knots[k + 1] - knots[k]) * f32(len(knots) - 1) / 255
}

// The other two channels of channel `c`, in order.
others :: proc(c: int) -> [2]int {
	return {(c + 1) % 3, (c + 2) % 3}
}

// The look, by turns: the tone given the rest, the colour mix, then the
// vignette across given down and down given across. The tone already
// takes each channel's scale and offset, so the mix is fitted only as
// much of the other two channels as keeps grey grey,
//   s_c = in_c + a_c0 (in_o0 - in_c) + a_c1 (in_o1 - in_c),
// which is a saturation and a cast: the full matrix would trade scale
// with the tone and wander. The tone and the mix are not linear
// together, so the mix takes a Gauss-Newton step each turn.
fit :: proc(samples: []Sample) -> (look: terrain.Preview_Look) {
	TONE_SMOOTH :: 0.01
	VIGNETTE_SMOOTH :: 0.001
	for c in 0 ..< 3 {
		look.colour[c][c] = 1
		for k in 0 ..< TONE_KNOTS {
			look.tone[c][k] = 255 * f32(k) / f32(TONE_KNOTS - 1)
		}
	}
	for k in 0 ..< VIGNETTE_KNOTS {
		look.across[k], look.down[k] = 1, 1
	}
	mix: [3][2]f32
	for _ in 0 ..< 16 {
		for c in 0 ..< 3 {
			eq := normal_make(TONE_KNOTS)
			for &s in samples {
				v := vignette(&look, s.d)
				normal_add(&eq, terrain.preview_mix(&look, s.src)[c], 255, v, s.dst[c])
			}
			normal_solve(&eq, TONE_SMOOTH, look.tone[c][:])
		}

		for c in 0 ..< 3 {
			o := others(c)
			a: [2][2]f64
			b: [2]f64
			for &s in samples {
				v := vignette(&look, s.d)
				m := terrain.preview_mix(&look, s.src)[c]
				r := s.dst[c] - v * terrain.preview_curve(look.tone[c][:], m, 255)
				g := v * slope(look.tone[c][:], m)
				j := [2]f64{f64(g * (s.src[o[0]] - s.src[c])), f64(g * (s.src[o[1]] - s.src[c]))}
				for p in 0 ..< 2 {
					for q in 0 ..< 2 {
						a[p][q] += j[p] * j[q]
					}
					b[p] += j[p] * f64(r)
				}
			}
			det := a[0][0] * a[1][1] - a[0][1] * a[1][0]
			if abs(det) > 1e-9 {
				mix[c][0] += f32((b[0] * a[1][1] - b[1] * a[0][1]) / det)
				mix[c][1] += f32((a[0][0] * b[1] - a[1][0] * b[0]) / det)
			}
			look.colour[c] = {}
			look.colour[c][c] = 1 - mix[c][0] - mix[c][1]
			look.colour[c][o[0]] = mix[c][0]
			look.colour[c][o[1]] = mix[c][1]
		}

		for axis in 0 ..< 2 {
			eq := normal_make(VIGNETTE_KNOTS)
			for &s in samples {
				other := axis == 0 ? terrain.preview_curve(look.down[:], s.d.y, 1) : terrain.preview_curve(look.across[:], s.d.x, 1)
				m := terrain.preview_mix(&look, s.src)
				for c in 0 ..< 3 {
					normal_add(&eq, s.d[axis], 1, other * terrain.preview_curve(look.tone[c][:], m[c], 255), s.dst[c])
				}
			}
			normal_solve(&eq, VIGNETTE_SMOOTH, axis == 0 ? look.across[:] : look.down[:])
		}
		// The middle untouched: the scale is the tone's.
		centre := look.across[0] * look.down[0]
		a0, d0 := look.across[0], look.down[0]
		for k in 0 ..< VIGNETTE_KNOTS {
			look.across[k] /= a0
			look.down[k] /= d0
		}
		for c in 0 ..< 3 {
			for k in 0 ..< TONE_KNOTS {
				look.tone[c][k] *= centre
			}
		}
	}
	return
}

vignette :: proc(look: ^terrain.Preview_Look, d: [2]f32) -> f32 {
	return terrain.preview_curve(look.across[:], d.x, 1) * terrain.preview_curve(look.down[:], d.y, 1)
}

residual :: proc(samples: []Sample, look: ^terrain.Preview_Look) -> f32 {
	sum: f64
	for &s in samples {
		v := vignette(look, s.d)
		m := terrain.preview_mix(look, s.src)
		for c in 0 ..< 3 {
			d := clamp(v * terrain.preview_curve(look.tone[c][:], m[c], 255), 0, 255) - s.dst[c]
			sum += f64(d * d)
		}
	}
	return f32(math.sqrt(sum / f64(3 * len(samples))))
}

// The RMS difference of two previews, and their luminance's correlation.
compare :: proc(a, b: terrain.Picture) -> (rmse, corr: f32) {
	n := a.width * a.height
	sum, ma, mb: f64
	for i in 0 ..< n * 3 {
		d := f64(a.pixels[i]) - f64(b.pixels[i])
		sum += d * d
	}
	la := make([]f64, n, context.temp_allocator)
	lb := make([]f64, n, context.temp_allocator)
	for i in 0 ..< n {
		la[i], lb[i] = f64(luma(a.pixels[i * 3:])), f64(luma(b.pixels[i * 3:]))
		ma += la[i]
		mb += lb[i]
	}
	ma, mb = ma / f64(n), mb / f64(n)
	dot, sa, sb: f64
	for i in 0 ..< n {
		dot += (la[i] - ma) * (lb[i] - mb)
		sa += (la[i] - ma) * (la[i] - ma)
		sb += (lb[i] - mb) * (lb[i] - mb)
	}
	return f32(math.sqrt(sum / f64(n * 3))), f32(dot / math.sqrt(sa * sb))
}

// The original preview and the look's side by side, twice the size.
shot_write :: proc(path: string, original, made: terrain.Picture) {
	GAP :: 4
	out := terrain.picture_make((2 * PREVIEW_W + GAP) * 2, PREVIEW_H * 2, 3)
	defer terrain.picture_destroy(&out)
	for y in 0 ..< out.height {
		for x in 0 ..< out.width {
			sx := x / 2
			src := original
			if sx >= PREVIEW_W + GAP {
				src, sx = made, sx - PREVIEW_W - GAP
			} else if sx >= PREVIEW_W {
				continue
			}
			i := (y / 2 * PREVIEW_W + sx) * 3
			copy(out.pixels[(y * out.width + x) * 3:][:3], src.pixels[i:i + 3])
		}
	}
	os.make_directory_all(filepath.dir(path))
	if !terrain.png_write(path, out) {
		fmt.eprintfln("preview_fit: cannot write %s", path)
	}
}

write_look :: proc(path: string, look: terrain.Preview_Look, levels: []Level, rmse: f32) -> bool {
	look := look
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "package terrain")
	fmt.sbprintln(&b)
	fmt.sbprintln(&b, "// Made by `mise run preview:fit` (tools/preview_fit), from the original")
	fmt.sbprintln(&b, "// previews and their maps in plugins/classic_levels: do not edit. Where")
	fmt.sbprintln(&b, "// each preview's crop was, and how well it matched:")
	for l in levels {
		fmt.sbprintfln(&b, "//   %s %s: (%d, %d) of %d rows, %.3f%s", l.id, l.preview_name, l.x, l.y, l.m.height, l.score, l.score < MATCH_MIN ? ", left out" : "")
	}
	fmt.sbprintfln(&b, "// The look comes within %.2f (RMS, 0-255) of the previews it was fitted to.", rmse)
	fmt.sbprintln(&b, "PREVIEW_LOOK :: Preview_Look {")
	fmt.sbprintfln(&b, "\tblur = %.2f,", look.blur)
	fmt.sbprintln(&b, "\tcolour = {")
	for row in look.colour {
		fmt.sbprintfln(&b, "\t\t{{%.4f, %.4f, %.4f, %.4f}},", row[0], row[1], row[2], row[3])
	}
	fmt.sbprintln(&b, "\t},")
	fmt.sbprintln(&b, "\ttone = {")
	for c in 0 ..< 3 {
		fmt.sbprint(&b, "\t\t{")
		for v, k in look.tone[c] {
			fmt.sbprintf(&b, "%s%.2f", k > 0 ? ", " : "", v)
		}
		fmt.sbprintln(&b, "},")
	}
	fmt.sbprintln(&b, "\t},")
	curve :: proc(b: ^strings.Builder, name: string, knots: []f32) {
		fmt.sbprintf(b, "\t%s = {{", name)
		for v, k in knots {
			fmt.sbprintf(b, "%s%.4f", k > 0 ? ", " : "", v)
		}
		fmt.sbprintln(b, "},")
	}
	curve(&b, "across", look.across[:])
	curve(&b, "down", look.down[:])
	fmt.sbprintln(&b, "}")
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}
