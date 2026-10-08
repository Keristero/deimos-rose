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
shown under and, optionally, `about`: a sentence more than the game's own
description. The build fails when a folder is missing from the list or
the list names a folder that is gone. The label, description,
dependencies and flags come from the plugin itself: its `plugin.json`, or
its `plugin_register({...})` call. The game shows the same words on its
Mods page.

## Diagrams

Diagrams are hand-written SVG drawn with the stylesheet's `d-*` classes
(`d-box`, `d-text`, `d-sub`, `d-arrow`, `d-lane`, `d-label`; `hot`, `cool`,
`warm` and `ok` colour a box or arrow), so one drawing works in the light
and the dark theme. `diagrams/site-pipeline.svg` is the example to copy:
it defines the arrowhead marker `d-head` that `d-arrow` uses.
