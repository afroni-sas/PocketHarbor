// The variables of a service or the shared ones of an environment: masked
// rows with reveal, inline add and edit, and a raw .env editor.

import { signal } from '@preact/signals'
import { ChevronDown, ChevronRight, Copy, EllipsisVertical, Eye, EyeOff, FileText, Pencil, Plus, Trash, TriangleExclamationPoint } from 'lucide-preact'
import { get, patch, post } from '../api.js'
import { toast } from '../state.js'
import { copy, openForm, openMenu, Spinner } from '../ui.jsx'

/** What the editor shows: for which base path, the list and the warnings. */
export const vars = signal({ base: '', list: null, resolved: null, warnings: [] })
const revealed = signal({})
const adding = signal(false)
const editing = signal('')
const showBuiltins = signal(false)

export async function loadVars(base, withResolved) {
  if (vars.peek().base !== base) {
    vars.value = { base, list: null, resolved: null, warnings: [] }
    revealed.value = {}
    adding.value = false
    editing.value = ''
  }
  try {
    const [list, res] = await Promise.all([get(base), withResolved ? get(`${base}?resolved=1`).catch(() => null) : null])
    if (vars.peek().base !== base) return
    vars.value = { base, list, resolved: res ? res.variables : null, warnings: res ? res.warnings : [] }
  } catch (err) {
    toast(err.message, 'error')
  }
}

const KEY = '[A-Za-z_][A-Za-z0-9_]*'

async function change(base, body, onChange, done) {
  try {
    await patch(base, body)
    if (done) toast(done, 'success')
    if (onChange) onChange()
    await loadVars(base, vars.peek().resolved !== null)
    return true
  } catch (err) {
    toast(err.message, 'error')
    return false
  }
}

function rawEditor(base, list, onChange) {
  const text = list.map((v) => `${v.name}=${/[\s#"'\\]/.test(v.value) ? JSON.stringify(v.value) : v.value}`).join('\n')
  openForm({
    title: 'Raw Editor',
    submit: 'Update Variables',
    wide: true,
    render: () => (
      <>
        <p class="muted small" style="margin:0">One KEY=value per line, as in a .env file. Variables left out are removed.</p>
        <textarea class="textarea" name="text" rows={14} spellcheck={false} defaultValue={text} autofocus />
      </>
    ),
    onSubmit: async ({ text: next }) => {
      await post(`${base}/raw`, { text: next, replace: true })
      if (onChange) onChange()
      await loadVars(base, vars.peek().resolved !== null)
      toast('Variables updated', 'success')
    },
  })
}

/** Colours ${{ references }} so they read as links between services. */
function Value({ text }) {
  const parts = text.split(/(\$\{\{[^}]*\}\})/g)
  return parts.map((part, i) =>
    part.startsWith('${{') ? (
      <span key={i} class="ref">
        {part}
      </span>
    ) : (
      part
    ),
  )
}

function AddRow({ base, onChange }) {
  const submit = async (e) => {
    e.preventDefault()
    const form = e.currentTarget
    const name = form.elements.name.value.trim()
    const value = form.elements.value.value
    if (await change(base, { set: [{ name, value }] }, onChange, `Added ${name}`)) adding.value = false
  }
  return (
    <form class="var-add" onSubmit={submit}>
      <input class="input mono" name="name" placeholder="VARIABLE_NAME" pattern={KEY} required autofocus spellcheck={false} />
      <input class="input mono" name="value" placeholder="value or ${{ service.VARIABLE }}" spellcheck={false} />
      <button class="btn primary sm">Add</button>
      <button type="button" class="btn ghost sm" onClick={() => (adding.value = false)}>
        Cancel
      </button>
    </form>
  )
}

function EditRow({ base, v, onChange }) {
  const submit = async (e) => {
    e.preventDefault()
    const value = e.currentTarget.elements.value.value
    if (await change(base, { set: [{ name: v.name, value }] }, onChange, `Updated ${v.name}`)) editing.value = ''
  }
  return (
    <form class="var-add" onSubmit={submit}>
      <input class="input mono" value={v.name} disabled />
      <input class="input mono" name="value" defaultValue={v.value} autofocus spellcheck={false} />
      <button class="btn primary sm">Save</button>
      <button type="button" class="btn ghost sm" onClick={() => (editing.value = '')}>
        Cancel
      </button>
    </form>
  )
}

function Row({ base, v, resolved, onChange }) {
  const open = revealed.value[v.name]
  const toggle = () => (revealed.value = { ...revealed.value, [v.name]: !open })
  const final = resolved && resolved[v.name]
  const menu = (e) =>
    openMenu(e.currentTarget, [
      ['Copy value', Copy, () => copy(final ?? v.value)],
      ['Edit', Pencil, () => (editing.value = v.name)],
      null,
      ['Delete', Trash, () => change(base, { unset: [v.name] }, onChange, `Removed ${v.name}`), true],
    ])
  return (
    <div class="var-row">
      <span class="name" title={v.name}>
        {v.name}
      </span>
      <span class="val" onClick={toggle} title={open ? 'Hide' : 'Show'}>
        {open ? (
          <>
            <Value text={v.value} />
            {final !== undefined && final !== v.value && <span class="muted"> → {final}</span>}
          </>
        ) : (
          '*******'
        )}
      </span>
      <span class="row" style="gap:2px">
        <button class="btn ghost icon sm" aria-label={open ? 'Hide value' : 'Show value'} onClick={toggle}>
          {open ? <EyeOff /> : <Eye />}
        </button>
        <button class="btn ghost icon sm" aria-label="Variable menu" onClick={menu}>
          <EllipsisVertical />
        </button>
      </span>
    </div>
  )
}

/**
 * `base` is the API path of the variables; `onChange` runs after a change
 * (a service marks itself as needing a deploy).
 */
export function VariablesEditor({ base, title, hint, onChange }) {
  const state = vars.value
  if (state.base !== base || !state.list) {
    return (
      <div class="empty">
        <Spinner />
      </div>
    )
  }
  const list = state.list
  const resolved = state.resolved ? Object.fromEntries(state.resolved.map((v) => [v.name, v.value])) : null
  const own = new Set(list.map((v) => v.name))
  const builtins = state.resolved ? state.resolved.filter((v) => v.name.startsWith('PHARBOR_') && !own.has(v.name)) : []
  return (
    <div>
      <div class="row" style="margin-bottom:12px;flex-wrap:wrap">
        <b style="font-size:14px">
          {list.length} {title}
        </b>
        <span class="spacer" />
        <button class="btn sm" onClick={() => rawEditor(base, list, onChange)}>
          <FileText /> Raw Editor
        </button>
        <button class="btn sm primary" onClick={() => ((adding.value = true), (editing.value = ''))}>
          <Plus /> New Variable
        </button>
      </div>
      {hint && <p class="muted small" style="margin:0 0 12px">{hint}</p>}
      {state.warnings.map((w) => (
        <div class="banner warn" key={w}>
          <TriangleExclamationPoint width={15} height={15} />
          {w}
        </div>
      ))}
      {adding.value && <AddRow base={base} onChange={onChange} />}
      {list.length === 0 && !adding.value && <div class="empty small">No variables yet.</div>}
      {list.map((v) =>
        editing.value === v.name ? <EditRow key={v.name} base={base} v={v} onChange={onChange} /> : <Row key={v.name} base={base} v={v} resolved={resolved} onChange={onChange} />,
      )}
      {builtins.length > 0 && (
        <>
          <div class="history-head muted small" onClick={() => (showBuiltins.value = !showBuiltins.value)}>
            {showBuiltins.value ? <ChevronDown width={14} height={14} /> : <ChevronRight width={14} height={14} />}
            {builtins.length} variables added by PocketHarbor
          </div>
          {showBuiltins.value &&
            builtins.map((v) => (
              <div class="var-row" key={v.name}>
                <span class="name muted">{v.name}</span>
                <span class="val">{v.value}</span>
                <button class="btn ghost icon sm" aria-label="Copy value" onClick={() => copy(v.value)}>
                  <Copy />
                </button>
              </div>
            ))}
        </>
      )}
    </div>
  )
}
