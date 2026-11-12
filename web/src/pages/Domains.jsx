// Public networking as Railway lays it out: one list of domains, each with
// its port and, until it works, "Waiting for DNS update · Show DNS records";
// the forms open in place. With Cloudflare connected, PocketHarbor writes the
// records itself; the state always comes from a real request through the name.

import { signal } from '@preact/signals'
import { ArrowRight, Check, CircleCheck, Copy, Globe, Info, Pencil, Plus, Trash, TriangleAlert, Zap } from 'lucide-preact'
import { enc, get, post } from '../api.js'
import { closeOverlay, overlay, toast } from '../state.js'
import { navigate } from '../router.js'
import { copy, Spinner } from '../ui.jsx'
import { privateName } from '../project.js'

/** The domains of the service on screen, with their records and states. */
export const domainInfo = signal({ id: '', data: null, checking: false, at: 0 })
/** Which form is open: '' | 'custom' | 'generate' | 'edit:DOMAIN'. */
const form = signal('')
const draft = signal({ domain: '', prefix: '', zone: '', port: '', error: '', busy: false })
const nameCheck = signal({ name: '', result: null })

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
                {ready || d.foreign_active
                  ? ', and Cloudflare serves the name through your tunnel.'
                  : ', wherever its DNS is managed: another Cloudflare account, a free subdomain service, any provider. Cloudflare then issues the certificate and sends the name through your tunnel, usually a few minutes after the records appear.'}
              </p>
            ) : info.managed && d.record === 'failed' && info.saas_zone ? (
              <p>{d.record_detail.charAt(0).toUpperCase() + d.record_detail.slice(1)}.</p>
            ) : info.managed && d.record === 'no_zone' ? (
              <>
                <p>
                  <span class="mono">{d.domain}</span> belongs to <span class="zone">{d.zone}</span>, which is not in your Cloudflare account
                  {info.zones.length > 0 ? ` (yours: ${info.zones.join(', ')})` : ''}. Cloudflare only sends a name through a tunnel when its zone is in the tunnel's own account, so no DNS record can bring this one to the phone.
                </p>
                <p class="muted small">
                  To use it anyway, with records added where its DNS is, choose a zone for such domains in{' '}
                  <button
                    class="linkish"
                    onClick={() => {
                      closeOverlay()
                      navigate('/settings?tab=networking')
                    }}
                  >
                    Settings › Public access
                  </button>
                  . Or use a name under one of your zones: Generate Domain proposes one.
                </p>
              </>
            ) : info.managed && d.record === 'conflict' ? (
              <p>
                {d.record_detail.charAt(0).toUpperCase() + d.record_detail.slice(1)}. PocketHarbor does not overwrite a record it did not write: delete it in Cloudflare, then press Check again.
              </p>
            ) : info.setup === 'tunnel' ? (
              <p>
                Add the following DNS record to <span class="zone">{d.zone}</span>, in the Cloudflare account of the tunnel, and add <span class="mono">{d.domain}</span> to the tunnel's public hostnames with the service <span class="mono">http://{origin}</span>. Or connect Cloudflare in Settings › Public access, and PocketHarbor does both.
              </p>
            ) : (
              <p>
                Add the following DNS record to <span class="zone">{d.zone}</span>. It reaches this phone on your network only, at{' '}
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

function removeDomain(svc, domain, update) {
  overlay.value = () => (
    <div class="backdrop" onMouseDown={(e) => e.target === e.currentTarget && closeOverlay()}>
      <div class="modal" role="dialog" aria-label="Remove Custom Domain">
        <header>
          <h3>Remove Custom Domain</h3>
        </header>
        <div class="body">
          <p style="margin:0">
            Are you sure you want to remove the custom domain <b>{domain}</b>?
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
              try {
                await update(svc, { domains: svc.domains.filter((x) => x !== domain) }, true)
                loadDomains(svc.id)
              } catch (err) {
                toast(err.message, 'error')
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

function Row({ svc, d, info, update }) {
  const state = stateOf(d, info)
  const custom = d.kind === 'custom'
  const editing = form.value === `edit:${d.domain}`
  const href = d.status === 'active' && d.via !== 'https' ? `http://${d.domain}${d.via.includes('port') ? `:${info.proxy_port}` : ''}` : `https://${d.domain}`
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
            <button class="btn ghost icon sm" aria-label={`Remove ${d.domain}`} title="Remove" onClick={() => removeDomain(svc, d.domain, update)}>
              <Trash />
            </button>
          )}
        </span>
      </div>
      {editing && <EditForm svc={svc} d={d} update={update} />}
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

function EditForm({ svc, d, update }) {
  const v = draft.value
  const port = portOf(v.port)
  const changed = port && port !== (svc.port || 8080)
  const submit = async (e) => {
    e.preventDefault()
    if (!changed) return
    try {
      await savePort(svc, update, port)
      form.value = ''
    } catch (err) {
      draft.value = { ...draft.peek(), error: err.message }
    }
  }
  return (
    <form class="net-form inline" onSubmit={submit}>
      <input class="input" value={d.domain} disabled aria-label="Domain" />
      <label for="edit-port">Enter the port your app is listening on</label>
      <input
        class="input"
        id="edit-port"
        type="number"
        min="1"
        max="65535"
        value={v.port}
        autofocus
        onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value, error: '' })}
        onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), (form.value = ''))}
      />
      <Foot hint={v.error || (d.kind === 'base' ? 'The name comes from the base domain; the port is the service’s' : 'Update your target port')} error={!!v.error}>
        <button type="button" class="btn sm" onClick={() => (form.value = '')}>
          Cancel
        </button>
        <button class="btn primary sm" disabled={!changed}>
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

async function addDomain(svc, update, domain, port) {
  draft.value = { ...draft.peek(), busy: true, error: '' }
  try {
    await update(svc, { domains: [...svc.domains, domain] }, true)
    await savePort(svc, update, port)
    form.value = ''
    draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
    // The dialog opens at once, as on Railway; the check fills it in.
    const data = await get(`/services/${enc(svc.id)}/domains`)
    if (domainInfo.peek().id === svc.id) domainInfo.value = { ...domainInfo.peek(), data }
    showDnsRecords(svc.id, domain)
    loadDomains(svc.id)
  } catch (err) {
    draft.value = { ...draft.peek(), busy: false, error: err.message }
  }
}

function CustomForm({ svc, update }) {
  const v = draft.value
  const domain = cleanDomain(v.domain)
  const c = nameCheck.value.name === domain ? nameCheck.value.result : null
  let hint = 'Enter your custom domain'
  let ok = false
  let error = !!v.error
  if (v.error) hint = v.error
  else if (v.domain.trim() && !domain) {
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
        if (domain && !(c && c.owner)) addDomain(svc, update, domain, port)
      }}
    >
      <b>Add Custom Domain</b>
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

async function generateRelayDomain(svc, update, port) {
  draft.value = { ...draft.peek(), busy: true, error: '' }
  try {
    await savePort(svc, update, port)
    const res = await post(`/services/${enc(svc.id)}/generate-domain`)
    form.value = ''
    draft.value = { domain: '', prefix: '', zone: '', port: '', error: '', busy: false }
    toast(`${res.domain} is ready`, 'success')
    await loadDomains(svc.id)
  } catch (err) {
    draft.value = { ...draft.peek(), busy: false, error: err.message }
  }
}

/** Railway's Generate Service Domain: an address on workers.dev through the
 * relay; without it, a name in one of the Cloudflare zones, or a temporary
 * address. */
function GenerateForm({ svc, update, info, quickTunnel }) {
  const v = draft.value
  const zones = info.zones || []
  if (info.relay_ready) {
    return (
      <form
        class="net-form"
        onSubmit={(e) => {
          e.preventDefault()
          generateRelayDomain(svc, update, portOf(v.port))
        }}
      >
        <b>Generate Service Domain</b>
        <label for="gen-port">Enter the port your app is listening on</label>
        <input class="input" id="gen-port" type="number" min="1" max="65535" placeholder={String(svc.port || 8080)} value={v.port} autofocus onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value, error: '' })} />
        <Foot hint={v.error || 'Choose your target port'} error={!!v.error}>
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
  if (!info.managed) {
    return (
      <form
        class="net-form"
        onSubmit={async (e) => {
          e.preventDefault()
          draft.value = { ...draft.peek(), busy: true }
          try {
            await savePort(svc, update, portOf(v.port))
            await quickTunnel(svc)
            form.value = ''
          } finally {
            draft.value = { ...draft.peek(), busy: false }
          }
        }}
      >
        <b>Generate Service Domain</b>
        <label for="gen-port">Enter the port your app is listening on</label>
        <input class="input" id="gen-port" type="number" min="1" max="65535" placeholder={String(svc.port || 8080)} value={v.port} autofocus onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value })} />
        <Foot hint={info.managed ? 'Your Cloudflare account has no zone yet: this gives a temporary trycloudflare.com address' : 'A temporary trycloudflare.com address; connect Cloudflare in Settings for lasting ones'}>
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
  const prefix = v.prefix.trim().toLowerCase()
  const zone = v.zone || zones[0]
  const domain = prefix ? cleanDomain(`${prefix}.${zone}`) : ''
  const valid = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(prefix) && domain
  return (
    <form
      class="net-form"
      onSubmit={(e) => {
        e.preventDefault()
        if (valid) addDomain(svc, update, domain, portOf(v.port) || svc.port || 8080)
      }}
    >
      <b>Generate Service Domain</b>
      <div class="gen-name">
        <input class="input" aria-label="Name" value={v.prefix} autofocus spellcheck={false} onInput={(e) => (draft.value = { ...draft.peek(), prefix: e.currentTarget.value, error: '' })} />
        {zones.length > 1 ? (
          <select class="select" aria-label="Zone" value={zone} onChange={(e) => (draft.value = { ...draft.peek(), zone: e.currentTarget.value })}>
            {zones.map((z) => (
              <option key={z} value={z}>
                .{z}
              </option>
            ))}
          </select>
        ) : (
          <span class="gen-zone">.{zone}</span>
        )}
      </div>
      <label for="gen-port">Enter the port your app is listening on</label>
      <input class="input" id="gen-port" type="number" min="1" max="65535" placeholder={String(svc.port || 8080)} value={v.port} onInput={(e) => (draft.value = { ...draft.peek(), port: e.currentTarget.value })} />
      <Foot hint={v.error || (valid ? `PocketHarbor writes ${domain} in your Cloudflare account` : 'Choose your target port')} error={!!v.error}>
        <button type="button" class="btn sm" onClick={() => (form.value = '')}>
          Cancel
        </button>
        <button class="btn primary sm" disabled={!valid || v.busy}>
          {v.busy && <Spinner />} Generate Domain
        </button>
      </Foot>
    </form>
  )
}

/** Railway's Public Networking: the list, the forms and the two buttons. */
export function PublicNetworking({ svc, update, quickTunnel, label, quick }) {
  const state = domainInfo.value
  const info = state.id === svc.id ? state.data : null
  const list = info ? info.domains : null
  const open = form.value
  const any = (list && list.length > 0) || quick || svc.hostnames.includes('*')
  return (
    <>
      <p class="net-hint">{any ? 'Access your application over HTTP with the following domains' : 'Access to this service publicly through HTTP'}</p>
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
                  <ArrowRight width={11} height={11} /> Port {svc.port || 8080} · temporary address
                </span>
              </div>
              <span class="net-actions">
                <button class="btn ghost icon sm" aria-label="Copy" title="Copy" onClick={() => copy(quick)}>
                  <Copy />
                </button>
              </span>
            </div>
          )}
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
      {open === 'custom' && <CustomForm svc={svc} update={update} />}
      {open === 'generate' && info && <GenerateForm svc={svc} update={update} info={info} quickTunnel={quickTunnel} />}
      <div class="net-buttons">
        <button
          class="btn sm"
          disabled={open === 'generate'}
          onClick={() => {
            draft.value = { domain: '', prefix: label, zone: '', port: '', error: '', busy: false }
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
