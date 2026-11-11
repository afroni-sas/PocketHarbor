// Settings > Alerts: where alerts go (Discord, Slack, email, webhooks),
// which events each channel gets, the resource thresholds, and the latest
// deliveries.

import { effect, signal, untracked } from '@preact/signals'
import { EllipsisVertical, Hash, Mail, MessageCircle, Pencil, Plus, Send, Trash, Webhook } from 'lucide-preact'
import { del, get, patch, post, put } from '../api.js'
import { me, toast } from '../state.js'
import { route } from '../router.js'
import { attempt, confirm, openForm, openMenu, Spinner, timeAgo } from '../ui.jsx'

const data = signal(null)
const log = signal(null)
const newKind = signal('discord')
const testing = signal('')

export const eventLabels = {
  deploy_failed: 'Deploy failed',
  deploy_succeeded: 'Deploy succeeded',
  crashed: 'Service crashed',
  cron_failed: 'Cron run failed',
  backup_failed: 'Backup failed',
  high_cpu: 'High CPU',
  high_memory: 'High memory',
  high_disk: 'High volume usage',
  test: 'Test',
}

const kinds = {
  discord: { label: 'Discord', icon: MessageCircle, placeholder: 'https://discord.com/api/webhooks/...', hint: 'Channel settings, Integrations, Webhooks, New Webhook, Copy Webhook URL.' },
  slack: { label: 'Slack', icon: Hash, placeholder: 'https://hooks.slack.com/services/...', hint: 'An incoming webhook of a Slack app, for one channel.' },
  email: { label: 'Email', icon: Mail, placeholder: 're_...', hint: 'Sent through Resend: paste an API key; the sender must use a domain verified there.' },
  webhook: { label: 'Webhook', icon: Webhook, placeholder: 'https://example.com/hooks/pocketharbor', hint: 'A JSON POST for each event, signed with HMAC-SHA256 when a secret is set.' },
}

export async function loadAlerts() {
  try {
    const [d, l] = await Promise.all([get('/alerts'), get('/alerts/log')])
    data.value = d
    log.value = l
  } catch (err) {
    toast(err.message, 'error')
  }
}

effect(() => {
  if (me.value && route.value.path === '/settings' && route.value.query.tab === 'alerts') untracked(loadAlerts)
})

function EventChecks({ selected }) {
  const all = data.peek().events
  return (
    <div class="checks">
      {all.map((e) => (
        <label class="check" key={e}>
          <input type="checkbox" name={`ev:${e}`} defaultChecked={selected.includes(e)} />
          {eventLabels[e] || e}
        </label>
      ))}
    </div>
  )
}

const chosen = (form) =>
  Object.entries(form)
    .filter(([k, v]) => k.startsWith('ev:') && v === true)
    .map(([k]) => k.slice(3))

const list = (text) =>
  (text || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)

function randomSecret() {
  const bytes = new Uint8Array(24)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
}

function addChannel() {
  newKind.value = 'discord'
  const secret = randomSecret()
  openForm({
    title: 'Add an alert channel',
    submit: 'Add channel',
    wide: true,
    render: () => {
      const k = newKind.value
      const info = kinds[k]
      return (
        <>
          <div class="segmented" role="radiogroup" aria-label="Kind" style="align-self:flex-start">
            {Object.entries(kinds).map(([id, v]) => (
              <button type="button" key={id} role="radio" aria-checked={k === id} class={k === id ? 'on' : ''} onClick={() => (newKind.value = id)}>
                {v.label}
              </button>
            ))}
          </div>
          <div class="field">
            <label for="cname">Name</label>
            <input class="input" id="cname" name="name" defaultValue={`${info.label} alerts`} key={`name-${k}`} required />
          </div>
          <div class="field">
            <label for="ctarget">{k === 'email' ? 'Resend API key' : 'Webhook URL'}</label>
            <input class="input mono" id="ctarget" name="target" type={k === 'email' ? 'password' : 'url'} placeholder={info.placeholder} key={`t-${k}`} required autocomplete="off" />
            <span class="hint">{info.hint}</span>
          </div>
          {k === 'webhook' && (
            <div class="field">
              <label for="csign">Signing secret</label>
              <input class="input mono" id="csign" name="signing" defaultValue={secret} autocomplete="off" />
              <span class="hint">Each request carries X-PocketHarbor-Signature: sha256=HMAC of the body. Leave empty to not sign.</span>
            </div>
          )}
          {k === 'email' && (
            <div class="row" style="gap:12px;align-items:flex-start">
              <div class="field" style="flex:1">
                <label for="cfrom">From</label>
                <input class="input" id="cfrom" name="email_from" placeholder="PocketHarbor <alerts@example.com>" required />
              </div>
              <div class="field" style="flex:1">
                <label for="cto">To</label>
                <input class="input" id="cto" name="email_to" placeholder="me@example.com, ops@example.com" required />
              </div>
            </div>
          )}
          <div class="field">
            <label>Events</label>
            <EventChecks selected={data.peek().defaults} />
          </div>
          <div class="field">
            <label for="cproj">Projects</label>
            <input class="input" id="cproj" name="projects" placeholder="All projects" />
            <span class="hint">Comma-separated project names, to only get their alerts.</span>
          </div>
        </>
      )
    },
    onSubmit: async (f) => {
      const kind = newKind.peek()
      await post('/alerts/channels', {
        name: f.name,
        kind,
        target: f.target,
        signing: f.signing || '',
        email_from: f.email_from || '',
        email_to: list(f.email_to),
        events: chosen(f),
        projects: list(f.projects),
      })
      await loadAlerts()
      toast('Channel added; send it a test', 'success')
    },
  })
}

function editChannel(ch) {
  openForm({
    title: `Edit ${ch.name}`,
    submit: 'Save',
    render: () => (
      <>
        <div class="field">
          <label for="ename">Name</label>
          <input class="input" id="ename" name="name" defaultValue={ch.name} required />
        </div>
        <div class="field">
          <label>Events</label>
          <EventChecks selected={ch.events} />
        </div>
        <div class="field">
          <label for="eproj">Projects</label>
          <input class="input" id="eproj" name="projects" defaultValue={ch.projects.join(', ')} placeholder="All projects" />
        </div>
      </>
    ),
    onSubmit: async (f) => {
      await patch(`/alerts/channels/${ch.id}`, { name: f.name, events: chosen(f), projects: list(f.projects) })
      await loadAlerts()
    },
  })
}

async function test(ch) {
  testing.value = ch.id
  try {
    const res = await post(`/alerts/channels/${ch.id}/test`)
    if (res.ok) toast(`Test sent to ${ch.name}`, 'success')
    else toast(`${ch.name}: ${res.error}`, 'error')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    testing.value = ''
  }
}

function Channel({ ch }) {
  const K = kinds[ch.kind]
  const Icon = K.icon
  const menu = (e) =>
    openMenu(e.currentTarget, [
      ['Edit', Pencil, () => editChannel(ch)],
      null,
      [
        'Delete',
        Trash,
        () =>
          confirm({
            title: `Delete ${ch.name}?`,
            body: 'Its alerts stop.',
            action: 'Delete',
            onConfirm: async () => {
              await del(`/alerts/channels/${ch.id}`)
              await loadAlerts()
            },
          }),
        true,
      ],
    ])
  return (
    <div class="channel">
      <span class="deploy-icon">
        <Icon width={15} height={15} />
      </span>
      <div class="what">
        <b>{ch.name}</b>
        <span class="muted small">
          {K.label} · {ch.kind === 'email' ? ch.email_to.join(', ') : ch.target}
          {ch.projects.length > 0 && ` · ${ch.projects.join(', ')}`}
        </span>
        <span class="muted small">{ch.events.map((e) => eventLabels[e] || e).join(', ') || 'No events'}</span>
      </div>
      <label class="check small" title={ch.enabled ? 'Alerts are sent' : 'Paused'}>
        <input type="checkbox" checked={ch.enabled} onChange={(e) => attempt(() => patch(`/alerts/channels/${ch.id}`, { enabled: e.currentTarget.checked }).then(loadAlerts))} />
        {ch.enabled ? 'On' : 'Paused'}
      </label>
      <button class="btn sm" onClick={() => test(ch)} disabled={testing.value === ch.id}>
        {testing.value === ch.id ? <span class="spinner" style="width:13px;height:13px" /> : <Send />}
        Test
      </button>
      <button class="btn ghost icon sm" aria-label={`${ch.name} menu`} onClick={menu}>
        <EllipsisVertical />
      </button>
    </div>
  )
}

function saveThresholds(e) {
  e.preventDefault()
  const f = e.currentTarget.elements
  const n = (el) => Math.max(0, Math.round(Number(el.value) || 0))
  attempt(async () => {
    const saved = await put('/alerts/thresholds', { cpu_percent: n(f.cpu), memory_mb: n(f.memory), disk_mb: n(f.disk) })
    data.value = { ...data.peek(), thresholds: saved }
  }, 'Thresholds saved')
}

export function Alerts() {
  const d = data.value
  const l = log.value
  if (!d) return <Spinner />
  const th = d.thresholds
  return (
    <>
      <section class="card card-pad set-card">
        <div class="row" style="margin-bottom:12px">
          <h3 style="margin:0">Channels</h3>
          <span class="spacer" />
          <button class="btn sm primary" onClick={addChannel}>
            <Plus /> Add channel
          </button>
        </div>
        {d.channels.length === 0 ? (
          <div class="empty small">No channel yet. Add Discord, Slack, email or a webhook to hear about failed deploys and crashes.</div>
        ) : (
          d.channels.map((ch) => <Channel key={ch.id} ch={ch} />)
        )}
      </section>

      <section class="card card-pad set-card">
        <h3>Thresholds</h3>
        <p class="muted small" style="margin:-6px 0 14px">Checked every 30 seconds for each service. Empty or 0 turns one off.</p>
        <form class="thresholds" onSubmit={saveThresholds} key={`${th.cpu_percent}-${th.memory_mb}-${th.disk_mb}`}>
          <div class="field">
            <label for="tcpu">CPU, average over 5 minutes</label>
            <div class="suffix">
              <input class="input" id="tcpu" name="cpu" type="number" min="0" defaultValue={th.cpu_percent || ''} placeholder="Off" />
              <span>%</span>
            </div>
          </div>
          <div class="field">
            <label for="tmem">Memory</label>
            <div class="suffix">
              <input class="input" id="tmem" name="memory" type="number" min="0" defaultValue={th.memory_mb || ''} placeholder="Off" />
              <span>MB</span>
            </div>
          </div>
          <div class="field">
            <label for="tdisk">Volumes</label>
            <div class="suffix">
              <input class="input" id="tdisk" name="disk" type="number" min="0" defaultValue={th.disk_mb || ''} placeholder="Off" />
              <span>MB</span>
            </div>
          </div>
          <button class="btn primary" style="align-self:flex-end">Save</button>
        </form>
      </section>

      <section class="card card-pad set-card">
        <h3>Recent alerts</h3>
        {!l || l.length === 0 ? (
          <div class="empty small">Nothing sent yet.</div>
        ) : (
          <table class="table">
            <thead>
              <tr>
                <th>When</th>
                <th>Event</th>
                <th>Channel</th>
                <th>Result</th>
              </tr>
            </thead>
            <tbody>
              {l.map((x, i) => (
                <tr key={i}>
                  <td title={new Date(x.t * 1000).toLocaleString()}>{timeAgo(x.t)}</td>
                  <td>
                    {x.title}
                    <div class="muted small">{eventLabels[x.event] || x.event}</div>
                  </td>
                  <td>{x.name}</td>
                  <td>{x.ok ? <span class="badge green">Sent</span> : <span class="badge red" title={x.error}>Failed</span>}{!x.ok && <div class="muted small">{x.error}</div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </>
  )
}
