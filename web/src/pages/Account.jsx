// The signed-in user: password, two-factor authentication and API tokens.

import { effect, signal, untracked } from '@preact/signals'
import { Copy, KeyRound, Plus, Shield, Trash, User } from 'lucide-preact'
import qrcode from 'qrcode-generator'
import { del, get, post } from '../api.js'
import { me, toast } from '../state.js'
import { navigate, route, withQuery } from '../router.js'
import { attempt, confirm, copy, openForm, timeAgo } from '../ui.jsx'
import { SettingsLayout } from './SettingsLayout.jsx'

const tokens = signal(null)
/** The token just created: shown once. */
const fresh = signal(null)
const totp = signal(null)

async function loadTokens() {
  try {
    tokens.value = await get('/tokens')
  } catch (err) {
    toast(err.message, 'error')
  }
}

effect(() => {
  if (me.value && route.value.path === '/account') untracked(loadTokens)
})

function changePassword() {
  openForm({
    title: 'Change password',
    submit: 'Change password',
    render: () => (
      <>
        <div class="field">
          <label for="cur">Current password</label>
          <input class="input" id="cur" name="current" type="password" autocomplete="current-password" required autofocus />
        </div>
        <div class="field">
          <label for="np">New password</label>
          <input class="input" id="np" name="next" type="password" autocomplete="new-password" minLength={8} required />
        </div>
        <div class="field">
          <label for="np2">Confirm the new password</label>
          <input class="input" id="np2" name="confirm" type="password" autocomplete="new-password" required />
        </div>
        <p class="muted small" style="margin:0">Your other sessions are signed out.</p>
      </>
    ),
    onSubmit: async (f) => {
      if (f.next !== f.confirm) throw new Error('The new passwords do not match')
      await post('/me/password', { current: f.current, new: f.next })
      toast('Password changed', 'success')
    },
  })
}

async function startTotp() {
  await attempt(async () => {
    const res = await post('/me/2fa/setup')
    const qr = qrcode(0, 'M')
    qr.addData(res.uri)
    qr.make()
    totp.value = { ...res, image: qr.createDataURL(5, 0) }
  })
}

async function enableTotp(e) {
  e.preventDefault()
  const code = e.currentTarget.elements.code.value.replace(/\s/g, '')
  await attempt(async () => {
    await post('/me/2fa/enable', { code })
    totp.value = null
    me.value = { ...me.value, totp_enabled: true }
  }, 'Two-factor authentication is on')
}

function disableTotp() {
  openForm({
    title: 'Turn off two-factor authentication',
    submit: 'Turn off',
    danger: true,
    render: () => (
      <div class="field">
        <label for="dcode">Code from your authenticator app</label>
        <input class="input mono" id="dcode" name="code" inputMode="numeric" autocomplete="one-time-code" required autofocus />
      </div>
    ),
    onSubmit: async ({ code }) => {
      await post('/me/2fa/disable', { code: code.replace(/\s/g, '') })
      me.value = { ...me.value, totp_enabled: false }
      toast('Two-factor authentication is off', 'success')
    },
  })
}

function newToken() {
  openForm({
    title: 'New API token',
    submit: 'Create',
    render: () => (
      <div class="field">
        <label for="tname">Name</label>
        <input class="input" id="tname" name="name" placeholder="ci, laptop..." required autofocus />
        <span class="hint">Send it as "Authorization: Bearer ..." to /api/. It can do everything you can.</span>
      </div>
    ),
    onSubmit: async ({ name }) => {
      fresh.value = await post('/tokens', { name })
      await loadTokens()
    },
  })
}

function removeToken(t) {
  confirm({
    title: `Revoke ${t.name}?`,
    body: 'Anything using it stops working.',
    action: 'Revoke',
    onConfirm: async () => {
      await del(`/tokens/${encodeURIComponent(t.id)}`)
      if (fresh.peek() && fresh.peek().id === t.id) fresh.value = null
      await loadTokens()
    },
  })
}

function TwoFactor({ user }) {
  const setup = totp.value
  if (user.totp_enabled) {
    return (
      <div class="row">
        <span class="badge green">On</span>
        <span class="muted small" style="flex:1">Signing in asks for a code from your authenticator app.</span>
        <button class="btn danger sm" onClick={disableTotp}>
          Turn off
        </button>
      </div>
    )
  }
  if (!setup) {
    return (
      <div class="row">
        <span class="badge">Off</span>
        <span class="muted small" style="flex:1">Ask for a code from an authenticator app when signing in.</span>
        <button class="btn sm primary" onClick={startTotp}>
          Set up
        </button>
      </div>
    )
  }
  return (
    <div class="row" style="align-items:flex-start;gap:20px;flex-wrap:wrap">
      <img class="qr" src={setup.image} alt="QR code for the authenticator app" />
      <form class="stack" style="flex:1;min-width:220px" onSubmit={enableTotp}>
        <p class="muted small" style="margin:0">Scan the code with your authenticator app, or enter this key:</p>
        <div class="code-box">
          {setup.secret}
          <span class="spacer" />
          <button type="button" class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(setup.secret)}>
            <Copy />
          </button>
        </div>
        <div class="field">
          <label for="code">Code from the app</label>
          <input class="input mono" id="code" name="code" inputMode="numeric" autocomplete="one-time-code" required autofocus />
        </div>
        <div class="row">
          <button class="btn primary">Turn on</button>
          <button type="button" class="btn ghost" onClick={() => (totp.value = null)}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}

const sections = [
  ['profile', 'Profile', User],
  ['security', 'Security', Shield],
  ['tokens', 'API Tokens', KeyRound],
]

export function Account() {
  const user = me.value
  const list = tokens.value
  const made = fresh.value
  const tab = sections.some(([id]) => id === route.value.query.tab) ? route.value.query.tab : 'profile'
  return (
    <SettingsLayout title="Account" items={sections} current={tab} onSelect={(id) => navigate(withQuery('/account', { tab: id === 'profile' ? undefined : id }), true)}>
      {tab === 'profile' && (
      <section class="card card-pad set-card">
        <h3>Profile</h3>
        <div class="row">
          <span class="avatar" style="width:40px;height:40px;font-size:15px">{user.email ? user.email[0].toUpperCase() : '?'}</span>
          <div style="flex:1">
            <b>{user.email}</b>
            {user.created_at > 0 && <div class="muted small">Member since {new Date(user.created_at * 1000).toLocaleDateString()}</div>}
          </div>
          <span class={`badge${user.totp_enabled ? ' green' : ''}`}>{user.totp_enabled ? '2FA on' : '2FA off'}</span>
        </div>
      </section>
      )}
      {tab === 'security' && (
        <>
          <section class="card card-pad set-card">
            <h3>Password</h3>
            <div class="row">
              <span class="muted small" style="flex:1">Changing it signs out your other sessions.</span>
              <button class="btn sm" onClick={changePassword}>
                <KeyRound /> Change password
              </button>
            </div>
          </section>
      <section class="card card-pad set-card">
        <h3 class="row">
          <Shield width={16} height={16} /> Two-factor authentication
        </h3>
        <TwoFactor user={user} />
      </section>
        </>
      )}
      {tab === 'tokens' && (
      <section class="card card-pad set-card">
        <div class="row" style="margin-bottom:12px">
          <h3 style="margin:0">API Tokens</h3>
          <span class="spacer" />
          <button class="btn sm" onClick={newToken}>
            <Plus /> New token
          </button>
        </div>
        {made && (
          <div class="banner" style="flex-direction:column;align-items:stretch">
            <span>
              Copy <b>{made.name}</b> now: it is not shown again.
            </span>
            <div class="code-box">
              {made.token}
              <span class="spacer" />
              <button class="btn ghost icon sm" aria-label="Copy" onClick={() => copy(made.token)}>
                <Copy />
              </button>
            </div>
          </div>
        )}
        {list && list.length === 0 && <div class="empty small">No tokens yet.</div>}
        {list && list.length > 0 && (
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Token</th>
                <th>Created</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {list.map((t) => (
                <tr key={t.id}>
                  <td>{t.name}</td>
                  <td class="mono muted">{t.hint}</td>
                  <td>{timeAgo(t.created_at)}</td>
                  <td style="text-align:right">
                    <button class="btn ghost icon sm" aria-label={`Revoke ${t.name}`} onClick={() => removeToken(t)}>
                      <Trash />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
      )}
    </SettingsLayout>
  )
}
