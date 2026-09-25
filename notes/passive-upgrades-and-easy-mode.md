
# Easy mode

A new difficulty option will be presented with classic mode disabled, in local play this will be a lobby setting for the host to modify, in local play this will be displayed on the level select screen

At the end of each stage, after the scores are counted, the reward screen appears and each living player is able to choose a passive upgrade, the number of rewards presented is 2 + 1 for each additional player


# Passive upgrades
Major enhancement feature:

Passive upgrades that can be granted to players during a play session, they persist between levels but not between play sessions, these modify a player's toolkit in a range of ways including:
- stat modifcations for ships
- unlocking new weapons
- upgrading weapons

- some upgrades will be flagged as stackable

All upgrades should be implemented in such a way that will allow other passives to be applied, altering the same statistics without overwriting each others changes, Due to this, consideration will need to be made when each upgrade is added for how the mechanic will behave with all upgrades that could affect said mechanic applied up to their maximum number of stacks if applicable.

All upgrades must be deterministic and properly resynced on reconnect

### Gaining passives

- Passives can be presented on a new reward screen
- the reward screen pauses the game, presenting each player with an assortment of passive upgrades to choose from
- if a player already has a passive, but it is not yet max level - they may be presented with the next level of that passive
- each passive has an a small icon.
    - a short description of what the passive does is displayed in a fixed location for the passive which the player currently has selected, passives with numerical modifiers will display a human readable name for the modifier, the current value with the new post modification value beside it.
- The rewards screen can show many icons, automatically expanding the number of rows and columns as required to display all the icons, leaving room for the description box.
- players can use their movement keys to switch between options, and press their air to air fire button to select an option, their ground fire will deselect the option
- in multiplayer, the same number of options will appear, but both players cannot lock in the same option - they must account for each other's choices.
    - the option which each player has selected is indicated by a border highlight that uses their accent color. it is low saturation and brightness until the player has locked in thier choice, when multiple players are selected on the same item the borders are rendered outside eachother rather than overlapping, the order of which is determined by the number of players
- once all living players are ready, the game resumes
- reuse menu sound effects for this interface.
- make careful consideration for multiplayer determinism for rollback, especially around the pausing + resuming and locking in choices / unlocking them.

## Passive list
stackable upgrade effects are listed in (10/20/30) format, one for each level, if a level does not modify a stat it will have (x), only the current level's effect is applied *for example (10,x,30) only applies 30 at level 3, not 40* if an x is present the stat is unchanged at that level and the previous value is used, values with x should not be listed in the reward screen as they are not changing

an **increase** is a % change from the base value, rounded appropriately
suggested stat names look like this: `damage`, any time multiple sources modify a stat, all sources should be added together before they are applied. "increase" and "decrease" are summed together before being applied
a passive that lists **extra** is providing a flat increase to a values

As a general rule, all passives should have atleast one unique modifier that alters gameplay in a novel way, exmaples of this inclide:
- risky_reward
- accelerating_projectiles
- side_firing_volley
-


### Ship upgrades


#### Improved Manuvouring
Description: Increases maneuverability
Desired effect: The ship can change direction faster
    - increased `maneuverability` (20/50)
    - enables `risky_reward` (x/true) //spawns 2000 points pickups at random locations around the screen every 20 seconds

#### Auto Charge
Description: Air to Air weapon will automatically charge, charge speed is reduced
Desired effect: The air to air weapon automatically charges, tapping the button will unleash a charged attack, holding the button will autofire, unleashing a charge attack still blocks standard attack, only disables overheating at level 2
    - enables `auto_charge_air_to_air` (true,x)
    - enables `prevent_overheat` (x,true)
    - decreased `charge_rate` (50,x)
    - increased `overheat_delay` (50,x) //irrelevant once prevent overheat appears

#### Improved Charge
Description: Improves weapon charging performance
Desired effect: while charging weapons, the charge level increases faster, and the maximum charge is increased, discharging is unchanged but weapons will continue to fire for longer as result
Visual effect: intensity of charging particle effect is increased as it increases beyond the standard charge range. (the old maximum value)
    - increased `maximum_charge` (10/20/30)
    - increased `charge_rate` (10,20,30)

#### Shield Regen
Description: Shields regenerate after a delay
Desired effect: After a delay which is reset whenever the shields take damage, shields will regenerate slowly until full, or until damage is taken.
Visual effect: while regenerating, accent colored particles are subtley drawn to the ship
    - enables `sheild_regenerates` (true,x,x)
    - decreased `recharge_delay` (30,15,0) //seconds before regen begins
    - increased `charge_rate` (1,2,x) //I'm indicating a percentage per second here

### Weapon upgrades
Internal names (the weapon ids in the data, `src/assets/data`): the four air weapons in the order they unlock -- Weapon 1 is `aiic` (Ion Cannon, levels 1-3), Weapon 2 `aibg` (Bacta Gun), Weapon 3 `airg` (Rear Gun), Weapon 4 `aipb` (Photon Beam) -- and the one ground weapon, `plbo` (Plasma Bomb). How each entry below was implemented is in `src/docs/passive-upgrades.md`.

projectile spread patterns should continue the pattern of the original weapon unless otherwise specified

each group of projectiles that fires at the same time is a volley, single button pressess can produce multiple volleys
each volley usually contains the same number of projectiles

#### Ground Varient 1 (`plbo`, Plasma Bomb)
Description: Empowers ground weapon, but fires behind you
Desired effect: Empowers ground weapon, but it fires backwards, the distance from the player is about half, and the reticle adjusts against the bottom of the screen the same way it normally adjusts against the top (inveted obviously)
    - decreased `volley_delay` (10,20,x)
    - `extra_projectiles` (x,x,1)


#### Weapon 1 (non charged) (`aiic`, Ion Cannon)
Description: Empowers Weapon 1's non charged attack
Desired effect: Enhance weapon's standard fire
    - `extra_projectiles` (2,x,6)
    - `extra_volley` (x,1,x)
    - enables `accelerating_projectiles` (x,x,true)
    - decreased `initial_projectile_speed` (x,x,50)

#### Weapon 2 (non charged) (`aibg`, Bacta Gun)
Description: Empowers Weapon 2's non charged attack
Desired effect: Enhance weapon's standard fire
    - `extra_projectiles` (2,4,x)
    - `extra_volley` (x,x,1)
    - increased `projectile_lifetime` (10,20,50)//this effectively increases a weapon's range

#### Weapon 3 (non charged) (`airg`, Rear Gun)
Description: Empowers Weapon 3's non charged attack
Desired effect: Enhance weapon's standard fire
    - `extra_volley` (1,2,0)
    - enables `side_firing_volley` (x,x,true)

#### Weapon 4 (non charged) (`aipb`, Photon Beam)
Description: Empowers Weapon 4's non charged attack
Desired effect: Enhance weapon's standard fire
    - `extra_projectiles` (x,2,3)
    - decreased `firing_delay` (10,x,30) //delay between attacks
    - decreased `volley_delay` (10,x,30) //delay between volleys
