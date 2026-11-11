// The Metrics tab of a service and the Observability page of an
// environment, from the samples the panel takes every 30 seconds.

import { computed, effect, signal, untracked } from '@preact/signals'
import { Table } from 'lucide-preact'
import { enc, get } from '../api.js'
import { me, services } from '../state.js'
import { openService, page, serviceId } from '../project.js'
import { ServiceIcon, Spinner, Status } from '../ui.jsx'
import { bytes, Chart, colors, count, millis, percent, RangePicker } from './Chart.jsx'

/** Shared by the tab and the page, so switching keeps the range. */
const range = signal(3600)
const asTable = signal(false)
/** id → { range, data } */
const cache = signal({})

async function load(id, seconds) {
  try {
    const data = await get(`/services/${enc(id)}/metrics?range=${seconds}`)
    cache.value = { ...cache.peek(), [id]: { range: seconds, data } }
  } catch {
    // The next poll tries again; the old chart stays.
  }
}

function seriesOf(id) {
  const c = cache.value[id]
  return c ? c.data : null
}

const one = (label, value) => [{ label, color: colors.single, value }]

function chartsFor(svc) {
  return [
    { id: 'cpu', title: 'CPU', series: one('CPU', (p) => p.cpu), format: percent },
    { id: 'mem', title: 'Memory', series: one('Memory', (p) => p.mem), format: bytes, binary: true },
    { id: 'req', title: 'Requests', series: one('Requests', (p) => p.req), format: count, total: true },
    { id: 'p95', title: 'Response time (p95)', series: one('p95', (p) => p.p95), format: millis },
    {
      id: 'net',
      title: 'Network',
      series: [
        { label: 'Received', color: colors.first, value: (p) => p.rx },
        { label: 'Sent', color: colors.second, value: (p) => p.tx },
      ],
      format: bytes,
      binary: true,
    },
    svc.volumes.length > 0 && { id: 'disk', title: 'Volume usage', series: one('Volumes', (p) => p.disk), format: bytes, binary: true },
  ].filter(Boolean)
}

function totals(points) {
  let req = 0
  let err = 0
  for (const p of points) {
    req += p.req
    err += p.err
  }
  return { req, err }
}

// The service tab ------------------------------------------------------------

const tabKey = computed(() => {
  const p = page.value
  if (!me.value || !p || !p.service || p.tab !== 'metrics') return ''
  return `${serviceId(p, p.service)}\n${range.value}`
})

let tabTimer = 0
effect(() => {
  const k = tabKey.value
  clearInterval(tabTimer)
  if (!k) return
  const [id, seconds] = k.split('\n')
  untracked(() => load(id, Number(seconds)))
  tabTimer = setInterval(() => document.hidden || load(id, Number(seconds)), 30000)
})

function MetricsTable({ data, svc }) {
  const rows = [...data.points].reverse()
  return (
    <div class="table-wrap">
      <table class="table mono-num">
        <thead>
          <tr>
            <th>Time</th>
            <th>CPU</th>
            <th>Memory</th>
            <th>Requests</th>
            <th>5xx</th>
            <th>p95</th>
            <th>Received</th>
            <th>Sent</th>
            {svc.volumes.length > 0 && <th>Volumes</th>}
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => (
            <tr key={p.t}>
              <td>{new Date(p.t * 1000).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' })}</td>
              <td>{percent(p.cpu)}</td>
              <td>{bytes(p.mem)}</td>
              <td>{count(p.req)}</td>
              <td>{count(p.err)}</td>
              <td>{millis(p.p95)}</td>
              <td>{bytes(p.rx)}</td>
              <td>{bytes(p.tx)}</td>
              {svc.volumes.length > 0 && <td>{bytes(p.disk)}</td>}
            </tr>
          ))}
        </tbody>
      </table>
      {rows.length === 0 && <div class="empty small">No samples in this range yet.</div>}
    </div>
  )
}

export function MetricsTab({ svc }) {
  const c = cache.value[svc.id]
  const data = c ? c.data : null
  const stale = c && c.range !== range.value
  return (
    <div>
      <div class="row" style="margin-bottom:16px">
        <RangePicker value={range.value} onChange={(v) => (range.value = v)} />
        <span class="spacer" />
        <button class={`btn sm${asTable.value ? ' active' : ''}`} aria-pressed={asTable.value} onClick={() => (asTable.value = !asTable.value)}>
          <Table /> Table
        </button>
      </div>
      {!data ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : (
        <div style={stale ? 'opacity:.55;transition:opacity .2s' : ''}>
          {data.points.length === 0 && (
            <div class="banner">
              The panel samples every {data.interval} seconds; the first points appear within a minute of a deploy.
            </div>
          )}
          {asTable.value ? (
            <MetricsTable data={data} svc={svc} />
          ) : (
            <div class="charts">
              {chartsFor(svc).map((ch) => {
                const t = ch.total ? totals(data.points) : null
                return (
                  <Chart
                    key={ch.id}
                    id={`${svc.id}:${ch.id}`}
                    title={ch.title}
                    series={ch.series}
                    points={data.points}
                    format={ch.format}
                    binary={ch.binary}
                    from={data.from}
                    to={data.to}
                    step={data.step}
                    summary={t ? `${count(t.req)} total · ${count(t.err)} 5xx` : undefined}
                  />
                )
              })}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// The Observability page ----------------------------------------------------

const pageKey = computed(() => {
  const p = page.value
  if (!me.value || !p || p.view !== 'observability') return ''
  const list = services.value
  if (!list) return ''
  const ids = list.filter((s) => s.deployment > 0).map((s) => s.id)
  return `${range.value}\n${ids.join(',')}`
})

let pageTimer = 0
effect(() => {
  const k = pageKey.value
  clearInterval(pageTimer)
  if (!k) return
  const [seconds, ids] = k.split('\n')
  const all = ids ? ids.split(',') : []
  const fetchAll = () => all.forEach((id) => load(id, Number(seconds)))
  untracked(fetchAll)
  pageTimer = setInterval(() => document.hidden || fetchAll(), 30000)
})

function ServiceMetrics({ svc }) {
  const data = seriesOf(svc.id)
  const mini = [
    { id: 'cpu', title: 'CPU', series: one('CPU', (p) => p.cpu), format: percent },
    { id: 'mem', title: 'Memory', series: one('Memory', (p) => p.mem), format: bytes, binary: true },
    { id: 'req', title: 'Requests', series: one('Requests', (p) => p.req), format: count },
  ]
  return (
    <section class="obs-service">
      <header>
        <button class="obs-name" onClick={() => openService(svc.name, { tab: 'metrics' })}>
          <ServiceIcon svc={svc} size={16} />
          {svc.name}
        </button>
        <Status svc={svc} />
      </header>
      {!data ? (
        <div class="empty">
          <Spinner />
        </div>
      ) : (
        <div class="charts three">
          {mini.map((ch) => (
            <Chart
              key={ch.id}
              id={`obs:${svc.id}:${ch.id}`}
              title={ch.title}
              series={ch.series}
              points={data.points}
              format={ch.format}
              binary={ch.binary}
              from={data.from}
              to={data.to}
              step={data.step}
              height={90}
            />
          ))}
        </div>
      )}
    </section>
  )
}

export function Observability() {
  const list = services.value
  const shown = list ? list.filter((s) => s.deployment > 0) : null
  return (
    <div class="stage-page">
      <div class="page" style="max-width:1200px;padding-top:28px">
        <div class="page-head">
          <h1>Observability</h1>
          <span class="spacer" />
          <RangePicker value={range.value} onChange={(v) => (range.value = v)} />
        </div>
        {!shown ? (
          <div class="empty">
            <Spinner />
          </div>
        ) : shown.length === 0 ? (
          <div class="card empty">Nothing is deployed in this environment yet.</div>
        ) : (
          shown.map((svc) => <ServiceMetrics key={svc.id} svc={svc} />)
        )}
      </div>
    </div>
  )
}
