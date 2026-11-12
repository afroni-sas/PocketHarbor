// Connecting Cloudflare and GitHub in two steps: a button opens their token
// form with every permission already filled in, and one field takes back
// what they show. Used in Settings and wherever a feature needs them.

import { signal } from '@preact/signals'
import { ExternalLink } from 'lucide-preact'
import { put } from './api.js'
import { toast } from './state.js'
import { Spinner } from './ui.jsx'

/** The token, and the Account ID if any, out of whatever was pasted: the
 * token alone, or all that Cloudflare shows once it is made. */
export function readCloudflarePaste(text) {
  const word = text.trim()
  const token =
    (text.match(/cf[a-z]{2}_[A-Za-z0-9_-]{20,}/) || text.match(/(?<![\w-])[\w-]{40}(?![\w-])/) || [/^\S{20,}$/.test(word) ? word : ''])[0]
  const account = (text.replace(token, '').match(/(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])/i) || [''])[0]
  return { token, account }
}

/** A GitHub token out of what was pasted. */
export function readGithubPaste(text) {
  return (text.match(/github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}/) || [text.trim()])[0]
}

const busy = signal('')

async function connect(e, kind, onDone) {
  e.preventDefault()
  const form = e.currentTarget
  const text = form.elements.token.value
  let body
  if (kind === 'cloudflare') {
    body = readCloudflarePaste(text)
    if (!body.token) return toast('Paste the token that Cloudflare shows', 'error')
  } else {
    body = { token: readGithubPaste(text) }
    if (body.token.length < 20) return toast('Paste the token that GitHub shows', 'error')
  }
  busy.value = kind
  try {
    await put(kind === 'cloudflare' ? '/cloudflare' : '/github', body)
    form.reset()
    toast(kind === 'cloudflare' ? 'Cloudflare connected' : 'GitHub token saved', 'success')
    if (onDone) await onDone()
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    busy.value = ''
  }
}

const steps = {
  cloudflare: {
    button: 'Create the token on Cloudflare',
    placeholder: 'Paste the token here',
    hint: 'The permissions are filled in: Continue to summary, Create Token, then paste it here.',
    submit: 'Connect',
  },
  github: {
    button: 'Create the token on GitHub',
    placeholder: 'github_pat_...',
    hint: 'The permissions are filled in: choose the repositories, Generate token, then paste it here.',
    submit: 'Save',
  },
}

/** The two steps, for `kind` 'cloudflare' or 'github'. */
export function TokenSteps({ kind, url, onDone, secondary }) {
  const t = steps[kind]
  const working = busy.value === kind
  return (
    <div class="token-steps">
      <a class={`btn${secondary ? '' : ' primary'}`} href={url} target="_blank" rel="noreferrer">
        {t.button} <ExternalLink />
      </a>
      <form class="cf-paste" onSubmit={(e) => connect(e, kind, onDone)}>
        <input class="input mono" name="token" type="password" placeholder={t.placeholder} required autocomplete="off" aria-label={`${kind} token`} />
        <button class="btn" disabled={working}>
          {working && <Spinner />}
          {t.submit}
        </button>
      </form>
      <p class="muted small token-hint">{t.hint}</p>
    </div>
  )
}
