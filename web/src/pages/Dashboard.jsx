import { effect, signal } from '@preact/signals'
import { Check, ChevronDown, LayoutGrid, List, Plus, Search, Star } from 'lucide-preact'
import { get, post } from '../api.js'
import { me, projects } from '../state.js'
import { follow, navigate, route } from '../router.js'
import { openForm, openMenu, ServiceIcon, timeAgo } from '../ui.jsx'
import { openPalette } from './Palette.jsx'

/** What the browser remembers between visits; nothing that matters. */
function remembered(key, fallback) {
  try {
    const v = localStorage.getItem(key)
    return v === null ? fallback : JSON.parse(v)
  } catch {
    return fallback
  }
}

function remember(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // A private window: it is forgotten, which is fine.
  }
}

const query = signal('')
const previews = signal({})
const sortBy = signal(remembered('pharbor.sort', 'activity'))
const layout = signal(remembered('pharbor.layout', 'grid'))
export const favorites = signal(remembered('pharbor.favorites', []))

async function load() {
  try {
    const [list, all] = await Promise.all([get('/projects'), get('/services?environment=production')])
    const byProject = {}
    for (const svc of all) (byProject[svc.project] ||= []).push(svc)
    previews.value = byProject
    projects.value = list
  } catch {
    // Signed out: the app shows the sign-in page.
  }
}

effect(() => {
  if (me.value && route.value.path === '/') load()
})

export function newProject() {
  openForm({
    title: 'New project',
    submit: 'Create',
    render: () => (
      <div class="field">
        <label for="pname">Name</label>
        <input class="input" id="pname" name="name" placeholder="my-app" pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required autofocus />
        <span class="hint">Lowercase letters, digits and dashes.</span>
      </div>
    ),
    onSubmit: async ({ name }) => {
      await post('/projects', { name })
      navigate(`/project/${name}`)
    },
  })
}

function toggleFavorite(e, name) {
  e.preventDefault()
  e.stopPropagation()
  const now = favorites.value.includes(name) ? favorites.value.filter((n) => n !== name) : [...favorites.value, name]
  favorites.value = now
  remember('pharbor.favorites', now)
}

const sorts = {
  activity: 'Recent Activity',
  created: 'Creation Date',
  name: 'Alphabetical',
}

function chooseSort(e) {
  openMenu(
    e.currentTarget,
    Object.entries(sorts).map(([id, label]) => [
      label,
      sortBy.value === id ? Check : null,
      () => {
        sortBy.value = id
        remember('pharbor.sort', id)
      },
    ]),
  )
}

function setLayout(value) {
  layout.value = value
  remember('pharbor.layout', value)
}

/** The last time anything of the project was deployed. */
function activity(p) {
  let last = p.created_at
  for (const svc of previews.value[p.name] || []) last = Math.max(last, svc.deployed_at || 0)
  return last
}

function sorted(list) {
  const fav = new Set(favorites.value)
  const key = sortBy.value
  return [...list].sort((a, b) => {
    const f = Number(fav.has(b.name)) - Number(fav.has(a.name))
    if (f !== 0) return f
    if (key === 'name') return a.name.localeCompare(b.name)
    if (key === 'created') return b.created_at - a.created_at
    return activity(b) - activity(a)
  })
}

function Health({ p }) {
  const all = p.services > 0 && p.online === p.services
  return (
    <span class="project-health">
      <span class={`dot ${all ? 'green' : p.online < p.services ? 'yellow' : ''}`} />
      production · {p.online}/{p.services} services online
    </span>
  )
}

function StarButton({ name }) {
  const on = favorites.value.includes(name)
  return (
    <button class={`star${on ? ' on' : ''}`} aria-label={on ? `Remove ${name} from favorites` : `Add ${name} to favorites`} aria-pressed={on} onClick={(e) => toggleFavorite(e, name)}>
      <Star />
    </button>
  )
}

function ProjectCard({ p }) {
  const list = previews.value[p.name] || []
  return (
    <a class="card project-card" href={`/project/${p.name}`} onClick={follow}>
      <header>
        <span class="name">{p.name}</span>
        <StarButton name={p.name} />
      </header>
      <div class="preview">
        <div class="tiles">
          {list.slice(0, 8).map((svc) => (
            <span key={svc.id} class="tile" title={svc.name}>
              <ServiceIcon svc={svc} size={16} />
            </span>
          ))}
          {list.length > 8 && <span class="tile more">+{list.length - 8}</span>}
        </div>
        <Health p={p} />
      </div>
    </a>
  )
}

function ProjectRow({ p }) {
  const list = previews.value[p.name] || []
  return (
    <a class="project-row" href={`/project/${p.name}`} onClick={follow}>
      <span class="name">{p.name}</span>
      <span class="tiles">
        {list.slice(0, 6).map((svc) => (
          <span key={svc.id} class="tile" title={svc.name}>
            <ServiceIcon svc={svc} size={14} />
          </span>
        ))}
      </span>
      <Health p={p} />
      <span class="muted small">{timeAgo(activity(p))}</span>
      <StarButton name={p.name} />
    </a>
  )
}

export function Dashboard() {
  const list = projects.value
  const q = query.value.toLowerCase()
  const shown = sorted((list || []).filter((p) => p.name.includes(q)))
  return (
    <div class="page">
      <div class="page-head">
        <h1>Projects</h1>
        <span class="spacer" />
        <div class="search">
          <Search />
          <input class="input" placeholder="Search projects..." value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} aria-label="Search projects" />
          <button class="kbd-hint" onClick={openPalette} title="Open the command palette" aria-label="Open the command palette">
            <kbd class="kbd">Ctrl</kbd>
            <kbd class="kbd">K</kbd>
          </button>
        </div>
        <button class="btn primary" onClick={newProject}>
          <Plus /> New
        </button>
      </div>
      <div class="list-bar">
        <span class="count">
          <LayoutGrid /> {list ? `${list.length} Project${list.length === 1 ? '' : 's'}` : 'Loading...'}
        </span>
        <span class="sep" />
        <button class="btn ghost sm sort" onClick={chooseSort}>
          Sort By: {sorts[sortBy.value] || sorts.activity}
          <ChevronDown />
        </button>
        <span class="spacer" />
        <div class="view-toggle" role="radiogroup" aria-label="Layout">
          <button class={layout.value === 'grid' ? 'on' : ''} role="radio" aria-checked={layout.value === 'grid'} aria-label="Grid" onClick={() => setLayout('grid')}>
            <LayoutGrid />
          </button>
          <button class={layout.value === 'list' ? 'on' : ''} role="radio" aria-checked={layout.value === 'list'} aria-label="List" onClick={() => setLayout('list')}>
            <List />
          </button>
        </div>
      </div>
      {list && list.length === 0 ? (
        <div class="card empty">
          <p style="margin:0 0 14px">Nothing deployed yet.</p>
          <button class="btn primary" onClick={newProject}>
            <Plus /> Create a project
          </button>
        </div>
      ) : q && shown.length === 0 ? (
        <div class="card empty">No project matches “{query.value}”.</div>
      ) : layout.value === 'list' ? (
        <div class="project-list card">
          {shown.map((p) => (
            <ProjectRow key={p.name} p={p} />
          ))}
        </div>
      ) : (
        <div class="projects">
          {shown.map((p) => (
            <ProjectCard key={p.name} p={p} />
          ))}
        </div>
      )}
    </div>
  )
}
