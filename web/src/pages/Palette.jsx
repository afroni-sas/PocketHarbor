// The command palette, Ctrl+K or Cmd+K anywhere, as on Railway: jump to a
// project, a service or a page, or run an action, from the keyboard.

import { signal } from '@preact/signals'
import {
  Activity,
  Box,
  CornerDownLeft,
  Database,
  FolderOpen,
  HardDrive,
  Layers,
  LayoutGrid,
  LayoutTemplate,
  Play,
  Plus,
  RotateCcw,
  Rocket,
  ScrollText,
  Search,
  Settings,
  SquareTerminal,
  User,
} from 'lucide-preact'
import { enc, get, post } from '../api.js'
import { closeOverlay, me, overlay, projects, services, toast } from '../state.js'
import { navigate, withQuery } from '../router.js'
import { openService, page, projectPath, refresh, setQuery } from '../project.js'
import { GithubIcon, ServiceIcon } from '../ui.jsx'
import { openAdd } from './AddDialog.jsx'
import { newProject } from './Dashboard.jsx'

const query = signal('')
const index = signal(0)

/** Everything the palette can do from where the user is. */
function commands() {
  const out = []
  const p = page.peek()
  const svcs = (p && services.peek()) || []
  const current = p && p.service ? svcs.find((s) => s.name === p.service) : null
  if (current) {
    const id = current.id
    const name = current.name
    out.push(
      { group: name, label: `Deploy ${name}`, icon: Rocket, run: () => post(`/services/${enc(id)}/deploy`).then(() => (toast('Deploying', 'success'), refresh())) },
      { group: name, label: `Restart ${name}`, icon: RotateCcw, run: () => post(`/services/${enc(id)}/restart`).then(() => (toast('Restarted', 'success'), refresh())) },
      { group: name, label: `Open the console of ${name}`, icon: SquareTerminal, run: () => setQuery({ tab: 'console', logs: undefined }) },
      { group: name, label: `View the logs of ${name}`, icon: ScrollText, run: () => navigate(projectPath('/logs')) },
    )
  }
  if (p) {
    out.push(
      { group: 'Add', label: 'New service', icon: Plus, run: () => openAdd() },
      { group: 'Add', label: 'Add a GitHub repository', icon: GithubIcon, run: () => openAdd('repo') },
      { group: 'Add', label: 'Add a database', icon: Database, run: () => openAdd('database') },
      { group: 'Add', label: 'Add a template', icon: LayoutTemplate, run: () => openAdd('template') },
      { group: 'Add', label: 'Add a Docker image', icon: Box, run: () => openAdd('image') },
      { group: 'Add', label: 'Add a volume', icon: HardDrive, run: () => openAdd('volume') },
    )
    for (const svc of svcs) {
      out.push({ group: 'Services', label: svc.name, hint: svc.image || svc.repo, svc, run: () => (navigate(projectPath()), openService(svc.name)) })
    }
    out.push(
      { group: 'Project', label: 'Architecture', icon: LayoutGrid, run: () => navigate(projectPath()) },
      { group: 'Project', label: 'Observability', icon: Activity, run: () => navigate(projectPath('/observability')) },
      { group: 'Project', label: 'Logs', icon: ScrollText, run: () => navigate(projectPath('/logs')) },
      { group: 'Project', label: 'Project settings', icon: Settings, run: () => navigate(projectPath('/settings')) },
    )
  }
  for (const proj of projects.peek() || []) {
    out.push({ group: 'Projects', label: proj.name, hint: `${proj.online}/${proj.services} online`, icon: FolderOpen, run: () => navigate(`/project/${enc(proj.name)}`) })
    if (p && proj.name === p.project) {
      for (const env of proj.environments) {
        if (env !== p.env) {
          out.push({ group: 'Environments', label: `Switch to ${env}`, icon: Layers, run: () => navigate(withQuery(`/project/${enc(p.project)}`, { env: env === 'production' ? undefined : env })) })
        }
      }
    }
  }
  out.push(
    { group: 'Go to', label: 'All projects', icon: LayoutGrid, run: () => navigate('/') },
    { group: 'Go to', label: 'New project', icon: Plus, run: newProject },
    { group: 'Go to', label: 'Settings', icon: Settings, run: () => navigate('/settings') },
    { group: 'Go to', label: 'Alerts', icon: Play, run: () => navigate('/settings?tab=alerts') },
    { group: 'Go to', label: 'Account', icon: User, run: () => navigate('/account') },
  )
  return out
}

function matching(list, q) {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return list
  return list.filter((c) => {
    const text = `${c.group} ${c.label} ${c.hint || ''}`.toLowerCase()
    return words.every((w) => text.includes(w))
  })
}

async function run(c) {
  closeOverlay()
  try {
    await c.run()
  } catch (err) {
    toast(err.message, 'error')
  }
}

function rows(all, at) {
  const out = []
  let group = ''
  all.forEach((c, i) => {
    if (c.group !== group) {
      group = c.group
      out.push(
        <div key={`g-${group}`} class="palette-group">
          {group}
        </div>,
      )
    }
    const Icon = c.icon
    out.push(
      <div
        key={`c-${c.group}-${c.label}`}
        id={`cmd-${i}`}
        role="option"
        aria-selected={i === at}
        class={`palette-item${i === at ? ' on' : ''}`}
        onMouseMove={() => index.value !== i && (index.value = i)}
        onClick={() => run(c)}
        ref={(el) => i === at && el && el.scrollIntoView({ block: 'nearest' })}
      >
        {c.svc ? <ServiceIcon svc={c.svc} size={16} /> : Icon ? <Icon width={16} height={16} /> : null}
        <span class="label">{c.label}</span>
        {c.hint && <span class="hint">{c.hint}</span>}
        {i === at && <CornerDownLeft class="enter" width={14} height={14} />}
      </div>,
    )
  })
  return out
}

function Palette() {
  const all = matching(commands(), query.value)
  const at = Math.min(index.value, Math.max(0, all.length - 1))
  const key = (e) => {
    if (e.key === 'ArrowDown') index.value = (at + 1) % Math.max(1, all.length)
    else if (e.key === 'ArrowUp') index.value = (at - 1 + all.length) % Math.max(1, all.length)
    else if (e.key === 'Enter' && all[at]) run(all[at])
    else if (e.key === 'Escape') closeOverlay()
    else return
    e.preventDefault()
  }
  return (
    <div class="backdrop palette-backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="palette" role="dialog" aria-label="Command palette">
        <div class="palette-input">
          <Search />
          <input
            autofocus
            placeholder="Search projects, services and actions..."
            value={query.value}
            onInput={(e) => ((query.value = e.currentTarget.value), (index.value = 0))}
            onKeyDown={key}
            aria-label="Command"
            aria-controls="palette-list"
            aria-activedescendant={all[at] ? `cmd-${at}` : undefined}
          />
          <kbd class="kbd">Esc</kbd>
        </div>
        <div class="palette-list" id="palette-list" role="listbox">
          {all.length === 0 && <div class="empty small">Nothing matches “{query.value}”.</div>}
          {rows(all, at)}
        </div>
      </div>
    </div>
  )
}

export async function openPalette() {
  if (!me.peek()) return
  query.value = ''
  index.value = 0
  overlay.value = Palette
  if (!projects.peek()) {
    try {
      projects.value = await get('/projects')
    } catch {
      // The list stays without projects.
    }
  }
}

addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault()
    if (overlay.peek() === Palette) closeOverlay()
    else openPalette()
  }
})
