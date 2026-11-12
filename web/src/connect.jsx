// Connecting Cloudflare and GitHub: their own button, with their logo,
// opens their token form with every permission already filled in; the
// field to paste the token back then appears beside it.

import { signal } from '@preact/signals'
import { put } from './api.js'
import { toast } from './state.js'
import { GithubIcon, Spinner } from './ui.jsx'
import { siCloudflare } from './brands.js'

// The same links as token_url in src/cloudflare.zig and src/github.zig;
// the dashboard keeps its own copy, so that it works with any server.
export const cloudflareTokenUrl =
  'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=' +
  '%5B%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C' +
  '%7B%22key%22%3A%22argotunnel%22%2C%22type%22%3A%22edit%22%7D%2C' +
  '%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C' +
  '%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C' +
  '%7B%22key%22%3A%22ssl_and_certificates%22%2C%22type%22%3A%22edit%22%7D%5D' +
  '&accountId=*&zoneId=all&name=PocketHarbor'

export const githubTokenUrl =
  'https://github.com/settings/personal-access-tokens/new?name=PocketHarbor' +
  '&description=Builds+and+deploys+on+push+from+PocketHarbor&expires_in=none' +
  '&contents=read&repository_hooks=write'

export function CloudflareIcon({ size = 18 }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden="true">
      <path d={siCloudflare.path} />
    </svg>
  )
}

const brand = {
  cloudflare: { name: 'Cloudflare', Icon: CloudflareIcon, url: cloudflareTokenUrl },
  github: { name: 'GitHub', Icon: GithubIcon, url: githubTokenUrl },
}

/** "Connect Cloudflare" or "Connect GitHub", as their own buttons look.
 * With `href` it opens that page in a new tab; otherwise it calls `onClick`. */
export function ConnectButton({ kind, href, onClick, small }) {
  const { name, Icon } = brand[kind]
  const cls = `brand-btn ${kind}${small ? ' sm' : ''}`
  const inner = (
    <>
      <Icon size={small ? 14 : 18} />
      Connect {name}
    </>
  )
  return href ? (
    <a class={cls} href={href} target="_blank" rel="noreferrer" onClick={onClick}>
      {inner}
    </a>
  ) : (
    <button type="button" class={cls} onClick={onClick}>
      {inner}
    </button>
  )
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

/** A GitHub token out of what was pasted. */
export function readGithubPaste(text) {
  return (text.match(/github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}/) || [text.trim()])[0]
}

const busy = signal('')
/** Which token forms were opened: their paste field shows. */
const opened = signal({})

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
    opened.value = { ...opened.peek(), [kind]: false }
    toast(`${brand[kind].name} connected`, 'success')
    if (onDone) await onDone()
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    busy.value = ''
  }
}

/** The brand's Connect button; once it has opened their form, the field
 * that takes the token back. */
export function TokenSteps({ kind, onDone }) {
  const { name, url } = brand[kind]
  const working = busy.value === kind
  const open = opened.value[kind]
  return (
    <div class="token-steps">
      <ConnectButton kind={kind} href={url} onClick={() => (opened.value = { ...opened.peek(), [kind]: true })} />
      {open ? (
        <>
          <form class="cf-paste" onSubmit={(e) => connect(e, kind, onDone)}>
            <input class="input mono" name="token" type="password" placeholder={`Paste the ${name} token`} required autofocus autocomplete="off" aria-label={`${name} token`} />
            <button class="btn primary" disabled={working}>
              {working && <Spinner />}
              Connect
            </button>
          </form>
          <p class="muted small token-hint">
            {kind === 'cloudflare'
              ? 'The permissions are already filled in: Continue to summary, Create Token, then paste it here.'
              : 'The permissions are already filled in: choose the repositories, Generate token, then paste it here.'}
          </p>
        </>
      ) : (
        <button type="button" class="linkish small token-have" onClick={() => (opened.value = { ...opened.peek(), [kind]: true })}>
          I already have a token
        </button>
      )}
    </div>
  )
}
