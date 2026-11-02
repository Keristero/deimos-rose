# The website

Generated, never edited. `build.mjs` turns `site.config.json`, the plugin
folders and the GitHub releases API into three pages, and
`.github/workflows/site.yml` deploys them to GitHub Pages once Build has
finished on main. Node 20 or later; nothing to install.

| Task | Does |
|---|---|
| `mise run site:build` | builds into `build/site` (`OFFLINE=1` skips the releases API) |
| `mise run site:serve` | builds and serves it on http://localhost:8000 |
| `mise run site:check` | fails unless this branch adds an entry to `changes` (`BASE=ref`, default `origin/main`) |

## Every feature branch adds a change

A branch merged to main adds one entry at the **top** of `changes`. The
pull request workflow runs `site:check` and fails without it.

```json
{
  "id": "runtime-plugins",
  "title": "Plugins load at run time",
  "date": "2026-10-12",
  "kind": "engineering",
  "pr": 14,
  "summary": "One or two sentences a player could follow.",
  "highlights": ["Optional bullets", "Each a single line"],
  "diagram": "diagrams/runtime-plugins.svg"
}
```

| Field | |
|---|---|
| `id` | the branch name, kebab-case, unique |
| `title`, `summary` | plain text; `` `code` `` spans are kept |
| `kind` | `feature`, `engineering`, `content` or `fix` |
| `date` | `YYYY-MM-DD`, the day it merges; entries are newest first |
| `pr` | the pull request's number, or `null` until it is opened |
| `highlights` | optional; shown on the Changes page only |
| `diagram` | optional; an SVG under `site/diagrams/`, inlined so it follows the theme |

A change's `Changelog:` block in its commits is still where the game's
patch notes come from (AGENTS.md). The site's entry is the branch's
headline; the patch notes are the detail.

## Plugins

`plugins` lists every folder in `src/plugins/`, with the `group` it is
shown under, the `shot` it is pictured in and, optionally, `about`: a
sentence more than the game's own description. The build fails when a folder is missing from the list or
the list names a folder that is gone. `"hidden": true` keeps a plugin off
the site, with no card, screenshot or download link, and then needs no
`group` or `shot` (the Meme Mod is hidden). It still ships in the
release, and no shown plugin may need it. The label, description,
dependencies and flags come from the plugin itself: its `plugin.json`, or
its `plugin_register({...})` call. The game shows the same words on its
Mods page.

## Download page

`download.html` lists the game, the level editor and every shown plugin
with a tick box. Ticking a plugin ticks what it needs, and what those
need; unticking one unticks what needs it (`picker.mjs`). Download fetches
the ticked zips and joins them into one in the browser (`zip.mjs`):
entries are copied as they are, the first of each name kept, so it costs
what copying does. Only the zips nothing else ticked already brings are
fetched, since a plugin's zip carries what it needs.

The zips come from the site itself, `dl/`: GitHub sends release files
without CORS headers, so a page cannot fetch them from the release.
`build.mjs --mirror` (`MIRROR=1 mise run site:build`) copies the newest
release's, about 470 MB, and the deploy does it every time; without it
the page lists everything and points at the releases instead.
`SITE_ZIPS=zips MIRROR=1 mise run site:build` takes them from
`mise run dist:zips`'s output. `mise run site:test` tests the join and
the ticks.

## Screenshots

Every plugin's card shows `shots/<name>.webp`, and the build fails when
one is missing. `shot` names the scene: one of the game's menu-shot
scenarios (`game/main.odin`'s `run_menu_shot`, and each plugin's
`ui.shot_register`), then any launch flags:

```json
{ "name": "water", "group": "Presentation", "shot": "water_splash" },
{ "name": "recovered_levels", "group": "Content", "shot": "playing -campaign recovered_levels -level Delos" }
```

`playing` is a level ten seconds in, firing, with nothing on but what
`-mod`, `-campaign` and `-level` say: the scene for a plugin with no
scenario of its own. `mise run site:shots` renders every one with the
game (`ONLY='water wind'` for some) and writes 960x720 WebP, about 100 KB
each, with ImageMagick. The images are committed, as `src/assets/` is:
CI has no display, and a picture only changes when its plugin's look
does. HD Textures' needs its textures generated first (`mise run
hd:textures`).

## Diagrams

Diagrams are hand-written SVG drawn with the stylesheet's `d-*` classes
(`d-box`, `d-text`, `d-sub`, `d-arrow`, `d-lane`, `d-label`; `hot`, `cool`,
`warm` and `ok` colour a box or arrow), so one drawing works in the light
and the dark theme. `diagrams/site-pipeline.svg` is the example to copy:
it defines the arrowhead marker `d-head` that `d-arrow` uses.
