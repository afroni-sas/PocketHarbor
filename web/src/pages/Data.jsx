// A database's Data tab: its tables (or keys, or collections) as cards, each
// one opening as a grid that pages, sorts, filters and edits in place; a raw
// query bar that runs anything with the database's own client; a Raw view
// of what is shown; and the database's statistics.

import { computed, effect, signal, untracked } from '@preact/signals'
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, Columns3, EllipsisVertical, KeyRound, Pencil, Play, Plus, RefreshCw, Search, Table, Trash, X } from 'lucide-preact'
import { enc, get } from '../api.js'
import { me, services, toast } from '../state.js'
import { page as route, serviceId } from '../project.js'
import { count } from './Chart.jsx'
import { confirm, openForm, openMenu, size, Spinner } from '../ui.jsx'
import * as db from '../data/dialects.js'

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

const SQL = { postgres: true, mysql: true }
const PAGE = 50

// State ------------------------------------------------------------------

/** What the database holds: its tables, keys or collections. */
const list = signal({ id: '', kind: '', items: null, error: '', more: false })
/** Where the view is: home, a table, a key; the page, sort and filter. */
const nav = signal({ sub: 'data', mode: 'home', name: '', page: 1, sort: '', dir: 'asc', filter: '', raw: false, schema: '', search: '' })
/** The open table or collection: its columns and one page of rows. */
const grid = signal({ key: '', meta: null, data: null, error: '', loading: false })
/** The open Redis key. */
const keyView = signal({ name: '', data: null, error: '', loading: false })
/** The raw query bar and what it last returned. */
const raw = signal({ text: '', result: null, running: false, rawView: false })
const statsView = signal({ id: '', data: null, error: '' })
/** The cell being edited in place: "row index/column". */
const editing = signal('')

const current = computed(() => {
  const p = route.value
  if (!me.value || !p || !p.service) return null
  const svc = (services.value || []).find((s) => s.name === p.service)
  if (!svc || !dbKind(svc)) return null
  return (p.tab || 'data') === 'data' && svc.status === 'running' ? { id: serviceId(p, p.service), kind: dbKind(svc) } : null
})

function go(change) {
  nav.value = { ...nav.peek(), ...change }
}

// Loading ----------------------------------------------------------------

export async function loadList(id) {
  const kind = list.peek().kind
  try {
    if (kind === 'redis') {
      const r = await db.redisKeys(id, nav.peek().search ? `*${nav.peek().search}*` : '*')
      list.value = { id, kind, items: r.keys.map(([name, type, ttl]) => ({ name, type, ttl })), error: '', more: r.more, total: r.total }
      return
    }
    const d = await get(`/services/${enc(id)}/data`)
    list.value = { id, kind: d.kind, items: d.items, error: d.error, more: false }
  } catch (err) {
    list.value = { id, kind, items: [], error: err.message, more: false }
  }
}

async function loadGrid(id, kind) {
  const n = nav.peek()
  const key = `${id}\n${n.name}`
  let meta = grid.peek().key === key ? grid.peek().meta : null
  grid.value = { ...grid.peek(), key, meta, loading: true, error: '' }
  try {
    if (kind === 'mongo') {
      const data = await db.mongoPage(id, n.name, { page: n.page, size: PAGE, filter: n.filter || '{}' })
      if (nav.peek().name !== n.name) return
      grid.value = { key, meta: { columns: columnsOf(data.docs) }, data, loading: false, error: '' }
      return
    }
    if (!meta) meta = await db.tableMeta(id, kind, n.name)
    const data = await db.tablePage(id, kind, n.name, meta, { page: n.page, size: PAGE, sort: n.sort, dir: n.dir, filter: n.filter })
    if (nav.peek().name !== n.name) return
    grid.value = { key, meta, data: { total: Number(data.total) || 0, rows: Array.isArray(data.rows) ? data.rows : [] }, loading: false, error: '' }
  } catch (err) {
    grid.value = { key, meta, data: grid.peek().data, loading: false, error: err.message }
  }
}

async function loadKey(id) {
  const name = nav.peek().name
  keyView.value = { ...keyView.peek(), name, loading: true, error: '' }
  try {
    const data = await db.redisKey(id, name)
    keyView.value = { name, data, loading: false, error: '' }
  } catch (err) {
    keyView.value = { name, data: null, loading: false, error: err.message }
  }
}

async function loadStats(id, kind) {
  statsView.value = { id, data: statsView.peek().id === id ? statsView.peek().data : null, error: '' }
  try {
    statsView.value = { id, data: await db.stats(id, kind), error: '' }
  } catch (err) {
    statsView.value = { id, data: null, error: err.message }
  }
}

// A new database starts at its home; changes of view load what they show.
effect(() => {
  const c = current.value
  if (!c) return
  untracked(() => {
    if (list.peek().id !== c.id) {
      list.value = { id: c.id, kind: c.kind, items: null, error: '', more: false }
      nav.value = { sub: 'data', mode: 'home', name: '', page: 1, sort: '', dir: 'asc', filter: '', raw: false, schema: '', search: '' }
      raw.value = { text: '', result: null, running: false, rawView: false }
      grid.value = { key: '', meta: null, data: null, error: '', loading: false }
      loadList(c.id)
    }
  })
})

function refresh(c) {
  const n = nav.peek()
  if (n.sub === 'stats') return loadStats(c.id, c.kind)
  if (n.mode === 'table') return loadGrid(c.id, c.kind)
  if (n.mode === 'key') return loadKey(c.id)
  return loadList(c.id)
}

function openItem(c, name) {
  go({ mode: c.kind === 'redis' ? 'key' : 'table', name, page: 1, sort: '', dir: 'asc', filter: '' })
  editing.value = ''
  if (SQL[c.kind]) raw.value = { ...raw.peek(), text: db.selectAll(c.kind, name), result: null }
  else if (c.kind === 'mongo') raw.value = { ...raw.peek(), text: db.mongoFind(name), result: null }
  else raw.value = { ...raw.peek(), result: null }
  if (c.kind === 'redis') loadKey(c.id)
  else loadGrid(c.id, c.kind)
}

function home(c) {
  go({ mode: 'home', name: '', filter: '' })
  raw.value = { ...raw.peek(), text: '', result: null }
  loadList(c.id)
}

// The raw query bar ----------------------------------------------------------

async function runRaw(c) {
  const text = raw.peek().text
  if (!text.trim() || raw.peek().running) return
  raw.value = { ...raw.peek(), running: true }
  const started = performance.now()
  try {
    const r = await db.rawQuery(c.id, text)
    raw.value = { ...raw.peek(), running: false, result: { ...r, ms: Math.round(performance.now() - started) } }
    // A statement that changed something: what is shown may be stale.
    if (r.code === 0 && nav.peek().mode !== 'home') refresh(c)
  } catch (err) {
    raw.value = { ...raw.peek(), running: false, result: { code: 1, output: err.message, ms: 0 } }
  }
}

const placeholders = {
  postgres: 'SELECT * FROM users LIMIT 10',
  mysql: 'SELECT * FROM users LIMIT 10',
  redis: 'GET greeting',
  mongo: 'db.getSiblingDB("app").users.find().limit(10)',
}

function RawBar({ c, hint }) {
  const r = raw.value
  const lines = Math.min(8, (r.text.match(/\n/g) || []).length + 1)
  return (
    <div class="raw-bar">
      <textarea
        class="input mono"
        rows={lines}
        spellcheck={false}
        placeholder={hint || placeholders[c.kind]}
        value={r.text}
        aria-label="Raw query"
        onInput={(e) => (raw.value = { ...raw.peek(), text: e.currentTarget.value })}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault()
            runRaw(c)
          }
        }}
      />
      <button class="btn sm" onClick={() => runRaw(c)} disabled={r.running || !r.text.trim()} title="Run (Enter; Shift+Enter for a new line)">
        {r.running ? <Spinner /> : <Play />} Run
      </button>
    </div>
  )
}

function RawResult({ c }) {
  const r = raw.value.result
  if (!r) return null
  const failed = r.code !== 0 || (c.kind === 'redis' && /^\(error\)/m.test(r.output || ''))
  const table = failed || raw.value.rawView ? null : db.tableOf(c.kind, r.output || '')
  return (
    <div class="raw-result">
      <div class="raw-result-head">
        <span class={`small ${failed ? 'red' : 'muted'}`}>
          {failed ? 'The query failed' : table ? `${count(table.rows.length)} row${table.rows.length === 1 ? '' : 's'}` : 'Done'}
          {r.ms > 0 && ` · ${r.ms} ms`}
          {r.truncated && ' · cut at 2 MB'}
        </span>
        <span class="spacer" />
        {!failed && SQL[c.kind] && <ViewSwitch on={raw.value.rawView} set={(v) => (raw.value = { ...raw.peek(), rawView: v })} />}
        <button class="btn ghost icon sm" aria-label="Close the result" title="Close" onClick={() => (raw.value = { ...raw.peek(), result: null })}>
          <X />
        </button>
      </div>
      {table ? (
        <div class="db-grid-wrap">
          <table class="db-grid">
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
                    <td key={j} title={cell ?? 'NULL'}>
                      <Cell value={cell} />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <pre class={`raw-text${failed ? ' failed' : ''}`}>{(r.output || '').trim() || (failed ? 'The query failed.' : 'It ran, and returned nothing.')}</pre>
      )}
    </div>
  )
}

/** Table or Raw: the same data as a grid or as JSON. */
function ViewSwitch({ on, set }) {
  return (
    <div class="seg" role="group" aria-label="View">
      <button class={on ? '' : 'on'} onClick={() => set(false)}>
        Table
      </button>
      <button class={on ? 'on' : ''} onClick={() => set(true)}>
        Raw
      </button>
    </div>
  )
}

// Cells ----------------------------------------------------------------------

function Cell({ value }) {
  if (value === null || value === undefined) return <span class="null">NULL</span>
  if (typeof value === 'boolean') return <span class={`bool ${value}`}>{String(value)}</span>
  if (typeof value === 'number') return <span class="num">{String(value)}</span>
  if (typeof value === 'object') {
    if (value.$oid) return <span class="oid">{value.$oid}</span>
    if (value.$date) return <span>{value.$date}</span>
    return <span class="json">{JSON.stringify(value)}</span>
  }
  return String(value)
}

/** The union of the documents' top-level fields, _id first. */
function columnsOf(docs) {
  const seen = new Set(['_id'])
  for (const d of docs || []) for (const k of Object.keys(d)) seen.add(k)
  return [...seen].slice(0, 30).map((name) => ({ name, type: '', pk: name === '_id' }))
}

// Home: the cards ------------------------------------------------------------

const nouns = { postgres: 'Tables', mysql: 'Tables', redis: 'Keys', mongo: 'Collections' }
const searching = signal(false)

function Home({ c }) {
  const l = list.value
  const n = nav.value
  const items = l.id === c.id ? l.items : null
  const schemas = c.kind === 'postgres' && items ? [...new Set(items.map((it) => db.splitName('postgres', it.name)[0]))] : []
  const schema = c.kind === 'postgres' ? n.schema || (schemas.includes('public') ? 'public' : schemas[0] || '') : ''
  const shown = (items || []).filter((it) => (!schema || it.name.startsWith(`${schema}.`)) && (!n.search || c.kind === 'redis' || it.name.toLowerCase().includes(n.search.toLowerCase())))
  return (
    <>
      {schemas.length > 1 && (
        <label class="db-schema">
          <span class="muted small">Schema</span>
          <select class="select" value={schema} onChange={(e) => go({ schema: e.currentTarget.value })}>
            {schemas.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </label>
      )}
      <div class="db-head">
        <b>{nouns[c.kind]}</b>
        <button class={`btn ghost icon sm${searching.value ? ' on' : ''}`} aria-label={`Search the ${nouns[c.kind].toLowerCase()}`} title="Search" onClick={() => (searching.value = !searching.value)}>
          <Search />
        </button>
        {items && <span class="muted small">{c.kind === 'redis' ? `${count(l.total ?? shown.length)} keys` : count(shown.length)}</span>}
        <span class="spacer" />
        <button class="btn ghost icon sm" aria-label="Refresh" title="Refresh" onClick={() => loadList(c.id)}>
          <RefreshCw />
        </button>
        {SQL[c.kind] && (
          <button class="btn sm" onClick={() => newTable(c, schema)}>
            <Plus /> New Table
          </button>
        )}
        {c.kind === 'redis' && (
          <button class="btn sm" onClick={() => newKey(c)}>
            <Plus /> Key
          </button>
        )}
      </div>
      {searching.value && (
        <input
          class="input db-search"
          placeholder={c.kind === 'redis' ? 'Keys containing…' : `Find a ${c.kind === 'mongo' ? 'collection' : 'table'}`}
          value={n.search}
          autofocus
          onInput={(e) => {
            go({ search: e.currentTarget.value })
            if (c.kind === 'redis') {
              clearTimeout(Home.timer)
              Home.timer = setTimeout(() => loadList(c.id), 300)
            }
          }}
        />
      )}
      <RawBar c={c} hint={SQL[c.kind] && shown.length ? db.selectAll(c.kind, shown[0].name) : c.kind === 'mongo' && shown.length ? db.mongoFind(shown[0].name) : ''} />
      <RawResult c={c} />
      {!items ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : shown.length === 0 ? (
        <div class="db-empty">
          {l.error ? <span class="red small">{l.error}</span> : <span class="muted">{n.search ? 'Nothing matches.' : `No ${nouns[c.kind].toLowerCase()} yet.`}</span>}
          {SQL[c.kind] && !l.error && !n.search && (
            <button class="btn sm" onClick={() => newTable(c, schema)}>
              <Plus /> New Table
            </button>
          )}
        </div>
      ) : c.kind === 'redis' ? (
        <KeyList c={c} items={shown} more={l.more} />
      ) : (
        <div class="db-cards">
          {shown.map((it) => (
            <button key={it.name} class="db-card" onClick={() => openItem(c, it.name)} title={it.name}>
              <Table />
              <span class="name">{schema ? it.name.slice(schema.length + 1) : it.name}</span>
              {it.rows !== null && it.rows !== undefined && <span class="rows">{count(it.rows)}</span>}
            </button>
          ))}
        </div>
      )}
    </>
  )
}

function ttlText(ttl) {
  if (ttl === -1) return 'no expiry'
  if (ttl < 0) return ''
  if (ttl < 120) return `${ttl}s`
  if (ttl < 7200) return `${Math.round(ttl / 60)}m`
  if (ttl < 172800) return `${Math.round(ttl / 3600)}h`
  return `${Math.round(ttl / 86400)}d`
}

function KeyList({ c, items, more }) {
  return (
    <div class="db-grid-wrap">
      <table class="db-grid keys">
        <thead>
          <tr>
            <th>Key</th>
            <th>Type</th>
            <th>TTL</th>
          </tr>
        </thead>
        <tbody>
          {items.map((it) => (
            <tr key={it.name} class="clickable" onClick={() => openItem(c, it.name)}>
              <td class="mono">{it.name}</td>
              <td>
                <span class={`type-badge ${it.type}`}>{it.type}</span>
              </td>
              <td class="muted">{ttlText(it.ttl)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {more && <div class="db-foot muted small">The first {items.length} keys; search to find others.</div>}
    </div>
  )
}

// A table or a collection ------------------------------------------------------

function TableView({ c }) {
  const n = nav.value
  const g = grid.value
  const meta = g.meta
  const data = g.data
  const cols = meta ? meta.columns || [] : []
  const rows = data ? (c.kind === 'mongo' ? data.docs || [] : data.rows) : []
  const total = data ? data.total : 0
  const pages = Math.max(1, Math.ceil(total / PAGE))
  const editable = c.kind === 'mongo' || (meta && db.identity(c.kind, meta))
  const view = c.kind === 'mongo' ? 'collection' : meta && (meta.kind === 'v' || meta.kind === 'm' || meta.kind === 'view') ? 'view' : 'table'
  return (
    <>
      <div class="db-head">
        <button class="crumb" onClick={() => home(c)}>
          {nouns[c.kind]}
        </button>
        <span class="crumb-sep">/</span>
        <b class="mono crumb-name" title={n.name}>
          {c.kind === 'postgres' && n.name.startsWith('public.') ? n.name.slice(7) : n.name}
        </b>
        <button class={`btn ghost icon sm${searching.value ? ' on' : ''}`} aria-label="Filter the rows" title="Filter" onClick={() => (searching.value = !searching.value)}>
          <Search />
        </button>
        <span class="spacer" />
        {g.loading && <Spinner />}
        <button class="btn ghost icon sm" aria-label="Refresh" title="Refresh" onClick={() => loadGrid(c.id, c.kind)}>
          <RefreshCw />
        </button>
        {SQL[c.kind] && view === 'table' && (
          <button class="btn sm" onClick={() => newColumn(c)}>
            <Columns3 /> Column
          </button>
        )}
        <ViewSwitch on={n.raw} set={(v) => go({ raw: v })} />
        {SQL[c.kind] && view === 'table' && (
          <button class="btn ghost icon sm" aria-label="Table menu" onClick={(e) => openMenu(e.currentTarget, [['Delete table', Trash, () => dropTable(c), true]])}>
            <EllipsisVertical />
          </button>
        )}
      </div>
      {searching.value && (
        <form
          class="db-filter"
          onSubmit={(e) => {
            e.preventDefault()
            go({ filter: e.currentTarget.elements.q.value.trim(), page: 1 })
            loadGrid(c.id, c.kind)
          }}
        >
          <input class="input mono" name="q" defaultValue={n.filter} placeholder={c.kind === 'mongo' ? '{ "status": "paid" }' : 'Rows containing…'} autofocus />
          <button class="btn sm">Filter</button>
          {n.filter && (
            <button
              type="button"
              class="btn ghost sm"
              onClick={() => {
                go({ filter: '', page: 1 })
                loadGrid(c.id, c.kind)
              }}
            >
              Clear
            </button>
          )}
        </form>
      )}
      <RawBar c={c} />
      <RawResult c={c} />
      {g.error && <div class="banner warn db-error">{g.error}</div>}
      {!data ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : n.raw ? (
        <pre class="raw-text">{JSON.stringify(rows, (k, v) => (k === '__ctid' ? undefined : v), 2)}</pre>
      ) : (
        <div class="db-grid-wrap">
          <table class="db-grid">
            <thead>
              <tr>
                {cols.map((col) => (
                  <th key={col.name} title={col.type ? `${col.type}${col.nullable === false ? ', not null' : ''}${col.default ? `, default ${col.default}` : ''}` : undefined}>
                    <button class="th" onClick={() => c.kind !== 'mongo' && sortBy(c, col.name)} disabled={c.kind === 'mongo'}>
                      {col.pk && <KeyRound class="pk" />}
                      {col.name}
                      {n.sort === col.name && (n.dir === 'desc' ? <ArrowDown /> : <ArrowUp />)}
                    </button>
                  </th>
                ))}
                <th class="actions" />
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 && (
                <tr>
                  <td class="muted none" colSpan={cols.length + 1}>
                    {n.filter ? 'No row matches the filter.' : 'No rows yet.'}
                  </td>
                </tr>
              )}
              {rows.map((row, i) => (
                <tr key={i}>
                  {cols.map((col) => (
                    <EditCell key={col.name} c={c} meta={meta} row={row} index={i} col={col} editable={editable && view !== 'view'} />
                  ))}
                  <td class="actions">
                    {editable && view !== 'view' && (
                      <button class="btn ghost icon sm" aria-label="Row menu" onClick={(e) => openMenu(e.currentTarget, [['Edit row', Pencil, () => editRow(c, meta, row)], null, ['Delete', Trash, () => deleteRow(c, meta, row), true]])}>
                        <EllipsisVertical />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {data && (
        <div class="db-pager">
          {view !== 'view' && (editable || c.kind === 'mongo') ? (
            <button class="btn sm" onClick={() => editRow(c, meta, null)}>
              <Plus /> {c.kind === 'mongo' ? 'Document' : 'Row'}
            </button>
          ) : (
            <span class="muted small">{view === 'view' ? 'A view: read only' : 'No primary key: rows are read only'}</span>
          )}
          <span class="spacer" />
          <span class="muted small">{count(total)} {c.kind === 'mongo' ? 'documents' : 'rows'}</span>
          <div class="pages">
            <button class="btn ghost icon sm" aria-label="First page" disabled={n.page <= 1} onClick={() => turn(c, 1)}>
              <ChevronsLeft />
            </button>
            <button class="btn ghost icon sm" aria-label="Previous page" disabled={n.page <= 1} onClick={() => turn(c, n.page - 1)}>
              <ChevronLeft />
            </button>
            <span class="small">
              Page {n.page} of {pages}
            </span>
            <button class="btn ghost icon sm" aria-label="Next page" disabled={n.page >= pages} onClick={() => turn(c, n.page + 1)}>
              <ChevronRight />
            </button>
            <button class="btn ghost icon sm" aria-label="Last page" disabled={n.page >= pages} onClick={() => turn(c, pages)}>
              <ChevronsRight />
            </button>
          </div>
        </div>
      )}
    </>
  )
}

function turn(c, p) {
  go({ page: p })
  loadGrid(c.id, c.kind)
}

function sortBy(c, col) {
  const n = nav.peek()
  go(n.sort === col ? { dir: n.dir === 'asc' ? 'desc' : 'asc', page: 1 } : { sort: col, dir: 'asc', page: 1 })
  loadGrid(c.id, c.kind)
}

/** A cell; a double click edits it in place (Enter saves, Escape cancels). */
function EditCell({ c, meta, row, index, col, editable }) {
  const value = row[col.name]
  const id = `${index}/${col.name}`
  const can = editable && c.kind !== 'mongo' && (value === null || typeof value !== 'object')
  if (editing.value === id) {
    const save = async (text) => {
      editing.value = ''
      if (text === db.cellText(value)) return
      try {
        await db.updateRow(c.id, c.kind, nav.peek().name, meta, row, { [col.name]: text })
        loadGrid(c.id, c.kind)
      } catch (err) {
        toast(err.message, 'error')
      }
    }
    return (
      <td class="editing">
        <input
          class="cell-input mono"
          defaultValue={db.cellText(value) ?? ''}
          autofocus
          onKeyDown={(e) => {
            if (e.key === 'Enter') save(e.currentTarget.value)
            else if (e.key === 'Escape') editing.value = ''
          }}
          onBlur={() => (editing.value = '')}
        />
      </td>
    )
  }
  return (
    <td title={can ? 'Double-click to edit' : db.cellText(value) ?? 'NULL'} onDblClick={() => can && (editing.value = id)} class={can ? 'can-edit' : ''}>
      <Cell value={value} />
    </td>
  )
}

// Forms --------------------------------------------------------------------

/** A row in a form: each column, empty for its default; a document as JSON. */
function editRow(c, meta, row) {
  if (c.kind === 'mongo') {
    const doc = row || {}
    return openForm({
      title: row ? 'Edit Document' : 'New Document',
      submit: row ? 'Save' : 'Add',
      wide: true,
      render: () => <textarea class="textarea" name="doc" rows={16} spellcheck={false} defaultValue={JSON.stringify(doc, null, 2)} autofocus />,
      onSubmit: async ({ doc: text }) => {
        let parsed
        try {
          parsed = JSON.parse(text)
        } catch {
          throw new Error('That is not valid JSON')
        }
        if (row) await db.mongoReplace(c.id, nav.peek().name, row._id, parsed)
        else await db.mongoInsert(c.id, nav.peek().name, parsed)
        loadGrid(c.id, c.kind)
      },
    })
  }
  const cols = meta.columns || []
  openForm({
    title: row ? 'Edit Row' : 'New Row',
    submit: row ? 'Save' : 'Add',
    wide: cols.length > 4,
    render: () => (
      <div class="row-form">
        {cols.map((col) => {
          const v = row ? db.cellText(row[col.name]) : null
          return (
            <div class="field" key={col.name}>
              <label>
                {col.pk && <KeyRound class="pk" />}
                <span class="mono">{col.name}</span> <span class="muted small">{col.type}</span>
              </label>
              <div class="row-field">
                <input class="input mono" name={`v:${col.name}`} defaultValue={v ?? ''} placeholder={row ? '' : col.default ? `default: ${col.default}` : col.nullable ? 'NULL' : ''} />
                {col.nullable !== false && (
                  <label class="check small" title="Store NULL">
                    <input type="checkbox" name={`n:${col.name}`} defaultChecked={row ? v === null : false} /> NULL
                  </label>
                )}
              </div>
            </div>
          )
        })}
      </div>
    ),
    onSubmit: async (values) => {
      const out = {}
      for (const col of cols) {
        const text = values[`v:${col.name}`]
        const isNull = values[`n:${col.name}`] === true
        if (row) {
          const before = db.cellText(row[col.name])
          const next = isNull ? null : text
          if (next !== before) out[col.name] = next
        } else if (isNull) out[col.name] = null
        else if (text !== '') out[col.name] = text
      }
      if (row && Object.keys(out).length === 0) return
      if (row) await db.updateRow(c.id, c.kind, nav.peek().name, meta, row, out)
      else await db.insertRow(c.id, c.kind, nav.peek().name, out)
      toast(row ? 'Row saved' : 'Row added', 'success')
      loadGrid(c.id, c.kind)
    },
  })
}

function deleteRow(c, meta, row) {
  confirm({
    title: c.kind === 'mongo' ? 'Delete this document?' : 'Delete this row?',
    body: 'It cannot be brought back, except from a backup.',
    action: 'Delete',
    onConfirm: async () => {
      if (c.kind === 'mongo') await db.mongoDelete(c.id, nav.peek().name, row._id)
      else await db.deleteRow(c.id, c.kind, nav.peek().name, meta, row)
      loadGrid(c.id, c.kind)
    },
  })
}

function TypeInput({ kind, name, value }) {
  return (
    <>
      <input class="input mono" name={name} list={`types-${kind}`} defaultValue={value} placeholder="type" required />
      <datalist id={`types-${kind}`}>
        {db.sqlTypes[kind].map((t) => (
          <option key={t} value={t} />
        ))}
      </datalist>
    </>
  )
}

function newColumn(c) {
  openForm({
    title: 'New Column',
    submit: 'Add Column',
    render: () => (
      <>
        <div class="field">
          <label>Name</label>
          <input class="input mono" name="name" required autofocus placeholder="created_at" />
        </div>
        <div class="field">
          <label>Type</label>
          <TypeInput kind={c.kind} name="type" value="text" />
        </div>
        <div class="field">
          <label>Default</label>
          <input class="input mono" name="default" placeholder="none, a value, or now()" />
        </div>
        <label class="check">
          <input type="checkbox" name="nullable" defaultChecked /> Can be NULL
        </label>
      </>
    ),
    onSubmit: async (v) => {
      await db.addColumn(c.id, c.kind, nav.peek().name, { name: v.name, type: v.type, default: v.default, nullable: v.nullable })
      grid.value = { ...grid.peek(), key: '' }
      toast(`Column ${v.name} added`, 'success')
      loadGrid(c.id, c.kind)
    },
  })
}

const draftColumns = signal([])

function ColumnsEditor({ kind }) {
  const cols = draftColumns.value
  const set = (i, change) => (draftColumns.value = cols.map((col, j) => (j === i ? { ...col, ...change } : col)))
  return (
    <div class="cols-editor">
      <div class="cols-row head">
        <span>Name</span>
        <span>Type</span>
        <span>Default</span>
        <span title="Primary key">Key</span>
        <span>NULL</span>
        <span />
      </div>
      {cols.map((col, i) => (
        <div class="cols-row" key={col.k}>
          <input class="input mono" value={col.name} onInput={(e) => set(i, { name: e.currentTarget.value })} placeholder="name" aria-label="Column name" />
          <input class="input mono" value={col.type} list={`types-${kind}`} onInput={(e) => set(i, { type: e.currentTarget.value })} placeholder="type" aria-label="Type" />
          <input class="input mono" value={col.default} onInput={(e) => set(i, { default: e.currentTarget.value })} placeholder="none" aria-label="Default" />
          <input type="checkbox" checked={col.pk} onChange={(e) => set(i, { pk: e.currentTarget.checked })} aria-label="Primary key" />
          <input type="checkbox" checked={col.nullable} disabled={col.pk} onChange={(e) => set(i, { nullable: e.currentTarget.checked })} aria-label="Can be NULL" />
          <button type="button" class="btn ghost icon sm" aria-label="Remove the column" onClick={() => (draftColumns.value = cols.filter((_, j) => j !== i))}>
            <X />
          </button>
        </div>
      ))}
      <datalist id={`types-${kind}`}>
        {db.sqlTypes[kind].map((t) => (
          <option key={t} value={t} />
        ))}
      </datalist>
      <button type="button" class="btn sm" onClick={() => (draftColumns.value = [...cols, { k: Date.now(), name: '', type: 'text', default: '', pk: false, nullable: true }])}>
        <Plus /> Column
      </button>
    </div>
  )
}

function newTable(c, schema) {
  draftColumns.value = [
    { k: 1, name: 'id', type: c.kind === 'postgres' ? 'bigserial' : 'bigint', default: '', pk: true, nullable: false },
    { k: 2, name: 'created_at', type: c.kind === 'postgres' ? 'timestamptz' : 'datetime', default: c.kind === 'postgres' ? 'now()' : 'current_timestamp', pk: false, nullable: false },
  ]
  openForm({
    title: 'New Table',
    submit: 'Create Table',
    wide: true,
    render: () => (
      <>
        <div class="field">
          <label>Name{c.kind === 'postgres' && schema ? <span class="muted small"> in {schema}</span> : null}</label>
          <input class="input mono" name="table" required autofocus placeholder="orders" />
        </div>
        <ColumnsEditor kind={c.kind} />
      </>
    ),
    onSubmit: async ({ table }) => {
      const cols = draftColumns.peek().map((col) => (c.kind === 'mysql' && col.pk && /^bigint|^int/.test(col.type) && !col.default ? { ...col, type: `${col.type} auto_increment` } : col))
      await db.createTable(c.id, c.kind, schema, table, cols)
      toast(`Table ${table} created`, 'success')
      await loadList(c.id)
      openItem(c, c.kind === 'postgres' ? `${schema || 'public'}.${table.trim()}` : table.trim())
    },
  })
}

function dropTable(c) {
  const name = nav.peek().name
  openForm({
    title: 'Delete Table',
    submit: 'Delete',
    danger: true,
    render: () => (
      <>
        <p class="muted" style="margin:0">
          <b class="mono">{name}</b> and every row in it go for good, except from a backup. Type its name to confirm.
        </p>
        <input class="input mono" name="confirm" autofocus required />
      </>
    ),
    onSubmit: async ({ confirm: typed }) => {
      if (typed.trim() !== name && typed.trim() !== db.splitName(c.kind, name)[1]) throw new Error('The name does not match')
      await db.dropTable(c.id, c.kind, name)
      toast(`Table ${name} deleted`, 'success')
      home(c)
    },
  })
}

// Redis keys -------------------------------------------------------------------

const redisTypes = ['string', 'hash', 'list', 'set', 'zset']

function newKey(c) {
  openForm({
    title: 'New Key',
    submit: 'Add Key',
    render: () => (
      <>
        <div class="field">
          <label>Name</label>
          <input class="input mono" name="name" required autofocus placeholder="greeting" />
        </div>
        <div class="field">
          <label>Type</label>
          <select class="select" name="type">
            {redisTypes.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </div>
        <div class="field">
          <label>Value</label>
          <input class="input mono" name="value" required placeholder="for a hash: field, then the value below" />
        </div>
        <div class="field">
          <label>
            Second value <span class="muted small">a hash's value, a sorted set's score</span>
          </label>
          <input class="input mono" name="second" />
        </div>
        <div class="field">
          <label>
            Expires after <span class="muted small">seconds; empty for never</span>
          </label>
          <input class="input mono" name="ttl" type="number" min="1" />
        </div>
      </>
    ),
    onSubmit: async (v) => {
      const add = {
        string: [['SET', v.name, v.value]],
        hash: [['HSET', v.name, v.value, v.second]],
        list: [['RPUSH', v.name, v.value]],
        set: [['SADD', v.name, v.value]],
        zset: [['ZADD', v.name, v.second || '0', v.value]],
      }[v.type]
      if (v.ttl) add.push(['EXPIRE', v.name, v.ttl])
      await db.redisRun(c.id, add)
      toast(`Key ${v.name} added`, 'success')
      await loadList(c.id)
      openItem(c, v.name)
    },
  })
}

/** A key's items as rows: [label, value, remove-command, edit-command]. */
function keyRows(name, data) {
  const v = data.value
  if (data.type === 'hash') {
    const out = []
    for (let i = 0; i + 1 < v.length; i += 2) out.push({ a: v[i], b: v[i + 1], remove: ['HDEL', name, v[i]], edit: (x) => ['HSET', name, v[i], x] })
    return { head: ['Field', 'Value'], rows: out }
  }
  if (data.type === 'zset') {
    const out = []
    for (let i = 0; i + 1 < v.length; i += 2) out.push({ a: v[i], b: v[i + 1], remove: ['ZREM', name, v[i]], edit: (x) => ['ZADD', name, x, v[i]] })
    return { head: ['Member', 'Score'], rows: out }
  }
  if (data.type === 'list') return { head: ['Index', 'Value'], rows: v.map((x, i) => ({ a: String(i), b: x, remove: null, edit: (y) => ['LSET', name, String(i), y] })) }
  if (data.type === 'set') return { head: ['Member'], rows: v.map((x) => ({ a: x, remove: ['SREM', name, x] })) }
  if (data.type === 'stream') return { head: ['ID', 'Fields'], rows: v.map((e) => ({ a: e[0], b: JSON.stringify(e[1]) })) }
  return { head: [], rows: [] }
}

function KeyView({ c }) {
  const n = nav.value
  const k = keyView.value
  const d = k.name === n.name ? k.data : null
  const run = async (cmds, done) => {
    try {
      await db.redisRun(c.id, cmds)
      if (done) toast(done, 'success')
      loadKey(c.id)
    } catch (err) {
      toast(err.message, 'error')
    }
  }
  return (
    <>
      <div class="db-head">
        <button class="crumb" onClick={() => home(c)}>
          Keys
        </button>
        <span class="crumb-sep">/</span>
        <b class="mono crumb-name" title={n.name}>
          {n.name}
        </b>
        {d && <span class={`type-badge ${d.type}`}>{d.type}</span>}
        <span class="spacer" />
        {k.loading && <Spinner />}
        <button class="btn ghost icon sm" aria-label="Refresh" title="Refresh" onClick={() => loadKey(c.id)}>
          <RefreshCw />
        </button>
        <ViewSwitch on={n.raw} set={(v) => go({ raw: v })} />
        <button
          class="btn ghost icon sm"
          aria-label="Key menu"
          onClick={(e) =>
            openMenu(e.currentTarget, [
              ['Set expiry', Pencil, () => setTtl(c, n.name, d)],
              null,
              [
                'Delete key',
                Trash,
                () =>
                  confirm({
                    title: 'Delete this key?',
                    body: `${n.name} and its value go for good.`,
                    action: 'Delete',
                    onConfirm: async () => {
                      await db.redisRun(c.id, [['DEL', n.name]])
                      home(c)
                    },
                  }),
                true,
              ],
            ])
          }
        >
          <EllipsisVertical />
        </button>
      </div>
      <RawBar c={c} />
      <RawResult c={c} />
      {k.error && <div class="banner warn db-error">{k.error}</div>}
      {!d ? (
        !k.error && (
          <div class="empty">
            <Spinner />
          </div>
        )
      ) : d.type === 'none' ? (
        <div class="db-empty muted">This key no longer exists.</div>
      ) : (
        <>
          <div class="key-meta muted small">
            {d.len !== undefined && <span>{d.type === 'string' ? `${count(d.len)} bytes` : `${count(d.len)} items`}</span>}
            <span>{d.ttl === -1 ? 'No expiry' : `Expires in ${ttlText(d.ttl)}`}</span>
          </div>
          {n.raw ? (
            <pre class="raw-text">{JSON.stringify(d.value, null, 2)}</pre>
          ) : d.type === 'string' ? (
            <form
              class="key-string"
              onSubmit={(e) => {
                e.preventDefault()
                const args = ['SET', n.name, e.currentTarget.elements.value.value]
                if (d.ttl > 0) args.push('KEEPTTL')
                run([args], 'Saved')
              }}
            >
              <textarea class="textarea" name="value" rows={8} spellcheck={false} defaultValue={d.value ?? ''} key={`${n.name}:${d.value}`} />
              <div class="row">
                <span class="spacer" />
                <button class="btn sm primary">Save</button>
              </div>
            </form>
          ) : (
            <KeyItems c={c} name={n.name} data={d} run={run} />
          )}
        </>
      )}
    </>
  )
}

function KeyItems({ name, data, run }) {
  const t = keyRows(name, data)
  const add = () =>
    openForm({
      title: { hash: 'New Field', zset: 'New Member', list: 'New Item', set: 'New Member' }[data.type] || 'Add',
      submit: 'Add',
      render: () => (
        <>
          <div class="field">
            <label>{data.type === 'hash' ? 'Field' : data.type === 'list' ? 'Value (added at the end)' : 'Member'}</label>
            <input class="input mono" name="a" required autofocus />
          </div>
          {(data.type === 'hash' || data.type === 'zset') && (
            <div class="field">
              <label>{data.type === 'hash' ? 'Value' : 'Score'}</label>
              <input class="input mono" name="b" required defaultValue={data.type === 'zset' ? '0' : ''} />
            </div>
          )}
        </>
      ),
      onSubmit: async ({ a, b }) =>
        run([{ hash: ['HSET', name, a, b], zset: ['ZADD', name, b, a], list: ['RPUSH', name, a], set: ['SADD', name, a] }[data.type]], 'Added'),
    })
  return (
    <>
      <div class="db-grid-wrap">
        <table class="db-grid">
          <thead>
            <tr>
              {t.head.map((h) => (
                <th key={h}>{h}</th>
              ))}
              <th class="actions" />
            </tr>
          </thead>
          <tbody>
            {t.rows.map((r, i) => (
              <tr key={i}>
                <td class="mono">{r.a}</td>
                {t.head.length > 1 && <td>{r.b}</td>}
                <td class="actions">
                  {(r.edit || r.remove) && (
                    <button
                      class="btn ghost icon sm"
                      aria-label="Item menu"
                      onClick={(e) =>
                        openMenu(
                          e.currentTarget,
                          [
                            r.edit && [
                              'Edit',
                              Pencil,
                              () =>
                                openForm({
                                  title: 'Edit',
                                  render: () => <input class="input mono" name="v" defaultValue={r.b} autofocus />,
                                  onSubmit: ({ v }) => run([r.edit(v)], 'Saved'),
                                }),
                            ],
                            r.remove && ['Remove', Trash, () => run([r.remove], 'Removed'), true],
                          ].filter(Boolean),
                        )
                      }
                    >
                      <EllipsisVertical />
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div class="db-pager">
        {data.type !== 'stream' && (
          <button class="btn sm" onClick={add}>
            <Plus /> {data.type === 'hash' ? 'Field' : data.type === 'list' ? 'Item' : 'Member'}
          </button>
        )}
        <span class="spacer" />
        {data.len > t.rows.length && <span class="muted small">The first {t.rows.length} of {count(data.len)}</span>}
      </div>
    </>
  )
}

function setTtl(c, name, d) {
  openForm({
    title: 'Expiry',
    submit: 'Save',
    render: () => (
      <div class="field">
        <label>
          Expires after <span class="muted small">seconds; empty to keep it for ever</span>
        </label>
        <input class="input mono" name="ttl" type="number" min="1" defaultValue={d && d.ttl > 0 ? d.ttl : ''} autofocus />
      </div>
    ),
    onSubmit: async ({ ttl }) => {
      await db.redisRun(c.id, [ttl ? ['EXPIRE', name, ttl] : ['PERSIST', name]])
      loadKey(c.id)
    },
  })
}

// Stats ----------------------------------------------------------------------

function Stat({ label, value, sub, tone }) {
  return (
    <div class="stat">
      <span class="muted small">{label}</span>
      <b class={tone || ''}>{value}</b>
      {sub && <span class="muted small">{sub}</span>}
    </div>
  )
}

const bytes = (n) => (n === null || n === undefined ? '—' : size(Number(n)))

function Stats({ c }) {
  const s = statsView.value
  const d = s.id === c.id ? s.data : null
  if (s.error) return <div class="banner warn db-error">{s.error}</div>
  if (!d)
    return (
      <div class="empty">
        <Spinner />
      </div>
    )
  if (c.kind === 'redis') {
    const hits = Number(d.keyspace_hits || 0)
    const misses = Number(d.keyspace_misses || 0)
    const keys = Object.entries(d)
      .filter(([k]) => /^db\d+$/.test(k))
      .reduce((t, [, v]) => t + Number((v.match(/keys=(\d+)/) || [0, 0])[1]), 0)
    return (
      <div class="stats">
        <div class="stat-row">
          <Stat label="Keys" value={count(keys)} />
          <Stat label="Memory" value={d.used_memory_human || '—'} sub={d.maxmemory_human && d.maxmemory !== '0' ? `of ${d.maxmemory_human}` : undefined} />
          <Stat label="Clients" value={d.connected_clients || '0'} />
          <Stat label="Hit rate" value={hits + misses ? `${((100 * hits) / (hits + misses)).toFixed(1)}%` : '—'} tone="green" />
          <Stat label="Version" value={d.redis_version || d.valkey_version || '—'} />
        </div>
        <p class="muted small">Up for {Math.round(Number(d.uptime_in_days || 0))} days · expiry events: {d.notify_keyspace_events || 'off'}</p>
      </div>
    )
  }
  if (c.kind === 'mongo') {
    const dbs = Array.isArray(d) ? d : []
    return (
      <div class="stats">
        <div class="db-grid-wrap">
          <table class="db-grid">
            <thead>
              <tr>
                <th>Database</th>
                <th class="n">Collections</th>
                <th class="n">Documents</th>
                <th class="n">Data</th>
                <th class="n">Storage</th>
                <th class="n">Indexes</th>
              </tr>
            </thead>
            <tbody>
              {dbs.map((x) => (
                <tr key={x.name}>
                  <td class="mono">{x.name}</td>
                  <td class="n">{x.collections}</td>
                  <td class="n">{count(x.objects)}</td>
                  <td class="n">{bytes(x.data)}</td>
                  <td class="n">{bytes(x.storage)}</td>
                  <td class="n">{bytes(x.indexes)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    )
  }
  const tables = Array.isArray(d.tables) ? d.tables : []
  const data = tables.reduce((t, x) => t + Number(x.data || 0), 0)
  const indexes = tables.reduce((t, x) => t + Number(x.indexes || 0), 0)
  return (
    <div class="stats">
      <div class="stat-row">
        <Stat label="Connections" value={d.max ? `${Math.round((100 * d.connections) / d.max)}%` : d.connections} sub={`${d.connections} / ${d.max}`} tone="green" />
        {c.kind === 'postgres' && <Stat label="Active" value={d.active} />}
        {c.kind === 'postgres' && <Stat label="Idle" value={d.idle} />}
        {c.kind === 'postgres' && <Stat label="Idle in Txn" value={d.idle_tx} />}
        {c.kind === 'postgres' && <Stat label="Cache Hit" value={d.cache_hit === null || d.cache_hit === undefined ? '—' : `${d.cache_hit}%`} tone="green" />}
      </div>
      <b class="stats-title">Tables</b>
      <div class="stat-row">
        {c.kind === 'postgres' && <Stat label="Database" value={bytes(d.database)} />}
        <Stat label="Tables" value={bytes(data)} />
        <Stat label="Indexes" value={bytes(indexes)} />
        {c.kind === 'postgres' && d.wal !== undefined && <Stat label="WAL" value={bytes(d.wal)} />}
        <Stat label="Version" value={String(d.version || '').split(' ')[0]} />
      </div>
      <div class="db-grid-wrap">
        <table class="db-grid">
          <thead>
            <tr>
              <th>Table</th>
              <th class="n">Rows</th>
              <th class="n">Data</th>
              <th class="n">Indexes</th>
              {c.kind === 'postgres' && <th class="n">Seq Scans</th>}
              {c.kind === 'postgres' && <th class="n">Idx Scans</th>}
            </tr>
          </thead>
          <tbody>
            {tables.length === 0 && (
              <tr>
                <td class="muted none" colSpan={6}>
                  No tables yet.
                </td>
              </tr>
            )}
            {tables.map((x) => (
              <tr key={x.name}>
                <td class="mono">{x.name}</td>
                <td class="n">{count(Number(x.rows || 0))}</td>
                <td class="n">{bytes(x.data)}</td>
                <td class="n">{bytes(x.indexes)}</td>
                {c.kind === 'postgres' && <td class="n">{count(Number(x.seq || 0))}</td>}
                {c.kind === 'postgres' && <td class="n">{count(Number(x.idx || 0))}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

// The tab ----------------------------------------------------------------------

const titles = { postgres: 'PostgreSQL', mysql: 'MySQL', redis: 'Redis', mongo: 'MongoDB' }

export function DataTab({ svc }) {
  const kind = dbKind(svc)
  if (svc.status !== 'running') {
    return <div class="card empty">The data view needs the database running.</div>
  }
  const c = { id: svc.id, kind }
  const n = nav.value
  return (
    <div class="db-view">
      <nav class="db-subtabs" aria-label={`${titles[kind]} views`}>
        <button
          class={n.sub === 'data' ? 'on' : ''}
          onClick={() => {
            go({ sub: 'data' })
          }}
        >
          Data
        </button>
        <button
          class={n.sub === 'stats' ? 'on' : ''}
          onClick={() => {
            go({ sub: 'stats' })
            loadStats(c.id, kind)
          }}
        >
          Stats
        </button>
      </nav>
      <div class="db-body">{n.sub === 'stats' ? <Stats c={c} /> : n.mode === 'table' ? <TableView c={c} /> : n.mode === 'key' ? <KeyView c={c} /> : <Home c={c} />}</div>
    </div>
  )
}
