package passives_view

// The passives' screenshot scenarios (ui/shots.odin), `mise run menu-shot
// MENU=...`, all new content. Player 1 flies a weapon on stage 3, two
// seconds in, alone, so no loadout screen opens:
//   - rear_gun_side: the Rear Gun at Weapon 3's level 3, fire held, so the
//     side volleys fly left and right beside the rear shots: a visual check
//     that the side shots are drawn turned to the way they fly.
//   - rear_gun_charge: the Rear Gun at Weapon 3 Charge's level 3, the
//     charge held to its top and let go, so the release's bubbles fly out
//     larger and shrink as they give their damage (Wears_Down).
//   - bacta_gun_charge: the Bacta Gun at Weapon 2 Charge's level 3, the
//     charge held to its top and let go, so the release's hits leave
//     corrosive clouds (Hit_Cloud) on the stage's first wave.
//   - ion_cannon_charge: the Ion Cannon at Weapon 1 Charge's level 3, the
//     same, with two Laser Tanks parked ahead, so the release's shots hit
//     them as they fly over (Hits_Ground).


import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/player_system"
import "dr:sim/systems/weapon_system"
import "dr:ui"

// Each scenario's weapon, and the passive it holds at level 3.
@(private = "file")
shot_loadout :: proc(name: string) -> (weapon: passives.Res_ID, passive: passives.Passive) {
	switch name {
	case "rear_gun_side":
		return passives.WEAPON_REAR_GUN, passives.WEAPON_3
	case "rear_gun_charge":
		return passives.WEAPON_REAR_GUN, passives.WEAPON_3_CHARGE
	case "bacta_gun_charge":
		return passives.WEAPON_BACTA_GUN, passives.WEAPON_2_CHARGE
	case "ion_cannon_charge":
		return passives.WEAPON_ION_CANNON, passives.WEAPON_1_CHARGE
	}
	return {}, {}
}

@(private = "file")
weapon_shot :: proc(s: ^sim.State, name: string) -> string {
	weapon, passive := shot_loadout(name)
	for &w, i in s.defs.weapons {
		if w.id == weapon {
			p := sim.player_at(s, 0)
			weapon_system.change_weapon(s, p.weapons, sim.WEP_AIR, i32(i))
			player_system.player_sprite_from_weapon(s, p)
			passives.levels_of(s, 0)[passive] = 3
			for _ in 0 ..< 120 {
				_ = sim.session_step(s, {})
			}
			if name == "ion_cannon_charge" {
				// Far ahead: the ground scrolls them down to the release.
				for ahead in ([]f32{240, 300}) {
					req := sim.spawn_request(sim.res_id("tala"))
					req.loc = p.loc - {0, ahead}
					req.stationary = true
					if !sim.ref_valid(s, lifecycle.eg_request_spawn(s, req)) {
						return "no Laser Tank"
					}
				}
			}
			return ""
		}
	}
	return "no such weapon"
}

@(private = "file", rodata)
REAR_GUN_PHASES := []ui.Shot_Phase{{4, {{.Fire_Air}, {}}}}

// The charge reaches its top of 12 levels in 15 + 12 * 4 steps; its
// release fires one bubble every 3 steps.
@(private = "file", rodata)
REAR_GUN_CHARGE_PHASES := []ui.Shot_Phase{{66, {{.Fire_Air}, {}}}, {20, {}}}

// The Bacta Gun's and the Ion Cannon's charges reach their top of 20
// levels in under 15 + 20 * 4 steps, at level 3's faster charge; their
// releases fire one volley a step.
@(private = "file", rodata)
FULL_CHARGE_PHASES := []ui.Shot_Phase{{96, {{.Fire_Air}, {}}}, {30, {}}}

register_shots :: proc() {
	ui.shot_register({name = "rear_gun_side", plugin = passives.ID, level = 2, alone = true, setup = weapon_shot, phases = REAR_GUN_PHASES})
	ui.shot_register({name = "rear_gun_charge", plugin = passives.ID, level = 2, alone = true, setup = weapon_shot, phases = REAR_GUN_CHARGE_PHASES})
	ui.shot_register({name = "bacta_gun_charge", plugin = passives.ID, level = 2, alone = true, setup = weapon_shot, phases = FULL_CHARGE_PHASES})
	ui.shot_register({name = "ion_cannon_charge", plugin = passives.ID, level = 2, alone = true, setup = weapon_shot, phases = FULL_CHARGE_PHASES})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/passives/view register_shots", register_shots)
}
