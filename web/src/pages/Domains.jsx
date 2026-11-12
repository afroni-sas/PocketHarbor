// Public networking as Railway lays it out: one list of domains, each with
// its port and, until it works, "Waiting for DNS update · Show DNS records";
// the forms open in place. With Cloudflare connected, PocketHarbor writes the
// records itself; the state always comes from a real request through the name.

import { signal } from '@preact/signals'
import { ArrowRight, Check, CircleCheck, Copy, Globe, Info, Pencil, Plus, Trash, TriangleAlert, Zap } from 'lucide-preact'
import { enc, get, post, put } from '../api.js'
import { closeOverlay, overlay, toast } from '../state.js'
import { navigate } from '../router.js'
import { copy, Spinner } from '../ui.jsx'
import { privateName, refresh } from '../project.js'
import { ConnectButton } from '../connect.jsx'

/** The domains of the service on screen, with their records and states. */
export const domainInfo = signal({ id: '', data: null, checking: false, at: 0 })
/** Which form is open: '' | 'custom' | 'generate' | 'edit:DOMAIN'. */
const form = signal('')
const draft = signal({ domain: '', prefix: '', zone: '', port: '', error: '', busy: false })
const nameCheck = signal({ name: '', result: null })

/** What is happening to a name, until it is done: "SERVICE DOMAIN" → text.
 * A name being added shows as a row before the server lists it. */
const pending = signal({})
const generating = '(generating)'

/** Cloudflare is connected in Settings › Public access. */
function connectCloudflare() {
  closeOverlay()
  navigate('/settings?tab=networking')
}

function setPending(svcId, domain, text) {
  const key = `${svcId} ${domain}`
  const next = { ...pending.peek() }
  if (text) next[key] = text
  else delete next[key]
  pending.value = next
}

function pendingOf(svcId, domain) {
  return pending.value[`${svcId} ${domain}`] || ''
}

/** Each load gets a number: only the latest may change what is shown. */
let latest = 0

/**
 * Loads the domains of service `id`, then checks them. `repeat` is the
 * periodic call: it only checks again while a name is not set up yet.
 */
export async function loadDomains(id, repeat = false) {
  if (domainInfo.peek().id !== id) {
    domainInfo.value = { id, data: null, checking: false, at: 0 }
    form.value = ''
  }
  const cur = domainInfo.peek()
  if (repeat && (cur.checking || (cur.data && cur.data.domains.every((d) => d.status === 'active')))) return
  const mine = ++latest
  const current = () => mine === latest && domainInfo.peek().id === id
  try {
    const data = await get(`/services/${enc(id)}/domains`)
    if (!current()) return
    // Keep the states already known while the new check runs.
    const old = domainInfo.peek().data
    if (old) for (const d of data.domains) Object.assign(d, pick(old.domains.find((o) => o.domain === d.domain)))
    domainInfo.value = { ...domainInfo.peek(), data, checking: data.domains.length > 0 }
    if (data.domains.length === 0) return
    const checked = await get(`/services/${enc(id)}/domains?check=1`)
    if (!current()) return
    domainInfo.value = { id, data: checked, checking: false, at: Date.now() }
  } catch {
    if (current()) domainInfo.value = { ...domainInfo.peek(), checking: false }
  }
}

function pick(d) {
  return d && d.status ? { status: d.status, via: d.via, detail: d.detail } : {}
}

/** "https://App.Example.com/path" → "app.example.com"; "" when it is not a name. */
export function cleanDomain(text) {
  const d = text
    .trim()
    .toLowerCase()
    .replace(/^[a-z]+:\/\//, '')
    .replace(/[/?#].*$/, '')
    .replace(/:\d+$/, '')
    .replace(/\.$/, '')
  return /^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$/.test(d) ? d : ''
}

/** What the sub-line says after the port, and whether the row warns. */
/** "_cf-custom-hostname.app.example.org" in the zone "example.org" → "_cf-custom-hostname.app". */
function relative(name, zone) {
  if (!zone || name === zone) return '@'
  return name.endsWith(`.${zone}`) ? name.slice(0, -zone.length - 1) : name
}

function stateOf(d, info) {
  if (d.record === 'relay') {
    if (!d.status || d.status === 'active') return { text: !d.status && domainInfo.value.checking ? 'Checking' : '', warn: false }
    return { text: 'Not reachable yet: the phone is connecting to the relay', warn: true, noRecords: true }
  }
  if (d.record === 'foreign') return d.foreign_active || d.status === 'active' ? { text: '', warn: false } : { text: 'Waiting for DNS update', warn: true }
  if (d.record === 'no_zone') return { text: 'Not in your Cloudflare zones', warn: true }
  if (d.record === 'conflict') return { text: 'Another DNS record holds this name', warn: true }
  if (d.record === 'failed') return { text: 'Cloudflare did not write the record', warn: true }
  if (d.status === 'active') return { text: '', warn: false }
  if (!d.status) return { text: domainInfo.value.checking ? 'Checking DNS' : '', warn: false }
  if (d.status === 'elsewhere') return { text: 'Points to another server', warn: true }
  if (d.status === 'cloudflare' && !info.managed && info.setup !== 'tunnel') return { text: 'Points to Cloudflare, not to this phone', warn: true }
  return { text: 'Waiting for DNS update', warn: true }
}

function ago(at) {
  if (!at) return ''
  const s = Math.round((Date.now() - at) / 1000)
  return s < 5 ? 'just now' : s < 60 ? `${s} seconds ago` : `${Math.round(s / 60)} minutes ago`
}

function CopyCell({ text }) {
  return (
    <button class="dns-copy mono" title="Copy" onClick={() => copy(text)}>
      <span>{text}</span>
      <Copy />
    </button>
  )
}

/** Railway's "Configure DNS Records" dialog, for one domain. */
export function showDnsRecords(svcId, domain) {
  overlay.value = () => {
    const info = domainInfo.value.id === svcId ? domainInfo.value.data : null
    const d = info && info.domains.find((x) => x.domain === domain)
    if (!d) return null
    const ready = d.status === 'active'
    const managed = info.managed && d.record === 'ready'
    const origin = info.origin.replace(/^https?:\/\//, '')
    return (
      <div class="backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
        <div class="modal dns-modal" role="dialog" aria-label="Configure DNS Records">
          <header>
            <h3>Configure DNS Records</h3>
            <span class="spacer" />
            <button class="btn ghost icon sm" onClick={closeOverlay} aria-label="Close">
              ×
            </button>
          </header>
          <div class="body">
            {ready && !managed ? (
              <p>
                This record is in place: <span class="mono">{d.domain}</span> reaches this phone{d.via === 'https' ? ' over HTTPS' : ''}.
              </p>
            ) : managed ? (
              <p>
                PocketHarbor added this record to <span class="zone">{d.zone}</span> in your Cloudflare account
                {ready ? '; the domain works.' : '. Cloudflare usually takes a few seconds to a few minutes to serve it.'}
              </p>
            ) : info.managed && d.record === 'foreign' ? (
              <p>
                {ready || d.foreign_active ? 'These records are in place: ' : 'Add the following DNS records to '}
                <span class="zone">{d.zone}</span>
                {ready || d.foreign_active ? '.' : ', wherever its DNS is. The certificate follows a few minutes later.'}
              </p>
            ) : info.managed && d.record === 'failed' && info.saas_zone ? (
              <p>{d.record_detail.charAt(0).toUpperCase() + d.record_detail.slice(1)}.</p>
            ) : info.managed && d.record === 'no_zone' ? (
              <>
                <p>
                  <span class="zone">{d.zone}</span> is not in your Cloudflare account.
                </p>
                <p class="muted small">
                  Add it there, or turn on Outside domains in{' '}
                  <button
                    class="linkish"
                    onClick={() => {
                      closeOverlay()
                      navigate('/settings?tab=networking')
                    }}
                  >
                    Settings › Public access
                  </button>{' '}
                  to point it with DNS records.
                </p>
              </>
            ) : info.managed && d.record === 'conflict' ? (
              <p>
                {d.record_detail.charAt(0).toUpperCase() + d.record_detail.slice(1)}. Delete it in Cloudflare, then Check again.
              </p>
            ) : info.setup === 'tunnel' ? (
              <p>
                Add this record to <span class="zone">{d.zone}</span>, and <span class="mono">{d.domain}</span> to the tunnel's hostnames with <span class="mono">http://{origin}</span>. Connecting Cloudflare does both for you.
              </p>
            ) : (
              <p>
                Add this record to <span class="zone">{d.zone}</span>. It reaches the phone on your network only, at{' '}
                <span class="mono">
                  http://{d.domain}
                  {info.proxy_port === 80 ? '' : `:${info.proxy_port}`}
                </span>
                . To reach it from the internet,{' '}
                <button
                  class="linkish"
                  onClick={() => {
                    closeOverlay()
                    navigate('/settings?tab=networking')
                  }}
                >
                  connect Cloudflare
                </button>
                .
              </p>
            )}
            {d.records.length > 0 && !(info.managed && d.record === 'no_zone') && (
              <div class="dns-table" role="table">
                <div class="dns-row head" role="row">
                  <span role="columnheader">Type</span>
                  <span role="columnheader">Name</span>
                  <span role="columnheader">Value</span>
                </div>
                {d.records.map((r) => (
                  <div class="dns-row" role="row" key={r.type + r.name}>
                    <span class="dns-type" role="cell">
                      {ready || managed || d.foreign_active ? <Check class="ok" width={14} height={14} /> : <TriangleAlert class="warn" width={14} height={14} />}
                      {r.type}
                    </span>
                    <span role="cell">
                      <CopyCell text={d.record === 'foreign' ? relative(r.name, d.zone) : r.name} />
                    </span>
                    <span role="cell">
                      <CopyCell text={r.value} />
                      {r.proxied && <span class="badge orange">Proxied</span>}
                    </span>
                  </div>
                ))}
              </div>
            )}
            {d.kind === 'base' && <p class="muted small">This record covers every service of the base domain.</p>}
            {!d.certificate && (
              <p class="banner warn">
                <TriangleAlert width={15} height={15} /> Cloudflare's free certificate covers {d.zone} and one level below it, not {d.domain}: browsers will refuse it. Use a name like app.{d.zone}.
              </p>
            )}
            {d.detail && !ready && (
              <p class="muted small">
                {d.detail.charAt(0).toUpperCase() + d.detail.slice(1)}. Checked {ago(domainInfo.value.at)}.
              </p>
            )}
          </div>
          <footer>
            <a class="linkish" href="https://github.com/afroni-sas/PocketHarbor#custom-domains" target="_blank" rel="noreferrer">
              View Documentation
            </a>
            <span class="spacer" />
            <button class="btn" onClick={() => recheck(svcId)} disabled={domainInfo.value.checking}>
              {domainInfo.value.checking && <Spinner />} Check again
            </button>
            <button class="btn" onClick={closeOverlay}>
              Dismiss
            </button>
          </footer>
        </div>
      </div>
    )
  }
}

async function recheck(svcId) {
  const info = domainInfo.peek().data
  if (info && info.managed) await post('/cloudflare/sync').catch((err) => toast(err.message, 'error'))
  await loadDomains(svcId)
}

function removeDomain(svc, domain, update, generated) {
  const what = generated ? 'generated domain' : 'custom domain'
  overlay.value = () => (
    <div class="backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="modal" role="dialog" aria-label={generated ? 'Remove Generated Domain' : 'Remove Custom Domain'}>
        <header>
          <h3>{generated ? 'Remove Generated Domain' : 'Remove Custom Domain'}</h3>
        </header>
        <div class="body">
          <p style="margin:0">
            Are you sure you want to remove the {what} <b>{domain}</b>?{generated ? ' Generate Domain can then make another.' : ''}
          </p>
        </div>
        <footer>
          <button class="btn" onClick={closeOverlay} autofocus>
            Cancel
          </button>
          <button
            class="btn danger-solid"
            onClick={async () => {
              closeOverlay()
              if (form.peek() === `edit:${domain}`) form.value = ''
              const managed = domainInfo.peek().data && domainInfo.peek().data.managed
              setPending(svc.id, domain, !managed ? 'Removing' : domain.endsWith('.workers.dev') ? 'Removing the domain and its Worker' : 'Removing the domain and its DNS record')
              try {
                await update(svc, { domains: svc.domains.filter((x) => x !== domain) }, true)
                await loadDomains(svc.id)
                toast(`${domain} removed`, 'success')
              } catch (err) {
                toast(err.message, 'error')
              } finally {
                setPending(svc.id, domain, '')
              }
            }}
          >
            Delete
          </button>
        </footer>
      </div>
    </div>
  )
}

/** A name on its way in or out: what is happening, with no action to take. */
function PendingRow({ domain, text, port }) {
  return (
    <div class="net-row busy" aria-busy="true">
      <span class="net-icon">
        <Spinner />
      </span>
      <div class="net-what">
        <span class="net-name">{domain}</span>
        <span class="net-sub">
          <ArrowRight width={11} height={11} /> Port {port} · <span class="muted">{text}…</span>
        </span>
      </div>
    </div>
  )
}

function Row({ svc, d, info, update }) {
  const state = stateOf(d, info)
  const custom = d.kind === 'custom' || d.kind === 'generated'
  const editing = form.value === `edit:${d.domain}`
  const busy = pendingOf(svc.id, d.domain)
  const href = d.status === 'active' && d.via !== 'https' ? `http://${d.domain}${d.via.includes('port') ? `:${info.proxy_port}` : ''}` : `https://${d.domain}`
  if (busy) return <PendingRow domain={d.domain} text={busy} port={svc.port || 8080} />
  return (
    <>
      <div class={`net-row${editing ? ' open' : ''}`}>
        {state.warn ? <TriangleAlert class="net-icon warn" /> : <Globe class="net-icon" />}
        <div class="net-what">
          <a href={href} target="_blank" rel="noreferrer">
            {d.domain}
          </a>
          <span class="net-sub">
            <ArrowRight width={11} height={11} /> Port {svc.port || 8080}
            {state.text && (
              <>
                {' · '}
                {state.text === 'Checking DNS' || state.text === 'Checking' ? <span class="muted">{state.text}</span> : state.text}
                {state.text !== 'Checking DNS' && state.text !== 'Checking' && !state.noRecords && (
                  <>
                    {' · '}
                    <button class="linkish" onClick={() => showDnsRecords(svc.id, d.domain)}>
                      Show DNS records
                    </button>
                  </>
                )}
              </>
            )}
            {!state.text && d.status === 'active' && d.records.length > 0 && custom && d.record !== 'relay' && (
              <>
                {' · '}
                <button class="linkish quiet" onClick={() => showDnsRecords(svc.id, d.domain)}>
                  DNS records
                </button>
              </>
            )}
          </span>
        </div>
        <span class="net-actions">
          <button class="btn ghost icon sm" aria-label={`Copy ${d.domain}`} title="Copy" onClick={() => copy(`https://${d.domain}`)}>
            <Copy />
          </button>
          <button
            class="btn ghost icon sm"
            aria-label={`Edit ${d.domain}`}
            title="Edit"
            onClick={() => {
              draft.value = { domain: d.domain, prefix: '', zone: '', port: String(svc.port || 8080), error: '', busy: false }
              form.value = editing ? '' : `edit:${d.domain}`
            }}
          >
            <Pencil />
          </button>
          {custom && (
            <button class="btn ghost icon sm" aria-label={`Remove ${d.domain}`} title="Remove" onClick={() => removeDomain(svc, d.domain, update, d.kind === 'generated')}>
              <Trash />
            </button>
          )}
        </span>
      </div>
      {editing && <EditForm svc={svc} d={d} info={info} update={update} />}
    </>
  )
}

function Foot({ hint, ok, error, children }) {
  return (
    <div class="net-foot">
      <span class={`small ${error ? 'red' : ok ? 'green' : 'muted'}`}>
        {ok ? <Check width={14} height={14} /> : error ? <TriangleAlert width={14} height={14} /> : <Info width={14} height={14} />} {hint}
      </span>
      {children}
    </div>
  )
}

function portOf(text) {
  const n = Number(text)
  return Number.isInteger(n) && n >= 1 && n <= 65535 ? n : 0
}

async function savePort(svc, update, port) {
  if (port && port !== (svc.port || 8080)) {
    await update(svc, { port })
    toast(`Port ${port} saved; deploy to apply it`, 'success')
  }
}

/** "ph-0a1b.example.workers.dev" → ["ph-0a1b", "example.workers.dev"]. */
function splitGenerated(domain) {
  const dot = domain.indexOf('.')
  return [domain.slice(0, dot), domain.slice(dot + 1)]
}

async function renameGenerated(svc, update, d, label, suffix, info, port) {
  const zone = suffix === info.relay_suffix ? '' : suffix
  form.value = ''
  setPending(svc.id, d.domain, 'Updating the domain')
  try {
    const res = await put(`/services/${enc(svc.id)}/generate-domain`, { label, zone })
    await savePort(svc, update, port)
    await refresh()
    await loadDomains(svc.id)
    toast(`${res.domain} is ready`, 'success')
  } catch (err) {
    toast(err.message, 'error')
    draft.value = { ...draft.peek(), error: err.message }
    form.value = `edit:${d.domain}`
  } finally {
    setPending(svc.id, d.domain, '')
  }
}

function EditForm({ svc, d, info, update }) {
  const v = draft.value
  const port = portOf(v.port)
  // A generated name: its label and where it lives can change.
  const editable = d.kind === 'generated' && info.managed
  const [label0, suffix0] = splitGenerated(d.domain)
  const suffixes = editable ? [...(info.relay_suffix ? [info.relay_suffix] : []), ...(info.zones || [])] : []
  if (editable && !suffixes.includes(suffix0)) suffixes.unshift(suffix0)
  const label = (v.prefix || label0).trim().toLowerCase()
  const suffix = v.zone || suffix0
  const renamed = editable && (label !== label0 || suffix !== suffix0)
  const labelOk = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)
  const changed = (port && port !== (svc.port || 8080)) || renamed
  const submit = async (e) => {
    e.preventDefault()
    if (!changed || (renamed && !labelOk)) return
    if (renamed) return renameGenerated(svc, update, d, label, suffix, info, port)
    try {
      await savePort(svc, update, port)
      form.value = ''
    } catch (err) {
      draft.value = { ...draft.peek(), error: err.message }
    }
  }
  const escape = (e) => e.key === 'Escape' && (e.preventDefault(), (form.value = ''))
  let hint = v.error || (d.kind === 'base' ? 'The name comes from the base domain; the port is the service’s' : 'Update your target port')
  if (!v.error && editable) {
    hint = renamed && !labelOk ? 'Use a-z, 0-9 and dashes' : suffix.endsWith('.workers.dev') ? 'On workers.dev: 100,000 requests a day' : `In ${suffix}, through the tunnel: no request limit`
  }
  return (
    <form class="net-form inline" onSubmit={submit}>
      {editable ? (
        <div class="domain-input">
          <input
            class="input mono"
            value={v.prefix || label0}
            aria-label="Name"
            spellcheck={false}
            autocomplete="off"
            onInput={(e) => (draft.value = { ...draft.peek(), prefix: e.currentTarget.value, error: '' })}
            onKeyDown={escape}
          />
          <span class="domain-dot">.</span>
          <select class="select mono" value={suffix} aria-label="Where" onChange={(e) => (draft.value = { ...draft.peek(), zone: e.currentTarget.value, error: '' })}>
            {suffixes.map((x) => (
              <option key={x} value={x}>
                {x}
              </option>
            ))}
          </select>
        </div>
      ) : (
        <input class="input" value={d.domain} disabled aria-label="Domain" />
      )}
      <label for="edit-port">Enter the port your app is listening on</label>
      <input
        class="input"
        id="edit-port"
        type="number"
        min="1"
        max="65535"
        value={v.port}
        autofocus={!editable}
        onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value, error: '' })}
        onKeyDown={escape}
      />
      <Foot hint={hint} error={!!v.error || (renamed && !labelOk)}>
        <button type="button" class="btn sm" onClick={() => (form.value = '')}>
          Cancel
        </button>
        <button class="btn primary sm" disabled={!changed || (renamed && !labelOk)}>
          Update
        </button>
      </Foot>
    </form>
  )
}

let checkTimer = 0
function checkName(svc, name) {
  clearTimeout(checkTimer)
  if (!name) {
    nameCheck.value = { name: '', result: null }
    return
  }
  checkTimer = setTimeout(async () => {
    try {
      const result = await get(`/domain-check?name=${enc(name)}&service=${enc(svc.id)}`)
      if (cleanDomain(draft.peek().domain) === name) nameCheck.value = { name, result }
    } catch {
      // The form still works without it.
    }
  }, 250)
}

async function addDomain(svc, update, domain, port, managed) {
  draft.value = { ...draft.peek(), busy: true, error: '' }
  setPending(svc.id, domain, managed ? 'Adding the domain and writing its DNS record' : 'Adding the domain')
  try {
    await update(svc, { domains: [...svc.domains, domain] }, true)
    await savePort(svc, update, port)
    form.value = ''
    draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
    // The dialog opens at once, as on Railway; the check fills it in.
    const data = await get(`/services/${enc(svc.id)}/domains`)
    if (domainInfo.peek().id === svc.id) domainInfo.value = { ...domainInfo.peek(), data }
    setPending(svc.id, domain, '')
    showDnsRecords(svc.id, domain)
    loadDomains(svc.id)
  } catch (err) {
    draft.value = { ...draft.peek(), busy: false, error: err.message }
  } finally {
    setPending(svc.id, domain, '')
  }
}

const other = '(other)'

function CustomForm({ svc, update, info }) {
  const v = draft.value
  const zones = (info && info.managed && info.zones) || []
  // With zones, a name in one of them, or any other one.
  const zone = zones.length ? v.zone || zones[0] : other
  const prefix = v.prefix.trim().toLowerCase().replace(/\.+$/, '')
  const domain = zone === other ? cleanDomain(v.domain) : cleanDomain(prefix ? `${prefix}.${zone}` : zone)
  const typed = zone === other ? v.domain.trim() : prefix
  const c = nameCheck.value.name === domain ? nameCheck.value.result : null
  let hint = 'Enter your custom domain'
  let ok = false
  let error = !!v.error
  if (v.error) hint = v.error
  else if (typed && !domain) {
    hint = 'Enter a domain name, like app.example.com'
    error = true
  } else if (c && c.owner) {
    hint = `Already used by ${c.owner}`
    error = true
  } else if (c && c.managed && !c.zone && c.saas) {
    hint = 'Available; its DNS stays where it is: PocketHarbor shows the two records to add there'
    ok = true
  } else if (c && c.managed && !c.zone) hint = 'Not in your Cloudflare zones: choose a zone for outside domains in Settings › Public access'
  else if (c && !c.certificate) {
    hint = `Available, but Cloudflare's free certificate stops one level below ${c.zone}`
    error = true
  } else if (c) {
    hint = c.managed ? `Available; PocketHarbor writes its record in ${c.zone}` : 'Available'
    ok = true
  }
  const port = portOf(v.port) || svc.port || 8080
  return (
    <form
      class="net-form"
      onSubmit={(e) => {
        e.preventDefault()
        if (domain && !(c && c.owner)) addDomain(svc, update, domain, port, info && info.managed)
      }}
    >
      <b>Add Custom Domain</b>
      {zones.length > 0 && (
        <div class="domain-input">
          {zone !== other && (
            <>
              <input
                class="input mono"
                placeholder="app"
                value={v.prefix}
                autofocus
                spellcheck={false}
                autocomplete="off"
                aria-label="Subdomain"
                onInput={(e) => {
                  const next = { ...draft.peek(), prefix: e.currentTarget.value, error: '' }
                  draft.value = next
                  const p = next.prefix.trim().toLowerCase()
                  checkName(svc, cleanDomain(p ? `${p}.${zone}` : zone))
                }}
                onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), (form.value = ''))}
              />
              <span class="domain-dot">.</span>
            </>
          )}
          <select
            class="select mono"
            value={zone}
            aria-label="Zone"
            onChange={(e) => {
              const z = e.currentTarget.value
              draft.value = { ...draft.peek(), zone: z, error: '' }
              if (z !== other) checkName(svc, cleanDomain(prefix ? `${prefix}.${z}` : z))
              else checkName(svc, cleanDomain(draft.peek().domain))
            }}
          >
            {zones.map((z) => (
              <option key={z} value={z}>
                {z}
              </option>
            ))}
            <option value={other}>Another domain…</option>
          </select>
        </div>
      )}
      {zone === other && (
        <input
          class="input"
          placeholder="example.com"
          value={v.domain}
          autofocus
          spellcheck={false}
          autocomplete="off"
          aria-label="Custom domain"
          onInput={(e) => {
            draft.value = { ...draft.peek(), domain: e.currentTarget.value, error: '' }
            checkName(svc, cleanDomain(e.currentTarget.value))
          }}
          onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), (form.value = ''))}
        />
      )}
      <label for="custom-port">Enter the port your app is listening on</label>
      <input
        class="input"
        id="custom-port"
        type="number"
        min="1"
        max="65535"
        placeholder={String(svc.port || 8080)}
        value={v.port}
        onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value })}
      />
      <Foot hint={hint} ok={ok} error={error}>
        <button type="button" class="btn sm" onClick={() => (form.value = '')}>
          Cancel
        </button>
        <button class="btn primary sm" disabled={!domain || (c && c.owner) || v.busy}>
          {v.busy && <Spinner />} Add Domain
        </button>
      </Foot>
    </form>
  )
}

async function generateRelayDomain(svc, update, port, info) {
  draft.value = { ...draft.peek(), busy: true, error: '' }
  form.value = ''
  setPending(svc.id, generating, info.generates_in ? `Writing its DNS record in ${info.generates_in}` : 'Deploying its Worker on workers.dev')
  try {
    await savePort(svc, update, port)
    const res = await post(`/services/${enc(svc.id)}/generate-domain`)
    draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
    await refresh()
    await loadDomains(svc.id)
    toast(`${res.domain} is ready`, 'success')
  } catch (err) {
    draft.value = { ...draft.peek(), busy: false, error: err.message }
    form.value = 'generate'
  } finally {
    setPending(svc.id, generating, '')
  }
}

/** Railway's Generate Service Domain: an address on workers.dev through the
 * relay, or a name in the zone chosen for generated names. */
function GenerateForm({ svc, update, info }) {
  const v = draft.value
  const zones = info.zones || []
  if (info.relay_ready || info.generates_in) {
    const where = info.generates_in ? `A name in ${info.generates_in}, through the tunnel: no request limit` : 'Choose your target port'
    return (
      <form
        class="net-form"
        onSubmit={(e) => {
          e.preventDefault()
          generateRelayDomain(svc, update, portOf(v.port), info)
        }}
      >
        <b>Generate Service Domain</b>
        <label for="gen-port">Enter the port your app is listening on</label>
        <input class="input" id="gen-port" type="number" min="1" max="65535" placeholder={String(svc.port || 8080)} value={v.port} autofocus onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value, error: '' })} />
        <Foot hint={v.error || where} error={!!v.error}>
          <button type="button" class="btn sm" onClick={() => (form.value = '')}>
            Cancel
          </button>
          <button class="btn primary sm" disabled={v.busy}>
            {v.busy && <Spinner />} Generate Domain
          </button>
        </Foot>
      </form>
    )
  }
  if (info.managed && zones.length === 0) {
    return (
      <div class="net-form">
        <b>Generate Service Domain</b>
        <Foot hint="Your Cloudflare account has no zone yet: add a domain to it, then press Sync now in Settings › Public access." error>
          <button type="button" class="btn sm" onClick={() => (form.value = '')}>
            Close
          </button>
        </Foot>
      </div>
    )
  }
  // Cloudflare is connected, but neither the relay nor a zone for generated
  // names is ready: say what is missing.
  return (
    <div class="net-form">
      <b>Generate Service Domain</b>
      <Foot
        hint={
          info.relay_error
            ? `The relay could not be deployed: ${info.relay_error}. Give the token Account › Workers Scripts › Edit and press Sync now, or choose a zone for generated domains in Settings › Public access.`
            : 'Choose where generated domains go in Settings › Public access: one of your zones, or workers.dev.'
        }
        error
      >
        <button type="button" class="btn sm" onClick={() => (form.value = '')}>
          Close
        </button>
      </Foot>
    </div>
  )
}

/** Railway's Public Networking: the list, the forms and the two buttons. */
export function PublicNetworking({ svc, update, quick }) {
  const state = domainInfo.value
  const info = state.id === svc.id ? state.data : null
  // The generated name first, as on Railway.
  const list = info ? [...info.domains.filter((d) => d.kind === 'generated'), ...info.domains.filter((d) => d.kind !== 'generated')] : null
  const hasGenerated = !!(list && list.some((d) => d.kind === 'generated'))
  const open = form.value
  // Names on their way in, that the list does not have yet.
  const prefix = `${svc.id} `
  const incoming = Object.entries(pending.value)
    .filter(([k]) => k.startsWith(prefix))
    .map(([k, text]) => ({ domain: k.slice(prefix.length), text }))
    .filter((p) => !(list && list.some((d) => d.domain === p.domain)))
  const any = (list && list.length > 0) || quick || svc.hostnames.includes('*') || incoming.length > 0
  return (
    <>
      <p class="net-hint">
        {any
          ? 'Access your application over HTTP with the following domains'
          : info && !info.managed
            ? 'Connect Cloudflare to reach this service from the internet, over HTTPS'
            : 'Access to this service publicly through HTTP'}
      </p>
      {list === null && svc.hostnames.some((h) => h !== '*') && (
        <div class="empty">
          <Spinner />
        </div>
      )}
      {any && (
        <div class="net-list">
          {quick && (
            <div class="net-row">
              <Globe class="net-icon" />
              <div class="net-what">
                <a href={quick} target="_blank" rel="noreferrer">
                  {quick.replace(/^https:\/\//, '')}
                </a>
                <span class="net-sub">
                  <ArrowRight width={11} height={11} /> Port {svc.port || 8080} · Preview URL
                </span>
              </div>
              <span class="net-actions">
                <button class="btn ghost icon sm" aria-label="Copy" title="Copy" onClick={() => copy(quick)}>
                  <Copy />
                </button>
              </span>
            </div>
          )}
          {incoming.map((p) => (
            <PendingRow key={p.domain} domain={p.domain === generating ? 'Generating a domain' : p.domain} text={p.text} port={svc.port || 8080} />
          ))}
          {list && list.map((d) => <Row key={d.domain} svc={svc} d={d} info={info} update={update} />)}
          {svc.hostnames.includes('*') && (
            <div class="net-row">
              <Globe class="net-icon" />
              <div class="net-what">
                <span>Any other hostname</span>
                <span class="net-sub">
                  <ArrowRight width={11} height={11} /> Port {svc.port || 8080} · the default service
                </span>
              </div>
            </div>
          )}
        </div>
      )}
      {open === 'custom' && info && info.managed && <CustomForm svc={svc} update={update} info={info} />}
      {open === 'generate' && info && info.managed && <GenerateForm svc={svc} update={update} info={info} />}
      {info && !info.managed && (
        <div class="net-buttons">
          <ConnectButton kind="cloudflare" small onClick={connectCloudflare} />
        </div>
      )}
      {info && info.managed && (
      <div class="net-buttons">
        <button
          class="btn sm"
          disabled={open === 'generate' || hasGenerated || !!pendingOf(svc.id, generating)}
          title={hasGenerated ? 'A service has one generated domain: remove it to make another' : undefined}
          onClick={() => {
            draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
            form.value = 'generate'
          }}
        >
          <Zap class="accent" /> Generate Domain
        </button>
        <button
          class="btn sm"
          disabled={open === 'custom'}
          onClick={() => {
            draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
            nameCheck.value = { name: '', result: null }
            form.value = 'custom'
          }}
        >
          <Plus class="accent" /> Custom Domain
        </button>
      </div>
      )}
    </>
  )
}

const editingPrivate = signal('')

/** Railway's private networking row; its pencil sets the port the app uses. */
export function PrivateNetworking({ svc, update }) {
  const name = privateName(svc)
  const port = svc.port || 8080
  const editing = editingPrivate.value === svc.id
  return (
    <div class="net-list">
      <div class={`net-row${editing ? ' open' : ''}`}>
        <CircleCheck class="net-icon ok" />
        <div class="net-what">
          <span class="net-name">
            {name}
            <span class="net-tag">port {port}</span>
          </span>
          <span class="net-sub">
            Ready to talk privately · other services reach it at <span class="mono">{name}:{port}</span>
          </span>
        </div>
        <span class="net-actions">
          <button class="btn ghost icon sm" aria-label="Copy the private address" title="Copy" onClick={() => copy(`${name}:${port}`)}>
            <Copy />
          </button>
          <button
            class="btn ghost icon sm"
            aria-label="Edit the port"
            title="Edit"
            onClick={() => {
              draft.value = { domain: '', prefix: '', zone: '', port: String(port), error: '', busy: false }
              editingPrivate.value = editing ? '' : svc.id
            }}
          >
            <Pencil />
          </button>
        </span>
      </div>
      {editing && (
        <form
          class="net-form inline"
          onSubmit={async (e) => {
            e.preventDefault()
            const n = portOf(draft.peek().port)
            if (!n) return
            try {
              await savePort(svc, update, n)
              editingPrivate.value = ''
            } catch (err) {
              draft.value = { ...draft.peek(), error: err.message }
            }
          }}
        >
          <label for="private-port">Enter the port your app is listening on</label>
          <input
            class="input"
            id="private-port"
            type="number"
            min="1"
            max="65535"
            value={draft.value.port}
            autofocus
            onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value, error: '' })}
            onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), (editingPrivate.value = ''))}
          />
          <Foot hint={draft.value.error || 'PORT is set to it, and its domains point at it'} error={!!draft.value.error}>
            <button type="button" class="btn sm" onClick={() => (editingPrivate.value = '')}>
              Cancel
            </button>
            <button class="btn primary sm" disabled={!portOf(draft.value.port) || portOf(draft.value.port) === port}>
              Update
            </button>
          </Foot>
        </form>
      )}
    </div>
  )
}
