// Settings of the whole phone: domains, public access, GitHub, image
// registries and the people who can sign in.

import { effect, signal, untracked } from '@preact/signals'
import { Bell, Cloud, Copy, ExternalLink, Eye, EyeOff, Plus, Server, Settings as SettingsIcon, Trash, Users } from 'lucide-preact'
import { del, get, patch, post, put } from '../api.js'
import { me, toast } from '../state.js'
import { navigate, route, withQuery } from '../router.js'
import { attempt, confirm, copy, GithubIcon, openForm, Spinner, timeAgo } from '../ui.jsx'
import { SettingsLayout } from './SettingsLayout.jsx'
import { Alerts } from './Alerts.jsx'

const data = signal({ settings: null, github: null, tunnel: null, registries: null, users: null, services: null })
const showSecret = signal(false)
const starting = signal(false)

const loaders = {
  general: async () => ({ settings: await get('/settings') }),
  networking: async () => {
    const [tunnel, services, settings, cloudflare] = await Promise.all([get('/tunnel'), get('/services'), get('/settings'), get('/cloudflare')])
    return { tunnel, services, settings, cloudflare }
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
  ['general', 'General', SettingsIcon],
  ['networking', 'Public access', Cloud],
  ['github', 'GitHub', GithubIcon],
  ['registries', 'Registries', Server],
  ['alerts', 'Alerts', Bell],
  ['members', 'Members', Users],
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

/** The token, and the Account ID if any, out of whatever was pasted: the
 * token alone, or all that Cloudflare shows once it is made. */
export function readCloudflarePaste(text) {
  const word = text.trim()
  const token =
    (text.match(/cf[a-z]{2}_[A-Za-z0-9_-]{20,}/) || text.match(/(?<![\w-])[\w-]{40}(?![\w-])/) || [/^\S{20,}$/.test(word) ? word : ''])[0]
  const account = (text.replace(token, '').match(/(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])/i) || [''])[0]
  return { token, account }
}

async function connectCloudflare(e) {
  e.preventDefault()
  const form = e.currentTarget
  const { token, account } = readCloudflarePaste(form.elements.token.value)
  if (!token) return toast('Paste the token that Cloudflare shows', 'error')
  starting.value = true
  try {
    await put('/cloudflare', { token, account })
    form.reset()
    toast('Cloudflare connected', 'success')
    await load('networking')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    starting.value = false
  }
}

async function syncCloudflare() {
  starting.value = true
  try {
    await post('/cloudflare/sync')
    toast('Up to date', 'success')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    starting.value = false
    await load('networking')
  }
}

function disconnectCloudflare() {
  confirm({
    title: 'Disconnect Cloudflare?',
    body: 'Your domains stop answering from the internet. The services keep running.',
    action: 'Disconnect',
    onConfirm: async () => {
      await del('/cloudflare')
      await load('networking')
    },
  })
}

async function saveChoice(body, done) {
  starting.value = true
  try {
    await patch('/cloudflare', body)
    toast(done, 'success')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    starting.value = false
    await load('networking')
  }
}

// While cloudflared starts, the card asks again every few seconds.
let connectorTimer = 0
function watchConnector(state) {
  clearTimeout(connectorTimer)
  if (state === 'starting') connectorTimer = setTimeout(() => route.peek().query.tab === 'networking' && load('networking'), 3000)
}

async function startConnector() {
  try {
    await post('/cloudflare/start')
    await load('networking')
  } catch (err) {
    toast(err.message, 'error')
  }
}

function Check({ ok, wait, label, title }) {
  return (
    <span class={`cf-check ${wait ? 'wait' : ok ? 'ok' : 'off'}`} title={title}>
      {wait ? <span class="spinner" style="width:11px;height:11px" /> : <span class={`dot ${ok ? 'green' : 'yellow'}`} />}
      {label}
    </span>
  )
}

function CloudflareCard() {
  const cf = data.value.cloudflare
  if (!cf) return null
  const busy = starting.value
  const st = cf.state || {}
  const zones = st.zones || []
  if (!cf.connected) {
    return (
      <section class="card card-pad set-card">
        <h3>Cloudflare</h3>
        <p class="muted small" style="margin:-6px 0 14px">Your services on the internet, over HTTPS, with no port to open.</p>
        <a class="btn primary" href={cf.create_url} target="_blank" rel="noreferrer">
          Create the token on Cloudflare <ExternalLink />
        </a>
        <form class="cf-paste" onSubmit={connectCloudflare}>
          <input class="input mono" name="token" type="password" placeholder="Paste the token here" required autocomplete="off" aria-label="Cloudflare token" />
          <button class="btn" disabled={busy}>
            {busy && <span class="spinner" style="width:13px;height:13px" />}
            Connect
          </button>
        </form>
        <p class="muted small" style="margin:8px 0 0">The permissions are filled in: Continue to summary, Create Token, then paste it here.</p>
      </section>
    )
  }
  watchConnector(cf.connector)
  const problems = [cf.connector === 'stopped' && 'The tunnel is stopped.', st.error, cf.relay && !cf.relay.ready && cf.relay.error].filter(Boolean)
  return (
    <section class="card card-pad set-card">
      <div class="cf-head">
        <h3>Cloudflare</h3>
        <span class="spacer" />
        <button class="btn sm" onClick={syncCloudflare} disabled={busy} title={st.synced_at ? `Synced ${timeAgo(st.synced_at)}` : undefined}>
          {busy && <span class="spinner" style="width:12px;height:12px" />} Sync
        </button>
        <button class="btn sm danger" onClick={disconnectCloudflare} disabled={busy}>
          Disconnect
        </button>
      </div>
      <div class="cf-checks">
        <Check ok={cf.connector === 'running'} wait={cf.connector === 'starting'} label="Tunnel" title={cf.connector === 'starting' ? 'Starting: cloudflared is downloaded the first time' : undefined} />
        <Check ok={cf.relay && cf.relay.ready} label="Relay" title="workers.dev addresses, with no domain" />
        <Check ok={zones.length > 0} label={zones.length ? zones.join(', ') : 'No zone'} title="Your domains on Cloudflare" />
      </div>
      {cf.relay && cf.relay.dashboard && (
        <div class="cf-line">
          <span class="muted small">Dashboard</span>
          <a class="mono small" href={`https://${cf.relay.dashboard}`} target="_blank" rel="noreferrer">
            {cf.relay.dashboard}
          </a>
          <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(`https://${cf.relay.dashboard}`)}>
            <Copy />
          </button>
        </div>
      )}
      {problems.map((p) => (
        <div class="banner warn" key={p}>
          {p}
          {p === 'The tunnel is stopped.' && (
            <button class="btn sm" onClick={startConnector}>
              Start
            </button>
          )}
        </div>
      ))}
      <label class="cf-line">
        <span class="muted small" title="Where Generate Domain puts names">Generated domains</span>
        <select class="select" value={cf.generated_zone} onChange={(e) => saveChoice({ generated_zone: e.currentTarget.value }, 'Saved')}>
          <option value="">workers.dev · 100k requests a day</option>
          {zones.map((z) => (
            <option key={z} value={z}>
              {z} · no limit
            </option>
          ))}
        </select>
      </label>
      {zones.length > 0 && (
        <label class="cf-line">
          <span class="muted small" title="Domains in another account or at another provider: two records to add where their DNS is. Needs Cloudflare for SaaS on the zone.">Outside domains</span>
          <select class="select" value={cf.saas_zone} onChange={(e) => saveChoice({ saas_zone: e.currentTarget.value }, 'Saved')}>
            <option value="">Off</option>
            {zones.map((z) => (
              <option key={z} value={z}>
                through {z}
              </option>
            ))}
          </select>
        </label>
      )}
      {st.hosts && st.hosts.length > 0 && (
        <details class="cf-details">
          <summary class="muted small">{st.hosts.length} names</summary>
          {st.hosts.map((h) => (
            <div class="cf-host" key={h.host}>
              <span class={`dot ${h.state === 'ready' || h.state === 'relay' || (h.state === 'foreign' && h.active) ? 'green' : 'yellow'}`} />
              <span class="mono">{h.host}</span>
              {h.detail && <span class="muted small cf-detail">{h.detail}</span>}
            </div>
          ))}
        </details>
      )}
    </section>
  )
}

function Networking() {
  const { tunnel, services } = data.value
  if (!tunnel || !services) return <Spinner />
  const busy = starting.value
  const managed = data.value.cloudflare && data.value.cloudflare.connected
  return (
    <>
      <CloudflareCard />
      {!managed && (
        <details class="card card-pad set-card cf-manual">
          <summary>
            <b>Without a Cloudflare account</b>
          </summary>
          <h4>Quick tunnel</h4>
          <p class="muted small">A temporary trycloudflare.com address for one service.</p>
          {tunnel.running && tunnel.url ? (
            <div class="code-box">
              <a href={tunnel.url} target="_blank" rel="noreferrer">
                {tunnel.url}
              </a>
              <span class="spacer" />
              <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(tunnel.url)}>
                <Copy />
              </button>
              <button class="btn sm danger" onClick={stopTunnel}>
                Stop
              </button>
            </div>
          ) : (
            <form class="row" onSubmit={quickTunnel}>
              <select class="select" name="service" required style="flex:1" defaultValue={tunnel.default_service}>
                {services.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.project} / {s.environment} / {s.name}
                  </option>
                ))}
              </select>
              <button class="btn" disabled={busy || services.length === 0}>
                {busy && <span class="spinner" style="width:13px;height:13px" />}
                Start
              </button>
            </form>
          )}
          <h4>Tunnel made by hand</h4>
          <p class="muted small">Its token, from Zero Trust › Networks › Tunnels. Point its hostnames at http://localhost:{data.value.settings?.proxy_port || 8080}.</p>
          <form class="row" onSubmit={namedTunnel}>
            <input class="input mono" name="token" type="password" placeholder="eyJhIjoi..." required autocomplete="off" style="flex:1" />
            <button class="btn" disabled={busy}>
              Start
            </button>
          </form>
        </details>
      )}
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
    <SettingsLayout title="Settings" items={tabs} current={tab} onSelect={(id) => navigate(withQuery('/settings', { tab: id === 'general' ? undefined : id }), true)}>
      <View />
    </SettingsLayout>
  )
}
