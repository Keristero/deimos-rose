// The Download page's ticks: keeps what a plugin needs ticked with it,
// shows the size, and on Download fetches the ticked zips from this site's
// copy of the release and joins them into one (zip.mjs), saved from
// memory. Nothing leaves the reader's computer.

import { joinZips } from './zip.mjs'
import { toggle, zipsFor } from './picker.mjs'

const data = JSON.parse(document.getElementById('picker-data').textContent)
const form = document.getElementById('picker')
const button = form.querySelector('button[type=submit]')
const sizeOut = document.getElementById('picker-size')
const status = document.getElementById('picker-status')
const progress = document.getElementById('picker-progress')
const boxes = [...form.querySelectorAll('.pick input')]
const box = (value) => boxes.find((b) => b.value === value)

const mb = (bytes) => (bytes < 1e6 ? `${Math.round(bytes / 1e3)} KB` : bytes < 1e7 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.round(bytes / 1e6)} MB`)
const list = (names) => {
	const labels = names.map((n) => data.labels[n] ?? n)
	return labels.length < 2 ? labels.join('') : `${labels.slice(0, -1).join(', ')} and ${labels.at(-1)}`
}

let os = /Linux|X11/.test(navigator.userAgent) && !/Android/.test(navigator.userAgent) ? 'linux' : 'windows'
form.querySelector(`input[name=os][value=${os}]`).checked = true
let ticked = new Set()
let busy = false

// What one platform offers: a plugin with no zip there is not offered.
const offer = () => data.mirror?.[os]

function render() {
	const m = offer()
	let total = 0
	for (const b of boxes) {
		const v = b.value
		const out = form.querySelector(`[data-size="${v}"]`)
		if (v === 'classic_levels') continue
		if (v === 'game' || v === 'editor') {
			const item = m?.[v]
			b.disabled = busy || !item
			if (!item) b.checked = false
			const size = v === 'editor' && !box('game').checked ? item?.size : item?.own
			out.textContent = item ? mb(size) : ''
			if (item && b.checked) total += size
			continue
		}
		const item = m?.plugins[v]
		if (!item) ticked.delete(v)
		b.disabled = busy || !item
		b.checked = ticked.has(v)
		b.closest('.pick').classList.toggle('unavailable', !item)
		out.textContent = item ? mb(item.own) : m ? 'Not in this release' : ''
		if (item && b.checked) total += item.own
	}
	const any = boxes.some((b) => b.checked && !b.disabled && b.value !== 'classic_levels')
	button.disabled = busy || !m || !any
	sizeOut.textContent = any ? `about ${mb(total)}` : ''
}

form.addEventListener('change', (e) => {
	const t = e.target
	if (t.name === 'os') {
		os = t.value
	} else if (t.value in data.deps) {
		const before = ticked
		ticked = toggle(data.deps, ticked, t.value, t.checked)
		const added = [...ticked].filter((n) => !before.has(n) && n !== t.value && n !== 'classic_levels')
		const removed = [...before].filter((n) => !ticked.has(n) && n !== t.value)
		if (added.length) status.textContent = `${data.labels[t.value]} needs ${list(added)}, so they are ticked too.`
		else if (removed.length) status.textContent = `${list(removed)} ${removed.length > 1 ? 'need' : 'needs'} ${data.labels[t.value]}, so ${removed.length > 1 ? 'they are' : 'it is'} unticked too.`
	}
	render()
})

// A zip's bytes, counting them into the progress bar as they come.
async function fetchZip(file, onBytes) {
	const res = await fetch(file)
	if (!res.ok) throw new Error(`${file}: HTTP ${res.status}`)
	const chunks = []
	let n = 0
	const reader = res.body.getReader()
	for (;;) {
		const { done, value } = await reader.read()
		if (done) break
		chunks.push(value)
		n += value.length
		onBytes(value.length)
	}
	const bytes = new Uint8Array(n)
	let at = 0
	for (const c of chunks) {
		bytes.set(c, at)
		at += c.length
	}
	return bytes
}

form.addEventListener('submit', async (e) => {
	e.preventDefault()
	const m = offer()
	const items = [
		box('game').checked && m.game,
		box('editor').checked && m.editor,
		...zipsFor(data.deps, ticked).map((n) => m.plugins[n]),
	].filter(Boolean)
	const total = items.reduce((n, i) => n + i.size, 0)
	busy = true
	render()
	progress.hidden = false
	progress.value = 0
	let got = 0
	try {
		const zips = []
		for (const [i, item] of items.entries()) {
			status.textContent = `Fetching ${i + 1} of ${items.length}…`
			zips.push(await fetchZip(item.file, (n) => (progress.value = (got += n) / total)))
		}
		status.textContent = 'Joining…'
		const joined = joinZips(zips)
		const name = `deimos-${data.tag}-${os}-amd64${box('game').checked ? '' : '-plugins'}.zip`
		const url = URL.createObjectURL(new Blob(joined.parts, { type: 'application/zip' }))
		const a = document.createElement('a')
		a.href = url
		a.download = name
		document.body.append(a)
		a.click()
		a.remove()
		setTimeout(() => URL.revokeObjectURL(url), 60000)
		const plugins = [...ticked].filter((n) => n !== 'classic_levels')
		status.textContent = `${name}, ${mb(joined.size)}: unzip it${box('game').checked ? '' : ' over your deimos folder'}${plugins.length ? ', then turn the plugins on from the Mods page in Preferences' : ''}.`
	} catch (err) {
		status.textContent = `The download failed (${err.message}). Each zip is also on the releases page.`
	} finally {
		busy = false
		progress.hidden = true
		render()
	}
})

render()
