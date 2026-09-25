package dps

// The report: a static HTML page with no scripts and nothing fetched, and a
// plain-text summary on stdout.
//
// - Weapons, best first by their DPS averaged over the two scenarios. Each
//   one opens to its passives, ranked by the gain they give it.
// - Passives: every level's gain averaged over every weapon and scenario,
//   best first, with the weapon it helps most.

import "core:fmt"
import "core:slice"
import "core:strings"

// A passive level's gain to one weapon in one scenario, in percent of the
// baseline. 0 when the baseline deals nothing.
gain_pct :: proc(best: [][Scenario][]Best, w: int, sc: Scenario, c: int) -> f64 {
	base := best[w][sc][0].dps
	if base <= 0 {
		return 0
	}
	return (best[w][sc][c].dps - base) / base * 100
}

weapon_mean :: proc(best: [][Scenario][]Best, w: int, c: int) -> f64 {
	return (best[w][.Single][c].dps + best[w][.Cluster][c].dps) / 2
}

weapon_gain :: proc(best: [][Scenario][]Best, w: int, c: int) -> f64 {
	return (gain_pct(best, w, .Single, c) + gain_pct(best, w, .Cluster, c)) / 2
}

// Weapons, best first.
weapon_order :: proc(sh: ^Shared, best: [][Scenario][]Best) -> []int {
	order := make([]int, len(sh.weapons), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	Ctx :: struct {
		best: [][Scenario][]Best,
	}
	ctx := Ctx{best}
	context.user_ptr = &ctx
	slice.sort_by(order, proc(a, b: int) -> bool {
		c := (^Ctx)(context.user_ptr)
		return weapon_mean(c.best, a, 0) > weapon_mean(c.best, b, 0)
	})
	return order
}

// A weapon's passive levels, most gain first; the baseline left out.
config_order :: proc(sh: ^Shared, best: [][Scenario][]Best, w: int) -> []int {
	order := make([]int, len(sh.configs) - 1, context.temp_allocator)
	for &o, i in order {
		o = i + 1
	}
	Ctx :: struct {
		best: [][Scenario][]Best,
		w:    int,
	}
	ctx := Ctx{best, w}
	context.user_ptr = &ctx
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		c := (^Ctx)(context.user_ptr)
		return weapon_gain(c.best, c.w, a) > weapon_gain(c.best, c.w, b)
	})
	return order
}

Overall :: struct {
	config:    int,
	mean:      f64, // gain averaged over every weapon and scenario
	own:       f64, // averaged over the weapons it changes at all
	affected:  int,
	top:       int, // the weapon it helps most
	top_gain:  f64,
}

// A gain this small is the same run give or take rounding: no effect.
NOISE_PCT :: 0.05

overall_order :: proc(sh: ^Shared, best: [][Scenario][]Best) -> []Overall {
	out := make([]Overall, len(sh.configs) - 1, context.temp_allocator)
	for &o, i in out {
		o.config = i + 1
		o.top = -1
		for w in 0 ..< len(sh.weapons) {
			g := weapon_gain(best, w, o.config)
			o.mean += g
			if abs(g) > NOISE_PCT {
				o.own += g
				o.affected += 1
			}
			if o.top < 0 || g > o.top_gain {
				o.top, o.top_gain = w, g
			}
		}
		o.mean /= f64(len(sh.weapons))
		if o.affected > 0 {
			o.own /= f64(o.affected)
		}
	}
	slice.stable_sort_by(out, proc(a, b: Overall) -> bool {
		return a.mean > b.mean
	})
	return out
}

// "tap 5.98 (every 2), charge 3.10" -- each kind of policy's best.
kind_summary :: proc(kinds: [Policy_Kind]Kind_Best) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for k, kind in kinds {
		if !k.tried {
			continue
		}
		name, _ := fmt.enum_value_to_string(kind)
		label := strings.to_lower(name, context.temp_allocator)
		if kind == .Tap {
			append(&parts, fmt.tprintf("%s %.2f (every %d)", label, k.dps, k.policy.period))
		} else {
			append(&parts, fmt.tprintf("%s %.2f", label, k.dps))
		}
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

signed_pct :: proc(v: f64) -> string {
	if abs(v) <= NOISE_PCT {
		return "0%"
	}
	return fmt.tprintf("%+.1f%%", v)
}

gain_class :: proc(v: f64) -> string {
	switch {
	case v > NOISE_PCT:
		return "up"
	case v < -NOISE_PCT:
		return "down"
	}
	return "flat"
}

report_text :: proc(sh: ^Shared, best: [][Scenario][]Best) {
	fmt.println("weapon                 single        cluster       (DPS, best policy, hits/s)")
	for w in weapon_order(sh, best) {
		s, c := best[w][.Single][0], best[w][.Cluster][0]
		kinds := s.by_kind
		fmt.printfln("%-14s %8s %-13s %5s  %8s %-13s %5s", sh.weapons[w].name,
			fmt.tprintf("%.2f", s.dps), policy_name(s.policy), fmt.tprintf("%.1f", s.hits),
			fmt.tprintf("%.2f", c.dps), policy_name(c.policy), fmt.tprintf("%.1f", c.hits))
		fmt.printfln("    single by policy: %s", kind_summary(kinds))
		for ci in config_order(sh, best, w) {
			g := weapon_gain(best, w, ci)
			if abs(g) <= NOISE_PCT {
				continue
			}
			fmt.printfln("    %-26s %7s %-13s %7s %s", config_name(sh.configs[ci]),
				signed_pct(gain_pct(best, w, .Single, ci)), policy_name(best[w][.Single][ci].policy),
				signed_pct(gain_pct(best, w, .Cluster, ci)), policy_name(best[w][.Cluster][ci].policy))
		}
	}
	fmt.println("passive, averaged over every weapon and scenario:")
	for o in overall_order(sh, best) {
		top := o.top >= 0 && o.top_gain > NOISE_PCT ? fmt.tprintf("most on %s", sh.weapons[o.top].name) : "helps none"
		fmt.printfln("    %-26s %7s  (%d weapons changed, %7s on those; %s)", config_name(sh.configs[o.config]),
			signed_pct(o.mean), o.affected, signed_pct(o.own), top)
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
  grid-template-columns: 2em minmax(7em, 1fr) repeat(2, minmax(8em, 1.2fr)); align-items: center; }
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
.head { display: grid; grid-template-columns: 2em minmax(7em, 1fr) repeat(2, minmax(8em, 1.2fr));
  gap: 12px; padding: 8px 12px; color: var(--dim); font-size: 0.78rem; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.06em; border-bottom: 1px solid var(--line); }
ul { padding-left: 20px; max-width: 75ch; } li { margin: 6px 0; }
code { font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: 0.88em; }
@media (max-width: 560px) {
  summary, .head { grid-template-columns: 1.5em 1fr 1fr; }
  summary .name, .head .nm { grid-column: 2 / 4; }
  summary .sg, .head .sg { grid-column: 2; }
  summary .cl, .head .cl { grid-column: 3; }
}
`

@(private = "file")
esc :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return r
}

report_html :: proc(sh: ^Shared, best: [][Scenario][]Best, date: string, seconds, stage: int) -> string {
	b := strings.builder_make()
	w :: proc(b: ^strings.Builder, format: string, args: ..any) {
		fmt.sbprintf(b, format, ..args)
	}
	order := weapon_order(sh, best)
	top := 0.0
	for wi in order {
		top = max(top, best[wi][.Single][0].dps, best[wi][.Cluster][0].dps)
	}
	w(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
	w(&b, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	w(&b, "<title>Deimos Rose DPS %s</title>\n", date)
	w(&b, "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@600&family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;600&display=swap\">\n")
	w(&b, "<style>%s</style>\n</head>\n<body>\n<main>\n", CSS)
	w(&b, "<h1>Deimos Rose DPS report</h1>\n<p class=\"sub\">%s &middot; stage %d &middot; %d s of play per run &middot; %d runs</p>\n",
		date, stage, seconds, len(sh.jobs))

	// Weapons.
	w(&b, "<h2>Weapons by DPS</h2>\n")
	w(&b, "<p class=\"sub\">Damage a second from a perfect player, against stand-in enemies that never move or die. Ranked by the average of the two scenarios. Open a weapon to see its passives ranked by the gain they give it.</p>\n")
	w(&b, "<div class=\"card\">\n<div class=\"head\"><span>#</span><span class=\"nm\">Weapon</span><span class=\"sg\">Single target</span><span class=\"cl\">Cluster of 5</span></div>\n")
	for wi, rank in order {
		wc := sh.weapons[wi]
		w(&b, "<details>\n<summary><span class=\"rank\">%d</span><span class=\"name\">%s</span>", rank + 1, esc(wc.name))
		for sc in Scenario {
			bs := best[wi][sc][0]
			pct := top > 0 ? bs.dps / top * 100 : 0
			w(&b, "<span class=\"metric %s\"><span class=\"v\">%.2f DPS</span><span class=\"p\">%s &middot; %.1f hits/s</span><span class=\"bar\" style=\"width:%.0f%%\"></span></span>",
				sc == .Single ? "sg" : "cl", bs.dps, policy_name(bs.policy), bs.hits, pct)
		}
		w(&b, "</summary>\n<div class=\"inner scroll\">\n<p class=\"none\">Best of each policy, single target: %s. Cluster: %s.</p>\n",
			kind_summary(best[wi][.Single][0].by_kind), kind_summary(best[wi][.Cluster][0].by_kind))
		w(&b, "<table>\n<tr><th>Passive</th><th class=\"n\">Single</th><th class=\"n\">Gain</th><th>Policy</th><th class=\"n\">Cluster</th><th class=\"n\">Gain</th><th>Policy</th></tr>\n")
		flat := make([dynamic]string, context.temp_allocator)
		for ci in config_order(sh, best, wi) {
			if abs(gain_pct(best, wi, .Single, ci)) <= NOISE_PCT && abs(gain_pct(best, wi, .Cluster, ci)) <= NOISE_PCT {
				append(&flat, config_name(sh.configs[ci]))
				continue
			}
			w(&b, "<tr><td>%s</td>", esc(config_name(sh.configs[ci])))
			for sc in Scenario {
				g := gain_pct(best, wi, sc, ci)
				w(&b, "<td class=\"n\">%.2f</td><td class=\"n %s\">%s</td><td>%s</td>",
					best[wi][sc][ci].dps, gain_class(g), signed_pct(g), policy_name(best[wi][sc][ci].policy))
			}
			w(&b, "</tr>\n")
		}
		w(&b, "</table>\n")
		if len(flat) > 0 {
			w(&b, "<p class=\"none\">No effect: %s.</p>\n", esc(strings.join(flat[:], ", ", context.temp_allocator)))
		}
		w(&b, "</div>\n</details>\n")
	}
	w(&b, "</div>\n")

	// Passives overall.
	w(&b, "<h2>Passives, averaged</h2>\n")
	w(&b, "<p class=\"sub\">Each passive level's DPS gain, averaged over all %d weapons and both scenarios. A weapon passive changes only its own weapon, so the average spreads its gain over weapons it cannot touch; the next column averages over only the weapons it changes.</p>\n", len(sh.weapons))
	w(&b, "<div class=\"card scroll\">\n<table>\n<tr><th>#</th><th>Passive</th><th class=\"n\">Average gain</th><th class=\"n\">Where it applies</th><th>Weapons changed</th><th>Most gain</th></tr>\n")
	for o, rank in overall_order(sh, best) {
		topw := o.top >= 0 && o.top_gain > NOISE_PCT ? fmt.tprintf("%s (%s)", sh.weapons[o.top].name, signed_pct(o.top_gain)) : "&ndash;"
		w(&b, "<tr><td>%d</td><td>%s</td><td class=\"n %s\">%s</td><td class=\"n %s\">%s</td><td>%d</td><td>%s</td></tr>\n",
			rank + 1, esc(config_name(sh.configs[o.config])), gain_class(o.mean), signed_pct(o.mean),
			gain_class(o.own), o.affected > 0 ? signed_pct(o.own) : "&ndash;", o.affected, topw)
	}
	w(&b, "</table>\n</div>\n")

	// Method.
	hit_delay := sh.defs.perm_floats[0xa7]
	w(&b, "<h2>How it was measured</h2>\n<ul>\n")
	w(&b, "<li>Measured in the simulation alone (<code>tools/dps</code>, <code>mise run dps:report</code>): no window, no rendering. Every run is a fresh game on stage %d with nothing placed in it, one player, seed %x.</li>\n", stage, SEED)
	w(&b, "<li>Once the ship is in play it is given the weapon and at most one passive at one level. After %d steps for the crosshair to settle, targets are spawned and %d s (%d steps) are measured.</li>\n", SETTLE_STEPS, seconds, seconds * STEP_HZ)
	w(&b, "<li>The targets are copies of the BlackHawk (air) and the Laser Tank (ground). Each copy is stationary, has one state that never fires, moves or changes, and its shields are topped back up every step. A shot that hits one still takes the enemy's own damage, as it would against the real thing.</li>\n")
	w(&b, "<li>Air targets stand %d px straight ahead of the ship. Ground targets stand on the crosshair, where the Plasma Bomb lands. The cluster is a V of five, 40 px across and 34 px deep.</li>\n", AIR_RANGE)
	w(&b, "<li>Each weapon is fired under every policy: a tap every 2 to %d steps, a full charge and release where it has a power-up, and holding where holding fires. The best policy is reported, so these are a perfect player's numbers.</li>\n", TAP_MAX)
	w(&b, "<li>An enemy ignores a hit that lands within %d step of its last one (perm float 0xa7, <code>entity_hit</code>). One target therefore takes at most %.0f hits a second, however many shots reach it.</li>\n",
		i32(hit_delay), f64(STEP_HZ) / (f64(hit_delay) + 1))
	w(&b, "<li>A gain within &plusmn;%.2f%% is shown as 0%%. Every run uses the same seed, but a passive that draws from the random stream (Risky Reward) shifts every draw after it, which moves the Chaingun's spread.</li>\n", NOISE_PCT)
	w(&b, "</ul>\n</main>\n</body>\n</html>\n")
	return strings.to_string(b)
}

