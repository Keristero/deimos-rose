#!/usr/bin/env node
// Fails a feature branch that does not add an entry to site.config.json's
// `changes`: every branch merged to main says what it changed on the site
// (AGENTS.md, "Branches and pull requests"). Run by the pull request
// workflow against the pull request's base, and by `mise run site:check`.
//
//   node site/check.mjs [base]     base: a ref; default $SITE_BASE, else origin/main
//
// It compares with the merge base, not the base's tip, so a base that has
// moved on since the branch began does not count the base's own new
// entries as the branch's.

import { execFileSync } from 'node:child_process'
import { loadConfig, loadPlugins } from './build.mjs'

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const CONFIG = 'src/site/site.config.json'

function resolveBase() {
	const wanted = [process.argv[2], process.env.SITE_BASE, 'origin/main', 'main'].filter(Boolean)
	for (const ref of wanted) {
		try {
			git('rev-parse', '--verify', '--quiet', `${ref}^{commit}`)
			return ref
		} catch {}
	}
	throw new Error(`site:check: none of ${wanted.join(', ')} is a commit here`)
}

function main() {
	// The branch's own config must build, whatever the base says.
	const config = loadConfig()
	loadPlugins(config)

	const base = resolveBase()
	const fork = git('merge-base', base, 'HEAD')
	if (fork === git('rev-parse', 'HEAD')) {
		console.log(`site:check: HEAD is ${base} itself; nothing to check`)
		return
	}
	let before = []
	try {
		before = JSON.parse(git('show', `${fork}:${CONFIG}`)).changes.map((c) => c.id)
	} catch {
		// The config is new on this branch: every entry is the branch's.
	}
	const added = config.changes.filter((c) => !before.includes(c.id))
	if (added.length === 0) {
		console.error(`site:check: this branch adds no entry to ${CONFIG}'s "changes" (compared with ${base} at ${fork.slice(0, 9)}).`)
		console.error('Every feature branch merged to main adds one, newest first; src/site/README.md shows the format.')
		process.exit(1)
	}
	for (const c of added) {
		console.log(`site:check: ${c.id} — ${c.title}`)
	}
}

try {
	main()
} catch (err) {
	console.error(err.message)
	process.exit(1)
}
