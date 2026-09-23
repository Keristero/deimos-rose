# Demo recording
The original game shipped with demos which were incredibly useful for validating that we were reproducing everything one to one.

There is however a gap in that we dont have demos for most of the levels.

To close this gap we should have the game automatically record demos using the same format as the original game, these demo recordings should be saved to a folder with unique names including the level name and number of players.

# Demo playback for accuracy and regression testing
Once we have had a human player record some demos - we should be able to inject these into the original game, this will give us a psudo ground truth to compare our odin implementation to. We replay our new demos for stages that did not originally have demos, and compare our implementation to ensure that it matches.

We would first have to confirm that our recorded demos for the first few stages match - we already have decent confidence that the simulation is matching for the first few stages, so we can use them as a validaiton that our demo recording works corrcetly.

Its possible and quite likely that our recorded demos for unseen stages will not successfully finish playing the stage when replayed in the real original game client, we can acknowledge that and ideally record new demos once our odin reproduction is more accurate that will match well enough.

# Formlise the demo test suite
We have a tidy way to run the menu comparisons, we should take screenshots at alteast 3 offsets per stage and record the comparison screenshots to an organised folder layout like we do for menus.