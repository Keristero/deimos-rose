# Terrain mod

`recovered_levels.drcampaign.json` is the Recovered Levels campaign
(`plugins/recovered_levels`, off by default): the level projects recovered
in `work/recovered/`, in the originals' play order, as a level-editor
campaign. `mise run terrain:mod` exports it through the editor's own
export (`deimos-editor -export`), as the Campaign tab would. Each project
is drawn lit, with its occlusion, as its map. Its preview is cut from the
map where the original's was cut from the original map (`terrain:preview`,
which `terrain:recover-all` runs). Its media mask is made from its water.
Its record is the project's, which the recovery copied from the
original's: the same units, music and briefing.

```sh
cd src
mise run terrain:recover-all          # the projects, if not already there
mise run terrain:mod                  # into plugins/recovered_levels
OUT=/tmp/mod mise run terrain:mod     # or elsewhere
```

The campaign can also be opened in the editor's Campaign tab
(`-campaign=tools/terrain_mod/recovered_levels.drcampaign.json`). Its
levels are named relative to it, so it needs `work/` beside `src/`.

It takes about 40 s for the twelve. Turn the plugin on in the Mods page
and it is a campaign on Level Select, or play one level straight away:
`deimos -campaign recovered_levels -level Leonidas`.
