// The site's pages, as functions of the validated config, the plugins as
// the game describes them, and the newest release. Plain template
// strings: three pages do not need a framework.

const esc = (s) =>
	String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

// `code` spans in config text, which is otherwise plain.
const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>')

const fmtDate = (iso) =>
	new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' })

const mb = (bytes) => `${Math.round(bytes / 1e6)} MB`

const NAV = [
	['index.html', 'Home'],
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
	return `<div class="downloads">
    ${button(release.windows, 'Windows', true)}
    ${button(release.linux, 'Linux', false)}
  </div>
  <p class="fine"><a href="${esc(release.url)}">${esc(release.tag)}</a>, ${fmtDate(release.date)} · <a href="${all}">all releases</a></p>`
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

function pluginPage({ config, plugins }) {
	const byName = Object.fromEntries(plugins.map((p) => [p.name, p]))
	const groups = [...new Set(plugins.map((p) => p.group))]
	const card = (p) => {
		const tags = [
			`<span class="tag">${p.kind === 'data' ? 'Content' : 'Code'}</span>`,
			p.session ? '<span class="tag" title="Changes the game; both netplay peers need it">Gameplay</span>' : '<span class="tag" title="Only changes what you see">Local</span>',
			p.defaultOn ? '<span class="tag on">On by default</span>' : '',
			p.companion ? '<span class="tag" title="Comes on with its dependencies">Companion</span>' : '',
		].join('')
		const deps = p.deps.length
			? `<p class="deps">Needs ${p.deps.map((d) => `<a href="#${esc(d)}">${esc(byName[d]?.label ?? d)}</a>`).join(', ')}</p>`
			: ''
		return `<article class="plugin" id="${esc(p.name)}">
      <h3>${esc(p.label)}</h3>
      <p>${esc(p.description)}.</p>
      ${p.about ? `<p class="muted">${inline(p.about)}</p>` : ''}
      ${p.levels ? `<p class="muted">${p.levels} levels.</p>` : ''}
      ${deps}
      <p class="tags">${tags}<code>${esc(p.name)}</code></p>
    </article>`
	}
	const body = `
<section class="page-head">
  <h1>Plugins</h1>
  <p class="lede">The core is the original game. Everything below is optional, switched on or off from the Mods page. In classic mode all of them are off.</p>
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
		'plugins.html': pluginPage(ctx),
		'changes.html': changesPage(ctx),
	}
}
