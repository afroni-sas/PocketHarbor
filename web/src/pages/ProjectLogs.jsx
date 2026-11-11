// Logs of a whole environment: every service's output merged by time, with
// a search done on the phone and a filter per service. Railway's Logs page.

import { computed, effect, signal, untracked } from '@preact/signals'
import { Pause, Play, Search } from 'lucide-preact'
import { enc, get } from '../api.js'
import { me, services } from '../state.js'
import { openService, page } from '../project.js'
import { Spinner } from '../ui.jsx'

const query = signal('')
/** What the server was asked: the search box, after a pause in typing. */
const asked = signal('')
const only = signal('')
const live = signal(true)
const data = signal({ key: '', lines: null, error: '' })
let el = null
let stick = true
let typing = 0

const key = computed(() => {
  const p = page.value
  if (!me.value || !p || p.view !== 'logs') return ''
  return `${p.project}\n${p.env}\n${asked.value}\n${only.value}`
})

async function load(k) {
  const [project, env, q, service] = k.split('\n')
  const params = new URLSearchParams({ tail: q ? '2000' : '300' })
  if (q) params.set('q', q)
  if (service) params.set('service', service)
  try {
    const lines = await get(`/projects/${enc(project)}/environments/${enc(env)}/logs?${params}`)
    if (key.peek() !== k) return
    data.value = { key: k, lines, error: '' }
    requestAnimationFrame(() => {
      if (stick && el) el.scrollTop = el.scrollHeight
    })
  } catch (err) {
    if (key.peek() === k) data.value = { key: k, lines: data.peek().lines || [], error: err.message }
  }
}

let timer = 0
effect(() => {
  const k = key.value
  const on = live.value
  clearInterval(timer)
  if (!k) return
  untracked(() => {
    if (data.peek().key !== k) {
      stick = true
      load(k)
    }
  })
  if (on) timer = setInterval(() => document.hidden || load(k), 3000)
})

function onInput(e) {
  query.value = e.currentTarget.value
  clearTimeout(typing)
  typing = setTimeout(() => (asked.value = query.peek().trim()), 350)
}

function Highlight({ text, q }) {
  if (!q) return text
  const lower = text.toLowerCase()
  const needle = q.toLowerCase()
  const out = []
  let at = 0
  for (;;) {
    const i = lower.indexOf(needle, at)
    if (i < 0) break
    out.push(text.slice(at, i), <mark key={i}>{text.slice(i, i + needle.length)}</mark>)
    at = i + needle.length
  }
  out.push(text.slice(at))
  return out
}

const level = (line) => (/\b(error|fatal|panic|exception|failed)\b/i.test(line) ? ' err' : /\bwarn(ing)?\b/i.test(line) ? ' warn' : '')
const stamp = (ms) => new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })

export function ProjectLogs() {
  const d = data.value
  const ready = d.key === key.value && d.lines
  const names = (services.value || []).filter((s) => s.container || s.deployment > 0).map((s) => s.name)
  const q = asked.value
  return (
    <div class="stage-page logs-page">
      <header class="logs-head">
        <div class="search" style="flex:1;max-width:520px">
          <Search />
          <input class="input" placeholder="Search the logs of every service..." value={query.value} onInput={onInput} aria-label="Search logs" />
        </div>
        <select class="select" style="width:auto;height:32px" value={only.value} onChange={(e) => (only.value = e.currentTarget.value)} aria-label="Service">
          <option value="">All services</option>
          {names.map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
        <span class="spacer" />
        <button class={`btn sm${live.value ? ' active' : ''}`} aria-pressed={live.value} onClick={() => (live.value = !live.value)}>
          {live.value ? <Pause /> : <Play />}
          {live.value ? 'Live' : 'Paused'}
        </button>
      </header>
      {!ready ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : (
        <>
          <div
            class="logs"
            ref={(e) => (el = e)}
            onScroll={(e) => {
              const t = e.currentTarget
              stick = t.scrollTop + t.clientHeight >= t.scrollHeight - 40
            }}
          >
            {d.lines.length === 0 && <span class="muted">{q ? 'No line matches.' : 'Nothing logged yet.'}</span>}
            {d.lines.map((l, i) => (
              <div key={i} class={`line env-line${level(l.text)}`}>
                <span class="muted">{stamp(l.t)}</span>
                <button class="svc-tag" onClick={() => openService(l.service, { tab: undefined })} title={`Open ${l.service}`}>
                  {l.service}
                </button>
                <span class="text">
                  <Highlight text={l.text} q={q} />
                </span>
              </div>
            ))}
          </div>
          <footer class="logs-foot">
            {d.error ? <span class="status red">{d.error}</span> : `${d.lines.length} lines${q ? ` matching “${q}”` : ''}${d.lines.length >= 2000 ? ' (the latest 2,000)' : ''}`}
          </footer>
        </>
      )}
    </div>
  )
}
