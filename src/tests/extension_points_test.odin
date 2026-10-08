package tests

// The extension points through which plugins reach the menus, the launch
// line and the frame loop without the core naming them (Phase 10 stage 1,
// decisions.md D82): each test pins what the plugins in this build
// register, so a registration that goes missing fails here rather than as
// a switch quietly gone from a screen.

import "core:testing"

import "dr:plugins/accent"
import accent_view "dr:plugins/accent/view"
import "dr:plugins/easy_mode"
import "dr:plugins/extra_prefs"
import "dr:plugins/fps_unlock"
import "dr:plugins/lighting"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/new_weapons"
import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:ui"

// 30FPS Unlock's -highrefreshrate is its own registration; -mod names any
// plugin; anything else is not a plugin's.
@(test)
launch_flags_switch_plugins_on :: proc(t: ^testing.T) {
	testing.expect_value(t, prefs.launch_mods({"-highrefreshrate"}), sim.Mods{int(fps_unlock.ID)})
	testing.expect_value(t, prefs.launch_mods({"-mod", "easy_mode"}), sim.Mods{int(easy_mode.ID)})
	testing.expect_value(t, prefs.launch_mods({"-mod", "easy_mode", "-highrefreshrate"}), sim.Mods{int(easy_mode.ID), int(fps_unlock.ID)})
	testing.expect_value(t, prefs.launch_mods({"-mod", "no_such_plugin", "-windowed"}), sim.Mods{})
	testing.expect_value(t, prefs.launch_mods({"-mod"}), sim.Mods{}) // its name missing
}

// Level Select offers Easy Mode alone; the lobby offers Easy Mode, then New
// Weapons, as it did before the switches were registered.
@(test)
setup_switches_on_each_screen :: proc(t: ^testing.T) {
	on :: proc(screen: ui.Setup_Screen) -> (out: [dynamic]sim.Plugin_ID) {
		out = make([dynamic]sim.Plugin_ID, context.temp_allocator)
		for s in ui.registered_setup_switches() {
			if screen in s.screens {
				append(&out, s.plugin)
			}
		}
		return
	}
	level_select := on(.Level_Select)
	testing.expect_value(t, len(level_select), 1)
	if len(level_select) == 1 {
		testing.expect_value(t, level_select[0], easy_mode.ID)
	}
	lobby := on(.Lobby)
	testing.expect_value(t, len(lobby), 2)
	if len(lobby) == 2 {
		testing.expect_value(t, lobby[0], easy_mode.ID)
		testing.expect_value(t, lobby[1], new_weapons.ID)
	}
}

// One switch sits in the middle; two sit 110 either side, where the
// lobby's EASY_X and WEAPONS_X put them.
@(test)
setup_switches_spread_about_the_middle :: proc(t: ^testing.T) {
	mid := f32(render.SCREEN_W / 2)
	testing.expect_value(t, ui.setup_switch_x(0, 1), mid)
	testing.expect_value(t, ui.setup_switch_x(0, 2), mid - 110)
	testing.expect_value(t, ui.setup_switch_x(1, 2), mid + 110)
}

// The players' colours are found by player, not by a plugin's name.
@(test)
player_hues_are_found_by_player :: proc(t: ^testing.T) {
	p1, ok1 := prefs.player_hue_setting(1)
	p2, ok2 := prefs.player_hue_setting(2)
	_, ok3 := prefs.player_hue_setting(3)
	testing.expect(t, ok1 && ok2 && !ok3)
	testing.expect_value(t, p1, accent_view.HUE_P1)
	testing.expect_value(t, p2, accent_view.HUE_P2)
	testing.expect_value(t, prefs.registered_settings()[p1].plugin, accent.ID)
}

// Netplay is the one plugin on exactly when a session is online, and
// Extra Preferences the one that offers the Extras page.
@(test)
online_plugins_and_the_settings_page :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.mods_online(), sim.Mods{int(netplay_plugin.ID)})
	testing.expect_value(t, prefs.settings_page_plugin(), extra_prefs.ID)
}

// A plugin's screenshot resolves to the core screen it is taken on, with
// its plugin; the core's own screens are not registered.
@(test)
menu_shots_name_their_plugin :: proc(t: ^testing.T) {
	easy, ok := ui.menu_shot_find("level_select_easy")
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, easy.plugin, easy_mode.ID)
		testing.expect_value(t, easy.screen, "level_select")
	}
	extras, ok2 := ui.menu_shot_find("preferences_extras")
	testing.expect(t, ok2)
	if ok2 {
		testing.expect_value(t, extras.plugin, accent.ID)
		testing.expect_value(t, extras.screen, "extras")
		testing.expect(t, extras.setup != nil)
	}
	sliders, ok3 := ui.menu_shot_find("preferences_extras_sliders")
	testing.expect(t, ok3)
	if ok3 {
		testing.expect_value(t, sliders.plugin, lighting.ID)
		testing.expect_value(t, sliders.screen, "extras")
	}
	_, core := ui.menu_shot_find("main")
	testing.expect(t, !core)
}
