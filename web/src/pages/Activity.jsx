// The two buttons at the right of Railway's project bar: the activity of the
// environment (its deployments, newest first) and the notifications (the
// alerts sent lately).

import { signal } from '@preact/signals'
import { Activity, Bell, CircleCheck, CircleX, Settings, X } from 'lucide-preact'
import { enc, get } from '../api.js'
import { closeOverlay, overlay } from '../state.js'
import { navigate } from '../router.js'
import { openService, page } from '../project.js'
import { Spinner, timeAgo } from '../ui.jsx'
import { eventLabels } from './Alerts.jsx'

const events = signal(null)
const alerts = signal(null)

const what = {
  active: 'Deployed',
  completed: 'Ran',
  removed: 'Replaced',
  failed: 'Failed to deploy',
  deploying: 'Deploying',
}

function Mark({ status }) {
  if (status === 'failed') return <CircleX class="feed-mark red" />
  if (status === 'deploying') return <span class="status-spin purple feed-mark" />
  return <CircleCheck class={`feed-mark${status === 'active' || status === 'completed' ? ' green' : ''}`} />
}

/** "Today", "Yesterday" or the date: the headings of the feed. */
function day(t) {
  const d = new Date(t * 1000)
  const today = new Date()
  const y = new Date(today)
  y.setDate(today.getDate() - 1)
  if (d.toDateString() === today.toDateString()) return 'Today'
  if (d.toDateString() === y.toDateString()) return 'Yesterday'
  return d.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' })
}

function Feed() {
  const list = events.value
  const rows = []
  let heading = ''
  for (const e of list || []) {
    const h = day(e.created_at)
    if (h !== heading) {
      heading = h
      rows.push(
        <div key={`h-${h}`} class="feed-day">
          {h}
        </div>,
      )
    }
    rows.push(
      <button
        key={`${e.service}#${e.number}`}
        class="feed-item"
        onClick={() => {
          closeOverlay()
          openService(e.service, { tab: undefined })
        }}
      >
        <Mark status={e.status} />
        <span class="what">
          <span class="line">
            <b>{e.service}</b> {(what[e.status] || e.status).toLowerCase()}
            <span class="muted"> · #{e.number}</span>
          </span>
          <span class="sub">{e.status === 'failed' && e.reason ? e.reason : e.message || e.image}</span>
        </span>
        <time class="muted small" title={new Date(e.created_at * 1000).toLocaleString()}>
          {timeAgo(e.created_at)}
        </time>
      </button>,
    )
  }
  return (
    <div class="drawer-backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <aside class="drawer" aria-label="Activity">
        <header>
          <h3>Activity</h3>
          <span class="spacer" />
          <button class="btn ghost icon sm" aria-label="Close" onClick={closeOverlay}>
            <X />
          </button>
        </header>
        <div class="drawer-body">
          {!list ? (
            <div class="empty">
              <Spinner />
            </div>
          ) : list.length === 0 ? (
            <div class="empty small">Nothing has been deployed in this environment yet.</div>
          ) : (
            rows
          )}
        </div>
      </aside>
    </div>
  )
}

export async function openActivity() {
  const p = page.peek()
  if (!p) return
  events.value = null
  overlay.value = Feed
  try {
    events.value = await get(`/projects/${enc(p.project)}/environments/${enc(p.env)}/activity`)
  } catch {
    events.value = []
  }
}

function Inbox({ left, top }) {
  const list = alerts.value
  return (
    <div style="position:fixed;inset:0;z-index:55" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="menu inbox" style={`left:${left}px;top:${top}px`}>
        <div class="inbox-head">
          <b>Notifications</b>
          <span class="spacer" />
          <button
            class="btn ghost icon sm"
            aria-label="Alert settings"
            title="Alert settings"
            onClick={() => {
              closeOverlay()
              navigate('/settings?tab=alerts')
            }}
          >
            <Settings />
          </button>
        </div>
        {!list ? (
          <div class="empty">
            <Spinner />
          </div>
        ) : list.length === 0 ? (
          <div class="empty small">
            No notifications. Add an alert channel in Settings to hear about crashes and failed deploys.
          </div>
        ) : (
          list.slice(0, 20).map((a, i) => (
            <div key={i} class="inbox-item">
              {a.ok ? <CircleCheck class="feed-mark" /> : <CircleX class="feed-mark red" />}
              <span class="what">
                <b>{a.title}</b>
                <span class="sub">
                  {eventLabels[a.event] || a.event} · {a.name}
                  {!a.ok && ` · not sent: ${a.error}`}
                </span>
              </span>
              <time class="muted small">{timeAgo(a.t)}</time>
            </div>
          ))
        )}
      </div>
    </div>
  )
}

export async function openInbox(anchor) {
  const r = anchor.getBoundingClientRect()
  const left = Math.max(8, Math.min(r.right - 380, innerWidth - 388))
  alerts.value = null
  overlay.value = () => <Inbox left={left} top={r.bottom + 6} />
  try {
    alerts.value = await get('/alerts/log')
  } catch {
    alerts.value = []
  }
}

export function TopActions() {
  return (
    <span class="top-actions">
      <button class="btn ghost icon" aria-label="Activity" title="Activity" onClick={openActivity}>
        <Activity />
      </button>
      <button class="btn ghost icon" aria-label="Notifications" title="Notifications" onClick={(e) => openInbox(e.currentTarget)}>
        <Bell />
      </button>
    </span>
  )
}
