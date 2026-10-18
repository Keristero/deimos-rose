package meme_view

import "dr:plugins/meme"
import "dr:prefs"
import "dr:sim"

// Hit Pause's settings, on the Extra Preferences page. The intensities are
// percent of the plugin's own look (100 as it is, 0 off); the volumes are
// percent of twice the default, so 50 is as it comes and 100 is double.

register_settings :: proc() {
	id := meme.id()
	shared.strength = prefs.setting_register({plugin = id, key = "hitstop_strength", label = "HIT PAUSE", kind = .Percent, default = 100})
	shared.shake = prefs.setting_register({plugin = id, key = "hitstop_shake", label = "KILL CAM SHAKE", kind = .Percent, default = 100})
	shared.zoom_amount = prefs.setting_register({plugin = id, key = "hitstop_zoom", label = "KILL CAM ZOOM", kind = .Percent, default = 100})
	shared.slowmo = prefs.setting_register({plugin = id, key = "hitstop_slowmo", label = "KILL CAM SLOW MOTION", kind = .Percent, default = 100})
	shared.reverb = prefs.setting_register({plugin = id, key = "hitstop_reverb", label = "KILL CAM REVERB", kind = .Percent, default = 100})
	shared.flames = prefs.setting_register({plugin = id, key = "hitstop_flames", label = "COMBO FLAMES", kind = .Percent, default = 100})
	shared.announcer_volume = prefs.setting_register({plugin = id, key = "hitstop_announcer_volume", label = "ANNOUNCER VOLUME", kind = .Percent, default = 50})
	shared.boom_volume = prefs.setting_register({plugin = id, key = "hitstop_boom_volume", label = "BOOM VOLUME", kind = .Percent, default = 50})
	shared.horn_volume = prefs.setting_register({plugin = id, key = "hitstop_horn_volume", label = "HORN VOLUME", kind = .Percent, default = 50})
	shared.flame_amount = 1 // until combo_apply reads the setting
}

// An intensity setting as a multiplier: 1 at 100.
intensity :: proc "contextless" (setting: [prefs.MAX_SETTINGS]int, id: prefs.Setting_ID) -> f32 {
	return f32(setting[id]) / 100
}

// A volume setting as a multiplier: 1 at 50, the default.
volume_scale :: proc "contextless" (setting: [prefs.MAX_SETTINGS]int, id: prefs.Setting_ID) -> f32 {
	return f32(setting[id]) / 50
}

@(init)
register_settings_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/meme/view register_settings", register_settings)
}
