import { me } from './state.js'

export class ApiError extends Error {
  constructor(message, status, data) {
    super(message)
    this.status = status
    this.data = data
  }
}

export async function api(method, path, body) {
  const init = { method, credentials: 'same-origin', headers: {} }
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(body)
  }
  const res = await fetch('/api' + path, init)
  const type = res.headers.get('content-type') || ''
  const data = type.startsWith('application/json') ? await res.json() : await res.text()
  if (!res.ok) {
    if (res.status === 401 && !path.startsWith('/login') && !path.startsWith('/setup')) me.value = null
    throw new ApiError((data && data.error) || res.statusText, res.status, data)
  }
  return data
}

export const get = (path) => api('GET', path)
export const post = (path, body = {}) => api('POST', path, body)
export const patch = (path, body) => api('PATCH', path, body)
export const put = (path, body) => api('PUT', path, body)
export const del = (path) => api('DELETE', path)

export const enc = encodeURIComponent
