#!/usr/bin/env node
// Builds the website from site.config.json: run before every deployment
// (.github/workflows/site.yml), never edited by hand. No dependencies
// beyond Node 20, so nothing is installed to build it.
//
//   node site/build.mjs [--out build/site] [--offline] [--mirror]
//
// What it reads, and why from there:
// - site.config.json: everything said about the project, and one entry
//   per merged feature branch (AGENTS.md, "Branches and pull requests").
// - site/shots/: a screenshot of each plugin, rendered by the game itself
//   from the scenario its entry names (site/shots.mjs, `mise run
//   site:shots`), and committed. A plugin without one fails the build.
// - src/plugins/: each plugin's label, description and dependencies, from
//   its plugin.json or its plugin_register call. The game shows the same
//   words on its Mods page, so the site cannot drift from it. A plugin
//   folder the config does not list, or a listed one that is gone, fails
//   the build.
// - The GitHub releases API, for the download buttons: the newest release
//   of main. Every release is published as a prerelease, which the API's
//   /releases/latest skips (it answers 404, seen 2026-10-08), so the list
//   is filtered here by tag: main's are v<major>.<minor>.<count> with no
//   branch suffix (tools/version/version.sh). --offline, or no network,
//   links the releases page instead.
// - --mirror: that release's zips, copied into the site's dl/ for the
//   Download page, which joins the ones a player ticks into one zip in the
//   browser. GitHub serves release files without CORS headers (checked
//   2026-10-18: github.com and release-assets.githubusercontent.com send
//   no Access-Control-Allow-Origin), so a page can fetch only its own
//   site's copy. SITE_ZIPS=<dir> copies them from a folder instead
//   (mise run dist:zips's zips/), to try the page before a release.

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, copyFileSync } from 'node:fs'
import { dirname, join, resolve, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { pages } from './pages.mjs'
import { readZip } from './zip.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const src = resolve(here, '..')

const args = process.argv.slice(2)
const flag = (name) => args.includes(name)
const option = (name, fallback) => {
	const i = args.indexOf(name)
	return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}
const out = resolve(option('--out', join(src, 'build', 'site')))

// ---------------------------------------------------------------------------
// The config, validated: a mistake fails the build here, with the field's
// path, rather than publishing a broken page.
// ---------------------------------------------------------------------------

export const KINDS = ['feature', 'engineering', 'content', 'fix']

export function loadConfig(path = join(here, 'site.config.json')) {
	const config = JSON.parse(readFileSync(path, 'utf8'))
	const problems = []
	const need = (ok, where, what) => ok || problems.push(`${where}: ${what}`)
	const text = (v) => typeof v === 'string' && v.trim() !== ''

	for (const key of ['title', 'tagline', 'description', 'repo']) {
		need(text(config.site?.[key]), `site.${key}`, 'a non-empty string')
	}
	need(Array.isArray(config.pitch), 'pitch', 'a list')
	for (const [i, p] of (config.pitch ?? []).entries()) {
		need(text(p.title) && text(p.body), `pitch[${i}]`, 'a title and a body')
	}

	need(Array.isArray(config.plugins), 'plugins', 'a list')
	const names = new Set()
	for (const [i, p] of (config.plugins ?? []).entries()) {
		need(text(p.name), `plugins[${i}].name`, 'a plugin folder name')
		need(!names.has(p.name), `plugins[${i}]`, `${p.name} listed twice`)
		need(p.hidden === undefined || p.hidden === true, `plugins[${i}].hidden`, 'true, or left out')
		// A hidden plugin is listed only so the list stays in step with
		// src/plugins/: it has no card, so no group and no picture.
		if (!p.hidden) {
			need(text(p.group), `plugins[${i}].group`, 'a group')
			need(text(p.shot), `plugins[${i}].shot`, 'the scenario its screenshot is taken in (site/shots.mjs)')
		}
		names.add(p.name)
	}

	need(Array.isArray(config.changes) && config.changes.length > 0, 'changes', 'a non-empty list')
	const ids = new Set()
	let previous = '9999-99-99'
	for (const [i, c] of (config.changes ?? []).entries()) {
		const at = `changes[${i}] (${c.id ?? '?'})`
		need(/^[a-z0-9][a-z0-9-]*$/.test(c.id ?? ''), at, 'an id in kebab-case: the branch name')
		need(!ids.has(c.id), at, 'an id used twice')
		ids.add(c.id)
		need(text(c.title), at, 'a title')
		need(text(c.summary), at, 'a summary')
		need(KINDS.includes(c.kind), at, `kind one of ${KINDS.join(', ')}`)
		need(/^\d{4}-\d{2}-\d{2}$/.test(c.date ?? ''), at, 'a date as YYYY-MM-DD')
		need(c.date <= previous, at, 'newest first: dated after the entry above it')
		previous = c.date ?? previous
		need(c.pr === undefined || c.pr === null || Number.isInteger(c.pr), at, 'pr a number or null')
		need(c.highlights === undefined || (Array.isArray(c.highlights) && c.highlights.every(text)), at, 'highlights a list of strings')
		if (c.diagram !== undefined) {
			need(existsSync(join(here, c.diagram)), at, `diagram ${c.diagram} not found under site/`)
		}
	}
	if (problems.length) {
		throw new Error(`site.config.json:\n  ${problems.join('\n  ')}`)
	}
	return config
}

// ---------------------------------------------------------------------------
// Plugins, as the game itself describes them
// ---------------------------------------------------------------------------

// The game's labels are capitals for its bitmap font; the site's are
// title case. Words with a digit keep their capitals (30FPS).
const titleCase = (s) =>
	s.split(/\s+/).map((w) => (/\d/.test(w) ? w : w[0] + w.slice(1).toLowerCase())).join(' ')

// The fields of a plugin_register({...}) call. The registration
// is plain Odin field assignments of literals and the DEPS constant, as
// every plugin writes it, so a pattern reads it without parsing Odin.
function readCodePlugin(dir, name) {
	const files = readdirSync(dir).filter((f) => f.endsWith('.odin')).map((f) => readFileSync(join(dir, f), 'utf8'))
	const source = files.join('\n')
	const block = source.match(/plugin_register\(\s*(?:sim\.Plugin)?\s*\{([\s\S]*?)\n\s*\}\s*\)/)
	if (!block) return null
	const field = (key) => block[1].match(new RegExp(`\\b${key}\\s*=\\s*("(?:[^"\\\\]|\\\\.)*"|true|false)`))?.[1]
	const str = (key) => {
		const v = field(key)
		return v ? JSON.parse(v) : undefined
	}
	if (str('name') !== name) return null
	const depsList = source.match(/\bDEPS\s*:[:=]\s*\[\]string\s*\{([^}]*)\}/)?.[1] ?? ''
	return {
		label: titleCase(str('label') ?? name),
		description: str('description') ?? '',
		deps: [...depsList.matchAll(/"([^"]+)"/g)].map((m) => m[1]),
		session: field('session') === 'true',
		defaultOn: field('default_on') === 'true',
		companion: field('companion') === 'true',
	}
}

export function loadPlugins(config) {
	const root = join(src, 'plugins')
	const onDisk = readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
	const listed = new Set(config.plugins.map((p) => p.name))
	const problems = [
		...onDisk.filter((n) => !listed.has(n)).map((n) => `plugins/${n} is not in site.config.json's plugins`),
		...[...listed].filter((n) => !onDisk.includes(n)).map((n) => `site.config.json lists ${n}, but plugins/${n} does not exist`),
	]
	const plugins = []
	for (const entry of config.plugins) {
		const dir = join(root, entry.name)
		if (!existsSync(dir) || entry.hidden) continue
		if (!existsSync(join(here, 'shots', `${entry.name}.webp`))) {
			problems.push(`plugins/${entry.name} has no screenshot, site/shots/${entry.name}.webp: mise run site:shots ONLY=${entry.name}`)
		}
		const manifest = join(dir, 'plugin.json')
		let meta
		if (existsSync(manifest)) {
			const m = JSON.parse(readFileSync(manifest, 'utf8'))
			meta = {
				label: m.label ?? titleCase(entry.name.replaceAll('_', ' ')),
				description: m.description ?? '',
				deps: m.deps ?? [],
				// As data/plugins.odin reads it (absent is false), except that a
				// campaign's levels change the game whatever it says.
				session: m.session === true || (m.levels?.length ?? 0) > 0,
				defaultOn: m.default_on ?? false,
				companion: false,
				levels: m.levels?.length ?? 0,
			}
		} else {
			meta = readCodePlugin(dir, entry.name)
			if (!meta) {
				problems.push(`plugins/${entry.name}: no plugin.json and no plugin_register({ name = "${entry.name}", ... }) found`)
				continue
			}
		}
		plugins.push({ ...meta, ...entry, kind: existsSync(manifest) ? 'data' : 'code' })
	}
	// A card names the plugins its plugin needs, so none of them may be hidden.
	const hidden = new Set(config.plugins.filter((p) => p.hidden).map((p) => p.name))
	for (const p of plugins) {
		for (const d of p.deps.filter((d) => hidden.has(d))) {
			problems.push(`plugins/${p.name} needs ${d}, which is hidden`)
		}
	}
	if (problems.length) {
		throw new Error(`plugins:\n  ${problems.join('\n  ')}`)
	}
	return plugins
}

// ---------------------------------------------------------------------------
// The newest release of main, for the download buttons
// ---------------------------------------------------------------------------

const MAIN_TAG = /^v\d+\.\d+\.\d+$/

// A release carries the game, the level editor and each plugin as zips of
// their own (decisions.md D87): deimos-<tag>-<os>-amd64.zip, then
// -editor.zip and -plugin-<name>.zip. SITE_RELEASES=<file> reads the
// releases API's answer from a file instead, to see the download links
// before a release has them.
async function latestRelease(repo) {
	if (flag('--offline')) return null
	const headers = { accept: 'application/vnd.github+json', 'user-agent': 'deimos-rose-site' }
	if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`
	try {
		let releases
		if (process.env.SITE_RELEASES) {
			releases = JSON.parse(readFileSync(process.env.SITE_RELEASES, 'utf8'))
		} else {
			const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=50`, { headers, signal: AbortSignal.timeout(15000) })
			if (!res.ok) throw new Error(`HTTP ${res.status}`)
			releases = await res.json()
		}
		const release = releases.find((r) => MAIN_TAG.test(r.tag_name) && !r.draft)
		if (!release) return null
		const asset = (os, suffix = '') => release.assets.find((a) => a.name.endsWith(`-${os}-amd64${suffix}.zip`))
		const both = (suffix) => ({ linux: asset('linux', suffix), windows: asset('windows', suffix) })
		const plugins = {}
		for (const a of release.assets) {
			const name = a.name.match(/-amd64-plugin-([a-z0-9_]+)\.zip$/)?.[1]
			if (name) plugins[name] ??= both(`-plugin-${name}`)
		}
		return {
			tag: release.tag_name,
			url: release.html_url,
			date: release.published_at.slice(0, 10),
			...both(''),
			editor: both('-editor'),
			plugins,
		}
	} catch (err) {
		console.warn(`site: no release information (${err.message}); linking the releases page`)
		return null
	}
}

// ---------------------------------------------------------------------------
// The release's zips, copied onto the site for the Download page
// ---------------------------------------------------------------------------

const OSES = ['windows', 'linux']

// Copies the game's, the editor's and each shown plugin's zip into
// out/dl/, and says what each adds over the game, for the page's size: a
// plugin's own folder (its zip also carries the plugins it needs), and
// what the editor's zip holds that the game's does not. Bytes are the
// entries' records, as zip.mjs copies them. A hidden plugin is not copied.
async function mirrorRelease(release, plugins) {
	mkdirSync(join(out, 'dl'), { recursive: true })
	const fetchZip = async (asset) => {
		let bytes
		if (process.env.SITE_ZIPS) {
			bytes = readFileSync(join(process.env.SITE_ZIPS, asset.name))
		} else {
			const res = await fetch(asset.browser_download_url, { signal: AbortSignal.timeout(600000) })
			if (!res.ok) throw new Error(`${asset.name}: HTTP ${res.status}`)
			bytes = Buffer.from(await res.arrayBuffer())
		}
		writeFileSync(join(out, 'dl', asset.name), bytes)
		return readZip(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength))
	}
	const weigh = (entries, keep) => entries.filter((e) => keep(e.name)).reduce((n, e) => n + e.local.length + e.central.length, 0)
	const mirror = { tag: release.tag }
	for (const os of OSES) {
		if (!release[os]) continue
		const game = await fetchZip(release[os])
		const inGame = new Set(game.map((e) => e.name))
		const item = (asset, own) => ({ file: `dl/${asset.name}`, size: asset.size, own })
		const m = { game: item(release[os], release[os].size), plugins: {} }
		if (release.editor[os]) {
			const editor = await fetchZip(release.editor[os])
			m.editor = item(release.editor[os], weigh(editor, (n) => !inGame.has(n)))
		}
		for (const p of plugins) {
			const asset = release.plugins[p.name]?.[os]
			if (!asset) continue
			const entries = await fetchZip(asset)
			m.plugins[p.name] = item(asset, weigh(entries, (n) => n.startsWith(`deimos/plugins/${p.name}/`)))
		}
		mirror[os] = m
	}
	return mirror
}

// ---------------------------------------------------------------------------

async function main() {
	const config = loadConfig()
	const plugins = loadPlugins(config)
	const release = await latestRelease(config.site.repo)
	const diagram = (path) => readFileSync(join(here, path), 'utf8').replace(/<\?xml[^>]*>\s*/, '')

	rmSync(out, { recursive: true, force: true })
	mkdirSync(out, { recursive: true })
	copyFileSync(join(here, 'style.css'), join(out, 'style.css'))
	copyFileSync(join(here, 'icon.svg'), join(out, 'icon.svg'))
	mkdirSync(join(out, 'shots'))
	for (const p of plugins) {
		copyFileSync(join(here, 'shots', `${p.name}.webp`), join(out, 'shots', `${p.name}.webp`))
	}
	if (config.site.screenshot) {
		copyFileSync(resolve(here, config.site.screenshot), join(out, 'screenshot.png'))
	}

	copyFileSync(join(here, 'zip.mjs'), join(out, 'zip.mjs'))
	copyFileSync(join(here, 'picker.mjs'), join(out, 'picker.mjs'))
	copyFileSync(join(here, 'download.js'), join(out, 'download.js'))
	const mirror = release && flag('--mirror') ? await mirrorRelease(release, plugins) : null

	const built = pages({ config, plugins, release, mirror, diagram })
	for (const [file, html] of Object.entries(built)) {
		writeFileSync(join(out, file), html)
	}
	// GitHub Pages runs Jekyll over the upload unless told not to.
	writeFileSync(join(out, '.nojekyll'), '')

	const where = relative(process.cwd(), out) || '.'
	console.log(`site: ${Object.keys(built).length} pages, ${plugins.length} plugins, ${config.changes.length} changes -> ${where}`)
	console.log(`site: downloads ${release ? `from ${release.tag}` : 'link the releases page'}`)
	if (mirror) {
		const files = readdirSync(join(out, 'dl'))
		const bytes = files.reduce((n, f) => n + statSync(join(out, 'dl', f)).size, 0)
		console.log(`site: ${files.length} zips copied for the Download page, ${Math.round(bytes / 1e6)} MB`)
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
	main().catch((err) => {
		console.error(err.message)
		process.exit(1)
	})
}
