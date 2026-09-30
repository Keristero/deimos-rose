# Terrain occlusion

`occlusion.py` bakes a level project's `occlusion` layer: how open to the
sky each map pixel is. The renderer multiplies the ambient light by it
(decisions.md D56). FLUX.2 [klein] 4B infers the layer from the project's
colour, as the renderer draws it, so the stones, cracks and gaps between
trees that the texture shows are occluded even where the heights are flat.
The docstring says why this method was chosen over GTAO and Marigold
normals.

```sh
cd src
mise run hd:setup                     # once: the venv hd:upscale uses, with Flux
PROJECT=../work/recovered/le07/le07.drproj.json mise run terrain:occlusion
```

`terrain:recover-all` runs it on every recovered level. It takes about 6 s
a tile on the Strix Halo, and a 480 x 3600 map is 9 tiles. The tiles are
cached in the project's `cache/` folder, keyed by the colour and the
settings, so a rerun after an unrelated change only reassembles them.
`<stem>.occlusion.json` records the model, the prompt and the versions.

On a recovered level, bake from the colour `terrain:recover` wrote, and
then run `terrain:relight`, which fits the layer to the original art and
divides it out of the colour (decisions.md D59). A bake after a relight
starts from the relit colour: it misses the tile cache and runs Flux
again.
