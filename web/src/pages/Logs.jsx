// One deployment, as Railway shows it: a panel stacked over the service's,
// with its details, its build log, the app's output and the HTTP requests.

import { computed, effect, signal, untracked } from '@preact/signals'
import { ChevronDown, ChevronRight, CircleCheck, CircleX, Download, EllipsisVertical, Eye, EyeOff, RefreshCw, Search, Undo2, X } from 'lucide-preact'
import { enc, get, post } from '../api.js'
import { me, toast } from '../state.js'
import { page, setQuery } from '../project.js'
import { attempt, GithubIcon, openMenu, ServiceIcon, Spinner, timeAgo } from '../ui.jsx'
import { LevelText, levelOf } from '../loglevel.jsx'
import { AnsiText, parseAnsi, plainOf } from '../ansi.jsx'

const data = signal({ key: '', text: null, rows: null })
const record = signal({ key: '', deployment: null, variables: null })
const query = signal('')
const showVars = signal(false)
const revealVars = signal(false)
let el = null
let stick = true

const tabs = [
  ['details', 'Details'],
  ['build', 'Build Logs'],
  ['deploy', 'Deploy Logs'],
  ['http', 'HTTP Logs'],
]

/** The tab when the URL names none: what a deployment is mostly opened for. */
const tabOf = (p) => (tabs.some(([id]) => id === p.logtab) ? p.logtab : 'build')

const logsKey = computed(() => {
  const p = page.value
  if (!me.value || !p || !p.service || !p.logs) return ''
  return `${p.project}.${p.env}.${p.service}\n${p.logs}\n${tabOf(p)}`
})

async function loadRecord(id, number) {
  const key = `${id}#${number}`
  if (record.peek().key !== key) record.value = { key, deployment: null, variables: null }
  try {
    const [list, variables] = await Promise.all([get(`/services/${enc(id)}/deployments`), get(`/services/${enc(id)}/deployments/${enc(number)}/variables`)])
    if (record.peek().key !== key) return
    record.value = { key, deployment: list.find((d) => String(d.number) === String(number)) || null, variables }
  } catch {
    // Kept as it was until the next poll.
  }
}

async function load(key) {
  const [id, number, tab] = key.split('\n')
  loadRecord(id, number)
  if (tab === 'details') {
    data.value = { key, text: '', rows: null }
    return
  }
  try {
    let text = null
    let rows = null
    if (tab === 'build') text = await get(`/services/${enc(id)}/deployments/${enc(number)}/log`)
    else if (tab === 'deploy') text = await get(`/services/${enc(id)}/logs?tail=2000`)
    else {
      const raw = await get(`/services/${enc(id)}/http-logs?tail=1000`)
      rows = []
      for (const line of String(raw).split('\n')) {
        if (!line) continue
        try {
          rows.push(JSON.parse(line))
        } catch {
          // A line cut by rotation.
        }
      }
    }
    if (logsKey.peek() !== key) return
    data.value = { key, text, rows }
    requestAnimationFrame(() => {
      if (stick && el) el.scrollTop = el.scrollHeight
    })
  } catch {
    if (logsKey.peek() === key && data.peek().key !== key) data.value = { key, text: '', rows: [] }
  }
}

let timer = 0
effect(() => {
  const key = logsKey.value
  clearInterval(timer)
  if (!key) return
  stick = true
  untracked(() => {
    if (data.peek().key !== key) data.value = { key: '', text: null, rows: null }
    load(key)
  })
  timer = setInterval(() => document.hidden || load(key), 2500)
})

addEventListener('keydown', (e) => {
  if (e.key !== '/' || (e.target instanceof Element && e.target.closest('input, textarea, select, [contenteditable], .console'))) return
  const box = document.getElementById('deploy-logs-search')
  if (box) {
    e.preventDefault()
    box.focus()
  }
})

function onScroll(e) {
  const t = e.currentTarget
  stick = t.scrollTop + t.clientHeight >= t.scrollHeight - 40
}

function Highlight({ text, q }) {
  if (!q) return text
  const out = []
  const lower = text.toLowerCase()
  let at = 0
  for (;;) {
    const i = lower.indexOf(q, at)
    if (i < 0) break
    out.push(text.slice(at, i), <mark key={i}>{text.slice(i, i + q.length)}</mark>)
    at = i + q.length
  }
  out.push(text.slice(at))
  return out
}


/** Railway's empty and loading state: a sketch of a log, and a sentence. */
function Waiting({ title, text }) {
  return (
    <div class="waiting">
      <div class="sketch" aria-hidden="true">
        {[70, 45, 85, 55, 30, 65].map((w, i) => (
          <span key={i} style={`width:${w}%`} />
        ))}
      </div>
      <b>{title}</b>
      <span>{text}</span>
    </div>
  )
}

/** What a terminal would show of a line that progress bars rewrite with \r. */
function lastState(line) {
  if (!line.includes('\r')) return line
  const parts = line.split('\r').filter((p) => p.trim())
  return parts.length ? parts[parts.length - 1].trimEnd() : ''
}

function TextLogs({ text, q, tab }) {
  const lines = text.split('\n').map(lastState).map((raw) => {
    const runs = parseAnsi(raw)
    return { runs, plain: plainOf(raw, runs) }
  })
  if (lines.length && lines[lines.length - 1].plain === '') lines.pop()
  const shown = q ? lines.filter((l) => l.plain.toLowerCase().includes(q)) : lines
  if (lines.length === 0) {
    return tab === 'deploy' ? <Waiting title="No output yet" text="What the app prints appears here as it runs." /> : <Waiting title="No build log" text="This deployment wrote nothing yet." />
  }
  return (
    <>
      <pre class="logs" ref={(e) => (el = e)} onScroll={onScroll}>
        {shown.length === 0 && <span class="muted">No line matches.</span>}
        {shown.map((l, i) => {
          const info = levelOf(l.plain)
          const mark = (t, k) => <Highlight key={k} text={t} q={q} />
          return (
            <div key={i} class={`line${info.level === 'error' ? ' err' : ''}`}>
              {/* A line the app coloured keeps its own colours. */}
              {l.runs ? <AnsiText runs={l.runs} mark={mark} /> : <LevelText text={l.plain} info={info} mark={mark} />}
            </div>
          )
        })}
      </pre>
      <footer class="logs-foot">{q ? `${shown.length} of ${lines.length} lines` : `${lines.length} lines`}</footer>
    </>
  )
}

const time = (ms) => new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
const statusClass = (s) => (s >= 500 || s === 499 ? 'red' : s >= 400 ? 'yellow' : 'green')

function HttpLogs({ rows, q }) {
  const shown = q ? rows.filter((r) => `${r.method} ${r.host}${r.path} ${r.status} ${r.client}`.toLowerCase().includes(q)) : rows
  if (rows.length === 0) return <Waiting title="No requests yet" text="Requests through the proxy appear here, with their status and time." />
  return (
    <>
      <div class="logs" ref={(e) => (el = e)} onScroll={onScroll}>
        <div class="http-row head">
          <span>Time</span>
          <span>Method</span>
          <span>Status</span>
          <span>Path</span>
          <span>Duration</span>
          <span>Client</span>
        </div>
        {shown.length === 0 && <div class="muted">No request matches.</div>}
        {shown.map((r, i) => (
          <div key={i} class="http-row">
            <span class="muted">{time(r.ts)}</span>
            <span>{r.method}</span>
            <span class={`status ${statusClass(r.status)}`}>{r.status}</span>
            <span title={r.host + r.path}>
              <span class="muted">{r.host}</span>
              <Highlight text={r.path} q={q} />
            </span>
            <span class="muted">{r.ms} ms</span>
            <span class="muted">{r.client}</span>
          </div>
        ))}
      </div>
      <footer class="logs-foot">{q ? `${shown.length} of ${rows.length} requests` : `${rows.length} requests`}</footer>
    </>
  )
}

function seconds(n) {
  if (n < 60) return `${n}s`
  return `${Math.floor(n / 60)}m ${n % 60}s`
}

function Item({ label, value, mono }) {
  return (
    <div class="kv">
      <span>{label}</span>
      <b class={mono ? 'mono' : ''}>{value || '—'}</b>
    </div>
  )
}

function Details({ svc }) {
  const r = record.value
  const d = r.deployment
  if (!d) return <Waiting title="Loading the deployment" text="Give it a moment." />
  // The service's own variables first, then those PocketHarbor adds.
  const all = r.variables || []
  const vars = [...all.filter((v) => !v.name.startsWith('PHARBOR_')), ...all.filter((v) => v.name.startsWith('PHARBOR_'))]
  const ok = d.status === 'active' || d.status === 'removed' || d.status === 'completed'
  return (
    <div class="deploy-detail">
      <div class={`detail-state ${d.status === 'failed' ? 'red' : d.status === 'deploying' ? 'purple' : 'green'}`}>
        {d.status === 'failed' ? <CircleX /> : d.status === 'deploying' ? <span class="status-spin" /> : <CircleCheck />}
        <span>{d.status === 'failed' ? `Deployment failed${d.reason ? `: ${d.reason}` : ''}` : d.status === 'deploying' ? 'Deploying' : d.status === 'completed' ? 'Completed: the task ran and exited with code 0' : ok ? 'Deployment successful' : d.status}</span>
        <span class="spacer" />
        {d.finished_at > 0 && <span class="muted small">took {seconds(Math.max(1, d.finished_at - d.created_at))}</span>}
      </div>

      <button class="detail-fold" onClick={() => (showVars.value = !showVars.value)} aria-expanded={showVars.value}>
        {showVars.value ? <ChevronDown width={14} height={14} /> : <ChevronRight width={14} height={14} />}
        {vars.length} Variables
        <span class="muted small">as this deployment ran with them</span>
      </button>
      {showVars.value && (
        <div class="detail-vars">
          <div class="row" style="justify-content:flex-end">
            <button class="btn ghost sm" onClick={() => (revealVars.value = !revealVars.value)}>
              {revealVars.value ? <EyeOff /> : <Eye />} {revealVars.value ? 'Hide values' : 'Show values'}
            </button>
          </div>
          {vars.map((v) => (
            <div class="kv" key={v.name}>
              <span class="mono">{v.name}</span>
              <b class="mono">{revealVars.value ? v.value : '*******'}</b>
            </div>
          ))}
        </div>
      )}

      <h4>{svc.repo ? 'Deployed via GitHub' : 'Deployed via Docker Image'}</h4>
      <div class="source-card">
        {svc.repo ? <GithubIcon size={18} /> : <ServiceIcon svc={{ image: d.image }} size={18} />}
        <div class="what">
          <span class="mono">{svc.repo ? `${svc.repo}@${svc.branch}` : d.image}</span>
          <span class="muted small">
            {d.commit ? `${d.commit} · ${d.message || 'no message'}` : `#${d.number} · ${timeAgo(d.created_at)} via ${d.trigger}`}
          </span>
        </div>
      </div>

      <h4>Configuration</h4>
      <div class="detail-grid">
        <div class="card card-pad">
          <b class="detail-card-title">Build</b>
          <Item label="Builder" value={svc.repo ? (svc.build_command ? 'Custom command' : 'Detected from the repository') : 'Pulled image'} />
          {svc.repo && <Item label="Root directory" value={svc.root_dir || '/'} mono />}
          {svc.build_command && <Item label="Build command" value={svc.build_command} mono />}
          <Item label="Image" value={d.image} mono />
        </div>
        <div class="card card-pad">
          <b class="detail-card-title">Deploy</b>
          <Item label="Runs on" value="This phone" />
          <Item label="Port" value={svc.port ? String(svc.port) : 'Detected'} />
          <Item label="Healthcheck path" value={svc.health_path} mono />
          <Item label="Healthcheck timeout" value={`${svc.health_timeout_s || 180} s`} />
          {svc.start_command && <Item label="Start command" value={svc.start_command} mono />}
          {svc.pre_deploy && <Item label="Pre-deploy" value={svc.pre_deploy} mono />}
          {!svc.cron && <Item label="Restart policy" value={restartLabel(svc)} />}
          {svc.sleep_after_s > 0 && <Item label="Sleeps after" value={`${svc.sleep_after_s} s idle`} />}
          <Item label="Container" value={d.container} mono />
        </div>
      </div>
    </div>
  )
}

function restartLabel(svc) {
  if (svc.restart_policy === 'always') return 'Always'
  if (svc.restart_policy === 'never') return 'Never'
  return `On Failure, ${svc.restart_retries} tries`
}

function download(name, text) {
  const a = document.createElement('a')
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }))
  a.download = name
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

const badges = { active: ['Active', 'green'], completed: ['Completed', 'green'], removed: ['Removed', 'gray'], failed: ['Failed', 'red'], deploying: ['Deploying', 'purple'] }

export function LogsView({ svc }) {
  const p = page.value
  const tab = tabOf(p)
  const d = data.value
  const q = query.value.trim().toLowerCase()
  const ready = d.key === logsKey.value
  const dep = record.value.deployment
  const [label, color] = (dep && badges[dep.status]) || ['', 'gray']
  const close = () => setQuery({ logs: undefined, logtab: undefined })
  const menu = (e) =>
    openMenu(e.currentTarget, [
      dep && (dep.status === 'active' || dep.status === 'completed') && ['Redeploy', RefreshCw, () => attempt(() => post(`/services/${enc(svc.id)}/redeploy`, { number: dep.number }).then(close), 'Redeploying')],
      dep && dep.status === 'removed' && ['Rollback to this deployment', Undo2, () => attempt(() => post(`/services/${enc(svc.id)}/rollback`, { number: dep.number }).then(close), 'Rolling back')],
      dep && dep.status === 'failed' && ['Retry', RefreshCw, () => attempt(() => post(`/services/${enc(svc.id)}/deploy`).then(close), 'Deploying')],
      ['Download this log', Download, () => (d.text ? download(`${svc.name}-${p.logs}-${tab}.log`, d.text) : toast('Nothing to download', 'info'))],
    ].filter(Boolean))
  const host = svc.hostnames.find((h) => h !== '*')
  return (
    <aside class="deploy-view" aria-label={`Deployment ${p.logs} of ${svc.name}`}>
      <header class="deploy-view-head">
        <div class="panel-title">
          <ServiceIcon svc={svc} size={22} />
          <h2>
            {svc.name} <span class="muted">/</span> <span class="mono">#{p.logs}</span>
          </h2>
          {label && <span class={`deploy-badge ${color}`}>{label}</span>}
          <span class="spacer" />
          {dep && <span class="muted small deploy-view-date" title={new Date(dep.created_at * 1000).toLocaleString()}>{new Date(dep.created_at * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}</span>}
          <button class="btn ghost icon sm" aria-label="Deployment actions" onClick={menu}>
            <EllipsisVertical />
          </button>
          <button class="btn ghost icon" aria-label="Close the deployment" title="Close (Esc)" onClick={close}>
            <X />
          </button>
        </div>
        {host && <div class="muted small deploy-view-host">{host}</div>}
        <nav class="tabs">
          {tabs.map(([id, text]) => (
            <button key={id} class={`tab${tab === id ? ' active' : ''}`} onClick={() => setQuery({ logtab: id === 'build' ? undefined : id }, true)}>
              {text}
            </button>
          ))}
        </nav>
      </header>
      {tab !== 'details' && (
        <div class="deploy-view-tools">
          <div class="search filter">
            <Search />
            <input class="input" id="deploy-logs-search" placeholder="Filter and search logs" value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} />
            <kbd class="kbd">/</kbd>
          </div>
          <button class="btn icon sm" aria-label="Download" title="Download" onClick={() => d.text && download(`${svc.name}-${p.logs}-${tab}.log`, d.text)} disabled={!d.text}>
            <Download />
          </button>
        </div>
      )}
      <div class="deploy-view-body">
        {tab === 'details' ? (
          <Details svc={svc} />
        ) : !ready ? (
          <Waiting title="Your logs are loading..." text="Give us a moment to fetch your logs." />
        ) : d.rows ? (
          <HttpLogs rows={d.rows} q={q} />
        ) : (
          <TextLogs text={d.text || ''} q={q} tab={tab} />
        )}
      </div>
    </aside>
  )
}
