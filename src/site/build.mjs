#!/usr/bin/env node
// Builds the website from site.config.json: run before every deployment
// (.github/workflows/site.yml), never edited by hand. No dependencies
// beyond Node 20, so nothing is installed to build it.
//
//   node site/build.mjs [--out build/site] [--offline]
//
// What it reads, and why from there:
// - site.config.json: everything said about the project, and one entry
//   per merged feature branch (AGENTS.md, "Branches and pull requests").
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

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, copyFileSync } from 'node:fs'
import { dirname, join, resolve, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { pages } from './pages.mjs'

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
		need(text(p.group), `plugins[${i}].group`, 'a group')
		need(!names.has(p.name), `plugins[${i}]`, `${p.name} listed twice`)
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
		if (!existsSync(dir)) continue
		const manifest = join(dir, 'plugin.json')
		let meta
		if (existsSync(manifest)) {
			const m = JSON.parse(readFileSync(manifest, 'utf8'))
			meta = {
				label: m.label ?? titleCase(entry.name.replaceAll('_', ' ')),
				description: m.description ?? '',
				deps: m.deps ?? [],
				session: true,
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
	if (problems.length) {
		throw new Error(`plugins:\n  ${problems.join('\n  ')}`)
	}
	return plugins
}

// ---------------------------------------------------------------------------
// The newest release of main, for the download buttons
// ---------------------------------------------------------------------------

const MAIN_TAG = /^v\d+\.\d+\.\d+$/

async function latestRelease(repo) {
	if (flag('--offline')) return null
	const headers = { accept: 'application/vnd.github+json', 'user-agent': 'deimos-rose-site' }
	if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`
	try {
		const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=50`, { headers, signal: AbortSignal.timeout(15000) })
		if (!res.ok) throw new Error(`HTTP ${res.status}`)
		const release = (await res.json()).find((r) => MAIN_TAG.test(r.tag_name) && !r.draft)
		if (!release) return null
		const asset = (os) => release.assets.find((a) => a.name.endsWith(`-${os}-amd64.zip`))
		return {
			tag: release.tag_name,
			url: release.html_url,
			date: release.published_at.slice(0, 10),
			linux: asset('linux'),
			windows: asset('windows'),
		}
	} catch (err) {
		console.warn(`site: no release information (${err.message}); linking the releases page`)
		return null
	}
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
	if (config.site.screenshot) {
		copyFileSync(resolve(here, config.site.screenshot), join(out, 'screenshot.png'))
	}

	const built = pages({ config, plugins, release, diagram })
	for (const [file, html] of Object.entries(built)) {
		writeFileSync(join(out, file), html)
	}
	// GitHub Pages runs Jekyll over the upload unless told not to.
	writeFileSync(join(out, '.nojekyll'), '')

	const where = relative(process.cwd(), out) || '.'
	console.log(`site: ${Object.keys(built).length} pages, ${plugins.length} plugins, ${config.changes.length} changes -> ${where}`)
	console.log(`site: downloads ${release ? `from ${release.tag}` : 'link the releases page'}`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
	main().catch((err) => {
		console.error(err.message)
		process.exit(1)
	})
}
