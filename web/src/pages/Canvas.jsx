// The project canvas: service cards on a dotted plane that pans, zooms and
// lets cards be dragged, with dashed arrows for variable references.

import { effect, signal } from '@preact/signals'
import { Braces, ChartLine, Copy, Grid3x3, HardDrive, Link, Maximize, Plus, Redo2, Rocket, Settings, SquareTerminal, Trash, Undo2, Workflow, ZoomIn, ZoomOut } from 'lucide-preact'
import { enc, get, patch, post } from '../api.js'
import { edges, services, toast } from '../state.js'
import { closeService, openService, page, panelWidth, privateName, refresh } from '../project.js'
import { attempt, copy, openMenuAt, ServiceIcon, Spinner, Status } from '../ui.jsx'
import { openAdd } from './AddDialog.jsx'
import { removeService } from './ServicePanel.jsx'

// Railway's card: 288 by 144, and 48 more for each volume.
const W = 288
const H = 144
const VOL = 48
const GAP_X = 360
const GAP_Y = 240

const view = signal({ x: 0, y: 0, k: 1 })
const grid = signal(true)
const drag = signal(null)
/** True while the cards glide to the places Auto Layout gave them. */
const arranging = signal(false)

/** Where cards were dropped, until the server's copy catches up. */
const moved = {}
let canvasEl = null
let fittedFor = ''

const heightOf = (svc) => H + svc.volumes.length * VOL

function overlaps(rects, x, y, h) {
  return rects.some((r) => x < r.x + W + 40 && x + W + 40 > r.x && y < r.y + r.h + 40 && y + h + 40 > r.y)
}

/** The first free slot of the grid cards are put on when nobody placed them. */
function freeSlot(rects, h) {
  for (let n = 0; ; n++) {
    const x = 80 + (n % 3) * GAP_X
    const y = 80 + Math.floor(n / 3) * GAP_Y
    if (!overlaps(rects, x, y, h)) return { x, y }
  }
}

function place(list) {
  const now = Date.now()
  const rects = []
  const nodes = []
  const later = []
  for (const svc of list) {
    const m = moved[svc.id]
    if (m && now - m.at < 15000 && (m.x !== svc.x || m.y !== svc.y)) nodes.push({ svc, x: m.x, y: m.y })
    else if (svc.x || svc.y) nodes.push({ svc, x: svc.x, y: svc.y })
    else later.push(svc)
  }
  for (const n of nodes) rects.push({ x: n.x, y: n.y, h: heightOf(n.svc) })
  for (const svc of later) {
    const h = heightOf(svc)
    const at = freeSlot(rects, h)
    rects.push({ ...at, h })
    nodes.push({ svc, ...at })
  }
  return nodes
}

/** A spot for a new card. */
export function nextSpot() {
  const rects = place(services.peek() || []).map((n) => ({ x: n.x, y: n.y, h: heightOf(n.svc) }))
  return freeSlot(rects, H)
}

const clampK = (k) => Math.min(2, Math.max(0.25, k))

function zoomAt(cx, cy, k) {
  const v = view.peek()
  const rect = canvasEl.getBoundingClientRect()
  const px = cx - rect.left
  const py = cy - rect.top
  const next = clampK(k)
  const wx = (px - v.x) / v.k
  const wy = (py - v.y) / v.k
  view.value = { x: px - wx * next, y: py - wy * next, k: next }
}

function zoomBy(f) {
  if (!canvasEl) return
  const rect = canvasEl.getBoundingClientRect()
  zoomAt(rect.left + rect.width / 2, rect.top + rect.height / 2, view.peek().k * f)
}

/** Shows every card, centred, at most at 100 %. */
export function fit() {
  if (!canvasEl) return
  const nodes = place(services.peek() || [])
  const rect = canvasEl.getBoundingClientRect()
  if (nodes.length === 0) {
    view.value = { x: 0, y: 0, k: 1 }
    return
  }
  let x0 = Infinity
  let y0 = Infinity
  let x1 = -Infinity
  let y1 = -Infinity
  for (const n of nodes) {
    x0 = Math.min(x0, n.x)
    y0 = Math.min(y0, n.y)
    x1 = Math.max(x1, n.x + W)
    y1 = Math.max(y1, n.y + heightOf(n.svc))
  }
  const width = rect.width
  // On a phone, readable cards matter more than seeing all of them.
  const least = rect.width < 760 ? 0.55 : 0.25
  const k = Math.max(least, clampK(Math.min(1, (width - 120) / (x1 - x0), (rect.height - 160) / (y1 - y0))))
  // Centred when it fits; otherwise from the top-left card.
  const fitsX = (x1 - x0) * k <= width - 40
  const fitsY = (y1 - y0) * k <= rect.height - 100
  view.value = {
    x: fitsX ? (width - (x1 - x0) * k) / 2 - x0 * k : 20 - x0 * k,
    y: fitsY ? (rect.height - (y1 - y0) * k) / 2 - y0 * k : 64 - y0 * k,
    k,
  }
  // A page opened on a service keeps that card in sight beside its panel.
  const open = page.peek()?.service
  if (open) reveal(open)
}

// Panning with one pointer, pinching with two.
const pointers = new Map()
let gesture = null

function begin() {
  const pts = [...pointers.values()]
  const v = view.peek()
  if (pts.length === 1) gesture = { kind: 'pan', x: pts[0].x, y: pts[0].y, v, moved: false }
  else if (pts.length >= 2) {
    const [a, b] = pts
    gesture = { kind: 'pinch', d: Math.hypot(a.x - b.x, a.y - b.y) || 1, mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2, v, moved: true }
  } else gesture = null
}

function onPointerDown(e) {
  if (e.button !== 0 && e.pointerType === 'mouse') return
  canvasEl.setPointerCapture(e.pointerId)
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
  begin()
  if (gesture) canvasEl.classList.add('panning')
}

function onPointerMove(e) {
  if (!pointers.has(e.pointerId) || !gesture) return
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
  const g = gesture
  if (g.kind === 'pan') {
    const dx = e.clientX - g.x
    const dy = e.clientY - g.y
    if (Math.abs(dx) + Math.abs(dy) > 3) {
      g.moved = true
      if (beforePanel) beforePanel.moved = true
    }
    view.value = { ...g.v, x: g.v.x + dx, y: g.v.y + dy }
    return
  }
  const [a, b] = [...pointers.values()]
  if (!b) return
  const rect = canvasEl.getBoundingClientRect()
  const k = clampK((g.v.k * Math.hypot(a.x - b.x, a.y - b.y)) / g.d)
  const wx = (g.mx - rect.left - g.v.x) / g.v.k
  const wy = (g.my - rect.top - g.v.y) / g.v.k
  const mx = (a.x + b.x) / 2 - rect.left
  const my = (a.y + b.y) / 2 - rect.top
  view.value = { x: mx - wx * k, y: my - wy * k, k }
}

function onPointerUp(e) {
  if (!pointers.has(e.pointerId)) return
  pointers.delete(e.pointerId)
  const g = gesture
  if (pointers.size === 0) {
    canvasEl.classList.remove('panning')
    gesture = null
    // A click on the empty plane closes the service panel, like Railway.
    if (g && g.kind === 'pan' && !g.moved && e.type === 'pointerup' && page.peek()?.service) closeService()
  } else begin()
}

function onWheel(e) {
  e.preventDefault()
  if (beforePanel) beforePanel.moved = true
  const v = view.peek()
  if (e.ctrlKey || e.metaKey) zoomAt(e.clientX, e.clientY, v.k * Math.exp(-e.deltaY * 0.01))
  else view.value = { ...v, x: v.x - e.deltaX, y: v.y - e.deltaY }
}

// Dragging a card; a press that does not move opens it.
let cardGesture = null

function cardDown(e, node) {
  if (e.button !== 0 && e.pointerType === 'mouse') return
  e.stopPropagation()
  e.currentTarget.setPointerCapture(e.pointerId)
  cardGesture = { id: node.svc.id, name: node.svc.name, sx: e.clientX, sy: e.clientY, x: node.x, y: node.y, moved: false }
}

function cardMove(e) {
  const g = cardGesture
  if (!g) return
  if (!g.moved && Math.hypot(e.clientX - g.sx, e.clientY - g.sy) < 5) return
  g.moved = true
  const k = view.peek().k
  drag.value = { id: g.id, x: Math.round(g.x + (e.clientX - g.sx) / k), y: Math.round(g.y + (e.clientY - g.sy) / k) }
}

function cardUp(e) {
  const g = cardGesture
  cardGesture = null
  if (!g) return
  e.stopPropagation()
  if (!g.moved) {
    if (e.type === 'pointerup') openService(g.name)
    return
  }
  const d = drag.peek()
  drag.value = null
  if (!d) return
  let x = grid.peek() ? Math.round(d.x / 20) * 20 : d.x
  const y = grid.peek() ? Math.round(d.y / 20) * 20 : d.y
  // 0,0 means "not placed yet".
  if (x === 0 && y === 0) x = 20
  history.value = { done: [...history.peek().done, { id: g.id, from: { x: g.x, y: g.y }, to: { x, y } }].slice(-50), undone: [] }
  moveTo(g.id, x, y)
}

function moveTo(id, x, y) {
  moved[id] = { x, y, at: Date.now() }
  services.value = [...(services.peek() || [])]
  patch(`/services/${enc(id)}`, { x, y }).catch((err) => toast(err.message, 'error'))
}

/** Card moves that can be undone, as on Railway's canvas. */
const history = signal({ done: [], undone: [] })

function undo() {
  const h = history.peek()
  const last = h.done[h.done.length - 1]
  if (!last) return
  history.value = { done: h.done.slice(0, -1), undone: [...h.undone, last] }
  glide(last.batch, () => {
    for (const m of last.batch || [last]) moveTo(m.id, m.from.x, m.from.y)
  })
}

function redo() {
  const h = history.peek()
  const next = h.undone[h.undone.length - 1]
  if (!next) return
  history.value = { done: [...h.done, next], undone: h.undone.slice(0, -1) }
  glide(next.batch, () => {
    for (const m of next.batch || [next]) moveTo(m.id, m.to.x, m.to.y)
  })
}

/** Runs `move`, letting the cards glide when several of them go at once. */
let glideTimer = 0
function glide(several, move) {
  if (!several) return move()
  clearTimeout(glideTimer)
  arranging.value = true
  move()
  glideTimer = setTimeout(() => (arranging.value = false), 420)
}

const ROW_GAP = 64

/**
 * Arranges the cards by their references, in columns from left to right:
 * the services nobody refers to first, then what they use, so that every
 * arrow points right. Each column is ordered to keep arrows from crossing,
 * and services without any reference go in rows below.
 */
export function layout(list, refs) {
  const names = list.map((s) => s.name)
  const byName = Object.fromEntries(list.map((s) => [s.name, s]))
  const out = {}
  const parents = {}
  for (const n of names) {
    out[n] = []
    parents[n] = []
  }
  for (const { from, to } of refs) {
    if (!(from in out) || !(to in out) || from === to || out[from].includes(to)) continue
    out[from].push(to)
    parents[to].push(from)
  }
  const linked = names.filter((n) => out[n].length || parents[n].length)
  const alone = names.filter((n) => !out[n].length && !parents[n].length)
  // The column: the longest chain of references that leads to the service.
  // A cycle is cut where the walk meets it again.
  const col = {}
  const walking = new Set()
  const depth = (n) => {
    if (n in col) return col[n]
    if (walking.has(n)) return 0
    walking.add(n)
    let d = 0
    for (const p of parents[n]) d = Math.max(d, depth(p) + 1)
    walking.delete(n)
    return (col[n] = d)
  }
  for (const n of linked) depth(n)
  // A service nobody refers to sits just before what it uses: arrows then
  // skip as few columns as possible.
  for (const n of linked) {
    if (parents[n].length === 0 && out[n].length > 0) col[n] = Math.max(0, Math.min(...out[n].map((m) => col[m])) - 1)
  }
  // No empty column left between the others.
  const used = [...new Set(linked.map((n) => col[n]))].sort((a, b) => a - b)
  for (const n of linked) col[n] = used.indexOf(col[n])
  const cols = []
  // Start from where the cards are, so that the order the user chose holds.
  const start = place(list)
  const yOf = Object.fromEntries(start.map((nd) => [nd.svc.name, nd.y]))
  for (const n of [...linked].sort((a, b) => yOf[a] - yOf[b])) (cols[col[n]] = cols[col[n]] || []).push(n)
  for (let i = 0; i < cols.length; i++) cols[i] = cols[i] || []
  // A few sweeps of the barycentre heuristic: each service near the middle
  // of the ones it is linked to in the column beside it.
  const rank = {}
  const index = () => cols.forEach((c) => c.forEach((n, i) => (rank[n] = i)))
  const centre = (n, links) => (links.length ? links.reduce((t, m) => t + rank[m], 0) / links.length : rank[n])
  index()
  for (let pass = 0; pass < 4; pass++) {
    const forward = pass % 2 === 0
    for (let i = forward ? 1 : cols.length - 2; forward ? i < cols.length : i >= 0; i += forward ? 1 : -1) {
      const near = (n) => (forward ? parents[n] : out[n]).filter((m) => col[m] === i + (forward ? -1 : 1))
      const key = Object.fromEntries(cols[i].map((n) => [n, centre(n, near(n))]))
      cols[i].sort((a, b) => key[a] - key[b] || rank[a] - rank[b])
      index()
    }
  }
  const snap = (v) => Math.round(v / 20) * 20
  const heights = cols.map((c) => c.reduce((t, n) => t + heightOf(byName[n]), 0) + Math.max(0, c.length - 1) * ROW_GAP)
  const tallest = Math.max(0, ...heights)
  const at = {}
  cols.forEach((c, i) => {
    let y = 80 + (tallest - heights[i]) / 2
    for (const n of c) {
      at[n] = { x: 80 + i * GAP_X, y: snap(y) }
      y += heightOf(byName[n]) + ROW_GAP
    }
  })
  // The others, in rows of as many cards as the columns above are wide.
  const across = Math.max(3, cols.length)
  let y = linked.length ? 80 + tallest + 120 : 80
  for (let i = 0; i < alone.length; i += across) {
    const row = alone.slice(i, i + across)
    row.forEach((n, j) => (at[n] = { x: 80 + j * GAP_X, y: snap(y) }))
    y += Math.max(...row.map((n) => heightOf(byName[n]))) + ROW_GAP
  }
  return at
}

function autoLayout() {
  const list = services.peek() || []
  if (list.length === 0) return
  const at = layout(list, edges.peek() || [])
  const now = Object.fromEntries(place(list).map((n) => [n.svc.id, { x: n.x, y: n.y }]))
  const batch = []
  for (const svc of list) {
    const to = at[svc.name]
    const from = now[svc.id]
    if (to && (to.x !== from.x || to.y !== from.y)) batch.push({ id: svc.id, from, to })
  }
  if (batch.length === 0) return fit()
  history.value = { done: [...history.peek().done, { batch }].slice(-50), undone: [] }
  glide(batch, () => {
    for (const m of batch) moveTo(m.id, m.to.x, m.to.y)
  })
  setTimeout(fit, 440)
}

addEventListener('keydown', (e) => {
  if (!(e.ctrlKey || e.metaKey) || !page.peek() || page.peek().view !== 'canvas') return
  const t = e.target
  if (t instanceof Element && t.closest('input, textarea, select, [contenteditable], .console')) return
  const k = e.key.toLowerCase()
  if (k === 'z' && !e.shiftKey) undo()
  else if ((k === 'z' && e.shiftKey) || k === 'y') redo()
  else return
  e.preventDefault()
})

function Card({ node, selected, dragging }) {
  const { svc, x, y } = node
  const host = svc.hostnames.find((h) => h !== '*' && !h.startsWith('*.'))
  return (
    <div
      class={`svc${selected ? ' selected' : ''}${dragging ? ' dragging' : ''}`}
      style={`left:${x}px;top:${y}px`}
      onPointerDown={(e) => cardDown(e, node)}
      onPointerMove={cardMove}
      onPointerUp={cardUp}
      onPointerCancel={cardUp}
      onContextMenu={(e) => cardMenu(e, svc)}
    >
      <div class="body">
        <div class="name">
          <ServiceIcon svc={svc} size={22} />
          <span>{svc.name}</span>
        </div>
        {host ? <div class="sub">{host}</div> : svc.hostnames.includes('*') ? <div class="sub">default service</div> : null}
        <div class="foot">
          <Status svc={svc} />
        </div>
      </div>
      {svc.volumes.map((v) => (
        <div class="vol" key={v.name}>
          <HardDrive />
          {v.name}
        </div>
      ))}
    </div>
  )
}

/** Right angles with corners rounded by `r`, as Railway draws its arrows. */
function stepPath(points, r = 5) {
  let d = `M${points[0].x},${points[0].y}`
  for (let i = 1; i < points.length - 1; i++) {
    const [a, p, b] = [points[i - 1], points[i], points[i + 1]]
    const k = Math.min(r, Math.hypot(p.x - a.x, p.y - a.y) / 2, Math.hypot(b.x - p.x, b.y - p.y) / 2)
    const inX = p.x - Math.sign(p.x - a.x) * k
    const inY = p.y - Math.sign(p.y - a.y) * k
    const outX = p.x + Math.sign(b.x - p.x) * k
    const outY = p.y + Math.sign(b.y - p.y) * k
    d += ` L${inX},${inY} Q${p.x},${p.y} ${outX},${outY}`
  }
  const end = points[points.length - 1]
  return `${d} L${end.x},${end.y}`
}

/** Whether the segment from `p` to `q` (level or upright) runs through card `r`. */
function hits(p, q, r) {
  const m = 10
  return Math.min(p.x, q.x) < r.x + r.w + m && Math.max(p.x, q.x) > r.x - m && Math.min(p.y, q.y) < r.y + r.h + m && Math.max(p.y, q.y) > r.y - m
}

const clear = (points, cards) => points.every((p, i) => i === 0 || !cards.some((r) => hits(points[i - 1], p, r)))

/**
 * From the side of `a` that faces `b` to the side of `b` that faces `a`, around
 * the other `cards` ({x, y, w, h}): through the middle, else through the gap
 * beside either end, else above or below what stands between them.
 */
export function route(a, ha, b, hb, offset = 0, cards = []) {
  if (b.x >= a.x + W + 24 || b.x + W + 24 <= a.x) {
    const right = b.x > a.x
    const s = { x: right ? a.x + W : a.x, y: a.y + ha / 2 + offset }
    const t = { x: right ? b.x : b.x + W, y: b.y + hb / 2 + offset }
    const dir = right ? 1 : -1
    const gap = (GAP_X - W) / 2
    const via = (x) => (Math.abs(s.y - t.y) < 1 ? [s, t] : [s, { x, y: s.y }, { x, y: t.y }, t])
    const near = s.x + dir * gap
    const far = t.x - dir * gap
    const tries = [via(Math.round((s.x + t.x) / 2)), via(near), via(far)]
    // Above or below the cards in between, nearest first.
    const between = cards.filter((r) => r.x + r.w > Math.min(near, far) && r.x < Math.max(near, far))
    if (between.length) {
      const top = Math.min(...between.map((r) => r.y)) - 28
      const bottom = Math.max(...between.map((r) => r.y + r.h)) + 28
      const around = (y) => [s, { x: near, y: s.y }, { x: near, y }, { x: far, y }, { x: far, y: t.y }, t]
      const cost = (y) => Math.abs(s.y - y) + Math.abs(t.y - y)
      tries.push(...(cost(top) <= cost(bottom) ? [around(top), around(bottom)] : [around(bottom), around(top)]))
    }
    return stepPath(tries.find((p) => clear(p, cards)) || tries[0])
  }
  const down = b.y > a.y
  const s = { x: a.x + W / 2 + offset, y: down ? a.y + ha : a.y }
  const t = { x: b.x + W / 2 + offset, y: down ? b.y : b.y + hb }
  if (Math.abs(s.x - t.x) < 1) return stepPath([s, { x: s.x, y: t.y }])
  const mid = Math.round((s.y + t.y) / 2)
  return stepPath([s, { x: s.x, y: mid }, { x: t.x, y: mid }, t])
}

function Edges({ nodes }) {
  const at = {}
  for (const n of nodes) at[n.svc.name] = n
  const all = edges.value
  const both = new Set(all.map((e) => `${e.from}>${e.to}`))
  const paths = []
  for (const { from, to } of all) {
    const a = at[from]
    const b = at[to]
    if (!a || !b) continue
    // Two services that refer to each other get two arrows side by side.
    const offset = both.has(`${to}>${from}`) ? (from < to ? -20 : 20) : 0
    const cards = nodes.filter((n) => n !== a && n !== b).map((n) => ({ x: n.x, y: n.y, w: W, h: heightOf(n.svc) }))
    paths.push(<path key={`${from}>${to}`} d={route(a, heightOf(a.svc), b, heightOf(b.svc), offset, cards)} />)
  }
  return (
    <svg class="edges" width="1" height="1" aria-hidden="true">
      <defs>
        <marker id="arrowhead" markerWidth="24" markerHeight="24" viewBox="-10 -10 20 20" markerUnits="strokeWidth" orient="auto-start-reverse" refX="0" refY="0">
          <polyline points="-5,-4 0,0 -5,4 -5,-4" stroke-linecap="round" stroke-linejoin="round" class="arrowhead" />
        </marker>
      </defs>
      <g class="edge-paths" marker-end="url(#arrowhead)">
        {paths}
      </g>
    </svg>
  )
}

/** The width the service panel leaves of the canvas. */
function openWidth(rect) {
  if (rect.width < 760) return rect.width
  const chosen = panelWidth.peek()
  return rect.width - (chosen ? Math.min(chosen, rect.width - 160) : Math.min(904, rect.width * 0.67))
}

// Opening a service moves the canvas so that its card stays in sight beside
// the panel; closing the panel puts the canvas back, unless it was moved.
let beforePanel = null
let shownService = ''
effect(() => {
  const p = page.value
  const name = p && p.view === 'canvas' ? p.service || '' : ''
  if (name === shownService) return
  const was = shownService
  shownService = name
  if (!canvasEl) return
  if (!name) {
    if (beforePanel && !beforePanel.moved) view.value = beforePanel.view
    beforePanel = null
    return
  }
  if (!was) beforePanel = { view: view.peek(), moved: false }
  reveal(name)
})

function reveal(name) {
  const node = place(services.peek() || []).find((n) => n.svc.name === name)
  if (!node || !canvasEl) return
  const rect = canvasEl.getBoundingClientRect()
  const room = openWidth(rect)
  const v = view.peek()
  const left = v.x + node.x * v.k
  const right = left + W * v.k
  if (rect.width >= 760 && left >= 24 && right <= room - 24) return
  const cx = room / 2 - (node.x + W / 2) * v.k
  view.value = { ...v, x: rect.width < 760 ? v.x : cx }
}

export function Canvas() {
  const list = services.value
  const v = view.value
  const d = drag.value
  const p = page.value
  const k = `${p.project}\n${p.env}`
  if (list && fittedFor !== k) {
    fittedFor = k
    requestAnimationFrame(fit)
  }
  const nodes = list ? place(list).map((n) => (d && d.id === n.svc.id ? { ...n, x: d.x, y: d.y } : n)) : []
  const size = 24 * v.k
  return (
    <div
      class={`canvas${grid.value ? ' dots' : ''}`}
      ref={(el) => (canvasEl = el)}
      style={`background-size:${size}px ${size}px;background-position:${v.x}px ${v.y}px`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      onWheel={onWheel}
    >
      <div class={`world${arranging.value ? ' arranging' : ''}`} style={`transform:translate(${v.x}px,${v.y}px) scale(${v.k})`}>
        <Edges nodes={nodes} />
        {nodes.map((n) => (
          <Card key={n.svc.id} node={n} selected={p.service === n.svc.name} dragging={d && d.id === n.svc.id} />
        ))}
      </div>
    </div>
  )
}

export function CanvasOverlay() {
  const list = services.value
  return (
    <>
      {!list && (
        <div class="canvas-empty">
          <Spinner />
        </div>
      )}
      {list && list.length === 0 && (
        <div class="canvas-empty">
          <div class="card card-pad" style="width:min(360px,90%)">
            <b style="display:block;margin-bottom:6px">This environment is empty</b>
            <p class="muted small" style="margin:0 0 14px">Deploy a GitHub repository or a Docker image.</p>
            <button class="btn primary" onClick={() => openAdd()}>
              <Plus /> Add a service
            </button>
          </div>
        </div>
      )}
      <div class="controls">
        <div class="group">
          <button title="Toggle the grid" aria-label="Toggle the grid" onClick={() => (grid.value = !grid.value)}>
            <Grid3x3 />
          </button>
        </div>
        <div class="group">
          <button title="Zoom in" aria-label="Zoom in" onClick={() => zoomBy(1.25)}>
            <ZoomIn />
          </button>
          <button title="Zoom out" aria-label="Zoom out" onClick={() => zoomBy(0.8)}>
            <ZoomOut />
          </button>
          <button title="Fit to screen" aria-label="Fit to screen" onClick={fit}>
            <Maximize />
          </button>
        </div>
        <div class="group">
          <button title="Auto layout" aria-label="Auto layout" onClick={autoLayout} disabled={!list || list.length < 2}>
            <Workflow />
          </button>
        </div>
        <div class="group">
          <button title="Undo (Ctrl+Z)" aria-label="Undo" onClick={undo} disabled={history.value.done.length === 0}>
            <Undo2 />
          </button>
          <button title="Redo (Ctrl+Shift+Z)" aria-label="Redo" onClick={redo} disabled={history.value.undone.length === 0}>
            <Redo2 />
          </button>
        </div>
      </div>
      <div class="stage-actions">
        <button class="btn add" onClick={() => openAdd()}>
          <Plus /> Add
        </button>
      </div>
    </>
  )
}

/** A free service name from what it runs: "owner/api" or "postgres:16" → "api", "postgres". */
export function uniqueName(base) {
  const clean =
    (base || 'service')
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 40) || 'service'
  const taken = new Set((services.peek() || []).map((s) => s.name))
  if (!taken.has(clean)) return clean
  for (let i = 2; ; i++) if (!taken.has(`${clean}-${i}`)) return `${clean}-${i}`
}

export async function createService(body) {
  const p = page.peek()
  const svc = await post('/services', { project: p.project, environment: p.env, ...nextSpot(), ...body })
  await refresh()
  openService(svc.name)
  return svc
}

/** A copy of a service's settings and variables, left for the user to deploy. */
async function duplicate(svc) {
  await attempt(async () => {
    const list = await get(`/services/${enc(svc.id)}/variables`)
    const copyOf = await createService({
      name: uniqueName(svc.name),
      image: svc.image,
      repo: svc.repo,
      branch: svc.branch,
      root_dir: svc.root_dir,
      auto_deploy: svc.auto_deploy,
      build_command: svc.build_command,
      start_command: svc.start_command,
      pre_deploy: svc.pre_deploy,
      port: svc.port,
      health_path: svc.health_path,
      sleep_after_s: svc.sleep_after_s,
      cron: svc.cron,
      backup_schedule: svc.backup_schedule,
      volumes: svc.volumes.map((v) => ({ name: v.name, mount: v.mount })),
      env: list.map((v) => `${v.name}=${v.value}`),
      deploy: false,
    })
    toast(`Duplicated as ${copyOf.name}; deploy it to start it`, 'success')
  })
}

/** Railway's right click on a card. */
function cardMenu(e, svc) {
  e.preventDefault()
  e.stopPropagation()
  cardGesture = null
  const go = (query) => openService(svc.name, query)
  const latest = svc.latest
  const items = []
  if (latest) items.push(['Latest deploy', Rocket, () => go({ logs: latest.number, logtab: latest.status === 'active' ? 'deploy' : undefined })])
  items.push(
    ['View Variables', Braces, () => go({ tab: 'variables' })],
    ['View Metrics', ChartLine, () => go({ tab: 'metrics' })],
    ['View Settings', Settings, () => go({ tab: 'settings' })],
  )
  if (!svc.cron) items.push(['Open Console', SquareTerminal, () => go({ tab: 'console' })])
  items.push(
    null,
    ['Copy private address', Link, () => copy(privateName(svc))],
    ['Duplicate', Copy, () => duplicate(svc)],
    null,
    ['Delete Service', Trash, () => removeService(svc), true],
  )
  openMenuAt(e.clientX, e.clientY, items)
}
