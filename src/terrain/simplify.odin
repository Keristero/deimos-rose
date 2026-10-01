package terrain

// Fewer triangles for a model too heavy to keep: Poly Haven's
// island_tree_01 is 1.6 million of them, a 59 MB buffer, for a tree the
// map draws some 60 texels across.
//
// Vertex clustering (Rossignac and Borrel, 1993): each part's vertices are
// gathered into cells of a grid, each cell's into one at their mean, and a
// triangle with two corners in one cell is gone. It keeps a solid's
// outline and cover from above, which is all the layer draws
// (scenery.odin), and it is quick: one pass a try. Not quadric error
// simplification, which keeps shape better at a given count but needs a
// heap of edge collapses over the whole mesh; nothing seen from 100 m up
// shows the difference.
//
// But a crown is not a solid. island_tree_01's is 44,168 leaves of 24
// triangles, each 5 cm across: a grid fine enough to keep a leaf keeps a
// million triangles, and one coarse enough to fit the budget folds every
// leaf to nothing and leaves the bare branches (it did). So a piece, a run
// of triangles joined by their corners, smaller than two cells is a leaf:
// clustered on a grid of its own, a few cells across it, and where the
// leaves are still too many, an even share of them kept and each grown by
// the root of what was dropped, so the crown covers as much from above
// (the way foliage is thinned for distance: SpeedTree's leaf reduction,
// and Cook, Halstead, Planck and Ryu's "Stochastic Simplification of
// Aggregate Detail", 2007).
//
// A cell holds a part's vertices whose UVs are near too, as well as their
// positions, so a texture's seam stays a seam: island_tree_01's bark wraps
// 15 times round, and a triangle across the seam would hold all 15.

import "core:math"
import "core:math/linalg"
import "core:slice"

// The triangles a model is brought under, all its variants together.
// Provisional: an import's, generous; the library's are fewer
// (tools/models).
MODEL_TRIANGLES :: 60_000

// UV cells a texture's width: a seam's two sides are a whole texture
// apart, so anything finer than one keeps it.
@(private = "file")
UV_CELLS :: 8

// Cells across a leaf's own grid: enough to keep it a leaf's shape, bent,
// in a few triangles.
@(private = "file")
LEAF_CELLS :: 3

// Brings `f` under `budget` triangles, if it is over, at the finest grid
// that does: the cell grows from 1/1024 of the largest model's extent by
// a root of two a try. Once what is not leaves is under half the budget,
// the leaves are thinned to fit instead. Its meshes are replaced, in
// `allocator`, which must be the one they were made in; their extents may
// grow by a grown leaf. Returns whether it changed them.
model_file_simplify :: proc(f: ^Model_File, budget := MODEL_TRIANGLES, allocator := context.allocator) -> bool {
	if file_triangles(f^) <= budget {
		return false
	}
	extent: f32
	for v in f.variants {
		extent = max(extent, linalg.length(v.hi - v.lo))
	}
	if extent <= 0 {
		return false
	}
	pieces := make([][]Piece, len(f.variants), context.temp_allocator)
	for v, k in f.variants {
		pieces[k] = mesh_pieces(v)
	}
	out := make([]Model_Mesh, len(f.variants), context.temp_allocator)
	reduce :: proc(f: ^Model_File, pieces: [][]Piece, out: []Model_Mesh, cell, keep: f32) -> (count, leaves: int) {
		for v, k in f.variants {
			n: int
			out[k], n = mesh_reduce(v, pieces[k], cell, keep)
			count += len(out[k].indices) / 3
			leaves += n
		}
		return
	}
	cell := extent / 1024
	search: for {
		count, leaves := reduce(f, pieces, out, cell, 1)
		if count <= budget {
			break
		}
		if rest := count - leaves; leaves > 0 && rest <= budget / 2 {
			keep := f32(budget - rest) / f32(leaves)
			// A share is a share of pieces, not of triangles: a little
			// less until it fits.
			for _ in 0 ..< 16 {
				if count, _ = reduce(f, pieces, out, cell, keep); count <= budget {
					break search
				}
				keep *= 0.9
			}
		}
		if cell > extent {
			break
		}
		// The count falls about as the square of the cell, for a surface:
		// so by about half a try.
		cell *= math.SQRT_TWO
	}
	for &v, k in f.variants {
		simple := out[k]
		delete(v.positions, allocator)
		delete(v.normals, allocator)
		delete(v.uvs, allocator)
		delete(v.colours, allocator)
		delete(v.indices, allocator)
		delete(v.parts, allocator)
		v.positions = slice.clone(simple.positions, allocator)
		v.normals = slice.clone(simple.normals, allocator)
		v.uvs = slice.clone(simple.uvs, allocator)
		v.colours = slice.clone(simple.colours, allocator)
		v.indices = slice.clone(simple.indices, allocator)
		v.parts = slice.clone(simple.parts, allocator)
		v.lo, v.hi = simple.lo, simple.hi
	}
	return true
}

file_triangles :: proc(f: Model_File) -> (n: int) {
	for v in f.variants {
		n += len(v.indices) / 3
	}
	return
}

// A run of one part's triangles joined by their corners: a leaf, a twig,
// a trunk.
@(private = "file")
Piece :: struct {
	part:      int,
	triangles: []u32, // their first indices
	lo, hi:    [3]f32,
}

// `m`'s pieces, part by part, in temp memory.
@(private = "file")
mesh_pieces :: proc(m: Model_Mesh) -> []Piece {
	root := make([]u32, len(m.positions), context.temp_allocator)
	find :: proc(root: []u32, i: u32) -> u32 {
		i := i
		for root[i] != i {
			root[i] = root[root[i]]
			i = root[i]
		}
		return i
	}
	out := make([dynamic]Piece, context.temp_allocator)
	of_root := make(map[u32]int, context.temp_allocator)
	for p, k in m.parts {
		for &r, i in root {
			r = u32(i)
		}
		for t := p.first; t + 2 < p.first + p.count; t += 3 {
			a := find(root, m.indices[t])
			root[find(root, m.indices[t + 1])] = a
			root[find(root, m.indices[t + 2])] = a
		}
		clear(&of_root)
		lists := make([dynamic][dynamic]u32, context.temp_allocator)
		for t := p.first; t + 2 < p.first + p.count; t += 3 {
			r := find(root, m.indices[t])
			at, found := of_root[r]
			if !found {
				at = len(lists)
				of_root[r] = at
				append(&lists, make([dynamic]u32, context.temp_allocator))
			}
			append(&lists[at], u32(t))
		}
		for list in lists {
			piece := Piece{part = k, triangles = list[:], lo = math.F32_MAX, hi = -math.F32_MAX}
			for t in list {
				for c in 0 ..< 3 {
					v := m.positions[m.indices[int(t) + c]]
					piece.lo, piece.hi = linalg.min(piece.lo, v), linalg.max(piece.hi, v)
				}
			}
			append(&out, piece)
		}
	}
	return out[:]
}

@(private = "file")
Cell :: struct {
	part:  int,
	piece: int, // a leaf's own grid, or -1 for the part's
	at:    [3]i32,
	uv:    [2]i32,
}

// `m` clustered at `cell` metres, and its leaves, pieces under two cells,
// on grids of their own: `keep` of them, grown to cover as all did. The
// triangles the leaves are.
@(private = "file")
mesh_reduce :: proc(m: Model_Mesh, pieces: []Piece, cell, keep: f32) -> (out: Model_Mesh, leaves: int) {
	out = m
	positions := make([dynamic][3]f32, context.temp_allocator)
	normals := make([dynamic][3]f32, context.temp_allocator)
	uvs := make([dynamic][2]f32, context.temp_allocator)
	colours := make([dynamic][4]u8, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	parts := make([dynamic]Model_Part, context.temp_allocator)
	members := make([dynamic]f32, context.temp_allocator)
	cells := make(map[Cell]u32, context.temp_allocator)
	seen := make(map[[3]u32]struct{}, context.temp_allocator)
	grow := 1 / math.sqrt(keep)
	next := 0
	// Cells are per part, so a vertex two parts share is two.
	for p, k in m.parts {
		first := len(indices)
		for ; next < len(pieces) && pieces[next].part == k; next += 1 {
			piece := pieces[next]
			size := piece.hi - piece.lo
			leaf := linalg.length(size) < 2 * cell
			// Evenly through the pieces, which are in the file's order: a
			// branch's leaves are together there, so each branch keeps its
			// share (the golden ratio's multiples spread most evenly).
			if leaf && math.mod(f32(next + 1) * 0.618034, 1) >= keep {
				continue
			}
			centre := (piece.lo + piece.hi) / 2
			grid, scale := cell, f32(1)
			if leaf {
				grid = max(max(size.x, size.y, size.z) / LEAF_CELLS, 1e-6)
				scale = grow
			}
			before := len(indices)
			for t in piece.triangles {
				corner: [3]u32
				for c in 0 ..< 3 {
					i := m.indices[int(t) + c]
					key := Cell {
						part  = k,
						piece = leaf ? next : -1,
					}
					for a in 0 ..< 3 {
						key.at[a] = i32(math.floor((m.positions[i][a] - (leaf ? piece.lo[a] : 0)) / grid))
					}
					for a in 0 ..< 2 {
						key.uv[a] = i32(math.floor(m.uvs[i][a] * UV_CELLS))
					}
					at, found := cells[key]
					if !found {
						at = u32(len(positions))
						cells[key] = at
						append(&positions, [3]f32{})
						append(&normals, [3]f32{})
						append(&uvs, m.uvs[i])
						append(&colours, m.colours != nil ? m.colours[i] : [4]u8{255, 255, 255, 255})
						append(&members, 0)
					}
					// Each corner counts, not each vertex: a vertex weighs as
					// many triangles as it is in, near enough its share.
					positions[at] += centre + (m.positions[i] - centre) * scale
					normals[at] += m.normals[i]
					members[at] += 1
					corner[c] = at
				}
				if corner[0] == corner[1] || corner[1] == corner[2] || corner[0] == corner[2] {
					continue
				}
				// The same three cells again, in any order and so either way
				// round: one is enough, the layer is double sided.
				sorted := corner
				slice.sort(sorted[:])
				if sorted in seen {
					continue
				}
				seen[sorted] = {}
				append(&indices, ..corner[:])
			}
			if leaf {
				leaves += (len(indices) - before) / 3
			}
		}
		q := p
		q.first, q.count = first, len(indices) - first
		if q.count > 0 {
			append(&parts, q)
		}
	}
	// A grown leaf may reach past the extent: the extent grows, but the
	// foot stays on the ground.
	for &v, k in positions {
		v /= members[k]
		v.y = max(v.y, 0)
		out.hi = linalg.max(out.hi, v)
		normals[k] = linalg.normalize0(normals[k])
		if normals[k] == 0 {
			normals[k] = {0, 1, 0}
		}
	}
	for v in positions {
		out.hi.x, out.hi.z = max(out.hi.x, abs(v.x)), max(out.hi.z, abs(v.z))
	}
	out.lo = {-out.hi.x, 0, -out.hi.z}
	out.positions, out.normals, out.uvs, out.indices, out.parts = positions[:], normals[:], uvs[:], indices[:], parts[:]
	out.colours = m.colours != nil ? colours[:] : nil
	return
}
