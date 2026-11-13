// PocketHarbor's relay, which PocketHarbor deploys to the user's Cloudflare
// account. The phone keeps one WebSocket open to a Durable Object; each
// visitor's request goes down that WebSocket in binary frames, and the
// response comes back the same way, streamed. Nothing on the phone listens
// on the internet, and no port is opened anywhere.
//
// A frame is one byte of type, four of request id (big-endian), then data.

export const HEAD = 1 // relay to phone: JSON {method, path, host, headers, length, ip}
export const BODY = 2 // relay to phone: a piece of the request body
export const END = 3 // relay to phone: the request is complete
export const RES_HEAD = 4 // phone to relay: JSON {status, headers}
export const RES_BODY = 5 // phone to relay: a piece of the response body
export const RES_END = 6 // phone to relay: the response is complete
export const ABORT = 7 // phone to relay: the request failed; data is the reason
export const WS_OPEN = 8 // relay to phone: a visitor asks for a WebSocket; JSON like HEAD
export const WS_TEXT = 9 // both ways: a text message of an open WebSocket
export const WS_BINARY = 10 // both ways: a binary message
export const WS_CLOSE = 11 // both ways: two bytes of code, then the reason
export const CANCEL = 12 // relay to phone: the visitor went away; the response stops

const CHUNK = 256 * 1024
const TIMEOUT_MS = 100_000
const encoder = new TextEncoder()
const decoder = new TextDecoder()

export function frame(type, id, data) {
  const bytes = data == null ? new Uint8Array(0) : typeof data === 'string' ? encoder.encode(data) : new Uint8Array(data)
  const out = new Uint8Array(5 + bytes.length)
  out[0] = type
  new DataView(out.buffer).setUint32(1, id)
  out.set(bytes, 5)
  return out
}

export function parse(data) {
  const bytes = new Uint8Array(data)
  return { type: bytes[0], id: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(1), data: bytes.subarray(5) }
}

const noBody = new Set([101, 204, 205, 304])

// Compression. The service may compress what it sends, which keeps the
// phone's uplink light. But a compressed body that crosses from the Durable
// Object to the Worker the visitor reached loses what says it is
// compressed, and Cloudflare compresses it a second time. So the relay
// asks the service only for what it can undo (gzip, deflate), undoes it,
// and lets Cloudflare compress for the visitor as it does for any Worker.
const UNDOABLE = new Set(['gzip', 'x-gzip', 'deflate'])

/** The visitor's Accept-Encoding, kept to what the relay can undo; "" if none. */
export function decodable(value) {
  return value
    .split(',')
    .map((part) => part.trim())
    .filter((part) => UNDOABLE.has(part.split(';')[0].trim().toLowerCase()))
    .join(', ')
}

const encodingOf = (head) => ((head.headers.find(([name]) => name.toLowerCase() === 'content-encoding') || [])[1] || '').trim().toLowerCase()

/** The service's headers, without the encoding the relay undoes. */
function plainHeaders(head) {
  if (!UNDOABLE.has(encodingOf(head))) return head.headers
  return head.headers.filter(([name]) => !['content-encoding', 'content-length'].includes(name.toLowerCase()))
}

/** The service's response, its body uncompressed when it was gzip or deflate. */
export function plainResponse(body, head) {
  const encoding = encodingOf(head)
  if (!UNDOABLE.has(encoding)) {
    // Something the relay did not ask for: passed on as it is.
    const manual = encoding !== '' && encoding !== 'identity'
    return new Response(body, { status: head.status, headers: head.headers, ...(manual ? { encodeBody: 'manual' } : {}) })
  }
  return new Response(body.pipeThrough(new DecompressionStream(encoding === 'x-gzip' ? 'gzip' : encoding)), { status: head.status, headers: plainHeaders(head) })
}

/** The relay's state for one phone: its socket and the requests in flight.
 * `accept(id, protocol, request)` answers a visitor's upgrade that the phone
 * agreed to, keeping the visitor's socket, and `visitor(id)` finds it
 * again; the Durable Object keeps those sockets across its hibernation. */
export class RelayCore {
  constructor(socket, accept, visitor) {
    this.socket = socket
    this.accept = accept
    this.visitor = visitor
    this.pending = new Map()
  }

  /** Sends a visitor's request to the phone, as `host`, and returns its response. */
  async handle(request, host) {
    const ws = this.socket()
    if (!ws) return new Response('This service is offline: the phone it runs on is not connected.', { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } })
    const upgrade = (request.headers.get('upgrade') || '').toLowerCase() === 'websocket'
    if (upgrade && !this.accept) return new Response('WebSockets need the Durable Object.', { status: 501 })
    const id = this.newId()
    const url = new URL(request.url)
    const body = request.body ? new Uint8Array(await request.arrayBuffer()) : null
    const headers = []
    for (const [name, value] of request.headers) {
      if (name.toLowerCase() !== 'accept-encoding') headers.push([name, value])
      else if (decodable(value)) headers.push([name, decodable(value)])
    }
    const head = {
      method: request.method,
      path: url.pathname + url.search,
      host,
      headers,
      length: body ? body.length : 0,
      ip: request.headers.get('cf-connecting-ip') || '',
    }
    // The visitor went away (the request's signal, with the
    // enable_request_signal flag): the phone stops the response instead of
    // streaming on for no one, as an SSE stream or a long download would.
    if (request.signal) request.signal.addEventListener('abort', () => this.cancel(id))
    const response = new Promise((resolve) => {
      const timer = setTimeout(() => this.finish(id, new Response('The phone did not answer in time.', { status: 504 })), TIMEOUT_MS)
      this.pending.set(id, { resolve, writer: null, timer, head: request.method === 'HEAD', upgrade, request })
    })
    try {
      if (upgrade) {
        ws.send(frame(WS_OPEN, id, JSON.stringify(head)))
        return response
      }
      ws.send(frame(HEAD, id, JSON.stringify(head)))
      for (let at = 0; body && at < body.length; at += CHUNK) ws.send(frame(BODY, id, body.subarray(at, at + CHUNK)))
      ws.send(frame(END, id))
    } catch {
      this.finish(id, new Response('The connection to the phone broke.', { status: 502 }))
    }
    return response
  }

  /** A request id that nothing uses: counting would start again at 1 after
   * the Durable Object hibernates, while visitors' WebSockets stay open. */
  newId() {
    const one = new Uint32Array(1)
    for (;;) {
      crypto.getRandomValues(one)
      const id = one[0]
      if (id !== 0 && !this.pending.has(id) && !(this.visitor && this.visitor(id))) return id
    }
  }

  /** Tells the phone that nobody reads a response any more, and forgets it. */
  cancel(id) {
    const p = this.pending.get(id)
    if (!p) return
    clearTimeout(p.timer)
    this.pending.delete(id)
    try {
      const ws = this.socket()
      if (ws) ws.send(frame(CANCEL, id))
    } catch {}
  }

  /** Resolves a request that has no response yet, and forgets it. */
  finish(id, response) {
    const p = this.pending.get(id)
    if (!p) return
    clearTimeout(p.timer)
    this.pending.delete(id)
    if (p.writer) p.writer.abort(new Error('relay closed')).catch(() => {})
    else p.resolve(response)
  }

  /** A frame from the phone. */
  message(data) {
    if (typeof data === 'string') return
    const f = parse(data)
    if (f.type === WS_TEXT || f.type === WS_BINARY || f.type === WS_CLOSE) return this.fromService(f)
    const p = this.pending.get(f.id)
    if (!p) return
    if (f.type === RES_HEAD) {
      const head = JSON.parse(decoder.decode(f.data))
      if (p.upgrade && head.status === 101) {
        // The service took the WebSocket: the visitor gets the other end.
        clearTimeout(p.timer)
        this.pending.delete(f.id)
        const protocol = (head.headers.find(([name]) => name.toLowerCase() === 'sec-websocket-protocol') || [])[1]
        p.resolve(this.accept(f.id, protocol, p.request))
        return
      }
      if (noBody.has(head.status) || p.head) {
        clearTimeout(p.timer)
        p.resolve(new Response(null, { status: head.status, headers: plainHeaders(head) }))
        p.writer = { write: () => Promise.resolve(), close: () => Promise.resolve(), abort: () => Promise.resolve() }
        return
      }
      const stream = new TransformStream()
      p.writer = stream.writable.getWriter()
      clearTimeout(p.timer)
      p.resolve(plainResponse(stream.readable, head))
    } else if (f.type === RES_BODY && p.writer) {
      p.writer.write(f.data.slice()).catch(() => this.cancel(f.id))
    } else if (f.type === RES_END) {
      if (p.writer) p.writer.close().catch(() => {})
      this.pending.delete(f.id)
    } else if (f.type === ABORT) {
      const why = decoder.decode(f.data) || 'The phone could not reach the service.'
      this.finish(f.id, new Response(why, { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } }))
    }
  }

  /** A message or a close from the service, for its visitor. */
  fromService(f) {
    const ws = this.visitor(f.id)
    if (!ws) return
    try {
      if (f.type === WS_TEXT) ws.send(decoder.decode(f.data))
      else if (f.type === WS_BINARY) ws.send(f.data.slice())
      else {
        const code = f.data.length >= 2 ? (f.data[0] << 8) | f.data[1] : 1000
        ws.close(code === 1005 || code === 1006 ? 1000 : code, decoder.decode(f.data.subarray(2)))
      }
    } catch {
      // The visitor is already gone.
    }
  }

  /** A message from a visitor's WebSocket, for the service on the phone. */
  fromVisitor(id, data) {
    const ws = this.socket()
    if (!ws) return false
    ws.send(typeof data === 'string' ? frame(WS_TEXT, id, data) : frame(WS_BINARY, id, data))
    return true
  }

  /** A visitor closed its WebSocket. */
  visitorClosed(id, code, reason) {
    const ws = this.socket()
    if (!ws) return
    const why = encoder.encode(reason || '')
    const data = new Uint8Array(2 + why.length)
    data[0] = (code >> 8) & 0xff
    data[1] = code & 0xff
    data.set(why, 2)
    try {
      ws.send(frame(WS_CLOSE, id, data))
    } catch {
      // The phone is gone too.
    }
  }

  /** The phone went away: everything in flight fails. */
  closed() {
    for (const id of [...this.pending.keys()]) this.finish(id, new Response('The connection to the phone broke.', { status: 502 }))
  }
}

/** The Durable Object that holds the phone's WebSocket, hibernating between requests. */
export class Relay {
  constructor(state) {
    this.state = state
    this.core = new RelayCore(
      () => this.state.getWebSockets('phone')[0],
      (id, protocol) => {
        const pair = new WebSocketPair()
        this.state.acceptWebSocket(pair[1], [`v:${id}`])
        return new Response(null, { status: 101, webSocket: pair[0], headers: protocol ? { 'sec-websocket-protocol': protocol } : {} })
      },
      (id) => this.state.getWebSockets(`v:${id}`)[0],
    )
    // Keepalives are answered without waking the object.
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'))
  }

  async fetch(request) {
    if (new URL(request.url).pathname === '/__harbor/connect') {
      for (const old of this.state.getWebSockets('phone')) old.close(1012, 'replaced by a new connection')
      const pair = new WebSocketPair()
      this.state.acceptWebSocket(pair[1], ['phone'])
      return new Response(null, { status: 101, webSocket: pair[0] })
    }
    return this.core.handle(request, request.headers.get('x-harbor-host'))
  }

  /** The visitor's id, for a visitor's socket; null for the phone's. */
  visitorId(ws) {
    const tag = this.state.getTags(ws).find((t) => t.startsWith('v:'))
    return tag ? Number(tag.slice(2)) : null
  }

  webSocketMessage(ws, data) {
    const id = this.visitorId(ws)
    if (id === null) return this.core.message(data)
    if (!this.core.fromVisitor(id, data)) ws.close(1012, 'The phone is not connected.')
  }

  webSocketClose(ws, code, reason) {
    const id = this.visitorId(ws)
    if (id !== null) return this.core.visitorClosed(id, code, reason)
    this.core.closed()
    // Without the phone, its visitors' WebSockets lead nowhere.
    for (const v of this.state.getWebSockets()) if (this.visitorId(v) !== null) v.close(1012, 'The phone went away.')
  }

  webSocketError(ws) {
    this.webSocketClose(ws, 1011, 'error')
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    const relay = env.RELAY.get(env.RELAY.idFromName('phone'))
    if (url.pathname === '/__harbor/connect') {
      if (env.ROLE !== 'hub' || request.headers.get('authorization') !== `Bearer ${env.SECRET}`) return new Response('Forbidden', { status: 403 })
      return relay.fetch(request)
    }
    // The phone routes by this name; a visitor cannot choose it.
    const forwarded = new Request(request)
    forwarded.headers.set('x-harbor-host', url.hostname)
    return relay.fetch(forwarded)
  },
}
