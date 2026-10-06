package hitstop_view

import "dr:plugins/hitstop"
import "dr:prefs"
import "dr:sim"

// Hit Pause's settings, on the Extra Preferences page. The intensities are
// percent of the plugin's own look (100 as it is, 0 off); the volumes are
// percent of twice the default, so 50 is as it comes and 100 is double.

STRENGTH: prefs.Setting_ID // how long a hit holds
SHAKE: prefs.Setting_ID // how hard the kill cam shakes the screen
ZOOM_AMOUNT: prefs.Setting_ID // how far the kill cam zooms in
SLOWMO: prefs.Setting_ID // how deep the kill cam's slow-motion goes
REVERB: prefs.Setting_ID // how much reverb the kill cam puts on the sound
FLAMES: prefs.Setting_ID // how much fire the combo text and meter throw
ANNOUNCER_VOLUME: prefs.Setting_ID
BOOM_VOLUME: prefs.Setting_ID
HORN_VOLUME: prefs.Setting_ID

register_settings :: proc() {
	id := hitstop.ID
	STRENGTH = prefs.setting_register({plugin = id, key = "hitstop_strength", label = "HIT PAUSE", kind = .Percent, default = 100})
	SHAKE = prefs.setting_register({plugin = id, key = "hitstop_shake", label = "KILL CAM SHAKE", kind = .Percent, default = 100})
	ZOOM_AMOUNT = prefs.setting_register({plugin = id, key = "hitstop_zoom", label = "KILL CAM ZOOM", kind = .Percent, default = 100})
	SLOWMO = prefs.setting_register({plugin = id, key = "hitstop_slowmo", label = "KILL CAM SLOW MOTION", kind = .Percent, default = 100})
	REVERB = prefs.setting_register({plugin = id, key = "hitstop_reverb", label = "KILL CAM REVERB", kind = .Percent, default = 100})
	FLAMES = prefs.setting_register({plugin = id, key = "hitstop_flames", label = "COMBO FLAMES", kind = .Percent, default = 100})
	ANNOUNCER_VOLUME = prefs.setting_register({plugin = id, key = "hitstop_announcer_volume", label = "ANNOUNCER VOLUME", kind = .Percent, default = 50})
	BOOM_VOLUME = prefs.setting_register({plugin = id, key = "hitstop_boom_volume", label = "BOOM VOLUME", kind = .Percent, default = 50})
	HORN_VOLUME = prefs.setting_register({plugin = id, key = "hitstop_horn_volume", label = "HORN VOLUME", kind = .Percent, default = 50})
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
	sim.register_step(.View, "plugins/hitstop/view register_settings", register_settings)
}
