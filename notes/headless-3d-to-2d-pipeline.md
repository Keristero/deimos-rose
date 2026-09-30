# 3d to 2d pipeline

To create new content for the game, we will need a 3d to 2d pipeline capable of recreating the same look.
We can use raylib to render 3d scenes, but we dont appear to have access to the original 3d models or textures used to generate the original art.

## Task 1, investigation
- search through the original code for any assets which could be from the original 3d art, look into the features available in the level editor for infrormation on how levels were constructed and document your findings
- Done 2026-09-28: see [headless-3d-to-2d-findings.md](headless-3d-to-2d-findings.md). No 3D source survives; the terrain was rendered top-down in Bryce 3D, and the level editor only placed units.

## Task 2, attempt recreation
- Attempt to recreate the first level's environment from a 3d model to see how well we can imitate the lighting, this is more of a proof of concept than a method we will use for real level creation

## Task 3, (do not attempt yet)
- Build an interactive level editor for sculpting levels with elevation changes, texture painting, water, placing enemy spawns, camps etc

**UPDATE**
- After the findings of the investigation and task 2 attempt recreation, it seems like we should be able to produce a fairly accurate heightmap for each level that we can use to recreate the original level geometries, we can verify the accuracy of these recreations by exporting new reproductions and comparing the shadow overlaps

### Level Editor Specs
- Plan 2026-09-30: see [level-editor-plan.md](level-editor-plan.md), which covers Task 2, Task 3 and the New Features below.
- The level edtior will be compiled to its own binary with its own workflow, it will come with the game files
- The plugin system will be improved so that plugins with their own assets store the assets in the plugin folder too.
    - All of the original levels should be bundled in a classic levels plugin, in future we will disable this plugin and enable the remastered levels plugin once that is ready, but classic mode will reenable them instead - this also gives us the oppertunity to create a new fully custom set of levels that dont use the original asssets for an original deimos rose campaign in future.
- The level editor will be able to export bundles of levels in a plugin format, including any custom assets or dependencies to other plugins introduced placement of custom enemies etc.
- The level editor uses raylib to give a live preview of the 3d scene, tools will allow the following:
    - Creating a new level with dimensions defaulting to existing level lengths
    - live lighting preview, toggle on/off
    - terrain brush which lets you choose a height and deform the terrian
    - selection of brushes for level editing with soft edges, round, square, and rough variants
    - adjustable lighting parameters to apply per level, all copy pasteable between levels, defaults to like original stages
    - automatic generation of level select texture
    - Easy drag and drop import of textures which can be brushed onto terrian any assets are auto bundled in the plugin
    - placement of enemy spawners with easy to use visual configuration for the various options.
        - image previews of entities
    - support for setting up all of the level properties from the original levels
    - automatic adding and removal of the ground unit sprites, these are only baked into the map on export
    - exported plugins can be reopened, they are exported with a small project file that holds any information required for the level editor
    - a play button in the editor will automatically launch the game from the directory it expects to be bundled in (level editor will be bundled in same folder as game binary)
        - capable of launching a mission straight to the same scroll position as the current position in the editor
    - custom skybox textures for reflective surfaces
    - wind parameter which will affect particle effects and the new water shader when we add support for that
    - ability to set an automatic water layer, at this height any terrain lowered under the water will be obscured by the water, with advanced rendering we will still be able to see through the water so a button to toggle the water visibility will be good to have
    - weapon/s which should be unlocked at the start of this stage



## New features
- ability to export images at higher resolutions than the game originally used
- ability to export addtional images with texture information for a deffered rendering pipeline featuring realtime 2d lighting and reflections, shadows should be exported as a mask layer so that shadowed areas can be lit by lights.

### Environments
The original game appears to use textured 3d modeled environments that are then rendered with a orthographic top down perspective to a 2d texture which is used as a scrolling background.

An additional water mask texture is used to indicate which areas of the ground texture are water.

Finally, small level select preview image is also generated.

The environment appears to use a simple terrain heightmap which is lit by a sun, there is some ambient light which allows some visibility into shadowed areas.

#### Environmental Details
- The ground appears to have textures brushed on with soft transitions where grass has been brushed over dirt for example.
- There are dense patches of jungle on some maps
- Maps generally feature large flat plataus, with occasinal enemy bases featuring ground targets
    - The base of structures is baked into the image
- There are static structures such as bridges and roads which are simply baked into the image on some maps
- There are gas vents of some description around the maps which can be hit by air to ground weapons for an eco bonus
- steep changes in elevation have cliff textures on them