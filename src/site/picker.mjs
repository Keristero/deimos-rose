// What the Download page's ticks mean, apart from the page: which plugins
// a tick brings with it, which an untick takes away, and which zips to
// fetch. Pure functions of the plugins' `deps`, tested in site.test.mjs.

// `name`, what it needs, what those need, and so on.
export function needs(deps, name, into = new Set()) {
	if (into.has(name)) return into
	into.add(name)
	for (const d of deps[name] ?? []) needs(deps, d, into)
	return into
}

// The plugins that need `name`, directly or through another.
export function neededBy(deps, name) {
	const by = new Set()
	for (const other of Object.keys(deps)) {
		if (other !== name && needs(deps, other).has(name)) by.add(other)
	}
	return by
}

// Ticking a plugin ticks what it needs; unticking one unticks what needs
// it, since that plugin's zip would bring it back.
export function toggle(deps, ticked, name, on) {
	const next = new Set(ticked)
	if (on) {
		for (const n of needs(deps, name)) next.add(n)
	} else {
		next.delete(name)
		for (const n of neededBy(deps, name)) next.delete(n)
	}
	return next
}

// The plugin zips to fetch for the ticked set: each zip brings what its
// plugin needs (tools/dist/zips.sh), so a plugin another ticked plugin
// needs comes in that one's zip.
export function zipsFor(deps, ticked) {
	return [...ticked].filter((name) => ![...ticked].some((other) => other !== name && needs(deps, other).has(name)))
}
