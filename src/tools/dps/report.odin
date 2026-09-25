package dps

// The report: a static HTML page with no scripts, and a plain-text summary
// on stdout. The same two parts for each set, primary fire and charge shots:
//
// - Weapons, best first by their DPS averaged over the four scenarios. Each
//   one opens to its passives, ranked by the DPS they add to it.
// - Passives: every level's DPS added, averaged over every weapon and
//   scenario, best first.
//
// Gains are ranked in DPS rather than percent: a weapon that cannot reach a
// target behind has nothing to take a percentage of, and a passive that
// turns it round is worth the most there.

import "core:fmt"
import "core:slice"
import "core:strings"

// A change this small is the same run give or take rounding: no effect.
// A 0.01-point hit over 60 s is 0.0002 DPS.
NOISE_DPS :: 0.005

cell :: #force_inline proc(t: Table, w: int, m: Mode, sc: Scenario, c: int) -> Best {
	return t[w][m][sc][c]
}

// Whether a weapon has anything in this set: the Plasma Bomb has no charge.
has_mode :: proc(t: Table, w: int, m: Mode) -> bool {
	return cell(t, w, m, .Single, 0).tried
}

delta :: proc(t: Table, w: int, m: Mode, sc: Scenario, c: int) -> f64 {
	return cell(t, w, m, sc, c).dps - cell(t, w, m, sc, 0).dps
}

// The loadout's DPS added, averaged over the scenarios.
mean_delta :: proc(t: Table, w: int, m: Mode, c: int) -> (d: f64) {
	for sc in Scenario {
		d += delta(t, w, m, sc, c)
	}
	return d / len(Scenario)
}

mean_dps :: proc(t: Table, w: int, m: Mode, c: int) -> (d: f64) {
	for sc in Scenario {
		d += cell(t, w, m, sc, c).dps
	}
	return d / len(Scenario)
}

// "+12.5%", "0", or "from 0" where the baseline deals nothing.
change_text :: proc(t: Table, w: int, m: Mode, sc: Scenario, c: int) -> string {
	d := delta(t, w, m, sc, c)
	if abs(d) <= NOISE_DPS {
		return "0"
	}
	base := cell(t, w, m, sc, 0).dps
	if base <= NOISE_DPS {
		return "from 0"
	}
	return fmt.tprintf("%+.1f%%", d / base * 100)
}

change_class :: proc(d: f64) -> string {
	switch {
	case d > NOISE_DPS:
		return "up"
	case d < -NOISE_DPS:
		return "down"
	}
	return "flat"
}

signed_dps :: proc(d: f64) -> string {
	if abs(d) <= NOISE_DPS {
		return "0"
	}
	return fmt.tprintf("%+.2f", d)
}

// The weapons with this set, best first.
weapon_order :: proc(sh: ^Shared, t: Table, m: Mode) -> []int {
	order := make([dynamic]int, context.temp_allocator)
	for w in 0 ..< len(sh.weapons) {
		if has_mode(t, w, m) {
			append(&order, w)
		}
	}
	Ctx :: struct {
		t: Table,
		m: Mode,
	}
	ctx := Ctx{t, m}
	context.user_ptr = &ctx
	slice.stable_sort_by(order[:], proc(a, b: int) -> bool {
		c := (^Ctx)(context.user_ptr)
		return mean_dps(c.t, a, c.m, 0) > mean_dps(c.t, b, c.m, 0)
	})
	return order[:]
}

// A weapon's passive levels, most DPS added first; the baseline left out.
config_order :: proc(sh: ^Shared, t: Table, w: int, m: Mode) -> []int {
	order := make([]int, len(sh.configs) - 1, context.temp_allocator)
	for &o, i in order {
		o = i + 1
	}
	Ctx :: struct {
		t: Table,
		w: int,
		m: Mode,
	}
	ctx := Ctx{t, w, m}
	context.user_ptr = &ctx
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		c := (^Ctx)(context.user_ptr)
		return mean_delta(c.t, c.w, c.m, a) > mean_delta(c.t, c.w, c.m, b)
	})
	return order
}

no_effect :: proc(t: Table, w: int, m: Mode, c: int) -> bool {
	for sc in Scenario {
		if abs(delta(t, w, m, sc, c)) > NOISE_DPS {
			return false
		}
	}
	return true
}

Overall :: struct {
	config:   int,
	mean:     f64, // DPS added, averaged over every weapon and scenario in the set
	own:      f64, // averaged over the weapons it changes
	affected: int,
	top:      int, // the weapon it adds most to, or -1
	top_gain: f64,
}

overall_order :: proc(sh: ^Shared, t: Table, m: Mode) -> []Overall {
	weapons := weapon_order(sh, t, m)
	out := make([]Overall, len(sh.configs) - 1, context.temp_allocator)
	for &o, i in out {
		o.config = i + 1
		o.top = -1
		for w in weapons {
			g := mean_delta(t, w, m, o.config)
			o.mean += g
			if !no_effect(t, w, m, o.config) {
				o.own += g
				o.affected += 1
			}
			if g > NOISE_DPS && (o.top < 0 || g > o.top_gain) {
				o.top, o.top_gain = w, g
			}
		}
		o.mean /= f64(max(len(weapons), 1))
		if o.affected > 0 {
			o.own /= f64(o.affected)
		}
	}
	slice.stable_sort_by(out, proc(a, b: Overall) -> bool {
		return a.mean > b.mean
	})
	return out
}

report_text :: proc(sh: ^Shared, t: Table) {
	for m in Mode {
		fmt.printfln("== %s (DPS over the whole run; best policy)", MODE_NAMES[m])
		fmt.printfln("%-14s %22s %22s %22s %22s", "weapon", "single", "cluster", "behind", "wave")
		for w in weapon_order(sh, t, m) {
			fmt.printf("%-14s", sh.weapons[w].name)
			for sc in Scenario {
				b := cell(t, w, m, sc, 0)
				fmt.printf(" %7s %-14s", fmt.tprintf("%.2f", b.dps), policy_name(b.policy))
			}
			fmt.println()
			for ci in config_order(sh, t, w, m) {
				if no_effect(t, w, m, ci) {
					continue
				}
				fmt.printf("    %-26s", config_name(sh.configs[ci]))
				for sc in Scenario {
					fmt.printf(" %7s", change_text(t, w, m, sc, ci))
				}
				fmt.printfln("   (%s DPS)", signed_dps(mean_delta(t, w, m, ci)))
			}
		}
		fmt.printfln("-- passives, DPS added averaged over every weapon and scenario:")
		for o in overall_order(sh, t, m) {
			top := o.top >= 0 ? fmt.tprintf("most on %s, %s", sh.weapons[o.top].name, signed_dps(o.top_gain)) : "adds to none"
			fmt.printfln("    %-26s %6s  (%d weapons changed, %s on those; %s)", config_name(sh.configs[o.config]),
				signed_dps(o.mean), o.affected, signed_dps(o.own), top)
		}
	}
}


CSS :: `
:root {
  --bg: #f3f5f9; --panel: #ffffff; --text: #151b27; --dim: #5a6479; --line: #d7dce7;
  --up: #1d7a3e; --down: #b8322b; --accent: #2f56c9; --bar: #aebfee;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --bg: #0d1119; --panel: #151b27; --text: #e2e7f1; --dim: #939db1; --line: #283043;
    --up: #5ccf7c; --down: #f07a70; --accent: #8ea8f5; --bar: #34467e;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --bg: #0d1119; --panel: #151b27; --text: #e2e7f1; --dim: #939db1; --line: #283043;
  --up: #5ccf7c; --down: #f07a70; --accent: #8ea8f5; --bar: #34467e;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.55 "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 28px 16px 56px; }
h1, h2 { font-family: "Chakra Petch", "IBM Plex Sans", system-ui, sans-serif; text-wrap: balance; }
h1 { font-size: 1.9rem; margin: 0 0 4px; letter-spacing: 0.02em; }
h2 { font-size: 1.2rem; margin: 36px 0 6px; letter-spacing: 0.03em; }
.sub { color: var(--dim); margin: 0 0 16px; max-width: 70ch; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { color: var(--dim); font-weight: 600; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.06em; }
td.n, th.n { text-align: right; font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: 0.9rem; }
.up { color: var(--up); } .down { color: var(--down); } .flat { color: var(--dim); }
details { border-bottom: 1px solid var(--line); }
details:last-child { border-bottom: 0; }
summary { cursor: pointer; padding: 10px 12px; display: grid; gap: 4px 12px; list-style: none;
  grid-template-columns: 2em minmax(7em, 1fr) repeat(4, minmax(7em, 1fr)); align-items: center; }
summary:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
summary::-webkit-details-marker { display: none; }
summary .rank { color: var(--dim); font-family: "IBM Plex Mono", ui-monospace, monospace; }
summary .name { font-weight: 600; }
summary .name::before { content: "\25B8  "; color: var(--accent); }
details[open] summary .name::before { content: "\25BE  "; }
.metric { display: flex; flex-direction: column; }
.metric .v { font-weight: 600; font-family: "IBM Plex Mono", ui-monospace, monospace; }
.metric .p { color: var(--dim); font-size: 0.8rem; }
.bar { height: 4px; background: var(--bar); border-radius: 2px; margin-top: 3px; }
.inner { padding: 0 12px 12px; }
.none { color: var(--dim); font-size: 0.85rem; margin: 8px 10px; }
.head { display: grid; grid-template-columns: 2em minmax(7em, 1fr) repeat(4, minmax(7em, 1fr));
  gap: 12px; padding: 8px 12px; color: var(--dim); font-size: 0.78rem; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.06em; border-bottom: 1px solid var(--line); }
ul { padding-left: 20px; max-width: 75ch; } li { margin: 6px 0; }
code { font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: 0.88em; }
@media (max-width: 640px) {
  summary, .head { grid-template-columns: 1.5em repeat(4, 1fr); }
  summary .name, .head .nm { grid-column: 2 / 6; }
  summary .s0, .head .s0 { grid-column: 2; }
  summary .s1, .head .s1 { grid-column: 3; }
  summary .s2, .head .s2 { grid-column: 4; }
  summary .s3, .head .s3 { grid-column: 5; }
}
nav.modes { display: flex; flex-wrap: wrap; gap: 8px 16px; margin: 0 0 8px; }
nav.modes a { color: var(--accent); font-weight: 600; text-decoration: none; }
nav.modes a:hover, nav.modes a:focus-visible { text-decoration: underline; }
h3 { font-size: 1rem; margin: 20px 0 6px; }
section.mode { scroll-margin-top: 12px; margin-top: 28px; }
`

esc :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return r
}

MODE_ANCHORS := [Mode]string {
	.Primary = "primary",
	.Charge  = "charge",
}

report_html :: proc(sh: ^Shared, t: Table, date: string, seconds, stage: int) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
	fmt.sbprintf(&b, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	fmt.sbprintf(&b, "<title>Deimos Rose DPS %s</title>\n", date)
	fmt.sbprintf(&b, "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@600&family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;600&display=swap\">\n")
	fmt.sbprintf(&b, "<style>%s</style>\n</head>\n<body>\n<main>\n", CSS)
	fmt.sbprintf(&b, "<h1>Deimos Rose DPS report</h1>\n<p class=\"sub\">%s &middot; stage %d &middot; %d s of play per run &middot; %d runs</p>\n",
		date, stage, seconds, len(sh.jobs))
	fmt.sbprintf(&b, "<p class=\"sub\">Two sets, each over the same four scenarios: primary fire, which never builds a charge, and charge shots, which charge to full, release and repeat. Every DPS is the damage dealt over the whole %d s, divided by %d, so a charge shot's DPS includes the time spent charging it.</p>\n",
		seconds, seconds)
	fmt.sbprintf(&b, "<nav class=\"modes\">")
	for m in Mode {
		fmt.sbprintf(&b, "<a href=\"#%s\">%s</a>", MODE_ANCHORS[m], MODE_NAMES[m])
	}
	fmt.sbprintf(&b, "<a href=\"#method\">How it was measured</a></nav>\n")
	for m in Mode {
		report_mode(&b, sh, t, m)
	}
	report_method(&b, sh, seconds, stage)
	fmt.sbprintf(&b, "</main>\n</body>\n</html>\n")
	return strings.to_string(b)
}

report_mode :: proc(b: ^strings.Builder, sh: ^Shared, t: Table, m: Mode) {
	order := weapon_order(sh, t, m)
	top := 0.0
	for wi in order {
		for sc in Scenario {
			top = max(top, cell(t, wi, m, sc, 0).dps)
		}
	}
	fmt.sbprintf(b, "<section class=\"mode\" id=\"%s\">\n<h2>%s</h2>\n", MODE_ANCHORS[m], MODE_NAMES[m])
	switch m {
	case .Primary:
		fmt.sbprintf(b, "<p class=\"sub\">Taps at every cadence from %d to %d steps, and holding where holding fires (Auto Charge). No charge is ever built.</p>\n",
			TAP_MIN, TAP_MAX)
	case .Charge:
		fmt.sbprintf(b, "<p class=\"sub\">Only the weapons with a charge attack; the Plasma Bomb has none. Each charges to full, releases, and starts again once the release is spent.</p>\n")
	}
	fmt.sbprintf(b, "<h3>Weapons by DPS</h3>\n<p class=\"sub\">Ranked by the average over the four scenarios. Open a weapon for its passives, ranked by the DPS they add.</p>\n")
	fmt.sbprintf(b, "<div class=\"card\">\n<div class=\"head\"><span>#</span><span class=\"nm\">Weapon</span>")
	for sc in Scenario {
		fmt.sbprintf(b, "<span class=\"s%d\">%s</span>", int(sc), SCENARIO_NAMES[sc])
	}
	fmt.sbprintf(b, "</div>\n")
	for wi, rank in order {
		fmt.sbprintf(b, "<details>\n<summary><span class=\"rank\">%d</span><span class=\"name\">%s</span>", rank + 1, esc(sh.weapons[wi].name))
		for sc in Scenario {
			bs := cell(t, wi, m, sc, 0)
			pct := top > 0 ? bs.dps / top * 100 : 0
			fmt.sbprintf(b, "<span class=\"metric s%d\"><span class=\"v\">%.2f</span><span class=\"p\">%s &middot; %.1f hits/s</span><span class=\"bar\" style=\"width:%.0f%%\"></span></span>",
				int(sc), bs.dps, policy_name(bs.policy), bs.hits, pct)
		}
		fmt.sbprintf(b, "</summary>\n<div class=\"inner scroll\">\n<table>\n<tr><th>Passive</th>")
		for sc in Scenario {
			fmt.sbprintf(b, "<th class=\"n\">%s</th><th class=\"n\">Change</th>", SCENARIO_NAMES[sc])
		}
		fmt.sbprintf(b, "<th class=\"n\">DPS added</th></tr>\n")
		flat := make([dynamic]string, context.temp_allocator)
		for ci in config_order(sh, t, wi, m) {
			if no_effect(t, wi, m, ci) {
				append(&flat, config_name(sh.configs[ci]))
				continue
			}
			fmt.sbprintf(b, "<tr><td>%s</td>", esc(config_name(sh.configs[ci])))
			for sc in Scenario {
				fmt.sbprintf(b, "<td class=\"n\">%.2f</td><td class=\"n %s\">%s</td>", cell(t, wi, m, sc, ci).dps,
					change_class(delta(t, wi, m, sc, ci)), change_text(t, wi, m, sc, ci))
			}
			md := mean_delta(t, wi, m, ci)
			fmt.sbprintf(b, "<td class=\"n %s\">%s</td></tr>\n", change_class(md), signed_dps(md))
		}
		fmt.sbprintf(b, "</table>\n")
		if len(flat) > 0 {
			fmt.sbprintf(b, "<p class=\"none\">No effect: %s.</p>\n", esc(strings.join(flat[:], ", ", context.temp_allocator)))
		}
		fmt.sbprintf(b, "</div>\n</details>\n")
	}
	fmt.sbprintf(b, "</div>\n")

	fmt.sbprintf(b, "<h3>Passives, averaged</h3>\n")
	fmt.sbprintf(b, "<p class=\"sub\">The DPS each passive level adds, averaged over the %d weapons above and the four scenarios. A weapon passive changes only its own weapon, so that average spreads its gain over weapons it cannot touch; the next column averages over only the weapons it changes.</p>\n",
		len(order))
	fmt.sbprintf(b, "<div class=\"card scroll\">\n<table>\n<tr><th>#</th><th>Passive</th><th class=\"n\">Average added</th><th class=\"n\">Where it applies</th><th class=\"n\">Weapons changed</th><th>Adds most to</th></tr>\n")
	for o, rank in overall_order(sh, t, m) {
		most := "&ndash;"
		if o.top >= 0 {
			most = fmt.tprintf("%s (%s)", esc(sh.weapons[o.top].name), signed_dps(o.top_gain))
		}
		own := o.affected > 0 ? signed_dps(o.own) : "&ndash;"
		fmt.sbprintf(b, "<tr><td>%d</td><td>%s</td><td class=\"n %s\">%s</td><td class=\"n %s\">%s</td><td class=\"n\">%d</td><td>%s</td></tr>\n",
			rank + 1, esc(config_name(sh.configs[o.config])), change_class(o.mean), signed_dps(o.mean),
			change_class(o.own), own, o.affected, most)
	}
	fmt.sbprintf(b, "</table>\n</div>\n</section>\n")
}

report_method :: proc(b: ^strings.Builder, sh: ^Shared, seconds, stage: int) {
	hit_delay := sh.defs.perm_floats[0xa7]
	fmt.sbprintf(b, "<h2 id=\"method\">How it was measured</h2>\n<ul>\n")
	fmt.sbprintf(b, "<li>In the simulation alone (<code>tools/dps</code>, <code>mise run dps:report</code>), with no window or rendering. Every run is a fresh game on stage %d with its placements removed, one player, and seed %x, so a passive's run is paired with the baseline's.</li>\n",
		stage, SEED)
	fmt.sbprintf(b, "<li>Once the ship is in play it gets the weapon and at most one passive at one level. After %d steps for the crosshair to settle, the targets are spawned and %d s (%d steps) are measured. DPS is the damage over all of it.</li>\n",
		SETTLE_STEPS, seconds, seconds * STEP_HZ)
	fmt.sbprintf(b, "<li>The targets are copies of the BlackHawk (air) and the Laser Tank (ground). Each copy is stationary, has one state that never fires, moves or changes, and outside the wave has its shields topped back up every step. A shot that hits one is still spent as it would be against the real enemy.</li>\n")
	fmt.sbprintf(b, "<li>Scenarios: <em>single target</em>, one target ahead; <em>cluster of 5</em>, that target and four more in a V, 40 px either side and 34 px further back; <em>target behind</em>, one target mirrored behind the ship. Air targets stand %d px from the ship. Ground targets stand where the crosshair lands the Plasma Bomb, and behind at the same distance.</li>\n",
		AIR_RANGE)
	fmt.sbprintf(b, "<li><em>Wave of 9</em> is the one scenario whose targets die: three rows of three, 40 px apart across and 34 px deep, starting where the single target stands. Each has %.1f shields, a stage 9&ndash;12 enemy's, and a target shot down is replaced %d steps later. Its DPS counts only the shields taken off, so damage past a kill counts only where it carries on to another target (the Discharge Beam) or throws out shrapnel that hits one.</li>\n",
		WAVE_SHIELDS, WAVE_RESPAWN_STEPS)
	fmt.sbprintf(b, "<li>Primary fire: a tap every %d to %d steps, and holding where holding fires (Auto Charge). A run in which a charge began is left out of this set. Charge shots: hold until the charge is full, let go for a step, hold again; under Auto Charge, the reverse. Each cell is the best run in its set, so these are a perfect player's numbers.</li>\n",
		TAP_MIN, TAP_MAX)
	fmt.sbprintf(b, "<li>An enemy ignores a hit that lands within %d step of its last one (perm float 0xa7, <code>entity_hit</code>). One target therefore takes at most %.0f hits a second, however many shots reach it.</li>\n",
		i32(hit_delay), f64(STEP_HZ) / (f64(hit_delay) + 1))
	fmt.sbprintf(b, "<li>Changes within &plusmn;%.3f DPS are shown as 0. &ldquo;From 0&rdquo; marks a scenario in which the bare weapon deals nothing.</li>\n",
		NOISE_DPS)
	fmt.sbprintf(b, "</ul>\n")
}
