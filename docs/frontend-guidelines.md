# Frontend guidelines

Rules for changing the AgentLens UI, and the reasoning behind them. Where a rule
looks arbitrary, the reasoning is the important half — follow the reasoning when
you hit a case the rule does not cover.

The governing idea: **this dashboard's job is to be believed.** Every rule below
exists because some plausible-looking alternative would let it mislead someone
quietly. A dashboard nobody trusts is worse than no dashboard, because people
still glance at it.

---

## 1. Colour

**One accent. Semantic colour reserved strictly for status.**

- `--al-accent` is the only decorative colour. Buttons, links, focus rings.
- Green, amber and red belong to `good`, `warning` and `critical`. **Nothing
  else may use them** — not a "success" toast, not a chart series, not a
  decorative badge.

Why: if red appears decoratively anywhere, red stops meaning anything. The whole
point of reserving it is that when you see it, it is information.

**Never let colour carry a signal alone.**

Every status is **icon + colour + text**. A meaningful fraction of users will not
distinguish red from green, and a bank may have an accessibility standard to
meet regardless.

```heex
<%!-- Right --%>
<.status_badge status={@kpi.status} />

<%!-- Wrong: colour is the only signal --%>
<span class="size-2 rounded-full bg-status-critical" />
```

**`unknown` is grey and must never read as healthy.**

It is a fourth state, not a lighter shade of `good`. Its tooltip says "not the
same as healthy" on purpose. Missing data that looks fine is the single most
dangerous thing this UI can render.

### Tokens

Colours are CSS custom properties on `:root`, overridden under
`[data-theme="dark"]`, and exposed to Tailwind through `@theme inline` in
`assets/css/app.css`. That indirection is what makes one set of components work
in both themes.

To add a colour: define `--al-*` in both blocks, then map it in `@theme inline`.
Never hardcode a hex or `oklch()` in a template.

---

## 2. Encoding good and bad

**Use a bullet chart, not a status dot.**

A dot says which side of a line you are on. A bullet chart says *how close to the
next line* — which is the difference between noticing a problem and being told
about one after it happened.

**Three directions, not two.**

`:higher_is_better`, `:lower_is_better`, **and `:target_band`**. Banded KPIs
shade critical at *both* extremes. An agent scoring maximum positive sentiment on
every response is malfunctioning, not excelling; a refusal rate near zero means
guardrails are not engaging. A two-direction encoding paints those green at
exactly the values that should worry you.

If you add a visual that judges a value, handle all three directions or do not
ship it.

**Trend arrows: geometry is the delta, colour is the meaning.**

Toxicity rising is a **red up-arrow** — up because the number went up, red
because for that KPI up is bad. Encoding direction in the colour instead would
require a legend on every chart.

Banded KPIs get a **neutral** arrow. A delta alone cannot say whether a banded
value moved toward or away from its band.

**Always show sample adequacy.**

A score from 3 runs and a score from 400 must not look alike. `sample_meter/1`
renders `n=40/240`, and goes grey with an icon below `min_sample_n`.

---

## 3. Absent data

**Gaps stay gaps. Never zero-fill, never interpolate.**

- A missing value renders as an em dash (`—`), never `0`.
- A chart with no points renders an explicit empty state, never a flat line at zero.
- `spanGaps: false` in the chart hook, so uPlot breaks the line rather than
  bridging it.

Why: "we measured zero" and "we have nothing" are completely different claims,
and a chart that conflates them will be believed.

---

## 4. Components

**The KPI card is the extension unit.**

`kpi_card/1` takes a `%Definition{}` and a reading. The definition already
carries name, description, unit, direction, thresholds and `min_sample_n`, so a
newly registered KPI renders correctly with **zero UI code**.

> **Never add per-KPI branching to a component.** No `case kpi.slug do`. If a KPI
> needs something bespoke, that is what the `component/0` callback on the KPI
> module is for.

If you find yourself wanting to special-case a slug in the UI, the missing thing
almost certainly belongs on `%Definition{}` instead — put it there and every KPI
benefits.

**Write Tailwind by hand. Do not use daisyUI for dashboard UI.**

daisyUI is present because the generator shipped it and the flash/layout
scaffolding uses it. Everything in `DashboardComponents` is hand-written so the
design is ours. (This is also a standing rule in `AGENTS.md`.)

---

## 5. Charts

**One hook. All charts go through `ChartHook`.**

`assets/js/chart_hook.js` is the only charting code in the app. Every chart is
that hook with different config, built server-side by `AgentLensWeb.ChartConfig`.

Do not add a second chart library. Do not hand-roll a `<canvas>` in a template.

**The two plugins are the point.**

- **Threshold bands** shade the plot into the zones the KPI's own thresholds
  define, drawn *under* the series. This is what makes a value trending toward a
  boundary visible several buckets early.
- **Annotations** mark events that change what the number *means* — a model swap,
  a KPI version bump. An unannotated methodology change looks exactly like real
  drift, and someone will spend a day chasing it.

Both are driven entirely by the definition, so they are correct for any KPI
without per-KPI code.

**Read the palette from CSS variables**, never hardcode. The hook watches
`data-theme` on `<html>` and redraws, which is why the theme toggle works.

**Downsampled percentile series are an envelope, not exact.** A percentile of
percentiles does not exist, so combining buckets takes the max. When
`downsampled?` is true the UI says so. Do not quietly drop that notice.

---

## 6. LiveView

**All view state lives in the URL.**

Time range, filters, drawer state — everything goes through `handle_params/3` and
query params. The back button works and every view is a shareable link. This is
cheap and it is most of what makes a dashboard feel finished.

Never keep a view option only in socket assigns.

**Never query in a LiveView. Read the cache.**

```elixir
# Right: cache read, falls back to a query only on a cold cache
Broadcaster.overview()

# Wrong: every mount hits the database
Query.overview()
```

`AgentLens.Broadcaster` is the single writer. LiveViews subscribe to its PubSub
topics and are pushed updates. **Never poll on a timer in a LiveView** — that
makes load scale with how many people are looking, which is exactly backwards.

**Mount from cache, then `start_async` the detail.** The page should be useful
before the queries finish, not a spinner over an empty screen.

**Push deltas, not series.** On a closed bucket the broadcaster sends one point
and the hook appends it. Do not re-render a whole series to update its last
value.

**ARIA state attributes must be explicit strings.**

```heex
<%!-- Right --%>
<button aria-pressed={to_string(@selected)}>

<%!-- Wrong: HEEx renders a bare `aria-pressed`, which assistive tech cannot read as state --%>
<button aria-pressed={@selected}>
```

This one bit us once already. `aria-pressed` and `aria-expanded` need
`"true"`/`"false"`.

---

## 7. Typography and restraint

- **Tabular numerals** (`.al-num`) on anything that updates, so digits do not
  jitter on a live dashboard.
- Sparklines in cards, full charts on drilldown.
- Dark mode is not an afterthought; check both before shipping.
- Give every interactive element a stable DOM id — the tests select on them.

---

## 8. Where things live

| Path | What |
|---|---|
| `assets/css/app.css` | design tokens, `@theme inline` mapping |
| `assets/js/chart_hook.js` | the only chart code |
| `lib/agent_lens_web/components/dashboard_components.ex` | status, bullet, sparkline, trend, sample, cards |
| `lib/agent_lens_web/components/layouts.ex` | app shell, breadcrumbs, mock-data badge |
| `lib/agent_lens_web/chart_config.ex` | server-side chart payload |
| `lib/agent_lens_web/time_range.ex` | range keys, labels, bounds |
| `lib/agent_lens_web/live/` | the three LiveViews |

---

## 9. Checklist before shipping a UI change

- [ ] No decorative use of green / amber / red
- [ ] Every status shows icon **and** colour **and** text
- [ ] `unknown` renders grey, never green
- [ ] All three threshold directions handled, including `:target_band`
- [ ] Absent data renders as `—` or an empty state, never `0`
- [ ] No per-KPI branching in a component
- [ ] View state in the URL, not socket-only
- [ ] Reads go through `Broadcaster`, not `Query`
- [ ] `aria-pressed` / `aria-expanded` are explicit strings
- [ ] Works in light **and** dark
- [ ] `mix precommit` and `mix dialyzer` pass
