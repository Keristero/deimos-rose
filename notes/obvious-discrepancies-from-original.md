I'm fairly sure most of these have been resolved now:

### Particle effects:
- Air to ground projectiles seem to have a larger glow radius than the originals
- Impact particles in the original are round and have a bit of texture to them (they are a soft round particle that tapers into a darker more translucent edge) (also applies to particles created when picking up coins)

### Other:
- when hitting ground targets, the highlight effect (brighten and fade) was more pronounced (higher peak brightness)
- some sprites are drawn outside the edge of the map, notably enemies spawning in from the left side of the screen, and we can see shadows cast by enemies that are about to spawn in from the top of the screen (the enemies appear for a moment before they begin moving)

### brightness / saturation of overall image:
- the orignal game's overall presentation seemed a little lighter and less saturated, I prefer the current appearance to this, but with classic mode enabled we should seek a 99% accurate color mapping.


### UI/HUD
- the numbers displaying the amount of lives each player has and their scores are not correctly aligned in the HUD.
- the ship icons are missing from the large circles in the UI (should use accented colors if enabled)
- the the globes which represent the currently selected powerup and the next two in the rotation are not populated or working, there should be a different colored circle for each powerup that cycles as you switch weapons.
- The shield and health meters have a rounded glass like appearance
- At the end of each level, a score count occurs. currently we are not showing any of the text in the middle of the screen under sector secured to detail this breakdown.
    - Shield bonus should flash above all characters who acheived it
    - ground accuracy appears
    - bonus appears and is counted
    - the ground accuracy and bonus fade, coin bonus is counted

### Audio
- Several sound effects are incorrect, for example:
- one of the guns is using the sound effects of the next unlocked gun
- the pitch of bullets hitting ground targets with shields is off (not sure if this applies to all, and it might just be the wrong sound effect)
- 
do an investigation to see if we can work out where the innacuracy comes from and try solve them it if you are confident.