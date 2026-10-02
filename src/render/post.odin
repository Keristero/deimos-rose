package render

// Post passes: what a mod does to the finished play field. The frame is
// drawn into a scene texture instead of straight to the canvas whenever a
// pass is on, then each pass reads the picture and draws its own into the
// next target, the last into the canvas. The score bar, notices and menus
// are drawn after, so no pass touches them.
//
// A pass has two steps because raylib's render targets do not nest
// (resume_canvas): `prepare` runs with no target bound and may draw into any
// offscreen texture of its own (a light map, a blurred glow), then `apply`
// runs with the destination bound and draws one full-field quad from `src`.
// Everything a pass needs from the frame is on the Renderer: the items it
// pushed to its layers (render_systems.odin), whose `emit` says what glows,
// and the Post_Frame below.
//
// With no pass on, none of this runs and the frame is drawn as it always was.

import rl "vendor:raylib"

import "dr:sim"

MAX_POST_PASSES :: 8

Post_Frame :: struct {
	scale:     f32, // output pixels a play field pixel
	side:      f32, // the view's sideways scroll
	t:         f32, // how far between steps, 1 when not interpolating
	particles: ^Particles,
	// The size of the whole canvas the play field sits in, in pixels.
	width, height: i32,
}

Post_Pass :: struct {
	name:    string,
	after:   []string,
	before:  []string,
	plugin:  sim.Plugin_ID, // runs only while this plugin is on
	// Optional: whether the pass does anything with the settings as they
	// are (a pass at zero strength costs nothing).
	enabled: proc(r: ^Renderer) -> bool,
	prepare: proc(r: ^Renderer, f: ^Post_Frame),
	// Draws the picture `src` (bottom-up, as a render texture is) over the
	// play field, in the target already bound.
	apply:   proc(r: ^Renderer, f: ^Post_Frame, src: rl.Texture2D),
	// Optional: frees what the pass keeps.
	destroy: proc(),
}

@(private = "file")
post_passes: sim.Registry(Post_Pass, MAX_POST_PASSES)

// Called from registration steps only (sim.register_step); `after` and
// `before` outlive the call, like a render system's.
post_pass_register :: proc(p: Post_Pass) {
	sim.registry_add(&post_passes, p)
}

Post_State :: struct {
	scene: rl.RenderTexture2D,
	pong:  rl.RenderTexture2D,
	// The passes of the plugins on, in order, by registry index (rebuilt
	// when the plugins on change), and those of them running this frame.
	order:       [MAX_POST_PASSES]u8,
	order_count: int,
	order_mods:  sim.Mods,
	order_built: bool,
	running:     [MAX_POST_PASSES]u8,
	count:       int,
}

post_destroy :: proc(r: ^Renderer) {
	if r.post.scene.id != 0 {
		rl.UnloadRenderTexture(r.post.scene)
	}
	if r.post.pong.id != 0 {
		rl.UnloadRenderTexture(r.post.pong)
	}
	for &p in sim.registry_items(&post_passes) {
		if p.destroy != nil {
			p.destroy()
		}
	}
	r.post = {}
}

// Binds the scene texture when some pass is on, and says so. Passes run in
// the order registered, or `after`/`before` where they say.
post_begin :: proc(r: ^Renderer, w, h: i32) -> bool {
	items := sim.registry_items(&post_passes)
	if len(items) == 0 {
		return false
	}
	if !r.post.order_built || r.post.order_mods != r.mods {
		r.post.order_count = int(sim.order_registered(items, r.mods, r.post.order[:]))
		r.post.order_mods = r.mods
		r.post.order_built = true
	}
	r.post.count = 0
	for idx in r.post.order[:r.post.order_count] {
		if items[idx].enabled == nil || items[idx].enabled(r) {
			r.post.running[r.post.count] = idx
			r.post.count += 1
		}
	}
	if r.post.count == 0 {
		return false
	}
	if r.post.scene.id == 0 || r.post.scene.texture.width != w || r.post.scene.texture.height != h {
		if r.post.scene.id != 0 {
			rl.UnloadRenderTexture(r.post.scene)
			rl.UnloadRenderTexture(r.post.pong)
		}
		r.post.scene = rl.LoadRenderTexture(w, h)
		r.post.pong = rl.LoadRenderTexture(w, h)
	}
	rl.BeginTextureMode(r.post.scene)
	rl.ClearBackground(rl.BLACK)
	return true
}

// Ends the scene, prepares every pass, then chains them: each reads the
// last one's picture and draws into the other texture, the last into the
// canvas.
post_end :: proc(r: ^Renderer, f: ^Post_Frame) {
	rl.EndTextureMode()
	items := sim.registry_items(&post_passes)
	for idx in r.post.running[:r.post.count] {
		if items[idx].prepare != nil {
			items[idx].prepare(r, f)
		}
	}
	bufs := [2]rl.RenderTexture2D{r.post.scene, r.post.pong}
	read := 0
	for i in 0 ..< r.post.count {
		last := i == r.post.count - 1
		write := 1 - read
		if last {
			resume_canvas(r)
			// Only the play field: the canvas's other parts are not the scene's.
			rl.BeginScissorMode(i32(VIEW_X * f.scale), 0, i32(PLAY_W * f.scale), i32(PLAY_H * f.scale))
		} else {
			rl.BeginTextureMode(bufs[write])
		}
		items[r.post.running[i]].apply(r, f, bufs[read].texture)
		if last {
			rl.EndScissorMode()
		} else {
			rl.EndTextureMode()
			read = write
		}
	}
}
