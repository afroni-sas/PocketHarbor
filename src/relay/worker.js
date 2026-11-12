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

/** The relay's state for one phone: its socket and the requests in flight. */
export class RelayCore {
  constructor(socket) {
    this.socket = socket
    this.next = 1
    this.pending = new Map()
  }

  /** Sends a visitor's request to the phone, as `host`, and returns its response. */
  async handle(request, host) {
    const ws = this.socket()
    if (!ws) return new Response('This service is offline: the phone it runs on is not connected.', { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } })
    if ((request.headers.get('upgrade') || '').toLowerCase() === 'websocket') {
      return new Response('WebSockets do not go through the relay yet.', { status: 501 })
    }
    const id = this.next
    this.next = this.next >= 0xffffffff ? 1 : this.next + 1
    const url = new URL(request.url)
    const body = request.body ? new Uint8Array(await request.arrayBuffer()) : null
    const headers = []
    for (const [name, value] of request.headers) headers.push([name, value])
    const head = {
      method: request.method,
      path: url.pathname + url.search,
      host,
      headers,
      length: body ? body.length : 0,
      ip: request.headers.get('cf-connecting-ip') || '',
    }
    const response = new Promise((resolve) => {
      const timer = setTimeout(() => this.finish(id, new Response('The phone did not answer in time.', { status: 504 })), TIMEOUT_MS)
      this.pending.set(id, { resolve, writer: null, timer, head: request.method === 'HEAD' })
    })
    try {
      ws.send(frame(HEAD, id, JSON.stringify(head)))
      for (let at = 0; body && at < body.length; at += CHUNK) ws.send(frame(BODY, id, body.subarray(at, at + CHUNK)))
      ws.send(frame(END, id))
    } catch {
      this.finish(id, new Response('The connection to the phone broke.', { status: 502 }))
    }
    return response
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
    const p = this.pending.get(f.id)
    if (!p) return
    if (f.type === RES_HEAD) {
      const head = JSON.parse(decoder.decode(f.data))
      if (noBody.has(head.status) || p.head) {
        clearTimeout(p.timer)
        p.resolve(new Response(null, { status: head.status, headers: head.headers }))
        p.writer = { write: () => Promise.resolve(), close: () => Promise.resolve(), abort: () => Promise.resolve() }
        return
      }
      const stream = new TransformStream()
      p.writer = stream.writable.getWriter()
      clearTimeout(p.timer)
      p.resolve(new Response(stream.readable, { status: head.status, headers: head.headers }))
    } else if (f.type === RES_BODY && p.writer) {
      p.writer.write(f.data.slice()).catch(() => {})
    } else if (f.type === RES_END) {
      if (p.writer) p.writer.close().catch(() => {})
      this.pending.delete(f.id)
    } else if (f.type === ABORT) {
      const why = decoder.decode(f.data) || 'The phone could not reach the service.'
      this.finish(f.id, new Response(why, { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } }))
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
    this.core = new RelayCore(() => this.state.getWebSockets('phone')[0])
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

  webSocketMessage(ws, data) {
    this.core.message(data)
  }

  webSocketClose() {
    this.core.closed()
  }

  webSocketError() {
    this.core.closed()
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
