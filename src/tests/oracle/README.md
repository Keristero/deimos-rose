# Oracle traces

The original game's random calls, recorded by `mise run oracle:trace` while
it played demo films under Wine, and kept here so the comparison can be run
on a machine without the Wine oracle. `mise run oracle:diff:saved` replays
every film in each trace and prints where the simulation first differs.

| File | Films | Recorded |
|---|---|---|
| `shipped.trace.xz` | de01..de04, the demos in Game.pak | the default prefix, `work/wine` |
| `players-pd.trace.xz` | pd01..pd11 (Perfect Demos) | a copy of the prefix, `work/wine-pd`, with the films in `Data/Local/film` |
| `players-dl.trace.xz` | dl01, de02, de03, dl04..dl10 (Demo Levels) | likewise, `work/wine-dl` |

The players' films come from `mise run assets:films`. A trace names each
film only by its seed; the diff finds the film in `assets/films` with that
seed.

The format is in `tools/oracle/trace.py`. `I <n> <player> <read>` marks a
film read: a "step" in the diff's output is a read count. The traces hold
no game data, only call sites, arguments and read counts. sha256 of each
file, decompressed:

```
106dee8aca0bc6855e03c1f9f02ce75149de7190d1db8198a3b51190127a26b6  shipped
ebc275bc7b0c6a14ce3a19ea502641942dcc8635e33d5d3ec0f6929fd471351e  players-pd
ad9a0f3ddc593491caf4975f714e2c4eb2b97f75b24b80ee1444014562d79182  players-dl
```

Each film was played once, so a trace records one run of the original. It
stops at the first read past the demo's end, where the original starts the
next film.
