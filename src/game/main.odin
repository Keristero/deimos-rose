package game

import "core:fmt"
import rl "vendor:raylib"

import "dr:sim"

// The original presents a 416x480 play-field inside a 640x480 screen; the
// terrain runtime configures a 416x480x16 source view. We keep that logical
// size and let raylib scale it to the window.
PLAY_W :: 416
PLAY_H :: 480

WINDOW_SCALE :: 2

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(PLAY_W * WINDOW_SCALE, PLAY_H * WINDOW_SCALE, "Deimos Rising")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	state: sim.State
	sim.init(&state, sim.Session{seed = 0x1234_5678, level_id = sim.level_id("le01"), game_type = .Single})

	for !rl.WindowShouldClose() {
		sim.step(&state, gather_input())

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{12, 14, 22, 255})

		p := state.players[0]
		rl.DrawRectangle(
			i32(p.x) * WINDOW_SCALE - 8,
			i32(p.y) * WINDOW_SCALE - 8,
			16, 16,
			rl.Color{120, 200, 255, 255},
		)

		rl.DrawText(
			fmt.ctprintf("frame %v  checksum %16x", state.frame, sim.checksum(&state)),
			10, 10, 16, rl.Color{150, 160, 180, 255},
		)
		rl.EndDrawing()
	}
}

// Presentation-side input capture. The simulation never reads a device.
gather_input :: proc() -> sim.Frame_Input {
	b: sim.Buttons
	if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) { b += {.Left} }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { b += {.Right} }
	if rl.IsKeyDown(.UP)    || rl.IsKeyDown(.W) { b += {.Up} }
	if rl.IsKeyDown(.DOWN)  || rl.IsKeyDown(.S) { b += {.Down} }
	if rl.IsKeyDown(.SPACE)                     { b += {.Fire_Air} }
	if rl.IsKeyDown(.LEFT_CONTROL)              { b += {.Fire_Ground} }
	if rl.IsKeyPressed(.LEFT_SHIFT)             { b += {.Change_Air} }
	return sim.Frame_Input{b, {}}
}
