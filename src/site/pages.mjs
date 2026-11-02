// The site's pages, as functions of the validated config, the plugins as
// the game describes them, and the newest release. Plain template
// strings: three pages do not need a framework.

const esc = (s) =>
	String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

// `code` spans in config text, which is otherwise plain.
const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>')

const fmtDate = (iso) =>
	new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' })

// A download's size: whole megabytes for the game, kilobytes for a plugin
// smaller than one.
const mb = (bytes) => (bytes < 1e6 ? `${Math.round(bytes / 1e3)} KB` : bytes < 1e7 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.round(bytes / 1e6)} MB`)

const NAV = [
	['index.html', 'Home'],
	['download.html', 'Download'],
	['plugins.html', 'Plugins'],
	['changes.html', 'Changes'],
]

function layout({ config, page, title, body }) {
	const site = config.site
	const repo = `https://github.com/${site.repo}`
	const nav = NAV.map(([href, label]) => `<a href="${href}"${href === page ? ' aria-current="page"' : ''}>${label}</a>`).join('')
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title ? `${title} · ${site.title}` : site.title)}</title>
<meta name="description" content="${esc(site.description)}">
<meta property="og:title" content="${esc(site.title)}">
<meta property="og:description" content="${esc(site.description)}">
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="style.css">
</head>
<body>
<header class="bar">
  <a class="brand" href="index.html"><img src="icon.svg" alt="" width="22" height="22">${esc(site.title)}</a>
  <nav>${nav}<a href="${repo}">GitHub</a></nav>
</header>
<main>
${body}
</main>
<footer class="foot">
  <p>Built from <a href="${repo}/blob/main/src/site/site.config.json">site.config.json</a> on every push to main.
  Deimos Rising © 2001–2002 Swoop Software and Ambrosia Software. Deimos Rose is an unofficial fan reimplementation.</p>
</footer>
</body>
</html>
`
}

function downloads(config, release) {
	const all = `https://github.com/${config.site.repo}/releases`
	if (!release || (!release.linux && !release.windows)) {
		return `<div class="downloads"><a class="button primary" href="${all}">Download from GitHub Releases</a></div>`
	}
	const button = (asset, os, primary) =>
		asset
			? `<a class="button${primary ? ' primary' : ''}" href="${esc(asset.browser_download_url)}">${os}<small>${mb(asset.size)}</small></a>`
			: ''
	const editor = smallLinks(release.editor)
	return `<div class="downloads">
    ${button(release.windows, 'Windows', true)}
    ${button(release.linux, 'Linux', false)}
  </div>
  <p class="fine">The original game, alone. Each <a href="plugins.html">plugin</a> is a download of its own${editor ? `, as is the level editor (${editor})` : ''}: unzip it over the same folder, or <a href="download.html">pick them and get one zip</a>.</p>
  <p class="fine"><a href="${esc(release.url)}">${esc(release.tag)}</a>, ${fmtDate(release.date)} · <a href="${all}">all releases</a></p>`
}

// "Windows 1.4 MB · Linux 1.4 MB", for a download smaller than the game's.
function smallLinks(pair) {
	if (!pair) return ''
	return [
		[pair.windows, 'Windows'],
		[pair.linux, 'Linux'],
	]
		.filter(([a]) => a)
		.map(([a, os]) => `<a href="${esc(a.browser_download_url)}">${os}</a> <small>${mb(a.size)}</small>`)
		.join(' · ')
}

const KIND_LABEL = { feature: 'Feature', engineering: 'Engineering', content: 'Content', fix: 'Fix' }

function changeCard(config, c, { diagram, full }) {
	const pr = Number.isInteger(c.pr)
		? ` · <a href="https://github.com/${config.site.repo}/pull/${c.pr}">#${c.pr}</a>`
		: ''
	const highlights = full && c.highlights?.length ? `<ul>${c.highlights.map((h) => `<li>${inline(h)}</li>`).join('')}</ul>` : ''
	const figure = full && c.diagram ? `<figure class="diagram">${diagram(c.diagram)}</figure>` : ''
	return `<article class="change" id="${esc(c.id)}">
    <p class="meta"><span class="kind kind-${c.kind}">${KIND_LABEL[c.kind]}</span><time datetime="${c.date}">${fmtDate(c.date)}</time>${pr}</p>
    <h3><a href="changes.html#${esc(c.id)}">${inline(c.title)}</a></h3>
    <p>${inline(c.summary)}</p>
    ${highlights}
    ${figure}
  </article>`
}

function home({ config, plugins, release, diagram }) {
	const site = config.site
	const groups = [...new Set(plugins.map((p) => p.group))]
	const body = `
<section class="hero">
  <div class="hero-text">
    <p class="eyebrow">${esc(site.tagline)}</p>
    <h1>${esc(site.title)}</h1>
    <p class="lede">${esc(site.description)}</p>
    ${downloads(config, release)}
  </div>
  ${site.screenshot ? `<img class="shot" src="screenshot.png" alt="The Deimos Rose main menu" width="1280" height="960">` : ''}
</section>

<section class="pitch">
  ${config.pitch.map((p) => `<div><h2>${esc(p.title)}</h2><p>${inline(p.body)}</p></div>`).join('\n  ')}
</section>

<section>
  <div class="section-head"><h2>Recent changes</h2><a href="changes.html">All changes →</a></div>
  <div class="changes">
  ${config.changes.slice(0, 3).map((c) => changeCard(config, c, { diagram, full: false })).join('\n  ')}
  </div>
</section>

<section>
  <div class="section-head"><h2>Plugins</h2><a href="plugins.html">The catalogue →</a></div>
  <p class="muted">${plugins.length} plugins in ${groups.length} groups: ${groups.map(esc).join(', ').toLowerCase()}. Classic mode turns every one of them off.</p>
</section>`
	return layout({ config, page: 'index.html', title: '', body })
}

function pluginPage({ config, plugins, release }) {
	const byName = Object.fromEntries(plugins.map((p) => [p.name, p]))
	const groups = [...new Set(plugins.map((p) => p.group))]
	const card = (p) => {
		const tags = [
			`<span class="tag">${p.kind === 'data' ? 'Content' : 'Code'}</span>`,
			p.session ? '<span class="tag" title="Changes the game; both netplay peers need it">Gameplay</span>' : '<span class="tag" title="Only changes what you see">Local</span>',
			p.defaultOn ? '<span class="tag on">On by default</span>' : '',
			p.companion ? '<span class="tag" title="Comes on with its dependencies">Companion</span>' : '',
		].join('')
		// Where a player gets it: Classic Levels is the game itself; a
		// plugin's zip brings everything it needs.
		const get = (p) => {
			if (p.name === 'classic_levels') return '<p class="get">Comes with the game.</p>'
			const links = smallLinks(release?.plugins?.[p.name])
			if (!links) return ''
			return `<p class="get">Download ${links}${p.deps.length ? ', with what it needs' : ''}</p>`
		}
		const deps = p.deps.length
			? `<p class="deps">Needs ${p.deps.map((d) => `<a href="#${esc(d)}">${esc(byName[d]?.label ?? d)}</a>`).join(', ')}</p>`
			: ''
		return `<article class="plugin" id="${esc(p.name)}">
      <img class="plugin-shot" src="shots/${esc(p.name)}.webp" alt="${esc(p.label)} in the game" width="960" height="720" loading="lazy">
      <h3>${esc(p.label)}</h3>
      <p>${esc(p.description)}.</p>
      ${p.about ? `<p class="muted">${inline(p.about)}</p>` : ''}
      ${p.levels ? `<p class="muted">${p.levels} levels.</p>` : ''}
      ${deps}
      ${get(p)}
      <p class="tags">${tags}<code>${esc(p.name)}</code></p>
    </article>`
	}
	const body = `
<section class="page-head">
  <h1>Plugins</h1>
  <p class="lede">The core is the original game. Everything below is optional: download a plugin, unzip it over the game's folder, and switch it on or off from the Mods page. In classic mode all of them are off.</p>
</section>
${groups
	.map(
		(g) => `<section>
  <h2>${esc(g)}</h2>
  <div class="grid">
    ${plugins.filter((p) => p.group === g).map(card).join('\n    ')}
  </div>
</section>`,
	)
	.join('\n')}`
	return layout({ config, page: 'plugins.html', title: 'Plugins', body })
}

// The game, the editor and the plugins as a list of ticks, joined into one
// zip in the browser (download.js) from the site's copy of the release
// (build.mjs --mirror). Ticking a plugin ticks what it needs (picker.mjs).
// The list is written here, so it reads without scripts; the sizes and
// the button need them.
function downloadPage({ config, plugins, release, mirror }) {
	const byName = Object.fromEntries(plugins.map((p) => [p.name, p]))
	const groups = [...new Set(plugins.map((p) => p.group))]
	const row = ({ value, label, about, needs = '', checked = false, disabled = false, note = '' }) =>
		`<label class="pick">
        <input type="checkbox" value="${esc(value)}"${checked ? ' checked' : ''}${disabled ? ' disabled' : ''}>
        <span class="pick-text"><strong>${esc(label)}</strong> <span class="muted">${esc(about)}</span>${needs}${note ? ` <span class="pick-note">${esc(note)}</span>` : ''}</span>
        <span class="pick-size" data-size="${esc(value)}"></span>
      </label>`
	const plugin = (p) => {
		const needs = p.deps.length ? `<span class="pick-needs">Needs ${p.deps.map((d) => esc(byName[d]?.label ?? d)).join(', ')}</span>` : ''
		if (p.name === 'classic_levels') return row({ value: p.name, label: p.label, about: p.description, checked: true, disabled: true, note: 'Comes with the game' })
		return row({ value: p.name, label: p.label, about: p.description, needs })
	}
	const data = {
		tag: mirror?.tag ?? null,
		deps: Object.fromEntries(plugins.map((p) => [p.name, p.deps.filter((d) => byName[d])])),
		labels: Object.fromEntries(plugins.map((p) => [p.name, p.label])),
		mirror,
	}
	const releases = `https://github.com/${config.site.repo}/releases`
	const body = `
<section class="page-head">
  <h1>Download</h1>
  <p class="lede">Tick what you want. A plugin brings the plugins it needs. Your browser joins them into one zip: unzip it, run <code>deimos</code> (<code>deimos.exe</code> on Windows) from inside the <code>deimos</code> folder, and turn plugins on from the Mods page in Preferences.</p>
</section>
<form class="picker" id="picker">
  <fieldset class="os">
    <legend>For</legend>
    <label><input type="radio" name="os" value="windows" checked> Windows</label>
    <label><input type="radio" name="os" value="linux"> Linux</label>
  </fieldset>
  <section>
    <h2>The game</h2>
    <div class="picks">
      ${row({ value: 'game', label: 'Deimos Rose', about: 'The original game. Untick it to add plugins to a copy you already have.', checked: true })}
      ${row({ value: 'editor', label: 'Level editor', about: 'deimos-editor: sculpt, paint and light levels, and export them as a plugin' })}
    </div>
  </section>
${groups
	.map(
		(g) => `  <section>
    <h2>${esc(g)}</h2>
    <div class="picks">
      ${plugins.filter((p) => p.group === g).map(plugin).join('\n      ')}
    </div>
  </section>`,
	)
	.join('\n')}
  <div class="picker-bar">
    <button class="button primary" type="submit" disabled>Download<small id="picker-size"></small></button>
    <p class="fine" id="picker-status" role="status" aria-live="polite">${
			mirror
				? `From <a href="${esc(release.url)}">${esc(mirror.tag)}</a>. Nothing is installed or uploaded: the zip is made on your computer.`
				: `This copy of the site has no release to join; get the zips from <a href="${releases}">the releases</a>.`
		}</p>
    <progress id="picker-progress" max="1" value="0" hidden></progress>
  </div>
</form>
<script type="application/json" id="picker-data">${JSON.stringify(data).replace(/</g, '\\u003c')}</script>
<script type="module" src="download.js"></script>`
	return layout({ config, page: 'download.html', title: 'Download', body })
}

function changesPage({ config, diagram }) {
	const body = `
<section class="page-head">
  <h1>Changes</h1>
  <p class="lede">One entry per feature branch merged to main, newest first. The game's own patch notes are on each <a href="https://github.com/${config.site.repo}/releases">release</a>.</p>
</section>
<section class="timeline">
  ${config.changes.map((c) => changeCard(config, c, { diagram, full: true })).join('\n  ')}
</section>`
	return layout({ config, page: 'changes.html', title: 'Changes', body })
}

export function pages(ctx) {
	return {
		'index.html': home(ctx),
		'download.html': downloadPage(ctx),
		'plugins.html': pluginPage(ctx),
		'changes.html': changesPage(ctx),
	}
}
