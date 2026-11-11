// The project canvas: service cards on a dotted plane that pans, zooms and
// lets cards be dragged, with dashed arrows for variable references.

import { signal } from '@preact/signals'
import { Box, Grid3x3, HardDrive, Maximize, Plus, Square, ZoomIn, ZoomOut } from 'lucide-preact'
import { enc, patch, post } from '../api.js'
import { edges, services, toast } from '../state.js'
import { closeService, openService, page, refresh } from '../project.js'
import { GithubIcon, openForm, openMenu, ServiceIcon, Spinner, Status } from '../ui.jsx'

const W = 260
const H = 106
const VOL = 36
const GAP_X = 320
const GAP_Y = 200

const view = signal({ x: 0, y: 0, k: 1 })
const grid = signal(true)
const drag = signal(null)

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
  // Keep the right part clear when a service panel covers it.
  const width = page.peek()?.service && rect.width > 760 ? rect.width * 0.38 : rect.width
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
    if (Math.abs(dx) + Math.abs(dy) > 3) g.moved = true
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
  moved[g.id] = { x, y, at: Date.now() }
  services.value = [...services.peek()]
  patch(`/services/${enc(g.id)}`, { x, y }).catch((err) => toast(err.message, 'error'))
}

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
    >
      <div class="body">
        <div class="name">
          <ServiceIcon svc={svc} />
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

function Edges({ nodes }) {
  const at = {}
  for (const n of nodes) at[n.svc.name] = n
  const paths = []
  for (const { from, to } of edges.value) {
    const a = at[from]
    const b = at[to]
    if (!a || !b) continue
    const ha = heightOf(a.svc)
    const hb = heightOf(b.svc)
    let s
    let t
    let horizontal = true
    if (b.x >= a.x + W + 20) {
      s = { x: a.x + W, y: a.y + ha / 2 }
      t = { x: b.x, y: b.y + hb / 2 }
    } else if (b.x + W + 20 <= a.x) {
      s = { x: a.x, y: a.y + ha / 2 }
      t = { x: b.x + W, y: b.y + hb / 2 }
    } else {
      horizontal = false
      const down = b.y > a.y
      s = { x: a.x + W / 2, y: down ? a.y + ha : a.y }
      t = { x: b.x + W / 2, y: down ? b.y : b.y + hb }
    }
    const span = horizontal ? t.x - s.x : t.y - s.y
    const c = Math.max(40, Math.abs(span) / 2) * Math.sign(span || 1)
    const d = horizontal
      ? `M${s.x},${s.y} C${s.x + c},${s.y} ${t.x - c},${t.y} ${t.x},${t.y}`
      : `M${s.x},${s.y} C${s.x},${s.y + c} ${t.x},${t.y - c} ${t.x},${t.y}`
    paths.push(<path key={`${from}>${to}`} d={d} />)
  }
  return (
    <svg class="edges" width="1" height="1" aria-hidden="true">
      <defs>
        <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0,1 L9,5 L0,9" fill="none" stroke="hsl(246, 8%, 45%)" stroke-width="1.5" />
        </marker>
      </defs>
      <g fill="none" stroke="hsl(246, 8%, 40%)" stroke-width="1.5" stroke-dasharray="6 5" marker-end="url(#arrow)">
        {paths}
      </g>
    </svg>
  )
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
      <div class="world" style={`transform:translate(${v.x}px,${v.y}px) scale(${v.k})`}>
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
            <button class="btn primary" onClick={(e) => addMenu(e.currentTarget)}>
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
      </div>
      <div class="stage-actions">
        <button class="btn" onClick={(e) => addMenu(e.currentTarget)}>
          <Plus /> Create
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

const portOf = (text) => (text ? Number(text) : undefined)

function addRepo() {
  openForm({
    title: 'Deploy a GitHub repository',
    submit: 'Deploy',
    render: () => (
      <>
        <div class="field">
          <label for="repo">Repository</label>
          <input class="input mono" id="repo" name="repo" placeholder="owner/name or https://github.com/owner/name" required autofocus />
          <span class="hint">Private repositories need a GitHub token in Settings.</span>
        </div>
        <div class="row" style="gap:12px;align-items:flex-start">
          <div class="field" style="flex:1">
            <label for="branch">Branch</label>
            <input class="input mono" id="branch" name="branch" defaultValue="main" required />
          </div>
          <div class="field" style="flex:1">
            <label for="root_dir">Root directory</label>
            <input class="input mono" id="root_dir" name="root_dir" placeholder="/" />
          </div>
        </div>
        <div class="field">
          <label for="port">Port</label>
          <input class="input mono" id="port" name="port" type="number" min="1" max="65535" placeholder="8080" />
          <span class="hint">Where the app listens. It gets PORT set to this.</span>
        </div>
      </>
    ),
    onSubmit: async (f) => {
      const repo = f.repo.trim().replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '').replace(/\/+$/, '')
      const name = uniqueName(repo.split('/').pop())
      await createService({ name, repo, branch: f.branch.trim(), root_dir: f.root_dir.trim().replace(/^\/+/, ''), port: portOf(f.port), deploy: true })
    },
  })
}

function addImage() {
  openForm({
    title: 'Deploy a Docker image',
    submit: 'Deploy',
    render: () => (
      <>
        <div class="field">
          <label for="image">Image</label>
          <input class="input mono" id="image" name="image" placeholder="nginx:alpine, ghcr.io/owner/app:latest" required autofocus />
        </div>
        <div class="field">
          <label for="port">Port</label>
          <input class="input mono" id="port" name="port" type="number" min="1" max="65535" placeholder="8080" />
          <span class="hint">Where the image listens, if it serves HTTP.</span>
        </div>
      </>
    ),
    onSubmit: async (f) => {
      const image = f.image.trim()
      const base = image.split('@')[0].split('/').pop().split(':')[0]
      await createService({ name: uniqueName(base), image, port: portOf(f.port), deploy: true })
    },
  })
}

function addEmpty() {
  openForm({
    title: 'Empty service',
    submit: 'Create',
    render: () => (
      <div class="field">
        <label for="name">Name</label>
        <input class="input" id="name" name="name" defaultValue={uniqueName('service')} pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required autofocus />
        <span class="hint">Connect a repository or an image in its settings.</span>
      </div>
    ),
    onSubmit: async ({ name }) => {
      await createService({ name, deploy: false })
    },
  })
}

export function addMenu(anchor) {
  openMenu(anchor, [
    'Add to this environment',
    ['GitHub Repo', GithubIcon, addRepo],
    ['Docker Image', Box, addImage],
    ['Empty Service', Square, addEmpty],
  ])
}
