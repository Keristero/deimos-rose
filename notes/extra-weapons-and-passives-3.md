# change to existing things
## Easy mode change
- currently in 2 player netplay you are presented with 3 options, it should be 3 + 1 for each player, so 4 options in 2 player, 3 in single player.

## Plugin split
- The passives for the extra weapons should be added by a seperate extra plugin that depends on both the extra weapon and the passive mod, this will allow users to turn off the extra passives while still using the new weapons.
- Any tests for added content should also be owned by the plugin that introduces the content (ideally)

## Discharge beam
- The change we did to add a delay and explosion to the discharge beam instead of just having a peircing beam did not play well in practice, revert to the previous charge beam, and rebalance the existing passives to accomidate this change.

## Chaingun
- the muzzle flash should appear under the ship for charge attacks, since they can go in any direction it should be centered under the center of the ship

## Rear firing ground weapon passive
- it should not overide the base ground weapon anymore, instead it adds a charge attack to it which fires a single strong shot backwards, reticle moves behind once you have been charging the air to ground weapon for a moment


# New passives for charge modifiers

### Weapon 1
- Fired projectiles can also hit ground targets, damage is reduced but the penalty goes down each level

### Weapon 2
- Hits from projectiles create corrosive clouds which linger for (2 seconds base)
    - corrosive clouds deal small amounts of damage to enemies inside them

### Weapon 3
- with this upgrade, bubbles reduce in size when they damage enemies until they run out of damage to give, or they expire like usual
- Each level makes the bubbles larger and longer lasting

### Weapon 4
- maximum charge capacity increased
- gains 2 extra projectiles for every x charge over the base amount (wide spread pattern), at full upgrades this would be + 4 projectiles, but the amount of projectiles falls off back to the base amount as the charge level depletes

### Weapon 5
- Firing speed ramps up as it fires
- Each level increases max charge

### Weapon 6
- The laser does not pierce in a straight line after the first target, it instead chains to the next closest enemy that has not already been hit by the laser, this continues until the laser runs out of damage
- Each level increases max charge and charge speed

# New alternative ground weapon charged attack
- Replaces other passive when picked, adjust the existing rear firing one to also replace this new passive when picked
- target reticle rotates around your ship, deals more damage, reticle position resets after releasing charged attack