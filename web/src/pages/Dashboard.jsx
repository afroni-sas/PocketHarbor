import { effect, signal } from '@preact/signals'
import { Plus, Search } from 'lucide-preact'
import { get, post } from '../api.js'
import { me, projects } from '../state.js'
import { navigate, route } from '../router.js'
import { openForm, ServiceIcon } from '../ui.jsx'

const query = signal('')
const previews = signal({})

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

function ProjectCard({ p }) {
  const list = previews.value[p.name] || []
  return (
    <div class="card project-card" onClick={() => navigate(`/project/${p.name}`)}>
      <header>{p.name}</header>
      <div class="preview">
        {list.slice(0, 8).map((svc) => (
          <span key={svc.id} class="tile">
            <ServiceIcon svc={svc} size={15} />
          </span>
        ))}
      </div>
      <footer>
        <span class={`dot ${p.services > 0 && p.online === p.services ? 'green' : p.online < p.services ? 'yellow' : ''}`} />
        production · {p.online}/{p.services} services online
      </footer>
    </div>
  )
}

export function Dashboard() {
  const list = projects.value
  const q = query.value.toLowerCase()
  const shown = (list || []).filter((p) => p.name.includes(q))
  return (
    <div class="page">
      <div class="page-head">
        <h1>Projects</h1>
        <span class="spacer" />
        <div class="search">
          <Search />
          <input class="input" placeholder="Search projects..." value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} />
        </div>
        <button class="btn primary" onClick={newProject}>
          <Plus /> New
        </button>
      </div>
      <div class="row muted small" style="margin-bottom:14px">
        {list ? `${list.length} project${list.length === 1 ? '' : 's'}` : 'Loading...'}
      </div>
      {list && list.length === 0 ? (
        <div class="card empty">
          <p style="margin:0 0 14px">Nothing deployed yet.</p>
          <button class="btn primary" onClick={newProject}>
            <Plus /> Create a project
          </button>
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
