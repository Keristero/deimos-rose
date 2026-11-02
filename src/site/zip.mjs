// Joins zips into one without unpacking them, in the browser (the
// Download page) and in Node (build.mjs, zip.test.mjs) alike: no imports.
//
// Every release zip is rooted at deimos/ (decisions.md D87), and a
// plugin's zip carries the plugins it needs, so the zips a player picks
// overlap: unzipped one over another, the same file lands on itself. A
// join does the same. Each entry's local record (its header and its
// still-compressed data) is copied as it is, the first copy of a name
// wins, and a new central directory points at the copies. Nothing is
// inflated or deflated, so joining the game and a dozen plugins costs
// what copying them does, and Unix permissions (the executable bit on
// deimos and each plugin's .so) survive in the copied directory entries.
//
// The release zips need nothing more: Linux's (zip 3.0) and Windows'
// (7-Zip) both write sizes in the local header (no data descriptors), no
// Zip64, and under 65,535 entries (checked 2026-10-18 on v0.1.308: the
// Windows game zip has 1,280 entries in 119 MB). Zip64 is refused rather
// than misread; data descriptors are carried along.

const LOCAL = 0x04034b50
const CENTRAL = 0x02014b50
const END = 0x06054b50
const END64_LOCATOR = 0x07064b50
const DESCRIPTOR = 0x08074b50

const names = new TextDecoder()

// The entries of a zip, in its central directory's order. Each is its
// name, its local record and its central directory entry, both views into
// `bytes`.
export function readZip(bytes) {
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
	let end = -1
	for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 0xffff); i--) {
		if (view.getUint32(i, true) === END) {
			end = i
			break
		}
	}
	if (end < 0) throw new Error('not a zip: no end of central directory')
	if (end >= 20 && view.getUint32(end - 20, true) === END64_LOCATOR) throw new Error('a Zip64 archive, which this does not join')
	const count = view.getUint16(end + 10, true)
	const at = view.getUint32(end + 16, true)
	if (count === 0xffff || at === 0xffffffff) throw new Error('a Zip64 archive, which this does not join')

	const entries = []
	let p = at
	for (let n = 0; n < count; n++) {
		if (view.getUint32(p, true) !== CENTRAL) throw new Error(`central directory entry ${n} is damaged`)
		const flags = view.getUint16(p + 8, true)
		const packed = view.getUint32(p + 20, true)
		const nameLen = view.getUint16(p + 28, true)
		const size = 46 + nameLen + view.getUint16(p + 30, true) + view.getUint16(p + 32, true)
		const local = view.getUint32(p + 42, true)
		if (view.getUint32(local, true) !== LOCAL) throw new Error(`local header ${n} is damaged`)
		let len = 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true) + packed
		if (flags & 0x8) {
			// A data descriptor follows the data, with or without its signature.
			len += view.getUint32(local + len, true) === DESCRIPTOR ? 16 : 12
		}
		entries.push({
			name: names.decode(bytes.subarray(p + 46, p + 46 + nameLen)),
			local: bytes.subarray(local, local + len),
			central: bytes.subarray(p, p + size),
		})
		p += size
	}
	return entries
}

// One zip from several, as the parts of a file: the first entry of each
// name, in order. Pass the parts to a Blob (browser) or Buffer.concat.
export function joinZips(zips) {
	const parts = []
	const directory = []
	const seen = new Set()
	let offset = 0
	let dirSize = 0
	for (const bytes of zips) {
		for (const e of readZip(bytes)) {
			if (seen.has(e.name)) continue
			seen.add(e.name)
			const central = e.central.slice()
			new DataView(central.buffer).setUint32(42, offset, true)
			parts.push(e.local)
			directory.push(central)
			offset += e.local.length
			dirSize += central.length
		}
	}
	if (directory.length > 0xffff || offset + dirSize > 0xffffffff) throw new Error('too big to join without Zip64')
	const end = new Uint8Array(22)
	const v = new DataView(end.buffer)
	v.setUint32(0, END, true)
	v.setUint16(8, directory.length, true)
	v.setUint16(10, directory.length, true)
	v.setUint32(12, dirSize, true)
	v.setUint32(16, offset, true)
	return { parts: [...parts, ...directory, end], size: offset + dirSize + 22, entries: directory.length }
}
