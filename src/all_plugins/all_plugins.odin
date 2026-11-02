package all_plugins

// Every code plugin, each with its view package where it has one, compiled
// in: what a program imports to have them all without loading libraries.
// The game imports none, and loads each from its library (decisions.md
// D85); the static build (build:static), the tests and the tools that
// measure plugins' content import this instead. Importing a package is what
// registers it: the step its `@(init)` names for sim.register_all.
//
// A plugin is added here as well as to plugins/: the tests'
// plugins_folders_are_all_in_the_build fails without it, and plugins:check
// would find the libraries and the static build disagree.

import _ "dr:plugins/accent"
import _ "dr:plugins/accent/view"
import _ "dr:plugins/chaingun"
import _ "dr:plugins/chaingun/view"
import _ "dr:plugins/easy_mode"
import _ "dr:plugins/easy_mode/view"
import _ "dr:plugins/extra_prefs"
import _ "dr:plugins/extra_prefs/view"
import _ "dr:plugins/fps_unlock"
import _ "dr:plugins/fps_unlock/view"
import _ "dr:plugins/meme"
import _ "dr:plugins/meme/view"
import _ "dr:plugins/lighting"
import _ "dr:plugins/lighting/view"
import _ "dr:plugins/loadout"
import _ "dr:plugins/loadout/view"
import _ "dr:plugins/netplay"
import _ "dr:plugins/netplay/view"
import _ "dr:plugins/new_weapon_passives"
import _ "dr:plugins/new_weapon_passives/view"
import _ "dr:plugins/new_weapons"
import _ "dr:plugins/new_weapons/view"
import _ "dr:plugins/passives"
import _ "dr:plugins/passives/view"
import _ "dr:plugins/water"
import _ "dr:plugins/water/view"
import _ "dr:plugins/wind"
import _ "dr:plugins/wind/view"
