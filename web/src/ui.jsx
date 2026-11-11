// Shared pieces: dialogs, menus, toasts, and how services look.

import { signal } from '@preact/signals'
import { Box, Clock, Database, Moon, X } from 'lucide-preact'
import { closeOverlay, overlay, toast, toasts } from './state.js'

export function GithubIcon(props) {
  return (
    <svg viewBox="0 0 16 16" width={props.size || 16} height={props.size || 16} fill="currentColor" class={props.class} aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  )
}

const databases = [
  [/postgres/, 'hsl(210, 60%, 62%)'],
  [/mysql|mariadb/, 'hsl(200, 70%, 60%)'],
  [/redis/, 'hsl(1, 70%, 60%)'],
  [/mongo/, 'hsl(120, 45%, 55%)'],
  [/minio/, 'hsl(350, 70%, 60%)'],
  [/nats/, 'hsl(160, 60%, 50%)'],
]

/** The icon and colour of a service, from what it runs. */
export function ServiceIcon({ svc, size = 18 }) {
  if (svc.repo) return <GithubIcon size={size} />
  if (svc.cron) return <Clock width={size} height={size} />
  const image = (svc.image || '').toLowerCase()
  for (const [re, color] of databases) {
    if (re.test(image)) return <Database width={size} height={size} color={color} />
  }
  return <Box width={size} height={size} />
}

/** What the card says about a service, and in which colour. */
export function statusOf(svc) {
  const latest = svc.latest
  if (latest && latest.status === 'deploying') return { label: latest.trigger === 'webhook' ? 'Building from a push' : 'Deploying', color: 'purple' }
  if (svc.status === 'scheduled') {
    const last = svc.last_run
    if (last && last.started_at && !last.finished_at) return { label: 'Running', color: 'purple' }
    if (last && last.finished_at) return { label: last.exit_code === 0 ? 'Last run succeeded' : `Last run failed (${last.exit_code})`, color: last.exit_code === 0 ? 'green' : 'red' }
    return { label: `Cron ${svc.cron}`, color: 'gray' }
  }
  switch (svc.status) {
    case 'running': return { label: 'Online', color: 'green' }
    case 'restarting': return { label: 'Restarting', color: 'yellow' }
    case 'asleep': return { label: 'Sleeping', color: 'gray', icon: Moon }
    case 'exited': return { label: 'Crashed', color: 'red' }
    case 'failed': return { label: latest && latest.status === 'failed' ? 'Deploy failed' : 'Failed', color: 'red' }
    case 'new': return { label: 'No deploys yet', color: 'gray' }
    default: return { label: svc.status, color: 'gray' }
  }
}

export function Status({ svc }) {
  const s = statusOf(svc)
  return (
    <span class={`status ${s.color}`}>
      <span class={`dot ${s.color}`} />
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
