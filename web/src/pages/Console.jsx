// A shell in the service's container, in the browser: xterm.js over a
// WebSocket to `pdock exec -it`. xterm.js loads only when the tab opens.

import { signal } from '@preact/signals'
import { RotateCcw, SquareTerminal } from 'lucide-preact'
import { enc } from '../api.js'

/** For the service whose console is open: connecting, open or closed. */
const state = signal({ id: '', status: 'idle', message: '' })

let term = null
let fitter = null
let sock = null
let observer = null
let element = null
let wanted = null

const theme = {
  background: '#191612',
  foreground: '#ece6dd',
  cursor: '#e0aa55',
  cursorAccent: '#191612',
  selectionBackground: 'rgba(196, 146, 60, 0.35)',
  black: '#24201b',
  brightBlack: '#6b6257',
}

function sendSize() {
  if (sock && sock.readyState === 1 && term) sock.send(`r${term.cols},${term.rows}`)
}

function connect(id) {
  if (sock) sock.close()
  state.value = { id, status: 'connecting', message: '' }
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
  const s = new WebSocket(`${scheme}://${location.host}/api/services/${enc(id)}/terminal`)
  s.binaryType = 'arraybuffer'
  sock = s
  s.onopen = () => {
    if (sock !== s) return
    state.value = { id, status: 'open', message: '' }
    fitter.fit()
    sendSize()
    term.focus()
  }
  s.onmessage = (e) => {
    if (sock === s) term.write(typeof e.data === 'string' ? e.data : new Uint8Array(e.data))
  }
  s.onclose = (e) => {
    if (sock !== s) return
    const message = e.reason || (state.peek().status === 'connecting' ? 'Could not connect. Is the service running?' : 'Disconnected')
    state.value = { id, status: 'closed', message }
    term.write(`\r\n\x1b[90m[${message}]\x1b[0m\r\n`)
  }
}

async function open(el, id) {
  const [{ Terminal }, { FitAddon }] = await Promise.all([import('@xterm/xterm'), import('@xterm/addon-fit'), import('@xterm/xterm/css/xterm.css')])
  if (element !== el) return
  term = new Terminal({
    theme,
    fontFamily: "ui-monospace, 'JetBrains Mono', SFMono-Regular, Menlo, Consolas, monospace",
    fontSize: 13,
    lineHeight: 1.2,
    cursorBlink: true,
    scrollback: 5000,
  })
  fitter = new FitAddon()
  term.loadAddon(fitter)
  term.open(el)
  fitter.fit()
  term.onData((d) => sock && sock.readyState === 1 && sock.send(`i${d}`))
  observer = new ResizeObserver(() => {
    fitter.fit()
    sendSize()
  })
  observer.observe(el)
  connect(id)
}

function close() {
  if (sock) sock.close()
  sock = null
  if (observer) observer.disconnect()
  observer = null
  if (term) term.dispose()
  term = null
  fitter = null
}

/** Mounts and unmounts the terminal with its element; keyed by service. */
function mount(el) {
  if (el === element) return
  close()
  element = el
  if (el && wanted) open(el, wanted)
}

export function ConsoleTab({ svc }) {
  if (svc.status !== 'running') {
    return (
      <div class="card empty">
        <SquareTerminal width={20} height={20} />
        <p style="margin:8px 0 0">The console opens a shell in the running container. This service is not running.</p>
      </div>
    )
  }
  wanted = svc.id
  const s = state.value
  const mine = s.id === svc.id
  return (
    <div class="console-wrap">
      <div class="row" style="margin-bottom:10px">
        <span class={`status ${mine && s.status === 'open' ? 'green' : mine && s.status === 'closed' ? 'red' : 'gray'}`}>
          <span class={`dot ${mine && s.status === 'open' ? 'green' : mine && s.status === 'closed' ? 'red' : ''}`} />
          {!mine || s.status === 'connecting' ? 'Connecting...' : s.status === 'open' ? `Connected to ${svc.name}` : s.message}
        </span>
        <span class="spacer" />
        {mine && s.status === 'closed' && (
          <button class="btn sm" onClick={() => connect(svc.id)}>
            <RotateCcw /> Reconnect
          </button>
        )}
      </div>
      <div class="console" key={svc.id} ref={mount} />
      <p class="muted small" style="margin:8px 0 0">
        A login shell inside the container. Changes to its files are lost on the next deploy, except in volumes.
      </p>
    </div>
  )
}
