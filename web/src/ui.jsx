// Shared pieces: dialogs, menus, toasts, and how services look.

import { signal } from '@preact/signals'
import { Box, CircleCheck, CircleX, Clock, Moon, X } from 'lucide-preact'
import {
  siAlpinelinux,
  siCaddy,
  siGhost,
  siGitea,
  siGrafana,
  siMariadb,
  siMinio,
  siMongodb,
  siMysql,
  siN8n,
  siNatsdotio,
  siNextcloud,
  siNginx,
  siNodedotjs,
  siPostgresql,
  siPython,
  siRabbitmq,
  siRedis,
  siTraefikproxy,
  siUptimekuma,
  siWordpress,
} from './brands.js'
import { closeOverlay, overlay, toast, toasts } from './state.js'

export function GithubIcon(props) {
  return (
    <svg viewBox="0 0 16 16" width={props.size || 16} height={props.size || 16} fill="currentColor" class={props.class} aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  )
}

// Products by the name of their image, drawn with their own logo as Railway
// does. The logos come from Simple Icons (CC0), through src/brands.js.
const brands = [
  [/^(postgres|postgis|timescaledb)/, siPostgresql],
  [/^(redis|valkey)/, siRedis],
  [/^mysql$/, siMysql],
  [/^mariadb$/, siMariadb],
  [/^mongo$/, siMongodb],
  [/^minio$/, siMinio],
  [/^nats$/, siNatsdotio],
  [/^nginx/, siNginx],
  [/^node$/, siNodedotjs],
  [/^python$/, siPython],
  [/^alpine$/, siAlpinelinux],
  [/^caddy$/, siCaddy],
  [/^grafana$/, siGrafana],
  [/^rabbitmq$/, siRabbitmq],
  [/^traefik$/, siTraefikproxy],
  [/^n8n$/, siN8n],
  [/^uptime-kuma$/, siUptimekuma],
  [/^gitea$/, siGitea],
  [/^nextcloud$/, siNextcloud],
  [/^wordpress$/, siWordpress],
  [/^ghost$/, siGhost],
]

/** "minio/minio:latest" → "minio": the name of the image, without owner or tag. */
function imageName(image) {
  const last = (image || '').toLowerCase().split('/').pop()
  return last.split(/[:@]/)[0]
}

export function brandOf(svc) {
  const name = imageName(svc.image)
  if (!name) return null
  for (const [re, icon] of brands) if (re.test(name)) return icon
  return null
}

/** A brand colour too dark for the dark background is lightened, keeping its hue. */
function readable(hex) {
  const n = parseInt(hex, 16)
  const c = [(n >> 16) & 255, (n >> 8) & 255, n & 255]
  const light = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
  if (light >= 110) return `#${hex}`
  // Black and near-grey logos become light grey; colours move halfway to white.
  const grey = Math.max(...c) - Math.min(...c) < 24
  const mix = grey ? 0.85 : light < 50 ? 0.6 : 0.45
  return `rgb(${c.map((v) => Math.round(v + (255 - v) * mix)).join(',')})`
}

export function BrandIcon({ icon, size = 18 }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill={readable(icon.hex)} role="img" aria-label={icon.title}>
      <path d={icon.path} />
    </svg>
  )
}

/** The icon of a service: its repository, its product, or what it is. */
export function ServiceIcon({ svc, size = 18 }) {
  if (svc.repo) return <GithubIcon size={size} />
  const brand = brandOf(svc)
  if (brand) return <BrandIcon icon={brand} size={size} />
  if (svc.cron) return <Clock width={size} height={size} />
  return <Box width={size} height={size} />
}

/** What the card says about a service: its words, colour and mark. */
export function statusOf(svc) {
  const latest = svc.latest
  if (latest && latest.status === 'deploying') {
    return { label: latest.trigger === 'webhook' || svc.repo ? 'Building' : 'Deploying', color: 'purple', mark: 'spin' }
  }
  if (svc.status === 'scheduled') {
    const last = svc.last_run
    if (last && last.started_at && !last.finished_at) return { label: 'Running', color: 'purple', mark: 'spin' }
    if (last && last.finished_at) {
      return last.exit_code === 0
        ? { label: 'Completed', color: 'green', mark: 'check' }
        : { label: `Failed (exit ${last.exit_code})`, color: 'red', mark: 'x' }
    }
    return { label: `Cron ${svc.cron}`, color: 'gray', mark: 'clock' }
  }
  switch (svc.status) {
    case 'running': return { label: 'Online', color: 'green', mark: 'dot' }
    case 'restarting': return { label: 'Restarting', color: 'yellow', mark: 'spin' }
    case 'asleep': return { label: 'Sleeping', color: 'gray', mark: 'moon' }
    case 'exited': return { label: 'Crashed', color: 'red', mark: 'x' }
    case 'failed': return { label: latest && latest.status === 'failed' ? 'Deploy failed' : 'Failed', color: 'red', mark: 'x' }
    case 'new': return { label: 'No deployments', color: 'gray', mark: 'dot' }
    default: return { label: svc.status, color: 'gray', mark: 'dot' }
  }
}

/** Railway's marks: a dot in a halo, a check, a cross, a spinner. */
export function StatusMark({ mark, color }) {
  if (mark === 'spin') return <span class={`status-spin ${color}`} aria-hidden="true" />
  if (mark === 'check') return <CircleCheck class="status-icon" aria-hidden="true" />
  if (mark === 'x') return <CircleX class="status-icon" aria-hidden="true" />
  if (mark === 'moon') return <Moon class="status-icon" aria-hidden="true" />
  if (mark === 'clock') return <Clock class="status-icon" aria-hidden="true" />
  return (
    <svg class="status-dot" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="8" cy="8" r="3" />
      <circle cx="8" cy="8" r="6.25" class="halo" />
    </svg>
  )
}

export function Status({ svc }) {
  const s = statusOf(svc)
  return (
    <span class={`status ${s.color}`}>
      <StatusMark mark={s.mark} color={s.color} />
      {s.label}
    </span>
  )
}

export function timeAgo(seconds) {
  if (!seconds) return ''
  const d = Date.now() / 1000 - seconds
  if (d < 45) return 'just now'
  if (d < 3600) return `${Math.round(d / 60)} minutes ago`.replace(/^1 minutes/, '1 minute')
  if (d < 86400) return `${Math.round(d / 3600)} hours ago`.replace(/^1 hours/, '1 hour')
  return `${Math.round(d / 86400)} days ago`.replace(/^1 days/, '1 day')
}

export function size(n) {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(1)} GB`
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(1)} MB`
  return `${Math.max(1, Math.round(n / 1024))} KB`
}

export function Spinner() {
  return <span class="spinner" />
}

export function Modal({ title, children, wide }) {
  return (
    <div class="backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="modal" style={wide ? 'width:min(720px,100%)' : ''} role="dialog" aria-label={title}>
        <header>
          <h3>{title}</h3>
          <span class="spacer" />
          <button class="btn ghost icon sm" onClick={closeOverlay} aria-label="Close">
            <X />
          </button>
        </header>
        {children}
      </div>
    </div>
  )
}

/** The values of a form's named fields; checkboxes become booleans. */
export function values(form) {
  const out = {}
  for (const el of form.elements) {
    if (!el.name) continue
    out[el.name] = el.type === 'checkbox' ? el.checked : el.value
  }
  return out
}

/** A dialog with a form. `onSubmit` gets the values; an error stays in it. */
export function openForm({ title, submit = 'Save', danger = false, wide = false, render, onSubmit }) {
  const busy = signal(false)
  const error = signal('')
  const handle = async (e) => {
    e.preventDefault()
    busy.value = true
    error.value = ''
    try {
      const keep = await onSubmit(values(e.currentTarget), e.currentTarget)
      if (keep !== true) closeOverlay()
    } catch (err) {
      error.value = err.message
    } finally {
      busy.value = false
    }
  }
  overlay.value = () => (
    <Modal title={title} wide={wide}>
      <form onSubmit={handle}>
        <div class="body">
          {render()}
          {error.value && <div class="error-text">{error.value}</div>}
        </div>
        <footer>
          <button type="button" class="btn" onClick={closeOverlay}>Cancel</button>
          <button class={`btn ${danger ? 'danger' : 'primary'}`} disabled={busy.value}>
            {busy.value && <span class="spinner" style="width:13px;height:13px" />}
            {submit}
          </button>
        </footer>
      </form>
    </Modal>
  )
}

export function confirm({ title, body, action = 'Confirm', danger = true, onConfirm }) {
  openForm({ title, submit: action, danger, render: () => <p style="margin:0" class="muted">{body}</p>, onSubmit: onConfirm })
}

/** A menu under `anchor`, each item [label, icon, onClick, danger]. */
export function openMenu(anchor, items) {
  const r = anchor.getBoundingClientRect()
  const left = Math.min(r.left, innerWidth - 230)
  const top = r.bottom + 4
  overlay.value = () => (
    <div style="position:fixed;inset:0;z-index:55" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="menu" style={`left:${left}px;top:${top}px`}>
        {items.map((item, i) => {
          if (!item) return <div key={i} class="divider" />
          if (typeof item === 'string') return <div key={i} class="menu-label">{item}</div>
          const [label, Icon, onClick, danger] = item
          return (
            <div key={i} class={`menu-item${danger ? ' danger' : ''}`} onClick={() => { closeOverlay(); onClick() }}>
              {Icon && <Icon />}
              {label}
            </div>
          )
        })}
      </div>
    </div>
  )
}

export async function attempt(fn, done) {
  try {
    await fn()
    if (done) toast(done, 'success')
  } catch (err) {
    toast(err.message, 'error')
  }
}

export function copy(text) {
  navigator.clipboard?.writeText(text).then(() => toast('Copied', 'success'), () => toast('Could not copy', 'error'))
}

// Browsers honour `autofocus` only while the page loads; dialogs and rows
// added later get the focus here.
new MutationObserver((records) => {
  for (const r of records) {
    for (const n of r.addedNodes) {
      if (n.nodeType !== 1) continue
      const el = n.hasAttribute('autofocus') ? n : n.querySelector('[autofocus]')
      if (el) {
        el.focus()
        return
      }
    }
  }
}).observe(document.body, { childList: true, subtree: true })

export function Overlays() {
  const Current = overlay.value
  return (
    <>
      {Current && <Current />}
      <div class="toasts" aria-live="polite">
        {toasts.value.map((t) => (
          <div key={t.id} class={`toast ${t.kind}`}>{t.message}</div>
        ))}
      </div>
    </>
  )
}
