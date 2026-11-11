import { render } from 'preact'
import './styles.css'
import { get } from './api.js'
import { installPrompt, me, status } from './state.js'
import { route } from './router.js'
import { Overlays, Spinner } from './ui.jsx'
import { Login, Setup } from './pages/Auth.jsx'
import { Shell } from './pages/Shell.jsx'
import { Dashboard } from './pages/Dashboard.jsx'
import { ProjectPage } from './pages/Project.jsx'
import { Account } from './pages/Account.jsx'
import { Workspace } from './pages/Workspace.jsx'

function App() {
  const user = me.value
  if (user === undefined) {
    return (
      <div class="splash">
        <Spinner />
      </div>
    )
  }
  if (user === null) return status.value && status.value.setup_needed ? <Setup /> : <Login />
  const path = route.value.path
  if (path.startsWith('/project/')) return <ProjectPage />
  if (path === '/account') return <Shell><Account /></Shell>
  if (path === '/settings') return <Shell><Workspace /></Shell>
  return <Shell><Dashboard /></Shell>
}

async function boot() {
  try {
    status.value = await get('/status')
  } catch {
    status.value = { setup_needed: false }
  }
  try {
    me.value = await get('/me')
  } catch {
    me.value = null
  }
}

// Installing the app needs a secure origin: through a tunnel or a domain
// with HTTPS, or localhost; not the phone's bare address.
if ('serviceWorker' in navigator && isSecureContext) {
  navigator.serviceWorker.register('/sw.js').catch(() => {})
}
addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault()
  installPrompt.value = e
})
addEventListener('appinstalled', () => (installPrompt.value = null))

boot()
render(
  <>
    <App />
    <Overlays />
  </>,
  document.getElementById('app'),
)
