With our own level editor, we can now export enough information to allow for various realtime effects on levels. namely

- Water shader
    - adds reflections, waves based on wind speed, ripple effects when groundshots land, water transparency

- Higher resolution export + High resolution mode
    - The new editor can export higher res images than the originals, we should let the user choose from 0.5x to 2x resoltion to export at, choosing an option will update the editor preview
    - High resolution mode will enable display of high resolution assets alongside any original assets, so you could play a high resolition level, High resolution mode is a multiplier 0.5 to 2x resolution in options

- HD Textures
    - Use the best model we can run on this GPU, all game textures to higher resolution (2x) versions which are enabled with this plugin.
    - During this work, produce HD original resolution masks for albedo, etc as required for other lighting / shader effects

- Realtime lights
    - particle effects such as bullets, enemy fire, explosions, powerups, and players charging weapons should cast light onto the terrain and surrounding units
    - We will need to modify our 2d to 3d pipeline to support all sprites to recover albedo information for realtime lighting
    - We could attempt to recover reflectivity of materials, but for now we will just assume that units are more "metalic" than terrain
    - Add a glow postprocessing pass with an intensity slider in extra settings, only applies to emmisive matarials, we will add textures to indicate emissive areas of sprites, for example most bullet particle effects will be emissive, other sprites may only have a few emissive pixels, for starters focus on bullets, explosions, sparks, etc.

- Skybox + Clouds
    - We should be able to specify a sky texture and cloud textures, these will be reflected by the water shader, clouds will be affected by wind speed.

- Wind affected particles
    - purely visual particle effects will be affected by wind with this enabled

- Realtime 3d (Extra for experts, can delay till later)
    - We dont need to use the pre baked images of the level, this should be a level setting with an option to try force it for any level that supports it in the extras menu
    - Realtime shadows (day night cycle)
        - this wont work very well on the recovered levels because they had some shadows baked into the albedo (so we wont enable it by default for these) but we should modify the level editor to allow users to set lighting for different y coordinates, the lighting will be smoothly interpolated as you move between multiple settings.