import { signal } from '@preact/signals'
import { post } from '../api.js'
import { me, status } from '../state.js'
import { values } from '../ui.jsx'

const busy = signal(false)
const error = signal('')
const needCode = signal(false)

async function submit(e, path) {
  e.preventDefault()
  const form = values(e.currentTarget)
  if (path === '/setup' && form.password !== form.confirm) {
    error.value = 'The passwords do not match'
    return
  }
  busy.value = true
  error.value = ''
  try {
    const user = await post(path, { email: form.email, password: form.password, code: form.code || undefined })
    status.value = { ...status.value, setup_needed: false }
    needCode.value = false
    me.value = user
  } catch (err) {
    if (err.data && err.data.code_required) needCode.value = true
    error.value = err.message
  } finally {
    busy.value = false
  }
}

function Frame({ title, lead, children }) {
  return (
    <div class="auth">
      <div class="auth-box">
        <img class="logo" src="/icon.svg" alt="" />
        <h1>{title}</h1>
        <p class="lead">{lead}</p>
        {children}
      </div>
    </div>
  )
}

export function Setup() {
  return (
    <Frame title="Welcome to PocketHarbor" lead="Create the owner account of this phone.">
      <form class="stack" onSubmit={(e) => submit(e, '/setup')}>
        <div class="field">
          <label for="email">Email</label>
          <input class="input" id="email" name="email" type="email" autocomplete="username" required autofocus />
        </div>
        <div class="field">
          <label for="password">Password</label>
          <input class="input" id="password" name="password" type="password" autocomplete="new-password" minLength={8} required />
          <span class="hint">At least 8 characters.</span>
        </div>
        <div class="field">
          <label for="confirm">Confirm password</label>
          <input class="input" id="confirm" name="confirm" type="password" autocomplete="new-password" required />
        </div>
        {error.value && <div class="error-text">{error.value}</div>}
        <button class="btn primary" style="height:38px" disabled={busy.value}>Create account</button>
      </form>
    </Frame>
  )
}

export function Login() {
  return (
    <Frame title="Sign in" lead="to the PocketHarbor on this phone">
      <form class="stack" onSubmit={(e) => submit(e, '/login')}>
        <div class="field">
          <label for="email">Email</label>
          <input class="input" id="email" name="email" type="email" autocomplete="username" required autofocus />
        </div>
        <div class="field">
          <label for="password">Password</label>
          <input class="input" id="password" name="password" type="password" autocomplete="current-password" required />
        </div>
        {needCode.value && (
          <div class="field">
            <label for="code">Authentication code</label>
            <input class="input mono" id="code" name="code" inputMode="numeric" autocomplete="one-time-code" pattern="[0-9 ]*" required autofocus />
            <span class="hint">From your authenticator app.</span>
          </div>
        )}
        {error.value && !(needCode.value && error.value.startsWith('enter the code')) && <div class="error-text">{error.value}</div>}
        <button class="btn primary" style="height:38px" disabled={busy.value}>Sign in</button>
      </form>
    </Frame>
  )
}
