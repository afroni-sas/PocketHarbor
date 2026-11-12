// The variables of a service or the shared ones of an environment: masked
// rows with reveal, inline add and edit, and a raw .env editor.

import { signal } from '@preact/signals'
import { Braces, ChevronDown, ChevronRight, Copy, CornerDownRight, EllipsisVertical, Eye, EyeOff, FileText, Pencil, Plug, Plus, Search, Trash, TriangleExclamationPoint } from 'lucide-preact'
import { get, patch, post } from '../api.js'
import { toast } from '../state.js'
import { copy, openForm, openMenu, Spinner } from '../ui.jsx'
import { CodeField, CodeText } from '../code.jsx'

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
    searching.value = false
    needle.value = ''
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
        <CodeField multiline mode="env" name="text" rows={14} defaultValue={text} autofocus />
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
      <CodeField name="value" placeholder="value or ${{ service.VARIABLE }}" />
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
      <CodeField name="value" defaultValue={v.value} autofocus />
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
      ['Copy name', Copy, () => copy(v.name)],
      ['Edit', Pencil, () => (editing.value = v.name)],
      null,
      ['Delete', Trash, () => change(base, { unset: [v.name] }, onChange, `Removed ${v.name}`), true],
    ])
  return (
    <div class="var-row">
      <span class="var-icon" aria-hidden="true">
        <Braces />
      </span>
      <span class="name" title={v.name}>
        {v.name}
      </span>
      <span class="val-cell">
        <span class={`val${open ? ' open' : ''}`} onClick={toggle} title={open ? 'Hide' : 'Show'}>
          {open ? (
            <>
              <CodeText text={v.value} />
              {final !== undefined && final !== v.value && <span class="muted"> → {final}</span>}
            </>
          ) : (
            '*******'
          )}
        </span>
        <span class="var-hover">
          <button class="btn ghost icon sm" aria-label={open ? 'Hide value' : 'Show value'} title={open ? 'Hide' : 'Show'} onClick={toggle}>
            {open ? <EyeOff /> : <Eye />}
          </button>
          <button class="btn ghost icon sm" aria-label="Copy value" title="Copy" onClick={() => copy(final ?? v.value)}>
            <Copy />
          </button>
        </span>
      </span>
      <button class="btn ghost icon sm" aria-label="Variable menu" onClick={menu}>
        <EllipsisVertical />
      </button>
    </div>
  )
}

const searching = signal(false)
const needle = signal('')

/** A reference added as a variable: NAME=${{ service.NAME }}. */
function addReference(base, list, name, value, onChange) {
  let key = name
  for (let i = 2; list.some((v) => v.name === key); i++) key = `${name}_${i}`
  change(base, { set: [{ name: key, value }] }, onChange, `Added ${key}`)
}

/**
 * `base` is the API path of the variables; `onChange` runs after a change
 * (a service marks itself as needing a deploy). `shared` lists the
 * environment's shared variables and `databases` the connection variables
 * of its databases, for the references a service can add.
 */
export function VariablesEditor({ base, title, hint, onChange, shared, databases }) {
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
  const q = needle.value.trim().toLowerCase()
  const shown = q ? list.filter((v) => v.name.toLowerCase().includes(q)) : list
  // Databases of the environment that this service does not use yet.
  const unused = (databases || []).filter((d) => !list.some((v) => v.value.includes(`\${{ ${d.service}.`) || v.value.includes(`\${{${d.service}.`)))
  const sharedMenu = (e) =>
    openMenu(
      e.currentTarget,
      shared && shared.length
        ? ['Reference a shared variable', ...shared.map((v) => [v.name, Braces, () => addReference(base, list, v.name, `\${{ shared.${v.name} }}`, onChange)])]
        : ['No shared variables yet: add them in the project settings'],
    )
  const dbMenu = (e) =>
    openMenu(e.currentTarget, ['Connect to', ...unused.map((d) => [`${d.service}: ${d.variable}`, Braces, () => addReference(base, list, d.variable, `\${{ ${d.service}.${d.variable} }}`, onChange)])])
  return (
    <div>
      <div class="var-head">
        <b>
          {list.length} {title}
        </b>
        {searching.value ? (
          <input
            class="input var-search"
            placeholder="Filter variables"
            value={needle.value}
            onInput={(e) => (needle.value = e.currentTarget.value)}
            onKeyDown={(e) => e.key === 'Escape' && ((needle.value = ''), (searching.value = false))}
            autofocus
          />
        ) : (
          <button class="btn ghost icon sm" aria-label="Filter variables" title="Filter" onClick={() => (searching.value = true)}>
            <Search />
          </button>
        )}
        <span class="spacer" />
        {shared && (
          <button class="btn ghost sm link" onClick={sharedMenu}>
            <CornerDownRight /> Shared Variable
          </button>
        )}
        <button class="btn ghost sm link" onClick={() => rawEditor(base, list, onChange)}>
          <Braces /> Raw Editor
        </button>
        <button class="btn sm outline" onClick={() => ((adding.value = true), (editing.value = ''))}>
          <Plus /> New Variable
        </button>
      </div>
      {hint && <p class="muted small" style="margin:0 0 14px">{hint}</p>}
      {unused.length > 0 && (
        <div class="banner suggest">
          <Plug width={15} height={15} />
          <span>
            Trying to connect a database?{' '}
            <button class="linkish" onClick={dbMenu}>
              Add Variable
            </button>
          </span>
        </div>
      )}
      {state.warnings.map((w) => (
        <div class="banner warn" key={w}>
          <TriangleExclamationPoint width={15} height={15} />
          {w}
        </div>
      ))}
      {adding.value && <AddRow base={base} onChange={onChange} />}
      {list.length === 0 && !adding.value && (
        <div class="card empty">
          <p style="margin:0 0 12px">No variables yet.</p>
          <button class="btn sm outline" onClick={() => (adding.value = true)}>
            <Plus /> New Variable
          </button>
        </div>
      )}
      {q && shown.length === 0 && <div class="empty small">No variable matches “{needle.value}”.</div>}
      {shown.map((v) =>
        editing.value === v.name ? <EditRow key={v.name} base={base} v={v} onChange={onChange} /> : <Row key={v.name} base={base} v={v} resolved={resolved} onChange={onChange} />,
      )}
      {builtins.length > 0 && (
        <>
          <button class="history-head" onClick={() => (showBuiltins.value = !showBuiltins.value)} aria-expanded={showBuiltins.value}>
            {showBuiltins.value ? <ChevronDown width={14} height={14} /> : <ChevronRight width={14} height={14} />}
            <span class="small">{builtins.length} variables added by PocketHarbor</span>
          </button>
          {showBuiltins.value &&
            builtins.map((v) => (
              <div class="var-row builtin" key={v.name}>
                <span class="var-icon" aria-hidden="true">
                  <Braces />
                </span>
                <span class="name">{v.name}</span>
                <span class="val-cell">
                  <span class="val open">{v.value}</span>
                </span>
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
