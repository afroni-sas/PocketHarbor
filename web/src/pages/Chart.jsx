// Line charts for metrics: thin lines over a faint wash, hairline grid, a
// crosshair that snaps to the nearest sample, and a tooltip with every
// series. One y-axis per chart; two measures get two charts.

import { signal } from '@preact/signals'
import { Check, ChevronDown, Clock } from 'lucide-preact'
import { openMenu } from '../ui.jsx'

/** Validated on the dark surface: one hue alone, or blue and orange together. */
export const colors = { single: '#9085e9', first: '#3987e5', second: '#d95926' }

/** Which chart is hovered, and at which sample. */
const hover = signal(null)

const W = 1000

export function bytes(n) {
  if (!n) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  let v = n
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`
}

const small = (v) => (Number.isInteger(v) ? String(v) : v.toFixed(1))
/** CPU as Railway shows it: 0.25 vCPU is a quarter of one core. */
export const vcpu = (v) => `${v === 0 ? '0' : v >= 10 ? Math.round(v) : v >= 1 ? v.toFixed(1) : v.toFixed(2)} vCPU`
export const percent = (v) => `${v >= 10 ? Math.round(v) : small(Math.round(v * 10) / 10)}%`
export const count = (v) => (v >= 10000 ? `${(v / 1000).toFixed(v >= 100000 ? 0 : 1)}K` : v >= 10 ? Math.round(v).toLocaleString() : small(v))
export const millis = (v) => (v >= 1000 ? `${(v / 1000).toFixed(1)} s` : v >= 10 ? `${Math.round(v)} ms` : `${small(v)} ms`)

/** A round top for the axis: 1, 2 or 5 times a power of ten (of 1024 for bytes). */
function niceMax(v, binary) {
  if (!(v > 0)) return binary ? 1024 : 1
  const base = binary ? 1024 : 10
  const power = binary ? Math.pow(1024, Math.floor(Math.log(v) / Math.log(1024))) : Math.pow(10, Math.floor(Math.log10(v)))
  const n = v / power
  const steps = binary ? [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024] : [1, 2, 5, 10]
  for (const s of steps) if (n <= s) return s * power
  return base * power
}

export function timeLabel(t, range) {
  const d = new Date(t * 1000)
  if (range > 86400) return d.toLocaleDateString([], { weekday: 'short', day: 'numeric' })
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function fullTime(t) {
  return new Date(t * 1000).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

/** Paths of one series, broken where samples are missing. */
function paths(points, value, x, y, step, area, height) {
  const lines = []
  const fills = []
  let run = []
  const flush = () => {
    if (run.length === 0) return
    const d = run.map(([px, py], i) => `${i ? 'L' : 'M'}${px.toFixed(1)},${py.toFixed(1)}`).join('')
    lines.push(run.length === 1 ? `M${run[0][0] - 2},${run[0][1]}L${run[0][0] + 2},${run[0][1]}` : d)
    if (area && run.length > 1) fills.push(`${d}L${run[run.length - 1][0].toFixed(1)},${height}L${run[0][0].toFixed(1)},${height}Z`)
    run = []
  }
  let last = null
  for (const p of points) {
    if (last !== null && p.t - last > step * 2.5) flush()
    run.push([x(p.t), y(value(p))])
    last = p.t
  }
  flush()
  return { lines, fills }
}

/**
 * `series`: [{ label, color, value(point) }]; `format` writes a value.
 * `from`, `to` and `step` come from the API, in seconds.
 */
export function Chart({ id, title, series, points, format, from, to, step, height = 150, binary = false, summary, quiet }) {
  const range = to - from
  let max = 0
  for (const p of points) for (const s of series) max = Math.max(max, s.value(p) || 0)
  const top = niceMax(max, binary)
  const x = (t) => ((t - from) / range) * W
  const y = (v) => height - (Math.max(0, v || 0) / top) * (height - 4) - 2
  const single = series.length === 1
  const drawn = series.map((s) => ({ ...s, ...paths(points, s.value, x, y, step, single, height) }))
  const h = hover.value
  const at = h && h.id === id && points[h.i] ? h.i : -1
  const latest = points.length ? points[points.length - 1] : null

  const pick = (e) => {
    if (!points.length) return
    const r = e.currentTarget.getBoundingClientRect()
    const t = from + ((e.clientX - r.left) / r.width) * range
    let best = 0
    for (let i = 1; i < points.length; i++) if (Math.abs(points[i].t - t) < Math.abs(points[best].t - t)) best = i
    hover.value = { id, i: best }
  }
  const key = (e) => {
    if (!points.length) return
    const i = at < 0 ? points.length - 1 : at
    if (e.key === 'ArrowLeft') hover.value = { id, i: Math.max(0, i - 1) }
    else if (e.key === 'ArrowRight') hover.value = { id, i: Math.min(points.length - 1, i + 1) }
    else return
    e.preventDefault()
  }
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => from + f * range)
  const shown = at >= 0 ? points[at] : null
  const left = shown ? (x(shown.t) / W) * 100 : 0

  return (
    <figure class="chart card">
      <figcaption>
        <span class="chart-title">{title}</span>
        <span class="spacer" />
        {summary !== undefined ? <b>{summary}</b> : latest && single && <b>{format(series[0].value(latest))}</b>}
      </figcaption>
      {!single && (
        <div class="legend">
          {series.map((s) => (
            <span key={s.label}>
              <i style={`background:${s.color}`} />
              {s.label}
            </span>
          ))}
        </div>
      )}
      <div class="chart-body">
        <div class="y-axis" style={`height:${height}px`}>
          {[1, 0.75, 0.5, 0.25, 0].map((f) => (
            <span key={f}>{format(top * f)}</span>
          ))}
        </div>
        <div
          class="plot"
          style={`height:${height}px`}
          tabIndex={0}
          role="img"
          aria-label={`${title}${latest && single ? `, latest ${format(series[0].value(latest))}` : ''}`}
          onPointerMove={pick}
          onPointerLeave={() => (hover.value = null)}
          onFocus={() => points.length && (hover.value = { id, i: points.length - 1 })}
          onBlur={() => (hover.value = null)}
          onKeyDown={key}
        >
          <svg viewBox={`0 0 ${W} ${height}`} preserveAspectRatio="none" width="100%" height={height} aria-hidden="true">
            {[0, 0.25, 0.5, 0.75, 1].map((f) => (
              <line key={f} x1="0" x2={W} y1={y(top * f)} y2={y(top * f)} class="grid" vector-effect="non-scaling-stroke" />
            ))}
            {drawn.map((s) => s.fills.map((d, i) => <path key={`f${s.label}${i}`} d={d} fill={s.color} fill-opacity="0.1" />))}
            {drawn.map((s) =>
              s.lines.map((d, i) => (
                <path key={`l${s.label}${i}`} d={d} fill="none" stroke={s.color} stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke" />
              )),
            )}
          </svg>
          {points.length === 0 ? (
            <div class="chart-empty">No samples in this range yet</div>
          ) : (
            quiet && max === 0 && <div class="chart-empty">{quiet}</div>
          )}
          {shown && (
            <>
              <div class="crosshair" style={`left:${left}%`} />
              {series.map((s) => (
                <div key={s.label} class="marker" style={`left:${left}%;top:${y(s.value(shown))}px;background:${s.color}`} />
              ))}
              <div class={`tip${left > 60 ? ' flip' : ''}`} style={`left:${left}%`}>
                <div class="tip-time">{fullTime(shown.t)}</div>
                {series.map((s) => (
                  <div key={s.label} class="tip-row">
                    <i style={`background:${s.color}`} />
                    <b>{format(s.value(shown))}</b>
                    <span>{s.label}</span>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
      <div class="x-axis">
        {ticks.map((t, i) => (
          <span key={i} style={`left:${i * 25}%`}>
            {timeLabel(t, range)}
          </span>
        ))}
      </div>
    </figure>
  )
}

export const ranges = [
  [900, 'Last 15 minutes'],
  [3600, 'Last hour'],
  [6 * 3600, 'Last 6 hours'],
  [86400, 'Last day'],
  [7 * 86400, 'Last 7 days'],
]

/** Railway's range button: a clock, the range, and a menu of the others. */
export function RangePicker({ value, onChange }) {
  const label = (ranges.find(([s]) => s === value) || ranges[1])[1]
  return (
    <button
      class="btn sm range"
      aria-label="Time range"
      onClick={(e) => openMenu(e.currentTarget, ranges.map(([s, l]) => [l, s === value ? Check : null, () => onChange(s)]))}
    >
      <Clock /> {label}
      <ChevronDown />
    </button>
  )
}
