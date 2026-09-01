import uPlot from "uplot"

// Every chart in the app is this one hook with different config, so charting
// stays in a single file.
//
// The interesting part is not the line — uPlot draws that. It is the two
// plugins below, which put the *judgement* behind the data:
//
//   - threshold bands, so a value trending toward a boundary is visible several
//     buckets before it crosses one;
//   - annotations, so a change in how a KPI was measured is marked on the
//     chart. An unannotated methodology change looks exactly like real drift,
//     and someone will spend a day chasing it.

const cssVar = (name) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim()

const palette = () => ({
  good: cssVar("--al-good"),
  warning: cssVar("--al-warn"),
  critical: cssVar("--al-crit"),
  unknown: cssVar("--al-unknown"),
  accent: cssVar("--al-accent"),
  ink: cssVar("--al-ink"),
  inkSoft: cssVar("--al-ink-soft"),
  grid: cssVar("--al-grid"),
  line: cssVar("--al-line"),
})

// Shades the y-axis into the zones the KPI's own thresholds define. Drawn
// underneath the series, never over it.
const thresholdBands = (bands) => ({
  hooks: {
    drawClear: [
      (u) => {
        if (!bands || bands.length === 0) return
        const colors = palette()
        const { ctx } = u
        const { left, top, width, height } = u.bbox

        ctx.save()
        ctx.beginPath()
        ctx.rect(left, top, width, height)
        ctx.clip()

        bands.forEach(({ from, to, status }) => {
          const yFrom = u.valToPos(to === null ? u.scales.y.max : to, "y", true)
          const yTo = u.valToPos(from === null ? u.scales.y.min : from, "y", true)

          ctx.globalAlpha = 0.1
          ctx.fillStyle = colors[status] || colors.unknown
          ctx.fillRect(left, Math.min(yFrom, yTo), width, Math.abs(yTo - yFrom))
        })

        ctx.restore()
      },
    ],
  },
})

// Vertical markers for events that change what the number *means* — a judge
// prompt revision, a model version change.
const annotations = (marks) => ({
  hooks: {
    draw: [
      (u) => {
        if (!marks || marks.length === 0) return
        const colors = palette()
        const { ctx } = u
        const { left, top, width, height } = u.bbox

        ctx.save()
        marks.forEach(({ at, label }) => {
          const x = u.valToPos(at, "x", true)
          if (x < left || x > left + width) return

          ctx.setLineDash([3, 3])
          ctx.strokeStyle = colors.inkSoft
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(x, top)
          ctx.lineTo(x, top + height)
          ctx.stroke()

          ctx.setLineDash([])
          ctx.fillStyle = colors.inkSoft
          ctx.font = "10px system-ui, sans-serif"
          ctx.textAlign = "left"
          ctx.fillText(label, x + 4, top + 10)
        })
        ctx.restore()
      },
    ],
  },
})

// Gaps must stay gaps. uPlot breaks the line on null, so a period with no data
// reads as absent rather than as a value of zero.
const toSeries = (points) => {
  const xs = points.map((p) => p.t)
  const ys = points.map((p) => (p.v === null || p.v === undefined ? null : p.v))
  return [xs, ys]
}

export const ChartHook = {
  mounted() {
    this.render()
    this.observer = new ResizeObserver(() => this.resize())
    this.observer.observe(this.el)

    // The theme toggle rewrites the palette; redraw so the chart follows.
    this.themeWatcher = new MutationObserver(() => this.render())
    this.themeWatcher.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })

    // A closed bucket arrives as a single point rather than a fresh series.
    //
    // The current bucket is still accumulating, so the same timestamp can
    // arrive repeatedly with a moving value: match on the timestamp and
    // replace, otherwise append. Treating every message as an append would
    // draw the same bucket several times over.
    this.handleEvent(`chart:${this.el.id}:point`, ({ t, v }) => {
      if (!this.chart) return

      const [xs, ys] = this.chart.data
      const last = xs.length - 1

      if (last >= 0 && xs[last] === t) {
        const nextYs = ys.slice()
        nextYs[last] = v
        this.chart.setData([xs, nextYs])
      } else {
        this.chart.setData([[...xs, t], [...ys, v]])
      }
    })
  },

  updated() {
    this.render()
  },

  destroyed() {
    this.observer?.disconnect()
    this.themeWatcher?.disconnect()
    this.chart?.destroy()
  },

  config() {
    return JSON.parse(this.el.dataset.chart)
  },

  resize() {
    if (!this.chart) return
    this.chart.setSize({
      width: this.el.clientWidth,
      height: this.chart.height,
    })
  },

  render() {
    const cfg = this.config()
    const colors = palette()
    this.chart?.destroy()
    this.el.innerHTML = ""

    const stroke = colors[cfg.status] || colors.accent

    this.chart = new uPlot(
      {
        width: this.el.clientWidth || 600,
        height: cfg.height || 260,
        padding: [12, 8, 0, 0],
        cursor: { y: false, points: { size: 6 } },
        legend: { show: cfg.legend !== false },
        scales: { x: { time: true } },
        axes: [
          {
            stroke: colors.inkSoft,
            grid: { stroke: colors.grid, width: 1 },
            ticks: { stroke: colors.line, width: 1 },
          },
          {
            stroke: colors.inkSoft,
            grid: { stroke: colors.grid, width: 1 },
            ticks: { stroke: colors.line, width: 1 },
            size: 56,
            values: (_u, splits) => splits.map((v) => cfg.unit_suffix
              ? `${Number(v.toFixed(cfg.precision ?? 2))}${cfg.unit_suffix}`
              : Number(v.toFixed(cfg.precision ?? 2))),
          },
        ],
        series: [
          { label: "Time" },
          {
            label: cfg.label || "Value",
            stroke,
            width: 1.75,
            fill: `color-mix(in oklch, ${stroke} 12%, transparent)`,
            spanGaps: false,
            points: { show: cfg.points_visible ?? false },
            value: (_u, v) =>
              v === null
                ? "no data"
                : `${Number(v.toFixed(cfg.precision ?? 2))}${cfg.unit_suffix || ""}`,
          },
        ],
        plugins: [thresholdBands(cfg.bands), annotations(cfg.annotations)],
      },
      toSeries(cfg.points),
      this.el
    )
  },
}

export default ChartHook
