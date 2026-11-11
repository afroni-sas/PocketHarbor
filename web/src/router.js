import { signal } from '@preact/signals'

function parse() {
  const url = new URL(location.href)
  return { path: url.pathname, query: Object.fromEntries(url.searchParams) }
}

export const route = signal(parse())

export function navigate(to, replace = false) {
  history[replace ? 'replaceState' : 'pushState'](null, '', to)
  route.value = parse()
}

addEventListener('popstate', () => (route.value = parse()))

/** onClick for in-app links: keeps new tabs and modified clicks working. */
export function follow(e) {
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  const a = e.currentTarget
  if (a.origin !== location.origin || a.target) return
  e.preventDefault()
  navigate(a.pathname + a.search)
}

/** "/project/:name/service/:svc" against a path: the parameters, or null. */
export function match(pattern, path) {
  const p = pattern.split('/')
  const s = path.split('/')
  if (p.length !== s.length) return null
  const params = {}
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) params[p[i].slice(1)] = decodeURIComponent(s[i])
    else if (p[i] !== s[i]) return null
  }
  return params
}

export function withQuery(path, query) {
  const q = new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined && v !== null && v !== ''))
  const text = q.toString()
  return text ? `${path}?${text}` : path
}
