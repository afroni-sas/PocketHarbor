// A project: the icon rail, the "project / environment" bar and the stage,
// which holds the canvas and the service panel, or the project settings.

import { computed, effect, untracked } from '@preact/signals'
import { Check, ChevronsUpDown, Copy, LayoutGrid, Layers, Network, Plus, Rocket, Settings, Trash, User } from 'lucide-preact'
import { del, enc, post } from '../api.js'
import { me, projects, toast } from '../state.js'
import { follow, navigate, withQuery } from '../router.js'
import { applyChanges, dirty, loadProject, page, project, projectPath } from '../project.js'
import { confirm, openForm, openMenu, timeAgo } from '../ui.jsx'
import { Canvas, CanvasOverlay } from './Canvas.jsx'
import { ServicePanel } from './ServicePanel.jsx'
import { loadVars, VariablesEditor } from './Variables.jsx'
import { newProject } from './Dashboard.jsx'

const envPath = (env, extra = '') => withQuery(`/project/${enc(page.peek().project)}${extra}`, { env: env === 'production' ? undefined : env })

function projectMenu(anchor) {
  const list = projects.peek() || []
  const here = page.peek().project
  openMenu(anchor, [
    'Projects',
    ...list.map((p) => [p.name, p.name === here ? Check : null, () => navigate(`/project/${enc(p.name)}`)]),
    null,
    ['New project', Plus, newProject],
    ['All projects', LayoutGrid, () => navigate('/')],
  ])
}

function newEnvironment() {
  const p = page.peek()
  openForm({
    title: 'New environment',
    submit: 'Create',
    render: () => (
      <>
        <div class="field">
          <label for="ename">Name</label>
          <input class="input" id="ename" name="name" placeholder="staging" pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required autofocus />
        </div>
        <p class="muted small" style="margin:0">
          The services and variables of <b>{p.env}</b> are copied into it. Nothing is deployed until you deploy it.
        </p>
      </>
    ),
    onSubmit: async ({ name }) => {
      const res = await post(`/projects/${enc(p.project)}/environments`, { name, from: p.env })
      await loadProject()
      navigate(envPath(name))
      toast(`Created ${name} with ${res.copied} service${res.copied === 1 ? '' : 's'}`, 'success')
    },
  })
}

function removeEnvironment(env) {
  const p = page.peek()
  confirm({
    title: `Delete ${env}?`,
    body: `Its services, their deployments, volumes and variables are removed from the phone.`,
    action: 'Delete environment',
    onConfirm: async () => {
      await del(`/projects/${enc(p.project)}/environments/${enc(env)}`)
      if (page.peek().env === env) navigate(envPath('production', page.peek().settings ? '/settings' : ''))
      await loadProject()
      toast(`${env} deleted`, 'success')
    },
  })
}

function envMenu(anchor) {
  const p = page.peek()
  const envs = project.peek()?.environments || [p.env]
  openMenu(anchor, [
    'Environments',
    ...envs.map((e) => [e, e === p.env ? Check : null, () => navigate(envPath(e, p.settings ? '/settings' : ''))]),
    null,
    ['New environment', Plus, newEnvironment],
    p.env !== 'production' && [`Delete ${p.env}`, Trash, () => removeEnvironment(p.env), true],
  ].filter((x) => x !== false))
}

function Topbar({ p }) {
  return (
    <header class="topbar">
      <a href="/" onClick={follow} class="home" aria-label="All projects">
        <img src="/icon.svg" alt="" />
      </a>
      <button class="crumb" onClick={(e) => projectMenu(e.currentTarget)}>
        <span class="proj-dot" />
        {p.project}
        <ChevronsUpDown />
      </button>
      <span class="slash">/</span>
      <button class="crumb" onClick={(e) => envMenu(e.currentTarget)}>
        <span class={`env-chip${p.env === 'production' ? '' : ' other'}`} />
        {p.env}
        <ChevronsUpDown />
      </button>
      <span class="spacer" />
      <nav class="top-tabs">
        <a href={projectPath()} onClick={follow} class={p.settings ? '' : 'active'} aria-label="Architecture">
          <Network />
          <span>Architecture</span>
        </a>
        <a href={projectPath('/settings')} onClick={follow} class={p.settings ? 'active' : ''} aria-label="Settings">
          <Settings />
          <span>Settings</span>
        </a>
      </nav>
    </header>
  )
}

function Rail({ p }) {
  const email = (me.value && me.value.email) || ''
  return (
    <nav class="rail">
      <a href="/" onClick={follow} title="All projects">
        <img class="logo" src="/icon.svg" alt="PocketHarbor" />
      </a>
      <a href={projectPath()} onClick={follow} class={`rail-btn${p.settings ? '' : ' active'}`} title="Architecture" aria-label="Architecture">
        <Network />
      </a>
      <a href={projectPath('/settings')} onClick={follow} class={`rail-btn${p.settings ? ' active' : ''}`} title="Project settings" aria-label="Project settings">
        <Settings />
      </a>
      <span class="spacer" />
      <a href="/settings" onClick={follow} class="rail-btn" title="Workspace settings" aria-label="Workspace settings">
        <Layers />
      </a>
      <a href="/account" onClick={follow} class="rail-btn" title={email} aria-label="Account">
        {email ? <span class="avatar" style="width:24px;height:24px;font-size:10px">{email[0].toUpperCase()}</span> : <User />}
      </a>
    </nav>
  )
}

/** Railway's "Apply changes" bar: settings saved but not deployed yet. */
function Staged({ beside }) {
  const pending = Object.values(dirty.value)
  if (pending.length === 0) return null
  return (
    <div class={`staged${beside ? ' beside' : ''}`}>
      <span>
        {pending.length === 1 ? `${pending[0]} has changes to deploy` : `Apply ${pending.length} changes`}
      </span>
      <button class="btn sm ghost" onClick={() => (dirty.value = {})}>
        Later
      </button>
      <button class="btn sm primary" onClick={applyChanges}>
        <Rocket /> Deploy
      </button>
    </div>
  )
}

// Project settings -------------------------------------------------------

const sharedBase = computed(() => {
  const p = page.value
  return me.value && p && p.settings ? `/projects/${enc(p.project)}/environments/${enc(p.env)}/variables` : ''
})

effect(() => {
  const base = sharedBase.value
  if (base) untracked(() => loadVars(base, false))
})

function removeProject(name) {
  openForm({
    title: `Delete ${name}?`,
    submit: 'Delete project',
    danger: true,
    render: () => (
      <>
        <p class="muted" style="margin:0">
          Every environment, service, deployment, volume, backup and variable of the project is removed. This cannot be undone.
        </p>
        <div class="field">
          <label for="confirm-project">
            Type <b class="mono">{name}</b> to confirm
          </label>
          <input class="input mono" id="confirm-project" name="name" required autofocus autocomplete="off" />
        </div>
      </>
    ),
    onSubmit: async (f) => {
      if (f.name !== name) throw new Error('The name does not match')
      await del(`/projects/${enc(name)}`)
      navigate('/')
      toast(`${name} deleted`, 'success')
    },
  })
}

function ProjectSettings({ p }) {
  const info = project.value
  const base = sharedBase.value
  return (
    <div class="stage-page">
      <div class="page" style="max-width:860px;padding-top:36px">
        <div class="page-head">
          <h1>Project Settings</h1>
        </div>

        <section class="card card-pad set-card">
          <h3>General</h3>
          <div class="row">
            <div class="field" style="flex:1">
              <label>Project name</label>
              <div class="code-box">
                {p.project}
                <span class="spacer" />
                <button class="btn ghost icon sm" aria-label="Copy" onClick={() => navigator.clipboard?.writeText(p.project)}>
                  <Copy />
                </button>
              </div>
            </div>
          </div>
          {info && <p class="muted small" style="margin:10px 0 0">Created {timeAgo(info.created_at)}.</p>}
        </section>

        <section class="card card-pad set-card">
          <div class="row" style="margin-bottom:12px">
            <h3 style="margin:0">Environments</h3>
            <span class="spacer" />
            <button class="btn sm" onClick={newEnvironment}>
              <Plus /> New environment
            </button>
          </div>
          {(info ? info.environments : []).map((e) => (
            <div class="domain-row" key={e}>
              <span class={`env-chip${e === 'production' ? '' : ' other'}`} />
              <a href={envPath(e)} onClick={follow}>
                <b>{e}</b>
              </a>
              {e === p.env && <span class="badge">current</span>}
              <span class="spacer" />
              {e !== 'production' && (
                <button class="btn ghost icon sm" aria-label={`Delete ${e}`} onClick={() => removeEnvironment(e)}>
                  <Trash />
                </button>
              )}
            </div>
          ))}
        </section>

        <section class="card card-pad set-card">
          <h3>Shared Variables</h3>
          <p class="muted small" style="margin:-6px 0 14px">
            Variables of <b>{p.env}</b> that services use with {'${{ shared.NAME }}'}.
          </p>
          {base && <VariablesEditor base={base} title="Shared Variables" />}
        </section>

        <section class="card card-pad set-card danger-card">
          <h3>Danger</h3>
          <div class="row">
            <div style="flex:1">
              <b>Delete project</b>
              <p class="muted small" style="margin:2px 0 0">Removes the project and everything in it.</p>
            </div>
            <button class="btn danger" onClick={() => removeProject(p.project)}>
              <Trash /> Delete project
            </button>
          </div>
        </section>
      </div>
    </div>
  )
}

export function ProjectPage() {
  const p = page.value
  if (!p) return null
  return (
    <div class="project">
      <Rail p={p} />
      <div class="project-main">
        <Topbar p={p} />
        <div class="stage">
          {p.settings ? (
            <ProjectSettings p={p} />
          ) : (
            <>
              <Canvas />
              <CanvasOverlay />
              <Staged beside={!!p.service} />
              {p.service && <ServicePanel />}
            </>
          )}
        </div>
      </div>
    </div>
  )
}
