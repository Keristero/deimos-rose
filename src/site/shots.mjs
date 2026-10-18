#!/usr/bin/env node
// Renders each plugin's screenshot for the Plugins page into
// site/shots/<plugin>.webp, from the `shot` its entry in site.config.json
// names: a menu-shot scenario, then any launch flags,
//
//   "shot": "water_splash"
//   "shot": "playing -campaign recovered_levels -level Delos"
//
// The scenarios are the game's own (game/main.odin's run_menu_shot and
// ui.shot_register); `playing` is a level a few seconds in with only what
// the flags turn on, for a plugin with no scenario of its own. The images
// are committed, as the game's data is (decisions.md D29): CI has no
// display to render them, and a picture changes only when its plugin's
// look does. Rerun it for a plugin whose look changed (ONLY=name).
//
//   node site/shots.mjs [--only name,name] [--bin build/deimos]
//
// Needs the game built (`mise run build`) and ImageMagick's `magick`, as
// tools/oracle/compare.sh does.

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadConfig } from './build.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const src = resolve(here, '..')

// Half again the original's 640x480: sharp on a card at twice the pixel
// density, about 120 KB each.
export const SHOT_SIZE = { width: 960, height: 720 }
export const shotPath = (name) => join(here, 'shots', `${name}.webp`)

const args = process.argv.slice(2)
const option = (name) => {
	const i = args.indexOf(name)
	return i >= 0 ? args[i + 1] : undefined
}
const only = (option('--only') ?? process.env.ONLY ?? '').split(/[\s,]+/).filter(Boolean)
const exe = process.platform === 'win32' ? '.exe' : ''
const bin = resolve(option('--bin') ?? join(process.env.DR_BUILD ?? join(src, 'build'), `deimos${exe}`))
if (!existsSync(bin)) {
	console.error(`site:shots: no game at ${bin} (mise run build)`)
	process.exit(1)
}

const config = loadConfig()
const wanted = config.plugins.filter((p) => only.length === 0 || only.includes(p.name))
const unknown = only.filter((n) => !config.plugins.some((p) => p.name === n))
if (unknown.length) {
	console.error(`site:shots: not in site.config.json's plugins: ${unknown.join(', ')}`)
	process.exit(1)
}

const work = mkdtempSync(join(tmpdir(), 'site-shots-'))
mkdirSync(join(here, 'shots'), { recursive: true })
const failed = []
for (const p of wanted) {
	const [scenario, ...flags] = p.shot.trim().split(/\s+/)
	const png = join(work, p.name)
	const run = spawnSync(bin, flags, {
		cwd: src,
		env: {
			...process.env,
			DR_ASSETS: process.env.DR_ASSETS ?? join(src, 'assets'),
			DR_PLUGINS: process.env.DR_PLUGINS ?? join(src, 'plugins'),
			DR_MENU_SHOT: scenario,
			DR_SHOT: png,
		},
		encoding: 'utf8',
	})
	if (!existsSync(`${png}.png`)) {
		const why = (run.stderr ?? '').split('\n').filter((l) => !l.startsWith('INFO:') && l.trim()).slice(-3).join(' | ')
		failed.push(`${p.name} (${p.shot}): no image${why ? `: ${why}` : ''}`)
		continue
	}
	const { width, height } = SHOT_SIZE
	execFileSync('magick', [`${png}.png`, '-resize', `${width}x${height}`, '-quality', '80', shotPath(p.name)])
	console.log(`site:shots: ${p.name} <- ${p.shot}`)
}
rmSync(work, { recursive: true, force: true })
if (failed.length) {
	console.error(`site:shots: failed:\n  ${failed.join('\n  ')}`)
	process.exit(1)
}
