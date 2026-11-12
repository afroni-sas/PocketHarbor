// Logs of a whole environment, as on Railway's Logs page: every service's
// output merged by time, a histogram of the volume with errors in red, a
// search done on the phone, a time range, and live updates.

import { computed, effect, signal, untracked } from '@preact/signals'
import { ArrowDown, ArrowUp, Download, Radio, Search } from 'lucide-preact'
import { enc, get } from '../api.js'
import { me, services } from '../state.js'
import { openService, page } from '../project.js'
import { openMenu, Spinner } from '../ui.jsx'
import { RangePicker } from './Chart.jsx'
import { LevelText, levelOf } from '../loglevel.jsx'

const query = signal('')
/** What the server was asked: the search box, after a pause in typing. */
const asked = signal('')
const only = signal('')
const live = signal(true)
const range = signal(3600)
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
  const params = new URLSearchParams({ tail: q ? '3000' : '1000' })
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

addEventListener('keydown', (e) => {
  if (e.key !== '/' || (e.target instanceof Element && e.target.closest('input, textarea, select, [contenteditable], .console'))) return
  const box = document.getElementById('logs-search')
  if (box) {
    e.preventDefault()
    box.focus()
  }
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

/** Errors: what went to stderr, or says it failed. */

const stamp = (ms) => {
  const d = new Date(ms)
  const pad = (n, w = 2) => String(n).padStart(w, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}
const clock = (ms) => new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

/** Sixty bars over the range, errors stacked on top in red. */
function Histogram({ lines, from, to }) {
  const n = 60
  const width = (to - from) / n
  const all = new Array(n).fill(0)
  const bad = new Array(n).fill(0)
  for (const l of lines) {
    const i = Math.min(n - 1, Math.max(0, Math.floor((l.t - from) / width)))
    all[i]++
    if (levelOf(l.text).level === 'error') bad[i]++
  }
  const top = Math.max(1, ...all)
  return (
    <div class="histogram" aria-hidden="true">
      <div class="bars">
        {all.map((c, i) => (
          <span key={i} class="bar" style={`height:${(c / top) * 100}%`} title={`${c} lines`}>
            {bad[i] > 0 && <span class="bad" style={`height:${(bad[i] / c) * 100}%`} />}
          </span>
        ))}
      </div>
      <div class="ends">
        <span>{clock(from)}</span>
        <span>{clock(to)}</span>
      </div>
    </div>
  )
}

function download(lines) {
  const text = lines.map((l) => `${new Date(l.t).toISOString()} ${l.service} ${l.stream} ${l.text}`).join('\n')
  const a = document.createElement('a')
  a.href = URL.createObjectURL(new Blob([text + '\n'], { type: 'text/plain' }))
  a.download = `${page.peek().project}-${page.peek().env}-logs.txt`
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

function chooseService(e, names) {
  openMenu(e.currentTarget, [
    ['All services', null, () => (only.value = '')],
    null,
    ...names.map((n) => [n, null, () => (only.value = n)]),
  ])
}

export function ProjectLogs() {
  const d = data.value
  const ready = d.key === key.value && d.lines
  const names = (services.value || []).filter((s) => s.container || s.deployment > 0).map((s) => s.name)
  const q = asked.value
  const to = Date.now()
  const from = to - range.value * 1000
  const lines = ready ? d.lines.filter((l) => l.t >= from) : []
  const cut = ready && d.lines.length > lines.length
  return (
    <div class="stage-page logs-page">
      <header class="logs-toolbar">
        <div class="search filter">
          <Search />
          <input class="input" id="logs-search" placeholder="Filter and search logs" value={query.value} onInput={onInput} aria-label="Search logs" />
          <kbd class="kbd">/</kbd>
        </div>
        <button class="btn sm" onClick={(e) => chooseService(e, names)}>
          {only.value || 'All services'}
        </button>
        <button class="btn icon sm" aria-label="Download these logs" title="Download" onClick={() => download(lines)} disabled={!lines.length}>
          <Download />
        </button>
        <RangePicker value={range.value} onChange={(v) => (range.value = v)} />
        <button class={`btn icon sm live${live.value ? ' on' : ''}`} aria-pressed={live.value} aria-label={live.value ? 'Live: on' : 'Live: paused'} title={live.value ? 'Live' : 'Paused'} onClick={() => (live.value = !live.value)}>
          <Radio />
        </button>
      </header>
      {!ready ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : (
        <>
          <Histogram lines={lines} from={from} to={to} />
          <div class="log-columns">
            <span />
            <span>Time</span>
            <span>Service</span>
            <span>Data</span>
          </div>
          <div
            class="logs log-table"
            ref={(e) => (el = e)}
            onScroll={(e) => {
              const t = e.currentTarget
              stick = t.scrollTop + t.clientHeight >= t.scrollHeight - 40
            }}
          >
            {cut && <div class="range-start">You reached the start of the range · {stamp(from)}</div>}
            {lines.length === 0 && <div class="empty small">{q ? `No line matches “${q}” in this range.` : 'Nothing logged in this range.'}</div>}
            {lines.map((l, i) => {
              const info = levelOf(l.text)
              return (
                <div key={i} class={`log-line${info.level === 'error' ? ' err' : ''}`}>
                  <span class="sev" />
                  <span class="time">{stamp(l.t)}</span>
                  <button class="svc-name" onClick={() => openService(l.service, { tab: undefined })} title={`Open ${l.service}`}>
                    {l.service}
                  </button>
                  <span class="text">
                    <LevelText text={l.text} info={info} mark={(t, k) => <Highlight key={k} text={t} q={q} />} />
                  </span>
                </div>
              )
            })}
          </div>
          <div class="scroll-buttons">
            <button class="btn icon sm" aria-label="To the oldest line" onClick={() => el && (el.scrollTop = 0)}>
              <ArrowUp />
            </button>
            <button class="btn icon sm" aria-label="To the newest line" onClick={() => el && ((el.scrollTop = el.scrollHeight), (stick = true))}>
              <ArrowDown />
            </button>
          </div>
          {d.error && <footer class="logs-foot"><span class="status red">{d.error}</span></footer>}
        </>
      )}
    </div>
  )
}
