1. The approach of comparing screenshots is good, but dont let perfect accuracy get in the way of a superior result.
- we should include an optional -classic setting (or launch argument for now) that strives to match the original graphics as accurately as possible
- where matching the original graphics would reduce the overall fidelity of the image, consider keeping the higher fidelity option. also consiser that the version we are running in wine may not be configured correctly or may not be presented exactly as the original was, but it should be quite close. subtle color grading differences can be ignored for phase5, we can revisit them after phase6 potentially.
- the ~99.5% accurate `-classic` setting is lower priority than getting broader goal of getting ~95% accuracy across the whole game for starters, we can refine the accuracy further later.

2. When I launch the game via the mise task - it is running at double speed (60fps), I belive the original ran at 30fps or even lower.
- for the odin version, we should still default to the original framerate for accuracy, but we should definitely ensure that all game code will function correctly when rendered at a varaible refresh rate - targetting the monitors native refresh rate when a `-highrefreshrate` option is set.

3. as we get into the territory of potentially adding more custom code that enhances the game from the original appearance and / or features, we should ensure that these customizations are added through a simple modding interface so that we can disable them if we want to.
- this will allow us to more easily test the accuracy against the original by comparing unmodified behaviour against the original
- in the distant future once we have made the game accurate, we may do a huge refactor to make it use an ECS internally, this will allow easier extension and we can build a more sophisticated modding API at that point (post final phase)
- something like widescreen is also out of scope for now, the level backgrounds and design dont really allow for it currently.