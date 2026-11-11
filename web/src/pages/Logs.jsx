// The logs of a deployment, over the canvas: build, deploy (the app's
// output) and HTTP requests, with a search that filters lines.

import { computed, effect, signal, untracked } from '@preact/signals'
import { ArrowLeft, Search, X } from 'lucide-preact'
import { enc, get } from '../api.js'
import { me } from '../state.js'
import { page, setQuery } from '../project.js'
import { Spinner } from '../ui.jsx'

const data = signal({ key: '', text: null, rows: null })
const query = signal('')
let el = null
let stick = true

const logsKey = computed(() => {
  const p = page.value
  if (!me.value || !p || !p.service || !p.logs) return ''
  return `${p.project}.${p.env}.${p.service}\n${p.logs}\n${p.logtab || 'build'}`
})

async function load(key) {
  const [id, number, tab] = key.split('\n')
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

const levelOf = (line) => (/\b(error|fatal|panic|exception|failed)\b/i.test(line) ? ' err' : /\bwarn(ing)?\b/i.test(line) ? ' warn' : '')

function TextLogs({ text, q }) {
  const lines = text.split('\n')
  if (lines[lines.length - 1] === '') lines.pop()
  const shown = q ? lines.filter((l) => l.toLowerCase().includes(q)) : lines
  return (
    <>
      <pre class="logs" ref={(e) => (el = e)} onScroll={onScroll}>
        {shown.length === 0 && <span class="muted">{q ? 'No line matches.' : 'Nothing logged yet.'}</span>}
        {shown.map((l, i) => (
          <div key={i} class={`line${levelOf(l)}`}>
            <Highlight text={l} q={q} />
          </div>
        ))}
      </pre>
      <footer class="logs-foot">{q ? `${shown.length} of ${lines.length} lines` : `${lines.length} lines`}</footer>
    </>
  )
}

const time = (ms) => new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
const statusClass = (s) => (s >= 500 || s === 499 ? 'red' : s >= 400 ? 'yellow' : 'green')

function HttpLogs({ rows, q }) {
  const shown = q ? rows.filter((r) => `${r.method} ${r.host}${r.path} ${r.status} ${r.client}`.toLowerCase().includes(q)) : rows
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
        {shown.length === 0 && <div class="muted">{q ? 'No request matches.' : 'No requests yet.'}</div>}
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

const tabs = [
  ['build', 'Build Logs'],
  ['deploy', 'Deploy Logs'],
  ['http', 'HTTP Logs'],
]

export function LogsView() {
  const p = page.value
  const tab = p.logtab || 'build'
  const d = data.value
  const q = query.value.trim().toLowerCase()
  const ready = d.key === logsKey.value
  return (
    <div class="logs-view">
      <header class="logs-head">
        <button class="btn ghost icon" aria-label="Back to the service" onClick={() => setQuery({ logs: undefined, logtab: undefined })}>
          <ArrowLeft />
        </button>
        <div>
          <b>{p.service}</b>
          <span class="muted small"> · deployment #{p.logs}</span>
        </div>
        <nav class="tabs" style="border:0;margin-left:18px">
          {tabs.map(([id, label]) => (
            <button key={id} class={`tab${tab === id ? ' active' : ''}`} onClick={() => setQuery({ logtab: id === 'build' ? undefined : id }, true)}>
              {label}
            </button>
          ))}
        </nav>
        <span class="spacer" />
        <div class="search" style="width:260px">
          <Search />
          <input class="input" placeholder="Filter logs..." value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} />
        </div>
        <button class="btn ghost icon" aria-label="Close the logs" onClick={() => setQuery({ logs: undefined, logtab: undefined })}>
          <X />
        </button>
      </header>
      {!ready ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : d.rows ? (
        <HttpLogs rows={d.rows} q={q} />
      ) : (
        <TextLogs text={d.text || ''} q={q} />
      )}
    </div>
  )
}
