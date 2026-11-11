// Application state, as signals. Components read `.value` while rendering and
// re-render when it changes; there are no hooks.

import { signal } from '@preact/signals'

/** The signed-in user: undefined while loading, null when signed out. */
export const me = signal(undefined)
/** From /api/status: whether the first account still has to be created. */
export const status = signal(null)

export const projects = signal(null)
/** The services and arrows of the project page's canvas. */
export const services = signal(null)
export const edges = signal([])

export const toasts = signal([])
let toastId = 0

export function toast(message, kind = 'info') {
  const id = ++toastId
  toasts.value = [...toasts.value, { id, message, kind }]
  setTimeout(() => {
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }, kind === 'error' ? 6000 : 3500)
}

/** One dialog or menu at a time, described by a render function. */
export const overlay = signal(null)
export const closeOverlay = () => (overlay.value = null)

/** Chrome's install prompt, kept until the user asks for it. */
export const installPrompt = signal(null)
