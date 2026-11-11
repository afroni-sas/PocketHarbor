// The layout of Railway's settings pages: a title, a menu of sections on the
// left, and the open section on the right. The section is in ?tab= so that
// it survives a reload and can be linked to.

export function SettingsLayout({ title, items, current, onSelect, children }) {
  return (
    <div class="settings-page">
      <header class="settings-title">
        <h1>{title}</h1>
      </header>
      <div class="settings-body">
        <nav class="settings-nav" aria-label={`${title} sections`}>
          {items.map(([id, label, Icon]) => (
            <button key={id} class={current === id ? 'on' : ''} aria-current={current === id ? 'page' : undefined} onClick={() => onSelect(id)}>
              <Icon />
              {label}
            </button>
          ))}
        </nav>
        <div class="settings-content">{children}</div>
      </div>
    </div>
  )
}
