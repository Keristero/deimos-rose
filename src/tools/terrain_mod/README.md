# Terrain mod

`package.py` packages the level projects recovered in `work/recovered/`
as a campaign plugin, Recovered Levels (`plugins/recovered_levels`, off by
default). Each project is drawn lit, with its occlusion, by `tools/terrain`
as the level's map, `images/im16/rlNN.png`. The original's level record is
copied with only its `background_image` changed, so the units, previews,
masks and music are the originals'. It needs only Python's standard
library.

```sh
cd src
mise run terrain:recover-all          # the projects, if not already there
mise run terrain:mod                  # into plugins/recovered_levels
OUT=/tmp/mod mise run terrain:mod     # or elsewhere
```

It takes about 20 s for the twelve. Turn the plugin on in the Mods page
and it is a campaign on Level Select, or play one level straight away:
`deimos -campaign recovered_levels -level Leonidas`.
