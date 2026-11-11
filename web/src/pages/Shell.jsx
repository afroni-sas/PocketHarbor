import { Download, LayoutGrid, LogOut, Settings, User } from 'lucide-preact'
import { post } from '../api.js'
import { installPrompt, me } from '../state.js'
import { follow, route } from '../router.js'
import { openMenu } from '../ui.jsx'

const items = [
  ['/', 'Projects', LayoutGrid],
  ['/settings', 'Settings', Settings],
  ['/account', 'Account', User],
]

async function logout() {
  await post('/logout').catch(() => {})
  me.value = null
}

async function install() {
  const prompt = installPrompt.peek()
  if (!prompt) return
  prompt.prompt()
  await prompt.userChoice.catch(() => {})
  installPrompt.value = null
}

export function Shell({ children }) {
  const path = route.value.path
  const user = me.value
  const email = (user && user.email) || ''
  return (
    <div class="shell">
      <aside class="sidebar">
        <div class="workspace">
          <img src="/icon.svg" alt="" />
          <div>
            <b>PocketHarbor</b>
            <small>{location.hostname}</small>
          </div>
        </div>
        {items.map(([href, label, Icon]) => (
          <a key={href} href={href} onClick={follow} class={`nav-item${path === href ? ' active' : ''}`}>
            <Icon />
            {label}
          </a>
        ))}
        {installPrompt.value && (
          <button class="nav-item" style="background:none;border:0;width:100%" onClick={install}>
            <Download />
            Install app
          </button>
        )}
        <div class="user">
          <span class="avatar">{email.slice(0, 1).toUpperCase()}</span>
          <span class="small" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1">{email}</span>
          <button class="btn ghost icon sm" aria-label="Account menu" onClick={(e) => openMenu(e.currentTarget, [['Sign out', LogOut, logout]])}>
            <LogOut />
          </button>
        </div>
      </aside>
      <main class="content">
        <nav class="mobile-bar">
          <a href="/" onClick={follow}>
            <img src="/icon.svg" alt="PocketHarbor" />
          </a>
          <span class="spacer" />
          {items.map(([href, label, Icon]) => (
            <a key={href} href={href} onClick={follow} class={`rail-btn${path === href ? ' active' : ''}`} aria-label={label}>
              <Icon />
            </a>
          ))}
          <button class="rail-btn" aria-label="Sign out" onClick={logout} style="background:none;border:0">
            <LogOut />
          </button>
        </nav>
        {children}
      </main>
    </div>
  )
}
