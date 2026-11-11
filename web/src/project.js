// State of the project page: which project, environment and service the URL
// names, the services of the canvas (polled), and changes not deployed yet.

import { computed, effect, signal, untracked } from '@preact/signals'
import { enc, get, post } from './api.js'
import { edges, me, projects, services, toast } from './state.js'
import { match, navigate, route, withQuery } from './router.js'

/** The pages of a project besides its canvas. */
const views = ['settings', 'observability', 'logs']

export const page = computed(() => {
  const r = route.value
  const m = match('/project/:project', r.path) || match('/project/:project/service/:service', r.path) || match('/project/:project/:view', r.path)
  if (!m || (m.view && !views.includes(m.view))) return null
  const view = m.view || 'canvas'
  return {
    project: m.project,
    service: m.service || null,
    view,
    settings: view === 'settings',
    env: r.query.env || 'production',
    tab: r.query.tab || '',
    logs: r.query.logs || '',
    logtab: r.query.logtab || '',
    section: r.query.section || '',
  }
})

/** The project's own record: its environments. */
export const project = signal(null)

/** Services whose settings changed since their last deploy: id → name. */
export const dirty = signal({})

export const serviceId = (p, name) => `${p.project}.${p.env}.${name}`

/** A path inside the current project that keeps the environment. */
export function projectPath(extra = '', query = {}) {
  const p = page.peek()
  return withQuery(`/project/${enc(p.project)}${extra}`, { env: p.env === 'production' ? undefined : p.env, ...query })
}

export const openService = (name, query = {}) => navigate(projectPath(`/service/${enc(name)}`, query))
export const closeService = () => navigate(projectPath())

/** Changes the query of the current URL, keeping the path. */
export function setQuery(changes, replace = false) {
  const r = route.peek()
  navigate(withQuery(r.path, { ...r.query, ...changes }), replace)
}

/** The name other services of the environment reach this one at. */
export function privateName(svc) {
  const inDefault = svc.project === 'default'
  const inProduction = svc.environment === 'production'
  if (inDefault && inProduction) return svc.name
  if (inDefault) return `${svc.name}-${svc.environment}`
  if (inProduction) return `${svc.project}-${svc.name}`
  return `${svc.project}-${svc.name}-${svc.environment}`
}

export function markDirty(svc) {
  dirty.value = { ...dirty.value, [svc.id]: svc.name }
}

/** Deploys every service with pending changes. */
export async function applyChanges() {
  const ids = Object.keys(dirty.peek())
  dirty.value = {}
  for (const id of ids) {
    try {
      await post(`/services/${enc(id)}/deploy`)
    } catch (err) {
      toast(err.message, 'error')
    }
  }
  toast(ids.length === 1 ? 'Deploying' : `Deploying ${ids.length} services`, 'success')
  refresh()
}

export async function loadProject() {
  const p = page.peek()
  if (!p) return
  try {
    const [info, list] = await Promise.all([get(`/projects/${enc(p.project)}`), get('/projects')])
    if (page.peek()?.project !== p.project) return
    project.value = info
    projects.value = list
    if (!info.environments.includes(p.env)) {
      toast(`No environment named ${p.env}`, 'error')
      navigate(`/project/${enc(p.project)}`, true)
    }
  } catch (err) {
    if (err.status === 404) {
      toast(`No project named ${p.project}`, 'error')
      navigate('/', true)
    }
  }
}

let busy = false
let again = false

/** Reloads the services and arrows of the canvas. */
export async function refresh() {
  const p = page.peek()
  if (!p) return
  if (busy) {
    again = true
    return
  }
  busy = true
  try {
    const base = `/projects/${enc(p.project)}/environments/${enc(p.env)}`
    const [list, arrows] = await Promise.all([
      get(`/services?project=${enc(p.project)}&environment=${enc(p.env)}`),
      get(`${base}/edges`).catch(() => []),
    ])
    const now = page.peek()
    if (now && now.project === p.project && now.env === p.env) {
      services.value = list
      edges.value = arrows
    }
  } catch {
    // Offline for a moment, or signed out: the next poll tries again.
  } finally {
    busy = false
    if (again) {
      again = false
      refresh()
    }
  }
}

const key = computed(() => {
  const p = page.value
  return me.value && p ? `${p.project}\n${p.env}` : ''
})

let timer = 0
let shown = ''

effect(() => {
  const k = key.value
  clearInterval(timer)
  if (k !== shown) {
    services.value = null
    edges.value = []
    if (k.split('\n')[0] !== shown.split('\n')[0]) project.value = null
  }
  shown = k
  if (!k) return
  untracked(() => {
    loadProject()
    refresh()
  })
  timer = setInterval(() => document.hidden || refresh(), 4000)
})

addEventListener('visibilitychange', () => {
  if (!document.hidden && key.peek()) refresh()
})
