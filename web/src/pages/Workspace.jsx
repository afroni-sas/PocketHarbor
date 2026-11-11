// Settings of the whole phone: domains, public access, GitHub, image
// registries and the people who can sign in.

import { effect, signal, untracked } from '@preact/signals'
import { Copy, Eye, EyeOff, Plus, Server, Trash } from 'lucide-preact'
import { del, get, patch, post, put } from '../api.js'
import { me, toast } from '../state.js'
import { navigate, route, withQuery } from '../router.js'
import { attempt, confirm, copy, openForm, Spinner, timeAgo } from '../ui.jsx'
import { Alerts } from './Alerts.jsx'

const data = signal({ settings: null, github: null, tunnel: null, registries: null, users: null, services: null })
const showSecret = signal(false)
const starting = signal(false)

const loaders = {
  general: async () => ({ settings: await get('/settings') }),
  networking: async () => {
    const [tunnel, services, settings] = await Promise.all([get('/tunnel'), get('/services'), get('/settings')])
    return { tunnel, services, settings }
  },
  github: async () => ({ github: await get('/github') }),
  registries: async () => ({ registries: await get('/registries') }),
  members: async () => ({ users: await get('/users') }),
  // Alerts.jsx loads its own data.
  alerts: async () => ({}),
}

async function load(tab) {
  try {
    const got = await loaders[tab]()
    data.value = { ...data.peek(), ...got }
  } catch (err) {
    toast(err.message, 'error')
  }
}

const tabs = [
  ['general', 'General'],
  ['networking', 'Public access'],
  ['github', 'GitHub'],
  ['registries', 'Registries'],
  ['alerts', 'Alerts'],
  ['members', 'Members'],
]

const currentTab = () => {
  const t = route.value.query.tab
  return tabs.some(([id]) => id === t) ? t : 'general'
}

effect(() => {
  if (!me.value || route.value.path !== '/settings') return
  const tab = currentTab()
  untracked(() => load(tab))
})

function DomainField({ field, label, hint, placeholder }) {
  const s = data.value.settings
  const value = s[field] || ''
  const save = (e) => {
    const next = e.currentTarget.value.trim().toLowerCase()
    if (next === value) return
    attempt(async () => {
      const saved = await patch('/settings', { [field]: next })
      data.value = { ...data.peek(), settings: saved }
    }, 'Saved')
  }
  return (
    <div class="field">
      <label>{label}</label>
      <input class="input mono" key={value} defaultValue={value} placeholder={placeholder} onBlur={save} onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()} />
      <span class="hint">{hint}</span>
    </div>
  )
}

function General() {
  const s = data.value.settings
  if (!s) return <Spinner />
  return (
    <>
      <section class="card card-pad set-card">
        <h3>Domains</h3>
        <div class="stack">
          <DomainField
            field="base_domain"
            label="Base domain"
            placeholder="apps.example.com"
            hint="Every service also answers at <service>.<base domain>. Point a wildcard DNS record or a tunnel to the phone."
          />
          <DomainField field="panel_domain" label="Dashboard domain" placeholder="harbor.example.com" hint="This dashboard answers there too, besides the phone's own address." />
        </div>
      </section>
      <section class="card card-pad set-card">
        <h3>Ports</h3>
        <div class="row" style="gap:24px">
          <div>
            <div class="muted small">Proxy</div>
            <b class="mono">{s.proxy_port}</b>
          </div>
          <div>
            <div class="muted small">Dashboard</div>
            <b class="mono">{s.panel_port}</b>
          </div>
        </div>
        <p class="muted small" style="margin:10px 0 0">The proxy listens where pharbor serve --listen says. The dashboard only listens on 127.0.0.1 and is reached through the proxy.</p>
      </section>
    </>
  )
}

async function quickTunnel(e) {
  e.preventDefault()
  const service = e.currentTarget.elements.service.value
  starting.value = true
  try {
    const res = await post('/tunnel/quick', { service })
    toast(`Public at ${res.url}`, 'success')
    await load('networking')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    starting.value = false
  }
}

async function namedTunnel(e) {
  e.preventDefault()
  const token = e.currentTarget.elements.token.value.trim()
  starting.value = true
  try {
    await post('/tunnel/named', { token })
    toast('Tunnel started', 'success')
    await load('networking')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    starting.value = false
  }
}

function stopTunnel() {
  confirm({
    title: 'Stop the tunnel?',
    body: 'Services stop answering from the internet; they keep running on the phone.',
    action: 'Stop',
    onConfirm: async () => {
      await del('/tunnel')
      await load('networking')
    },
  })
}

function Networking() {
  const { tunnel, services } = data.value
  if (!tunnel || !services) return <Spinner />
  const busy = starting.value
  return (
    <>
      <section class="card card-pad set-card">
        <h3>Cloudflare tunnel</h3>
        {tunnel.running ? (
          <>
            <div class="domain-row">
              <span class="dot green" />
              <span style="flex:1">{tunnel.status || 'Running'}</span>
              <button class="btn sm danger" onClick={stopTunnel}>
                Stop
              </button>
            </div>
            {tunnel.url && (
              <div class="code-box">
                <a href={tunnel.url} target="_blank" rel="noreferrer">
                  {tunnel.url}
                </a>
                <span class="spacer" />
                <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(tunnel.url)}>
                  <Copy />
                </button>
              </div>
            )}
          </>
        ) : (
          <p class="muted small" style="margin:0">
            No tunnel is running. A tunnel makes services reachable from the internet without opening a port.
          </p>
        )}
      </section>
      <section class="card card-pad set-card">
        <h3>Quick tunnel</h3>
        <p class="muted small" style="margin:-6px 0 12px">A random trycloudflare.com address for one service. No account needed; the address changes on restart.</p>
        <form class="row" onSubmit={quickTunnel}>
          <select class="select" name="service" required style="flex:1" defaultValue={tunnel.default_service}>
            {services.map((s) => (
              <option key={s.id} value={s.id}>
                {s.project} / {s.environment} / {s.name}
              </option>
            ))}
          </select>
          <button class="btn primary" disabled={busy || services.length === 0}>
            {busy && <span class="spinner" style="width:13px;height:13px" />}
            Start
          </button>
        </form>
      </section>
      <section class="card card-pad set-card">
        <h3>Named tunnel</h3>
        <p class="muted small" style="margin:-6px 0 12px">
          Your own domains through a tunnel of your Cloudflare account. Create it in Zero Trust, route its hostnames to http://localhost:{data.value.settings?.proxy_port || 8080}, then paste its token.
        </p>
        <form class="row" onSubmit={namedTunnel}>
          <input class="input mono" name="token" type="password" placeholder="eyJhIjoi..." required autocomplete="off" style="flex:1" />
          <button class="btn primary" disabled={busy}>
            Start
          </button>
        </form>
      </section>
    </>
  )
}

function setGithubToken(remove) {
  if (remove) {
    return confirm({
      title: 'Remove the GitHub token?',
      body: 'Builds of private repositories stop working.',
      action: 'Remove',
      onConfirm: async () => {
        await put('/github', { token: '' })
        await load('github')
      },
    })
  }
  openForm({
    title: 'GitHub token',
    submit: 'Save',
    render: () => (
      <div class="field">
        <label for="ghtoken">Personal access token</label>
        <input class="input mono" id="ghtoken" name="token" type="password" placeholder="github_pat_..." required autofocus autocomplete="off" />
        <span class="hint">A fine-grained token with read access to the contents of the repositories. It is stored encrypted.</span>
      </div>
    ),
    onSubmit: async ({ token }) => {
      await put('/github', { token: token.trim() })
      await load('github')
      toast('Token saved', 'success')
    },
  })
}

function Github() {
  const g = data.value.github
  if (!g) return <Spinner />
  const tunnel = data.value.tunnel
  const origin = tunnel && tunnel.url ? tunnel.url : location.origin
  const url = origin + g.webhook_path
  return (
    <>
      <section class="card card-pad set-card">
        <h3>Access</h3>
        <div class="row">
          <span class={`badge${g.has_token ? ' green' : ''}`}>{g.has_token ? 'Token set' : 'No token'}</span>
          <span class="muted small" style="flex:1">{g.has_token ? 'Private repositories can be built.' : 'Public repositories build without one.'}</span>
          {g.has_token && (
            <button class="btn sm" onClick={() => setGithubToken(true)}>
              Remove
            </button>
          )}
          <button class="btn sm primary" onClick={() => setGithubToken(false)}>
            {g.has_token ? 'Replace' : 'Add token'}
          </button>
        </div>
      </section>
      <section class="card card-pad set-card">
        <h3>Deploy on push</h3>
        <p class="muted small" style="margin:-6px 0 12px">
          In the repository, open Settings, Webhooks, Add webhook, with the content type application/json and the push event. GitHub must reach the phone, through a tunnel or a domain.
        </p>
        <div class="stack">
          <div class="field">
            <label>Payload URL</label>
            <div class="code-box">
              {url}
              <span class="spacer" />
              <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(url)}>
                <Copy />
              </button>
            </div>
          </div>
          <div class="field">
            <label>Secret</label>
            <div class="code-box">
              {showSecret.value ? g.webhook_secret : '•'.repeat(24)}
              <span class="spacer" />
              <button class="btn ghost icon sm" aria-label={showSecret.value ? 'Hide' : 'Show'} onClick={() => (showSecret.value = !showSecret.value)}>
                {showSecret.value ? <EyeOff /> : <Eye />}
              </button>
              <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(g.webhook_secret)}>
                <Copy />
              </button>
            </div>
          </div>
        </div>
      </section>
    </>
  )
}

function addRegistry() {
  openForm({
    title: 'Sign in to a registry',
    submit: 'Sign in',
    render: () => (
      <>
        <div class="field">
          <label for="rhost">Registry</label>
          <input class="input mono" id="rhost" name="host" placeholder="ghcr.io" required autofocus />
        </div>
        <div class="field">
          <label for="ruser">Username</label>
          <input class="input" id="ruser" name="username" required autocomplete="off" />
        </div>
        <div class="field">
          <label for="rpass">Password or token</label>
          <input class="input mono" id="rpass" name="password" type="password" required autocomplete="off" />
        </div>
      </>
    ),
    onSubmit: async (f) => {
      await post('/registries', { host: f.host.trim(), username: f.username.trim(), password: f.password })
      await load('registries')
      toast(`Signed in to ${f.host}`, 'success')
    },
  })
}

function Registries() {
  const list = data.value.registries
  if (!list) return <Spinner />
  return (
    <section class="card card-pad set-card">
      <div class="row" style="margin-bottom:12px">
        <h3 style="margin:0">Private registries</h3>
        <span class="spacer" />
        <button class="btn sm" onClick={addRegistry}>
          <Plus /> Add registry
        </button>
      </div>
      <p class="muted small" style="margin:0 0 12px">Images of these registries can be pulled with the credentials kept on the phone.</p>
      {list.length === 0 && <div class="empty small">None yet. Public images need nothing.</div>}
      {list.map((host) => (
        <div class="domain-row" key={host}>
          <Server />
          <span class="mono" style="flex:1">
            {host}
          </span>
          <button
            class="btn ghost icon sm"
            aria-label={`Sign out of ${host}`}
            onClick={() =>
              confirm({
                title: `Sign out of ${host}?`,
                body: 'Its private images can no longer be pulled.',
                action: 'Sign out',
                onConfirm: async () => {
                  await del(`/registries/${encodeURIComponent(host)}`)
                  await load('registries')
                },
              })
            }
          >
            <Trash />
          </button>
        </div>
      ))}
    </section>
  )
}

function addMember() {
  openForm({
    title: 'Add a member',
    submit: 'Add',
    render: () => (
      <>
        <div class="field">
          <label for="memail">Email</label>
          <input class="input" id="memail" name="email" type="email" required autofocus autocomplete="off" />
        </div>
        <div class="field">
          <label for="mpass">Password</label>
          <input class="input" id="mpass" name="password" type="password" minLength={8} required autocomplete="new-password" />
          <span class="hint">Give it to them; they can change it in their account.</span>
        </div>
      </>
    ),
    onSubmit: async (f) => {
      await post('/users', { email: f.email.trim(), password: f.password })
      await load('members')
      toast(`${f.email} can sign in`, 'success')
    },
  })
}

function Members() {
  const list = data.value.users
  if (!list) return <Spinner />
  const self = me.value
  return (
    <section class="card card-pad set-card">
      <div class="row" style="margin-bottom:12px">
        <h3 style="margin:0">Members</h3>
        <span class="spacer" />
        <button class="btn sm" onClick={addMember}>
          <Plus /> Add member
        </button>
      </div>
      <table class="table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Two-factor</th>
            <th>Added</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {list.map((u) => (
            <tr key={u.id}>
              <td>
                {u.email}
                {self && self.id === u.id && <span class="badge" style="margin-left:8px">you</span>}
              </td>
              <td>{u.totp_enabled ? <span class="badge green">On</span> : <span class="badge">Off</span>}</td>
              <td>{timeAgo(u.created_at)}</td>
              <td style="text-align:right">
                {!(self && self.id === u.id) && (
                  <button
                    class="btn ghost icon sm"
                    aria-label={`Remove ${u.email}`}
                    onClick={() =>
                      confirm({
                        title: `Remove ${u.email}?`,
                        body: 'They are signed out and can no longer sign in.',
                        action: 'Remove',
                        onConfirm: async () => {
                          await del(`/users/${encodeURIComponent(u.id)}`)
                          await load('members')
                        },
                      })
                    }
                  >
                    <Trash />
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

const views = { general: General, networking: Networking, github: Github, registries: Registries, alerts: Alerts, members: Members }

export function Workspace() {
  const tab = currentTab()
  const View = views[tab]
  return (
    <div class="page" style="max-width:860px">
      <div class="page-head">
        <h1>Settings</h1>
      </div>
      <nav class="tabs" style="margin-bottom:22px">
        {tabs.map(([id, label]) => (
          <button key={id} class={`tab${tab === id ? ' active' : ''}`} onClick={() => navigate(withQuery('/settings', { tab: id === 'general' ? undefined : id }), true)}>
            {label}
          </button>
        ))}
      </nav>
      <View />
    </div>
  )
}
