// "What would you like to create?": Railway's Add dialog. One search box,
// a list, and lists inside it for repositories, databases, templates,
// images and volumes, all usable from the keyboard.

import { signal } from '@preact/signals'
import { ArrowLeft, Box, ChevronRight, Database, HardDrive, Info, LayoutTemplate, Lock, Package, Square, TerminalSquare } from 'lucide-preact'
import { enc, get, patch, post } from '../api.js'
import { closeOverlay, overlay, services, toast } from '../state.js'
import { navigate } from '../router.js'
import { markDirty, openService, page, refresh } from '../project.js'
import { GithubIcon, openForm, ServiceIcon, Spinner } from '../ui.jsx'
import { createService, nextSpot, uniqueName } from './Canvas.jsx'
import { ConnectButton } from '../connect.jsx'

const view = signal('root')
const query = signal('')
const index = signal(0)
const busy = signal(false)
const repos = signal(null)
const templates = signal(null)

const titles = {
  repo: 'GitHub Repository',
  database: 'Database',
  template: 'Template',
  image: 'Docker Image',
  volume: 'Volume',
}

const placeholders = {
  root: 'What would you like to create?',
  repo: 'Search your repositories, or paste owner/name...',
  database: 'Choose a database...',
  template: 'Search templates...',
  image: 'nginx:alpine',
  volume: 'Choose the service to attach it to...',
}

async function loadRepos() {
  if (repos.peek()) return
  try {
    repos.value = await get('/github/repos')
  } catch (err) {
    repos.value = { has_token: false, repos: [], error: err.message }
  }
}

async function loadTemplates() {
  if (templates.peek()) return
  try {
    templates.value = await get('/templates')
  } catch {
    templates.value = []
  }
}

function go(next) {
  view.value = next
  query.value = ''
  index.value = 0
  if (next === 'repo') loadRepos()
  if (next === 'database' || next === 'template' || next === 'root') loadTemplates()
}

/** Creates a service, then opens it; `done` is what the toast says. */
async function make(body, done) {
  if (busy.peek()) return
  busy.value = true
  try {
    await createService(body)
    closeOverlay()
    toast(done, 'success')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    busy.value = false
  }
}

async function makeTemplate(t) {
  if (busy.peek()) return
  busy.value = true
  const p = page.peek()
  try {
    const res = await post(`/templates/${enc(t.id)}`, { project: p.project, environment: p.env, ...nextSpot() })
    closeOverlay()
    await refresh()
    openService(res.name)
    toast(`Deploying ${t.name}`, 'success')
  } catch (err) {
    toast(err.message, 'error')
  } finally {
    busy.value = false
  }
}

function repoName(text) {
  const t = text.trim().replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '').replace(/\/+$/, '')
  return /^[\w.-]+\/[\w.-]+$/.test(t) ? t : ''
}

function imageBase(image) {
  return image.split('@')[0].split('/').pop().split(':')[0]
}

function attachVolume(svc) {
  closeOverlay()
  openForm({
    title: `Attach a volume to ${svc.name}`,
    submit: 'Attach',
    render: () => (
      <>
        <div class="field">
          <label for="vmount">Mount path</label>
          <input class="input mono" id="vmount" name="mount" placeholder="/data" pattern="/.*" required autofocus />
          <span class="hint">Files written there survive deploys and restarts.</span>
        </div>
        <div class="field">
          <label for="vname">Name</label>
          <input class="input mono" id="vname" name="name" defaultValue={`${svc.name}-volume`} pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required />
        </div>
      </>
    ),
    onSubmit: async ({ name, mount }) => {
      await patch(`/services/${enc(svc.id)}`, { volumes: [...svc.volumes, { name, mount }] })
      markDirty(svc)
      await refresh()
      toast('Volume attached; deploy to mount it', 'success')
    },
  })
}

/** The rows of the current view, each with what Enter does. */
function rows() {
  const q = query.value.trim().toLowerCase()
  const has = (text) => !q || text.toLowerCase().includes(q)
  const v = view.value
  if (v === 'root') {
    const all = [
      { label: 'GitHub Repository', icon: GithubIcon, more: true, run: () => go('repo') },
      { label: 'Database', icon: Database, more: true, run: () => go('database') },
      { label: 'Template', icon: LayoutTemplate, more: true, run: () => go('template') },
      { label: 'Docker Image', icon: Box, more: true, run: () => go('image') },
      { label: 'Bucket', icon: Package, hint: 'S3 storage with MinIO', run: () => (templates.peek() || []).filter((t) => t.category === 'bucket').slice(0, 1).forEach(makeTemplate) },
      { label: 'Volume', icon: HardDrive, more: true, run: () => go('volume') },
      { label: 'Empty Service', icon: Square, run: () => make({ name: uniqueName('service'), deploy: false }, 'Empty service created: connect a repository or an image in its settings') },
    ]
    // Typing a template's name finds it from the first list too.
    const extra = q ? (templates.value || []).filter((t) => has(t.name)).map((t) => ({ label: t.name, svc: { image: t.image }, hint: t.category === 'database' ? 'Database' : 'Template', run: () => makeTemplate(t) })) : []
    return [...all.filter((r) => has(r.label)), ...extra]
  }
  if (v === 'repo') {
    const r = repos.value
    const typed = repoName(query.value)
    const out = []
    if (typed) out.push({ label: `Deploy ${typed}`, icon: GithubIcon, hint: 'branch main', run: () => make({ name: uniqueName(typed.split('/').pop()), repo: typed, branch: 'main', deploy: true }, `Deploying ${typed}`) })
    for (const repo of (r && r.repos) || []) {
      if (!has(repo.full_name) || repo.full_name === typed) continue
      out.push({
        label: repo.full_name,
        icon: repo.private ? Lock : GithubIcon,
        hint: repo.default_branch,
        run: () => make({ name: uniqueName(repo.full_name.split('/').pop()), repo: repo.full_name, branch: repo.default_branch, deploy: true }, `Deploying ${repo.full_name}`),
      })
    }
    return out
  }
  if (v === 'database' || v === 'template') {
    return (templates.value || [])
      .filter((t) => (v === 'template' || t.category === 'database') && (has(t.name) || has(t.image)))
      .map((t) => ({ label: t.name, svc: { image: t.image }, hint: t.image, run: () => makeTemplate(t) }))
  }
  if (v === 'volume') {
    return (services.value || []).filter((s) => has(s.name)).map((s) => ({ label: s.name, svc: s, hint: s.volumes.length ? `${s.volumes.length} volume${s.volumes.length === 1 ? '' : 's'}` : '', run: () => attachVolume(s) }))
  }
  return []
}

function submitImage() {
  const image = query.value.trim()
  if (!image) return
  make({ name: uniqueName(imageBase(image)), image, deploy: true }, `Deploying ${image}`)
}

function Dialog() {
  const v = view.value
  const list = rows()
  const at = Math.min(index.value, Math.max(0, list.length - 1))
  const key = (e) => {
    if (e.key === 'Escape') {
      e.preventDefault()
      if (v === 'root') closeOverlay()
      else go('root')
    } else if (e.key === 'Backspace' && v !== 'root' && !query.value) {
      e.preventDefault()
      go('root')
    } else if (e.key === 'ArrowDown') {
      e.preventDefault()
      index.value = (at + 1) % Math.max(1, list.length)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      index.value = (at - 1 + list.length) % Math.max(1, list.length)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      if (v === 'image') submitImage()
      else if (list[at]) list[at].run()
    }
  }
  const r = repos.value
  return (
    <div class="backdrop palette-backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="add-dialog-wrap">
        {v !== 'root' && <span class="add-crumb">{titles[v]}</span>}
        <div class="palette add-dialog" role="dialog" aria-label="Create">
          <div class="palette-input">
            {v === 'root' ? (
              <TerminalSquare />
            ) : (
              <button class="btn ghost icon sm" aria-label="Back" onClick={() => go('root')}>
                <ArrowLeft />
              </button>
            )}
            <input
              key={v}
              autofocus
              placeholder={placeholders[v]}
              value={query.value}
              onInput={(e) => ((query.value = e.currentTarget.value), (index.value = 0))}
              onKeyDown={key}
              aria-label={placeholders[v]}
              spellcheck={false}
            />
            {busy.value ? (
              <Spinner />
            ) : (
              v === 'image' &&
              query.value.trim() && (
                <button class="btn primary sm" onClick={submitImage}>
                  Deploy
                </button>
              )
            )}
          </div>
          {v === 'image' ? (
            <div class="add-image">
              <div class="add-note">
                <Info /> Enter a Docker image from Docker Hub, GHCR, Quay or another registry. It is pulled and deployed on this phone.
              </div>
              <div class="add-examples">
                <b>Examples</b>
                {['nginx:alpine', 'ghcr.io/owner/app:latest', 'quay.io/owner/app:tag', 'louislam/uptime-kuma:1', 'n8nio/n8n'].map((x) => (
                  <button
                    key={x}
                    class="mono"
                    onClick={(e) => {
                      query.value = x
                      e.currentTarget.closest('.add-dialog').querySelector('input').focus()
                    }}
                  >
                    {x}
                  </button>
                ))}
              </div>
            </div>
          ) : (
            <div class="palette-list" role="listbox">
              {v === 'repo' && r && !r.has_token && (
                <div class="add-connect">
                  <span>Connect GitHub to list your repositories here, or paste owner/name above.</span>
                  <ConnectButton
                    kind="github"
                    small
                    onClick={() => {
                      closeOverlay()
                      navigate('/settings?tab=github')
                    }}
                  />
                </div>
              )}
              {v === 'repo' && r && r.error && <div class="add-note red">{r.error}</div>}
              {v === 'repo' && !r && (
                <div class="empty">
                  <Spinner />
                </div>
              )}
              {list.length === 0 && v !== 'repo' && <div class="empty small">Nothing matches “{query.value}”.</div>}
              {list.map((row, i) => {
                const Icon = row.icon
                return (
                  <div
                    key={`${row.label}${i}`}
                    role="option"
                    aria-selected={i === at}
                    class={`palette-item${i === at ? ' on' : ''}`}
                    onMouseMove={() => index.value !== i && (index.value = i)}
                    onClick={row.run}
                    ref={(el) => i === at && el && el.scrollIntoView({ block: 'nearest' })}
                  >
                    {row.svc ? <ServiceIcon svc={row.svc} size={16} /> : Icon ? <Icon width={16} height={16} size={16} /> : null}
                    <span class="label">{row.label}</span>
                    {row.hint && <span class="hint">{row.hint}</span>}
                    {row.more && <ChevronRight class="enter" width={15} height={15} />}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

/** Opens the dialog, on its first list or straight on one of the others. */
export function openAdd(start = 'root') {
  if (!page.peek()) return
  busy.value = false
  go(start)
  overlay.value = Dialog
}
