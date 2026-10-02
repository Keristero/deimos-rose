#### Weapon 1 passive adjustment
- Level 3 of the weapon 1 passive is supposed to slow down the bullets and add a speed up, the speed up should only get back to the original speed after about 1 second.

#### Weapon 5 adjustments
- add a bright muzzle flash particle effect that flashes and fades very quickly with each shot for both the pirmary fire and the charge fire, it should be half the intensity on the primary fire

#### Weapon 6 adjustments
- slow the time between shots slightly
- Add a short delay (0.2) before each shot to improve the weapon feel, during this delay red particle effects are quickly drawn into the ship, the particle animation starts fast and slows down as the partciles get near the ship.
    - use a sound effect for the precharge
- increase the base width and vividness of the beam, also increase the damage to account for the reduced fire rate due to the increase delay before and after firing.
- Remove the shrapnel mechanic, keep the piercing when damage exceeds entity health

Laser charge attack adjustment:
- The charged laser was a bit boring, instead of just being a stronger version of the normal attack, the discharge beam should create some lingering red particles that appear in the path of the beam at a regular interval (as a result, more particles appear on a longer beam), the particles drift very slowly in a random direction, these particles dont damage or collide with anything
- after a short delay (scales with the level of charge, starting at 0.2, up to about 1 second with default max charge), the lingering particles explode (a single explosion sound effect plays now) into 3 white damaging particles each which fly out quickly with a short lifetime (fading like the bacta gun, but also fading to a orange color as they fade).

#### Weapon 5 (non charged) (Chain gun)
Description: Empowers Weapon 5's non charged attack
Desired effect: Enhance weapon's standard fire, the chaingun should fire continueously 
    - decreased `firing_delay` (30,60,100) //delay between attacks
    - increased `random_spread_range`

#### Weapon 6 (non charged) (Discharge Beam)
Description: Empowers Weapon 6's non charged attack
Desired effect: Enhance weapon's standard fire
    - increased `damage` (10,20,30) //should act as base damage for charge attack too
    - increased `base_beam_width` (10,20,30) //width also scales with damage

Follow up in `extra-weapons-and-passives-3.md`