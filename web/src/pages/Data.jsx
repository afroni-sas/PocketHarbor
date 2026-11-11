// The Data tab of a database, as on Railway: its tables, keys or
// collections on the left, a query console and the results on the right.
// Queries run with the database's own client inside its container.

import { computed, effect, signal, untracked } from '@preact/signals'
import { Play, RefreshCw, Table } from 'lucide-preact'
import { enc, get, post } from '../api.js'
import { me, services } from '../state.js'
import { page, serviceId } from '../project.js'
import { count } from './Chart.jsx'
import { Spinner } from '../ui.jsx'

/** Which client the data view uses for an image, as the server decides. */
export function dbKind(svc) {
  const image = (svc.image || '').toLowerCase()
  const repo = image.slice(image.lastIndexOf('/') + 1).split(/[:@]/)[0]
  if (/^postgres|^postgis$|^timescaledb/.test(repo)) return 'postgres'
  if (repo === 'mysql' || repo === 'mariadb') return 'mysql'
  if (/^redis|^valkey$/.test(repo)) return 'redis'
  if (repo === 'mongo') return 'mongo'
  return null
}

const list = signal({ id: '', kind: '', items: null, error: '' })
const selected = signal('')
const query = signal('')
const result = signal(null)
const running = signal(false)

const key = computed(() => {
  const p = page.value
  if (!me.value || !p || !p.service) return ''
  const svc = (services.value || []).find((s) => s.name === p.service)
  if (!svc || !dbKind(svc)) return ''
  const tab = p.tab || 'data'
  return tab === 'data' && svc.status === 'running' ? serviceId(p, p.service) : ''
})

export async function loadList(id) {
  try {
    const d = await get(`/services/${enc(id)}/data`)
    list.value = { id, kind: d.kind, items: d.items, error: d.error }
  } catch (err) {
    list.value = { id, kind: '', items: [], error: err.message }
  }
}

effect(() => {
  const id = key.value
  if (!id) return
  untracked(() => {
    if (list.peek().id !== id) {
      list.value = { id, kind: '', items: null, error: '' }
      selected.value = ''
      query.value = ''
      result.value = null
    }
    loadList(id)
  })
})

async function run(id, text) {
  if (!text.trim() || running.peek()) return
  running.value = true
  const started = performance.now()
  try {
    const r = await post(`/services/${enc(id)}/data/query`, { query: text })
    result.value = { ...r, ms: Math.round(performance.now() - started) }
  } catch (err) {
    result.value = { code: 1, output: err.message, ms: 0 }
  } finally {
    running.value = false
  }
}

const sqlName = (name, quote) => name.split('.').map((part) => quote + part.split(quote).join(quote + quote) + quote).join('.')
const redisString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`

const redisRead = {
  string: (k) => `GET ${k}`,
  hash: (k) => `HGETALL ${k}`,
  list: (k) => `LRANGE ${k} 0 99`,
  set: (k) => `SMEMBERS ${k}`,
  zset: (k) => `ZRANGE ${k} 0 99 WITHSCORES`,
  stream: (k) => `XRANGE ${k} - + COUNT 50`,
}

/** Opens an item: the query that shows it, run at once. */
async function open(id, kind, name) {
  selected.value = name
  let text
  if (kind === 'postgres') text = `select * from ${sqlName(name, '"')} limit 100;`
  else if (kind === 'mysql') text = `select * from ${sqlName(name, '`')} limit 100;`
  else if (kind === 'mongo') {
    const dot = name.indexOf('.')
    text = `db.getSiblingDB(${JSON.stringify(name.slice(0, dot))}).getCollection(${JSON.stringify(name.slice(dot + 1))}).find().limit(50).forEach(function (d) { printjson(d) })`
  } else {
    const k = redisString(name)
    let type = 'string'
    try {
      const r = await post(`/services/${enc(id)}/data/query`, { query: `TYPE ${k}` })
      type = r.output.trim().replace(/^"|"$/g, '')
    } catch {
      // Read it as a string.
    }
    text = `${(redisRead[type] || redisRead.string)(k)}\nTTL ${k}`
  }
  query.value = text
  await run(id, text)
}

/** RFC 4180, as psql --csv writes it. */
export function parseCsv(text) {
  const rows = []
  let row = []
  let field = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"'
        i++
      } else if (ch === '"') quoted = false
      else field += ch
    } else if (ch === '"') quoted = true
    else if (ch === ',') {
      row.push(field)
      field = ''
    } else if (ch === '\n') {
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else if (ch !== '\r') field += ch
  }
  if (field || row.length) {
    row.push(field)
    rows.push(row)
  }
  return rows
}

/** MySQL's --batch: tabs between fields, with \t, \n, \\ and \0 escaped. */
export function parseTsv(text) {
  const unescape = (f) => f.replace(/\\([tn0\\])/g, (_, c) => ({ t: '\t', n: '\n', 0: '\0', '\\': '\\' })[c])
  return text
    .split('\n')
    .filter((line) => line.length)
    .map((line) => line.split('\t').map(unescape))
}

/** A table when the output is one, else null. */
function tableOf(kind, output) {
  if (kind !== 'postgres' && kind !== 'mysql') return null
  const rows = kind === 'postgres' ? parseCsv(output) : parseTsv(output)
  if (rows.length === 0) return null
  const width = rows[0].length
  if (rows.some((r) => r.length !== width)) return null
  return { head: rows[0], rows: rows.slice(1) }
}

function Result({ kind }) {
  const r = result.value
  if (!r) return <div class="empty small">Pick a table on the left, or write a query and press Run.</div>
  const failed = r.code !== 0
  const table = failed ? null : tableOf(kind, r.output)
  const footer = (
    <div class="result-foot">
      {failed ? <span class="status red">Failed</span> : table ? `${count(table.rows.length)} row${table.rows.length === 1 ? '' : 's'}` : 'Done'}
      {r.ms > 0 && ` · ${r.ms} ms`}
      {r.truncated && ' · output cut at 2 MB'}
    </div>
  )
  if (table) {
    return (
      <>
        <div class="result-table">
          <table>
            <thead>
              <tr>
                {table.head.map((h, i) => (
                  <th key={i}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((row, i) => (
                <tr key={i}>
                  {row.map((cell, j) => (
                    <td key={j} title={cell}>
                      {kind === 'mysql' && cell === 'NULL' ? <span class="muted">NULL</span> : cell}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {footer}
      </>
    )
  }
  return (
    <>
      <pre class={`result-text${failed ? ' failed' : ''}`}>{r.output.trim() || (failed ? 'The query failed.' : 'The query ran; it returned nothing.')}</pre>
      {footer}
    </>
  )
}

const nouns = { postgres: 'Tables', mysql: 'Tables', redis: 'Keys', mongo: 'Collections' }
const placeholders = {
  postgres: 'select * from users limit 10;',
  mysql: 'select * from users limit 10;',
  redis: 'GET greeting',
  mongo: 'db.getSiblingDB("app").users.find().limit(10).forEach(printjson)',
}

export function DataTab({ svc }) {
  const kind = dbKind(svc)
  if (svc.status !== 'running') {
    return <div class="card empty">The data view needs the database running.</div>
  }
  const l = list.value
  const mine = l.id === svc.id
  const items = mine ? l.items : null
  return (
    <div class="data-view">
      <aside class="data-list">
        <header>
          <span class="section-title">{nouns[kind]}</span>
          <span class="spacer" />
          <button class="btn ghost icon sm" aria-label="Refresh" onClick={() => loadList(svc.id)}>
            <RefreshCw />
          </button>
        </header>
        {!items ? (
          <div class="empty">
            <Spinner />
          </div>
        ) : items.length === 0 ? (
          <div class="muted small" style="padding:8px">{l.error || `No ${nouns[kind].toLowerCase()} yet.`}</div>
        ) : (
          items.map((it) => (
            <button key={it.name} class={`data-item${selected.value === it.name ? ' on' : ''}`} onClick={() => open(svc.id, kind, it.name)} title={it.name}>
              <Table width={14} height={14} />
              <span class="name">{it.name}</span>
              {it.rows !== null && <span class="muted small">{count(it.rows)}</span>}
            </button>
          ))
        )}
      </aside>
      <section class="data-main">
        <div class="query">
          <textarea
            class="textarea"
            rows={4}
            spellcheck={false}
            placeholder={placeholders[kind]}
            value={query.value}
            onInput={(e) => (query.value = e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
                e.preventDefault()
                run(svc.id, query.peek())
              }
            }}
            aria-label="Query"
          />
          <div class="row">
            <span class="muted small">Ctrl+Enter runs it, inside the container with the database's own client.</span>
            <span class="spacer" />
            <button class="btn sm primary" onClick={() => run(svc.id, query.peek())} disabled={running.value}>
              {running.value ? <span class="spinner" style="width:13px;height:13px" /> : <Play />}
              Run
            </button>
          </div>
        </div>
        <Result kind={kind} />
      </section>
    </div>
  )
}
