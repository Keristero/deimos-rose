package game

// The plugins in this build, each with its view package where it has one.
// Importing a package is what registers it (its `@(init)`), and the game
// names no plugin's screen or effect itself: each view registers its own
// render systems, overlays, effects and settings. A plugin is added to the
// build by adding it here.

import _ "dr:plugins/accent"
import _ "dr:plugins/accent/view"
import _ "dr:plugins/easy_mode"
import _ "dr:plugins/easy_mode/view"
import _ "dr:plugins/extra_prefs"
import _ "dr:plugins/fps_unlock"
import _ "dr:plugins/loadout"
import _ "dr:plugins/loadout/view"
import _ "dr:plugins/netplay"
import _ "dr:plugins/new_weapons"
import _ "dr:plugins/new_weapons/view"
import _ "dr:plugins/passives"
import _ "dr:plugins/passives/view"
