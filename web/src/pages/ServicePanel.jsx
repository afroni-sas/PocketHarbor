// The panel that slides over the canvas for one service: deployments,
// variables, backups, cron runs and settings, as on Railway.

import { computed, effect, signal, untracked } from '@preact/signals'
import {
  Archive,
  Box,
  ChevronDown,
  ChevronRight,
  CircleCheck,
  CircleX,
  Clock,
  Copy,
  EllipsisVertical,
  ExternalLink,
  FileText,
  Globe,
  Hammer,
  HardDrive,
  Network,
  Play,
  Plug,
  Plus,
  RefreshCw,
  Rocket,
  RotateCcw,
  Search,
  Trash,
  TriangleExclamationPoint,
  Undo2,
  X,
} from 'lucide-preact'
import { del, enc, get, patch, post } from '../api.js'
import { me, services, toast } from '../state.js'
import { closeService, markDirty, page, privateName, refresh, serviceId, setQuery } from '../project.js'
import { attempt, confirm, copy, GithubIcon, openForm, openMenu, ServiceIcon, size, Spinner, statusOf, timeAgo } from '../ui.jsx'
import { loadVars, VariablesEditor } from './Variables.jsx'
import { LogsView } from './Logs.jsx'
import { MetricsTab } from './Metrics.jsx'
import { ConsoleTab } from './Console.jsx'
import { DataTab, dbKind } from './Data.jsx'

const deployments = signal({ id: '', list: null })
const backups = signal({ id: '', volumes: null, list: null })
const runs = signal({ id: '', log: null })
const tunnel = signal(null)
const showHistory = signal(true)
const filter = signal('')
const backingUp = signal('')

const current = computed(() => {
  const p = page.value
  if (!me.value || !p || !p.service) return ''
  const svc = (services.value || []).find((s) => s.name === p.service)
  return `${serviceId(p, p.service)}\n${p.tab || (svc && dbKind(svc) ? 'data' : 'deployments')}`
})

async function loadDeployments(id) {
  try {
    const list = await get(`/services/${enc(id)}/deployments`)
    if (current.peek().startsWith(id + '\n')) deployments.value = { id, list }
  } catch {
    // Kept as it was until the next poll.
  }
}

async function loadBackups(id) {
  try {
    const [volumes, list] = await Promise.all([get(`/services/${enc(id)}/volumes`), get(`/services/${enc(id)}/backups`)])
    list.sort((a, b) => b.created_at - a.created_at)
    if (current.peek().startsWith(id + '\n')) backups.value = { id, volumes, list }
  } catch (err) {
    toast(err.message, 'error')
  }
}

async function loadRuns(id) {
  try {
    const log = await get(`/services/${enc(id)}/cron-log`)
    if (current.peek().startsWith(id + '\n')) runs.value = { id, log }
  } catch {
    // Kept as it was.
  }
}

async function loadSettings(id) {
  loadBackups(id)
  try {
    tunnel.value = await get('/tunnel')
  } catch {
    tunnel.value = null
  }
}

const loaders = {
  deployments: [loadDeployments, 3000],
  variables: [(id) => loadVars(`/services/${enc(id)}/variables`, true), 0],
  backups: [loadBackups, 0],
  runs: [loadRuns, 4000],
  settings: [loadSettings, 0],
}

let timer = 0
effect(() => {
  const k = current.value
  clearInterval(timer)
  if (!k) return
  const [id, tab] = k.split('\n')
  const entry = loaders[tab]
  if (!entry) return
  const [load, every] = entry
  untracked(() => load(id))
  if (every) timer = setInterval(() => document.hidden || load(id), every)
})

addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || e.defaultPrevented) return
  // Escape belongs to the program in the terminal (vim, less...).
  if (e.target instanceof Element && e.target.closest('.console')) return
  const p = page.peek()
  if (!p || !p.service || document.querySelector('.backdrop, .menu')) return
  if (p.logs) setQuery({ logs: undefined, logtab: undefined })
  else closeService()
})

const svcPath = (svc, rest = '') => `/services/${enc(svc.id)}${rest}`

/** Saves fields of a service; most only apply with the next deploy. */
export async function update(svc, body, live = false) {
  await patch(svcPath(svc), body)
  if (!live) markDirty(svc)
  await refresh()
}

/** The variable other services use to reach a database made from a template. */
const connectVariable = [
  [/postgres/, 'DATABASE_URL'],
  [/mariadb/, 'MARIADB_URL'],
  [/mysql/, 'MYSQL_URL'],
  [/redis/, 'REDIS_URL'],
  [/mongo/, 'MONGO_URL'],
  [/minio/, 'S3_ENDPOINT'],
  [/nats/, 'NATS_URL'],
]

export function connectVar(svc) {
  const image = (svc.image || '').toLowerCase()
  for (const [re, name] of connectVariable) if (re.test(image)) return name
  return null
}

async function showConnect(svc) {
  const name = connectVar(svc)
  let resolved = []
  try {
    resolved = (await get(svcPath(svc, '/variables?resolved=1'))).variables
  } catch (err) {
    return toast(err.message, 'error')
  }
  const value = (resolved.find((v) => v.name === name) || {}).value || ''
  const reference = `\${{ ${svc.name}.${name} }}`
  const others = resolved.filter((v) => /URL|HOST|PORT|USER|ENDPOINT/.test(v.name) && v.name !== name && !v.name.startsWith('PHARBOR_'))
  openForm({
    title: `Connect to ${svc.name}`,
    submit: 'Done',
    wide: true,
    render: () => (
      <>
        <div class="field">
          <label>From another service of this environment</label>
          <div class="code-box">
            {reference}
            <span class="spacer" />
            <button type="button" class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(reference)}>
              <Copy />
            </button>
          </div>
          <span class="hint">Set it as a variable of that service, e.g. {name}={reference}; the canvas draws the arrow.</span>
        </div>
        <div class="field">
          <label>{name}</label>
          <div class="code-box">
            <span style="overflow:hidden;text-overflow:ellipsis">{value}</span>
            <span class="spacer" />
            <button type="button" class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(value)}>
              <Copy />
            </button>
          </div>
          <span class="hint">Reachable on the phone's private network only, unless you give the service a domain or a tunnel.</span>
        </div>
        {others.length > 0 && (
          <div class="field">
            <label>Other variables</label>
            {others.map((v) => (
              <div class="var-row" key={v.name}>
                <span class="name">{v.name}</span>
                <span class="val">{v.value}</span>
                <button type="button" class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(v.value)}>
                  <Copy />
                </button>
              </div>
            ))}
          </div>
        )}
      </>
    ),
    onSubmit: async () => {},
  })
}

async function deployNow(svc) {
  await attempt(async () => {
    await post(svcPath(svc, '/deploy'))
    loadDeployments(svc.id)
    refresh()
  }, 'Deploying')
}

const triggers = { cli: 'CLI', api: 'dashboard', webhook: 'GitHub push', redeploy: 'redeploy', rollback: 'rollback' }

function DeployCard({ svc, d, active }) {
  const deploying = d.status === 'deploying'
  const failed = d.status === 'failed'
  const s = statusOf(svc)
  const title = d.message || (svc.repo ? `${svc.repo}@${svc.branch}` : d.image || `Deployment #${d.number}`)
  const took = d.finished_at && d.created_at ? ` · ${Math.max(1, d.finished_at - d.created_at)}s` : ''
  const logs = () => setQuery({ logs: d.number, logtab: deploying || failed ? undefined : 'deploy' })
  const menu = (e) =>
    openMenu(e.currentTarget, [
      ['View logs', FileText, logs],
      active && ['Restart', RotateCcw, () => attempt(() => post(svcPath(svc, '/restart')).then(refresh), 'Restarted')],
      active && ['Redeploy', RefreshCw, () => attempt(() => post(svcPath(svc, '/redeploy'), { number: d.number }).then(() => loadDeployments(svc.id)), 'Redeploying')],
      !active && d.status === 'removed' && ['Rollback', Undo2, () => rollback(svc, d)],
    ].filter(Boolean))
  return (
    <div class={`deploy${active ? ' active' : ''}${failed ? ' failed' : ''}`}>
      <div class="main">
        <span class="deploy-icon">{svc.repo ? <GithubIcon size={15} /> : <Box />}</span>
        <div class="what">
          <b title={title}>{title}</b>
          <span>
            {timeAgo(d.created_at)} via {triggers[d.trigger] || d.trigger}
            {d.commit && <span class="mono"> · {d.commit}</span>}
            {took}
          </span>
        </div>
        {active && <span class="badge green">Active</span>}
        {deploying && (
          <span class="badge purple">
            <span class="spinner" style="width:10px;height:10px;margin-right:6px;border-width:1.5px" />
            {svc.repo ? 'Building' : 'Deploying'}
          </span>
        )}
        {failed && <span class="badge red">Failed</span>}
        {d.status === 'removed' && <span class="badge">Removed</span>}
        <button class="btn sm" onClick={logs}>
          View logs
        </button>
        <button class="btn ghost icon sm" aria-label="Deployment menu" onClick={menu}>
          <EllipsisVertical />
        </button>
      </div>
      {active && (
        <div class="state">
          {s.color === 'green' ? <CircleCheck width={15} height={15} color="var(--green)" /> : <span class={`dot ${s.color}`} />}
          <span class={`status ${s.color}`}>{s.color === 'green' ? 'Deployment successful' : s.label}</span>
        </div>
      )}
      {failed && d.reason && (
        <div class="state">
          <CircleX width={15} height={15} color="var(--red)" />
          <span class="status red">{d.reason}</span>
        </div>
      )}
    </div>
  )
}

function rollback(svc, d) {
  confirm({
    title: `Roll back to #${d.number}?`,
    body: 'The image of that deployment starts again with today’s variables, then replaces the active one.',
    action: 'Rollback',
    danger: false,
    onConfirm: async () => {
      await post(svcPath(svc, '/rollback'), { number: d.number })
      toast(`Rolling back to #${d.number}`, 'success')
      loadDeployments(svc.id)
    },
  })
}

function Hosts({ svc }) {
  const hosts = svc.hostnames.filter((h) => h !== '*')
  const t = tunnel.value
  return (
    <div class="domains">
      {hosts.map((h) => (
        <a key={h} href={`http://${h}`} target="_blank" rel="noreferrer" class="row" style="gap:6px">
          <Globe />
          {h}
        </a>
      ))}
      {svc.hostnames.includes('*') && (
        <span class="row muted" style="gap:6px">
          <Globe /> default service
        </span>
      )}
      {t && t.url && t.default_service === svc.id && (
        <a href={t.url} target="_blank" rel="noreferrer" class="row" style="gap:6px">
          <Globe />
          {t.url.replace('https://', '')}
        </a>
      )}
    </div>
  )
}

function Deployments({ svc }) {
  const d = deployments.value
  const list = d.id === svc.id ? d.list : null
  if (!svc.image && !svc.repo) {
    return (
      <div class="card empty">
        <p style="margin:0 0 14px">This service has no source yet.</p>
        <button class="btn primary" onClick={() => setQuery({ tab: 'settings' })}>
          Connect a repository or an image
        </button>
      </div>
    )
  }
  if (!list) return <div class="empty"><Spinner /></div>
  const activeAt = list.findIndex((x) => x.status === 'active')
  const split = activeAt >= 0 ? activeAt + 1 : Math.min(1, list.length)
  const top = list.slice(0, split)
  const history = list.slice(split)
  return (
    <>
      <div class="row" style="margin-bottom:14px;align-items:flex-start">
        <Hosts svc={svc} />
        <span class="spacer" />
        {connectVar(svc) && (
          <button class="btn sm" onClick={() => showConnect(svc)}>
            <Plug /> Connect
          </button>
        )}
        <button class="btn sm primary" onClick={() => deployNow(svc)}>
          <Rocket /> Deploy
        </button>
      </div>
      {list.length === 0 && <div class="card empty">No deployments yet.</div>}
      {top.map((x) => (
        <DeployCard key={x.number} svc={svc} d={x} active={x.status === 'active'} />
      ))}
      {history.length > 0 && (
        <>
          <div class="history-head section-title" onClick={() => (showHistory.value = !showHistory.value)}>
            {showHistory.value ? <ChevronDown width={14} height={14} /> : <ChevronRight width={14} height={14} />}
            History
          </div>
          {showHistory.value && history.map((x) => <DeployCard key={x.number} svc={svc} d={x} active={false} />)}
        </>
      )}
    </>
  )
}

function Backups({ svc }) {
  const b = backups.value
  if (b.id !== svc.id || !b.list) return <div class="empty"><Spinner /></div>
  const make = async () => {
    backingUp.value = svc.id
    await attempt(async () => {
      await post(svcPath(svc, '/backups'), { live: false })
      await loadBackups(svc.id)
    }, 'Backup created')
    backingUp.value = ''
    refresh()
  }
  const restore = (x) =>
    confirm({
      title: `Restore ${x.volume}?`,
      body: `The data of ${x.volume} is replaced by the backup of ${new Date(x.created_at * 1000).toLocaleString()}. The service stops while it is restored.`,
      action: 'Restore',
      onConfirm: async () => {
        await post(svcPath(svc, `/backups/${enc(x.volume)}/${enc(x.id)}/restore`))
        toast('Backup restored', 'success')
        refresh()
      },
    })
  const remove = (x) =>
    confirm({
      title: 'Delete this backup?',
      body: 'It cannot be brought back.',
      action: 'Delete',
      onConfirm: async () => {
        await del(svcPath(svc, `/backups/${enc(x.volume)}/${enc(x.id)}`))
        await loadBackups(svc.id)
      },
    })
  return (
    <>
      <div class="row" style="margin-bottom:14px;flex-wrap:wrap">
        {b.volumes.map((v) => (
          <span key={v.name} class="domain-row" style="margin:0">
            <HardDrive />
            <b>{v.name}</b>
            <span class="mono muted">{v.mount}</span>
            <span class="muted small">{size(v.size)}</span>
          </span>
        ))}
        <span class="spacer" />
        <ScheduleSelect svc={svc} />
        <button class="btn sm primary" onClick={make} disabled={backingUp.value === svc.id}>
          {backingUp.value === svc.id ? <span class="spinner" style="width:13px;height:13px" /> : <Archive />}
          {backingUp.value === svc.id ? 'Backing up...' : 'Backup now'}
        </button>
      </div>
      <p class="muted small" style="margin:0 0 12px">A backup stops the service for a moment so the files are consistent.</p>
      {b.list.length === 0 ? (
        <div class="card empty">No backups yet.</div>
      ) : (
        <table class="table">
          <thead>
            <tr>
              <th>Volume</th>
              <th>Created</th>
              <th>Size</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {b.list.map((x) => (
              <tr key={x.volume + x.id}>
                <td class="mono">{x.volume}</td>
                <td title={new Date(x.created_at * 1000).toLocaleString()}>{timeAgo(x.created_at)}</td>
                <td>{size(x.size)}</td>
                <td style="text-align:right">
                  <button
                    class="btn ghost icon sm"
                    aria-label="Backup menu"
                    onClick={(e) =>
                      openMenu(e.currentTarget, [
                        ['Restore', Undo2, () => restore(x)],
                        null,
                        ['Delete', Trash, () => remove(x), true],
                      ])
                    }
                  >
                    <EllipsisVertical />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  )
}

function ScheduleSelect({ svc }) {
  return (
    <select
      class="select"
      style="width:auto;height:28px;font-size:12.5px"
      value={svc.backup_schedule}
      aria-label="Backup schedule"
      onChange={(e) => attempt(() => update(svc, { backup_schedule: e.currentTarget.value }, true), 'Schedule saved')}
    >
      <option value="">No scheduled backups</option>
      <option value="daily">Daily backups</option>
      <option value="weekly">Weekly backups</option>
    </select>
  )
}

function Runs({ svc }) {
  const r = runs.value
  const last = svc.last_run
  const s = statusOf(svc)
  const runNow = () =>
    attempt(async () => {
      await post(svcPath(svc, '/run'))
      setTimeout(() => loadRuns(svc.id), 800)
    }, 'Run started')
  return (
    <>
      <div class="row" style="margin-bottom:14px">
        <Clock width={16} height={16} />
        <span class="mono">{svc.cron}</span>
        <span class={`status ${s.color}`}>
          <span class={`dot ${s.color}`} />
          {s.label}
        </span>
        {last && last.started_at > 0 && <span class="muted small">{timeAgo(last.started_at)}</span>}
        <span class="spacer" />
        <button class="btn sm primary" onClick={runNow} disabled={svc.deployment === 0}>
          <Play /> Run now
        </button>
      </div>
      {svc.deployment === 0 && <p class="muted small">Deploy it once so it has an image to run.</p>}
      <pre class="logs card" style="max-height:60vh;min-height:200px">{r.id === svc.id ? r.log || 'No runs yet.' : 'Loading...'}</pre>
    </>
  )
}

// Settings ---------------------------------------------------------------

function matches(...words) {
  const q = filter.value.trim().toLowerCase()
  return !q || words.some((w) => w && w.toLowerCase().includes(q))
}

function Group({ label, hint, keys, children }) {
  if (!matches(label, hint, keys)) return null
  return (
    <div class="set-group">
      <b>{label}</b>
      {hint && <p>{hint}</p>}
      {children}
    </div>
  )
}

function Section({ id, icon: Icon, title, keys, children }) {
  if (!matches(title, keys)) return null
  return (
    <section class="set-section" id={`set-${id}`}>
      <span class="ic">
        <Icon />
      </span>
      <div style="min-width:0">
        <h3>{title}</h3>
        {children}
      </div>
    </section>
  )
}

/** A field saved when it loses focus or on Enter. */
function Text({ svc, field, placeholder, live, number, mono = true }) {
  const value = svc[field] ?? ''
  const save = (e) => {
    const raw = e.currentTarget.value.trim()
    const next = number ? (raw === '' ? 0 : Number(raw)) : raw
    if (next === value || (number && Number.isNaN(next))) return
    attempt(() => update(svc, { [field]: next }, live), 'Saved')
  }
  return (
    <input
      class={`input${mono ? ' mono' : ''}`}
      key={`${svc.id}:${value}`}
      defaultValue={number && !value ? '' : value}
      placeholder={placeholder}
      type={number ? 'number' : 'text'}
      spellcheck={false}
      onBlur={save}
      onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
    />
  )
}

function connect(svc, kind) {
  openForm({
    title: kind === 'repo' ? 'Connect a repository' : 'Connect an image',
    submit: 'Connect',
    render: () =>
      kind === 'repo' ? (
        <>
          <div class="field">
            <label for="repo">Repository</label>
            <input class="input mono" id="repo" name="repo" placeholder="owner/name" required autofocus />
          </div>
          <div class="field">
            <label for="branch">Branch</label>
            <input class="input mono" id="branch" name="branch" defaultValue="main" required />
          </div>
        </>
      ) : (
        <div class="field">
          <label for="image">Image</label>
          <input class="input mono" id="image" name="image" placeholder="nginx:alpine" required autofocus />
        </div>
      ),
    onSubmit: async (f) => {
      const body = kind === 'repo' ? { repo: f.repo.trim(), branch: f.branch.trim() } : { image: f.image.trim() }
      await update(svc, { ...body, deploy: true }, true)
      toast('Deploying', 'success')
    },
  })
}

function addDomain(svc) {
  openForm({
    title: 'Custom domain',
    submit: 'Add',
    render: () => (
      <div class="field">
        <label for="domain">Domain</label>
        <input class="input mono" id="domain" name="domain" placeholder="app.example.com" required autofocus />
        <span class="hint">Point its DNS to this phone, or route it through your Cloudflare tunnel.</span>
      </div>
    ),
    onSubmit: async ({ domain }) => {
      await update(svc, { domains: [...svc.domains, domain.trim().toLowerCase()] }, true)
      toast('Domain added', 'success')
    },
  })
}

async function generateDomain(svc) {
  await attempt(async () => {
    const res = await post('/tunnel/quick', { service: svc.id })
    tunnel.value = await get('/tunnel').catch(() => ({ url: res.url, default_service: svc.id, running: true }))
    toast(`Public at ${res.url}`, 'success')
  })
}

function addVolume(svc) {
  openForm({
    title: 'Add a volume',
    submit: 'Add',
    render: () => (
      <>
        <div class="field">
          <label for="vname">Name</label>
          <input class="input mono" id="vname" name="name" defaultValue={`${svc.name}-data`} pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required />
        </div>
        <div class="field">
          <label for="mount">Mount path</label>
          <input class="input mono" id="mount" name="mount" placeholder="/data" pattern="/.*" required autofocus />
          <span class="hint">Files written there survive deploys and restarts.</span>
        </div>
      </>
    ),
    onSubmit: async ({ name, mount }) => {
      await update(svc, { volumes: [...svc.volumes, { name, mount }] })
      toast('Volume added; deploy to mount it', 'success')
    },
  })
}

function removeService(svc) {
  openForm({
    title: `Delete ${svc.name}?`,
    submit: 'Delete service',
    danger: true,
    render: () => (
      <>
        <p class="muted" style="margin:0">
          Its deployments, images, volumes, backups and variables are removed. This cannot be undone.
        </p>
        <div class="field">
          <label for="confirm-name">
            Type <b class="mono">{svc.name}</b> to confirm
          </label>
          <input class="input mono" id="confirm-name" name="name" required autofocus autocomplete="off" />
        </div>
      </>
    ),
    onSubmit: async ({ name }) => {
      if (name !== svc.name) throw new Error('The name does not match')
      await del(svcPath(svc))
      closeService()
      await refresh()
      toast(`${svc.name} deleted`, 'success')
    },
  })
}

const sections = [
  ['source', 'Source'],
  ['networking', 'Networking'],
  ['build', 'Build'],
  ['deploy', 'Deploy'],
  ['volumes', 'Volumes'],
  ['danger', 'Danger'],
]

function Settings({ svc }) {
  const b = backups.value
  const sizes = b.id === svc.id && b.volumes ? Object.fromEntries(b.volumes.map((v) => [v.name, v.size])) : {}
  const t = tunnel.value
  return (
    <div class="settings">
      <div>
        <div class="search" style="width:100%;margin-bottom:22px">
          <Search />
          <input class="input" placeholder="Filter settings..." value={filter.value} onInput={(e) => (filter.value = e.currentTarget.value)} />
        </div>

        <Section id="source" icon={GithubIcon} title="Source" keys="repository image branch root directory auto deploy">
          {svc.repo ? (
            <>
              <Group label="Source Repo" keys="repository github">
                <div class="domain-row">
                  <GithubIcon size={15} />
                  <a href={`https://github.com/${svc.repo}`} target="_blank" rel="noreferrer" class="mono">
                    {svc.repo}
                  </a>
                  <span class="spacer" />
                  <button class="btn sm" onClick={() => attempt(() => update(svc, { repo: '' }), 'Disconnected')}>
                    Disconnect
                  </button>
                </div>
              </Group>
              <Group label="Branch" hint="Pushes to this branch deploy the service." keys="branch">
                <Text svc={svc} field="branch" placeholder="main" />
              </Group>
              <Group label="Root Directory" hint="The folder of the repository the service is built from." keys="root directory monorepo">
                <Text svc={svc} field="root_dir" placeholder="/" />
              </Group>
              <Group label="Auto Deploy" keys="auto deploy push webhook">
                <label class="check">
                  <input type="checkbox" checked={svc.auto_deploy} onChange={(e) => attempt(() => update(svc, { auto_deploy: e.currentTarget.checked }, true), 'Saved')} />
                  Deploy on every push (needs the GitHub webhook of Settings)
                </label>
              </Group>
            </>
          ) : svc.image ? (
            <Group label="Source Image" hint="Pulled again on every deploy." keys="image docker registry">
              <Text svc={svc} field="image" placeholder="nginx:alpine" />
            </Group>
          ) : (
            <Group label="Source" hint="Where the service comes from." keys="repository image">
              <div class="row">
                <button class="btn" onClick={() => connect(svc, 'repo')}>
                  <GithubIcon size={15} /> Connect Repo
                </button>
                <button class="btn" onClick={() => connect(svc, 'image')}>
                  <Box /> Connect Image
                </button>
              </div>
            </Group>
          )}
        </Section>

        <Section id="networking" icon={Network} title="Networking" keys="domain public private port tunnel">
          <Group label="Public Networking" hint="Where the service answers outside the phone." keys="domain public tunnel">
            {svc.hostnames.map((h) => (
              <div class="domain-row" key={h}>
                <Globe />
                <span class="mono">{h === '*' ? 'any other hostname (default service)' : h}</span>
                <span class="spacer" />
                {svc.domains.includes(h) && (
                  <button class="btn ghost icon sm" aria-label={`Remove ${h}`} onClick={() => attempt(() => update(svc, { domains: svc.domains.filter((d) => d !== h) }, true), 'Domain removed')}>
                    <Trash />
                  </button>
                )}
              </div>
            ))}
            {t && t.url && t.default_service === svc.id && (
              <div class="domain-row">
                <Globe color="var(--green)" />
                <a class="mono" href={t.url} target="_blank" rel="noreferrer">
                  {t.url}
                </a>
                <span class="badge green">Tunnel</span>
                <span class="spacer" />
                <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(t.url)}>
                  <Copy />
                </button>
              </div>
            )}
            <div class="row">
              <button class="btn sm" onClick={() => generateDomain(svc)}>
                <Globe /> Generate Domain
              </button>
              <button class="btn sm" onClick={() => addDomain(svc)}>
                <Plus /> Custom Domain
              </button>
            </div>
            <p class="muted small" style="margin:8px 0 0">Generate Domain opens a Cloudflare quick tunnel to this service.</p>
          </Group>
          <Group label="Port" hint="The port the app listens on; PORT is set to it. 8080 when empty." keys="port">
            <Text svc={svc} field="port" placeholder="8080" number />
          </Group>
          <Group label="Private Networking" hint="Other services of this environment reach it at this name." keys="private internal dns">
            <div class="code-box">
              {privateName(svc)}:{svc.port || 8080}
              <span class="spacer" />
              <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(`${privateName(svc)}:${svc.port || 8080}`)}>
                <Copy />
              </button>
            </div>
          </Group>
        </Section>

        <Section id="build" icon={Hammer} title="Build" keys="build command builder dockerfile">
          {svc.repo ? (
            <>
              <Group label="Builder" keys="builder dockerfile nixpacks">
                <p class="muted small" style="margin:0">A Dockerfile is used when there is one; otherwise Node, Python, Go, Rust, PHP, Ruby, Java, Deno, Bun or static sites are detected.</p>
              </Group>
              <Group label="Custom Build Command" hint="Replaces the detected build step." keys="build command">
                <Text svc={svc} field="build_command" placeholder="npm run build" />
              </Group>
            </>
          ) : (
            <Group label="Builder" keys="builder image">
              <p class="muted small" style="margin:0">Images are pulled from their registry; nothing is built. Private registries are set in Settings.</p>
            </Group>
          )}
        </Section>

        <Section id="deploy" icon={Rocket} title="Deploy" keys="start command pre-deploy healthcheck cron sleep serverless restart">
          <Group label="Custom Start Command" hint="Replaces the command of the image or the detected one." keys="start command">
            <Text svc={svc} field="start_command" placeholder="node server.js" />
          </Group>
          <Group label="Pre-deploy Command" hint="Runs in the new image before it starts, e.g. database migrations." keys="pre-deploy migrations">
            <Text svc={svc} field="pre_deploy" placeholder="npm run migrate" />
          </Group>
          <Group label="Healthcheck Path" hint="The new deployment gets the traffic once this path answers 2xx." keys="healthcheck health zero downtime">
            <Text svc={svc} field="health_path" placeholder="/health" />
          </Group>
          <Group label="Cron Schedule" hint="Runs the service on a schedule, to completion, instead of keeping it up." keys="cron schedule job">
            <Text svc={svc} field="cron" placeholder="*/15 * * * *" live />
          </Group>
          <Group label="Serverless" hint="Stops the service after a while without requests; the next request wakes it up." keys="serverless sleep">
            <label class="check" style="margin-bottom:8px">
              <input type="checkbox" checked={svc.sleep_after_s > 0} onChange={(e) => attempt(() => update(svc, { sleep_after_s: e.currentTarget.checked ? 600 : 0 }, true), 'Saved')} />
              Sleep when inactive
            </label>
            {svc.sleep_after_s > 0 && (
              <div class="row">
                <span class="muted small">After</span>
                <div style="width:120px">
                  <Text svc={svc} field="sleep_after_s" number live />
                </div>
                <span class="muted small">seconds without requests</span>
              </div>
            )}
          </Group>
          <Group label="Restart Policy" keys="restart policy">
            <p class="muted small" style="margin:0">Always: a crashed service is started again.</p>
          </Group>
        </Section>

        <Section id="volumes" icon={HardDrive} title="Volumes" keys="volume storage disk backup">
          <Group label="Volumes" hint="Folders that survive deploys. Their backups are in the Backups tab." keys="volume mount">
            {svc.volumes.map((v) => (
              <div class="domain-row" key={v.name}>
                <HardDrive />
                <b>{v.name}</b>
                <span class="mono muted">{v.mount}</span>
                {sizes[v.name] !== undefined && <span class="muted small">{size(sizes[v.name])}</span>}
                <span class="spacer" />
                <button
                  class="btn ghost icon sm"
                  aria-label={`Detach ${v.name}`}
                  onClick={() =>
                    confirm({
                      title: `Detach ${v.name}?`,
                      body: 'The next deploy runs without it. Its files stay on the phone until the service is deleted.',
                      action: 'Detach',
                      onConfirm: () => update(svc, { volumes: svc.volumes.filter((x) => x.name !== v.name) }),
                    })
                  }
                >
                  <Trash />
                </button>
              </div>
            ))}
            <button class="btn sm" onClick={() => addVolume(svc)}>
              <Plus /> Add Volume
            </button>
          </Group>
          {svc.volumes.length > 0 && (
            <Group label="Backup Schedule" hint="Backups are kept on the phone; the last 7 are kept." keys="backup schedule">
              <ScheduleSelect svc={svc} />
            </Group>
          )}
        </Section>

        <Section id="danger" icon={TriangleExclamationPoint} title="Danger" keys="delete remove">
          <Group label="Delete Service" hint="Removes the service and everything it stored." keys="delete remove">
            <button class="btn danger" onClick={() => removeService(svc)}>
              <Trash /> Delete service
            </button>
          </Group>
        </Section>
      </div>
      <nav class="index">
        {sections.map(([id, label]) => (
          <a
            key={id}
            href={`#set-${id}`}
            onClick={(e) => {
              e.preventDefault()
              document.getElementById(`set-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
            }}
          >
            {label}
          </a>
        ))}
      </nav>
    </div>
  )
}

export function ServicePanel() {
  const p = page.value
  const list = services.value
  const svc = list && list.find((s) => s.name === p.service)
  if (!list) return null
  if (!svc) {
    return (
      <aside class="panel">
        <div class="empty">
          <p>No service named {p.service} in {p.env}.</p>
          <button class="btn" onClick={closeService}>
            Back to the canvas
          </button>
        </div>
      </aside>
    )
  }
  const tabs = [
    dbKind(svc) && ['data', 'Data'],
    ['deployments', 'Deployments'],
    ['variables', 'Variables'],
    ['metrics', 'Metrics'],
    !svc.cron && ['console', 'Console'],
    svc.volumes.length > 0 && ['backups', 'Backups'],
    svc.cron && ['runs', 'Cron Runs'],
    ['settings', 'Settings'],
  ].filter(Boolean)
  // The first tab is the default one, and has no ?tab= in the URL.
  const tab = tabs.some(([id]) => id === p.tab) ? p.tab : tabs[0][0]
  return (
    <>
      <aside class="panel" aria-label={svc.name}>
        <div class="panel-head">
          <div class="panel-title">
            <ServiceIcon svc={svc} size={22} />
            <h2>{svc.name}</h2>
            <span class="spacer" />
            <button class="btn ghost icon" aria-label="Close" onClick={closeService}>
              <X />
            </button>
          </div>
          <nav class="tabs">
            {tabs.map(([id, label]) => (
              <button key={id} class={`tab${tab === id ? ' active' : ''}`} onClick={() => setQuery({ tab: id === tabs[0][0] ? undefined : id }, true)}>
                {label}
              </button>
            ))}
          </nav>
        </div>
        <div class="panel-body">
          {tab === 'data' && <DataTab svc={svc} />}
          {tab === 'deployments' && <Deployments svc={svc} />}
          {tab === 'variables' && (
            <VariablesEditor
              base={`/services/${enc(svc.id)}/variables`}
              title="Service Variables"
              hint={'Reference other services with ${{ name.VARIABLE }} and shared ones with ${{ shared.VARIABLE }}.'}
              onChange={() => markDirty(svc)}
            />
          )}
          {tab === 'metrics' && <MetricsTab svc={svc} />}
          {tab === 'console' && <ConsoleTab svc={svc} />}
          {tab === 'backups' && <Backups svc={svc} />}
          {tab === 'runs' && <Runs svc={svc} />}
          {tab === 'settings' && <Settings svc={svc} />}
        </div>
      </aside>
      {p.logs && <LogsView />}
    </>
  )
}
