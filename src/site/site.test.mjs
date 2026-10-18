// The Download page's parts that can be checked without a browser: the
// zip join (zip.mjs) on zips made here by Info-ZIP, and what a tick brings
// (picker.mjs). `mise run site:test`; synthetic, so no release is needed.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { joinZips, readZip } from './zip.mjs'
import { needs, toggle, zipsFor } from './picker.mjs'

// A folder of `files` ({path: text}), zipped from inside it as the
// release zips are: rooted at deimos/. `stream` pipes zip to stdout, which
// writes data descriptors; `zip64` forces Zip64 records.
function zipOf(work, name, files, { stream = false, zip64 = false, exec = [] } = {}) {
	const root = join(work, name)
	for (const [path, text] of Object.entries(files)) {
		mkdirSync(dirname(join(root, path)), { recursive: true })
		writeFileSync(join(root, path), text)
	}
	for (const path of exec) chmodSync(join(root, path), 0o755)
	const zip = join(work, `${name}.zip`)
	const flags = ['-qr', ...(zip64 ? ['-fz'] : [])]
	if (stream) {
		writeFileSync(zip, execFileSync('zip', [...flags, '-', 'deimos'], { cwd: root }))
	} else {
		execFileSync('zip', [...flags, zip, 'deimos'], { cwd: root })
	}
	return zip
}

test('joined zips unzip to every file once, the first copy winning, permissions kept', () => {
	const work = mkdtempSync(join(tmpdir(), 'site-zip-'))
	try {
		const game = zipOf(work, 'game', { 'deimos/deimos': 'game', 'deimos/assets/a.txt': 'a'.repeat(5000) }, { exec: ['deimos/deimos'] })
		const chaingun = zipOf(work, 'chaingun', {
			'deimos/plugins/chaingun/chaingun.so': 'chaingun',
			'deimos/plugins/new_weapons/new_weapons.so': 'new weapons',
		}, { stream: true, exec: ['deimos/plugins/chaingun/chaingun.so'] })
		const weapons = zipOf(work, 'weapons', { 'deimos/plugins/new_weapons/new_weapons.so': 'a later copy' })

		const zips = [game, chaingun, weapons].map((z) => new Uint8Array(readFileSync(z)))
		assert.ok(readZip(zips[1]).some((e) => e.central[8] & 0x8), 'the streamed zip has data descriptors')
		const joined = joinZips(zips)
		const out = join(work, 'joined.zip')
		writeFileSync(out, Buffer.concat(joined.parts))
		assert.equal(statSync(out).size, joined.size)

		execFileSync('unzip', ['-tq', out])
		const listed = execFileSync('unzip', ['-Z1', out], { encoding: 'utf8' }).trim().split('\n')
		assert.equal(new Set(listed).size, listed.length, 'no name twice')
		assert.equal(listed.length, joined.entries)

		const into = join(work, 'unzipped')
		execFileSync('unzip', ['-q', out, '-d', into])
		assert.equal(readFileSync(join(into, 'deimos/assets/a.txt'), 'utf8'), 'a'.repeat(5000))
		assert.equal(readFileSync(join(into, 'deimos/plugins/new_weapons/new_weapons.so'), 'utf8'), 'new weapons')
		assert.ok(statSync(join(into, 'deimos/deimos')).mode & 0o100, 'the game stays executable')
		assert.ok(statSync(join(into, 'deimos/plugins/chaingun/chaingun.so')).mode & 0o100, 'a plugin stays executable')
	} finally {
		rmSync(work, { recursive: true, force: true })
	}
})

test('a Zip64 archive is refused, not misread', () => {
	const work = mkdtempSync(join(tmpdir(), 'site-zip-'))
	try {
		const z = zipOf(work, 'big', { 'deimos/x': 'x' }, { zip64: true })
		assert.throws(() => readZip(new Uint8Array(readFileSync(z))), /Zip64/)
	} finally {
		rmSync(work, { recursive: true, force: true })
	}
})

const deps = {
	extra_prefs: [],
	loadout: ['extra_prefs'],
	new_weapons: ['loadout'],
	chaingun: ['new_weapons'],
	netplay: [],
}

test('a tick brings what it needs, and what that needs', () => {
	assert.deepEqual([...needs(deps, 'chaingun')].sort(), ['chaingun', 'extra_prefs', 'loadout', 'new_weapons'])
	assert.deepEqual([...toggle(deps, new Set(['netplay']), 'chaingun', true)].sort(), ['chaingun', 'extra_prefs', 'loadout', 'netplay', 'new_weapons'])
})

test('an untick takes away what needs it, and nothing it needs', () => {
	const all = new Set(Object.keys(deps))
	assert.deepEqual([...toggle(deps, all, 'loadout', false)].sort(), ['extra_prefs', 'netplay'])
	assert.deepEqual([...toggle(deps, all, 'chaingun', false)].sort(), ['extra_prefs', 'loadout', 'netplay', 'new_weapons'])
})

test('only the zips nothing else ticked brings are fetched', () => {
	assert.deepEqual(zipsFor(deps, new Set(Object.keys(deps))).sort(), ['chaingun', 'netplay'])
	assert.deepEqual(zipsFor(deps, new Set(['loadout', 'extra_prefs'])), ['loadout'])
})
