// Records a short clip of each weapon in play, for a look at how it feels
// rather than one frame of it.
//
//   clips <assets root> <out dir> <weapon id>...
//
// Each clip's frames are written as PNGs to <out dir>/<weapon>/, and the
// line "clip <weapon> <dir>" is printed for each; `mise run weapon-clips`
// turns them into GIFs. It draws through the game's own renderer, into an
// offscreen texture behind a hidden window, with no audio device.
//
// A weapon is flown on the stage it unlocks, in a New Weapons session with
// the loadout screen skipped, and the ship's shields are topped up every
// step so it lives to the end. The script, in steps:
//
// - WARM, not recorded, while the stage's first enemies arrive;
// - TAPS of a press every TAP_EVERY steps;
// - for a weapon with a charge, HOLD held, then let go for the rest.
//
// A ground weapon is tapped for the whole clip.
package clips

import "core:fmt"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:game"
import "dr:prefs"
import "dr:sim"

WARM :: 150
TAPS :: 60
TAP_EVERY :: 4
HOLD :: 60
STEPS :: 145

SEED :: 0x1234_5678

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: clips <assets root> <out dir> <weapon id>...")
		os.exit(2)
	}
	root, out_dir := os.args[1], os.args[2]
	defs, _ := data.assets_defs_load(root)
	data.extra_defs_load(root, &defs)
	if len(defs.levels) == 0 {
		fmt.eprintfln("clips: no game data under %s (run mise run assets:all)", root)
		os.exit(1)
	}

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(game.SCREEN_W * game.WINDOW_SCALE, game.SCREEN_H * game.WINDOW_SCALE, "clips")
	defer rl.CloseWindow()
	r: game.Renderer
	game.renderer_init(&r, root, false, false)
	defer game.renderer_destroy(&r)
	r.canvas = rl.LoadRenderTexture(game.SCREEN_W * game.WINDOW_SCALE, game.SCREEN_H * game.WINDOW_SCALE)

	state := new(sim.State)
	defer free(state)
	for id in os.args[3:] {
		if !clip(&r, &defs, state, root, id, out_dir) {
			os.exit(1)
		}
	}
}

clip :: proc(r: ^game.Renderer, defs: ^sim.Defs, state: ^sim.State, root, id, out_dir: string) -> bool {
	wi := -1
	for &w, i in defs.weapons {
		if w.id == sim.res_id(id) {
			wi = i
		}
	}
	if wi < 0 {
		fmt.eprintfln("clips: no weapon %s", id)
		return false
	}
	wd := &defs.weapons[wi]
	ground := wd.type == sim.WEP_GROUND
	charge := !ground && !wd.auto_repeat &&
		(wd.powerup_air_activation_spawn != sim.NONE || wd.powerup_air_release_spawn != sim.NONE)

	// The defaults, not the player's saved preferences, outside classic
	// mode with New Weapons on.
	ps := game.Prefs_State{saved = prefs.defaults()}
	ps.saved.classic, r.classic = false, false
	game.extra_set(&ps, .New_Weapons, 1)
	fl: game.Flow
	game.flow_init(&fl, root, defs, state, r, &ps)
	defer game.flow_destroy(&fl)
	particles: game.Particles
	game.particles_init(&particles)
	defer game.particles_destroy(&particles)
	blurs: game.Blurs
	game.blurs_init(&blurs)
	defer game.blurs_destroy(&blurs)
	notices: game.Notices

	game.flow_start_session(&fl, SEED, .Single, max(int(wd.minimum_level_available) - 1, 0))
	state.loadout.shown = true
	fl.mode = .Playing
	p := &state.players[0]
	if ground {
		sim.change_weapon(state, &p.weapons, sim.WEP_GROUND, i32(wi))
	} else {
		p.weapons.loadout[0] = i32(wi)
		sim.change_weapon(state, &p.weapons, sim.WEP_AIR, i32(wi))
		sim.player_sprite_from_weapon(state, p)
	}

	name := strings.trim_prefix(strings.trim_prefix(wd.name, "Air - "), "Ground - ")
	slug, _ := strings.replace_all(strings.to_lower(name), " ", "-")
	dir := fmt.aprintf("%s/%s", out_dir, slug)
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		fmt.eprintfln("clips: cannot make %s: %v", dir, err)
		return false
	}
	button: sim.Button = ground ? .Fire_Ground : .Fire_Air
	for k in -WARM ..< STEPS {
		fire := false
		switch {
		case k < 0:
		case ground || k < TAPS:
			fire = k % TAP_EVERY == 0
		case charge:
			fire = k < TAPS + HOLD
		}
		b: sim.Buttons
		if fire {
			b += {button}
		}
		_ = sim.session_step(state, {b, {}})
		p.shields = 100
		game.flow_effects_sync(&fl, &particles, &blurs, &notices)
		game.flow_effects_step(&fl, r, &particles, &blurs, &notices)
		if k < 0 {
			continue
		}
		rl.BeginTextureMode(r.canvas)
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		game.flow_draw(&fl, r, &particles, &blurs, &notices, game.WINDOW_SCALE)
		rl.EndTextureMode()
		img := rl.LoadImageFromTexture(r.canvas.texture)
		rl.ImageFlipVertical(&img) // render textures are bottom-up
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
		rl.ExportImage(img, fmt.ctprintf("%s/%04d.png", dir, k))
		rl.UnloadImage(img)
	}
	if p.state != .Playing {
		fmt.eprintfln("clips: %s: the ship was not in play at the end (%v)", slug, p.state)
	}
	fmt.printfln("clip %s %s", slug, dir)
	return true
}
