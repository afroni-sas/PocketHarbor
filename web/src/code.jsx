// Syntax colours for variables: a field whose text is drawn again, coloured,
// on a layer behind it. The field itself stays a plain input or textarea,
// so typing, selection, undo and forms work as everywhere else.

const REF = /\$\{\{(\s*)([^}]*?)(\s*)\}\}/g

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
const tok = (cls, text) => `<span class="tk-${cls}">${esc(text)}</span>`

/** ${{ service.NAME }}: braces, service and name each in their colour,
 * every character kept so the layer lines up with the field. */
function refHtml(lead, inner, trail) {
  const dot = inner.indexOf('.')
  const body = dot > 0 ? tok('svc', inner.slice(0, dot)) + tok('dot', '.') + tok('var', inner.slice(dot + 1)) : tok('var', inner)
  return `<span class="tk-ref">${tok('brace', '${{')}${esc(lead)}${body}${esc(trail)}${tok('brace', '}}')}</span>`
}

/** A value: its references, and numbers or booleans when it is one. */
export function valueHtml(v, whole = false) {
  if (whole && /^\s*(-?\d+(\.\d+)?|true|false|yes|no|on|off)\s*$/i.test(v)) return tok('num', v)
  let out = ''
  let last = 0
  for (const m of v.matchAll(REF)) {
    out += esc(v.slice(last, m.index))
    out += refHtml(m[1], m[2], m[3])
    last = m.index + m[0].length
  }
  return out + esc(v.slice(last))
}

/** The value part of a .env line: quoted, or bare with a # comment after. */
function envValueHtml(rest) {
  const lead = rest.match(/^\s*/)[0]
  const v = rest.slice(lead.length)
  let out = esc(lead)
  const q = v[0]
  if (q === '"' || q === "'") {
    let i = 1
    while (i < v.length && v[i] !== q) i += q === '"' && v[i] === '\\' ? 2 : 1
    const str = v.slice(0, i + 1)
    const tail = v.slice(i + 1)
    out += `<span class="tk-str">${q === '"' ? valueHtml(str) : esc(str)}</span>`
    const c = tail.search(/#/)
    return out + (c >= 0 ? esc(tail.slice(0, c)) + tok('comment', tail.slice(c)) : esc(tail))
  }
  const c = v.search(/\s#/)
  const bare = c >= 0 ? v.slice(0, c) : v
  return out + valueHtml(bare, true) + (c >= 0 ? tok('comment', v.slice(c)) : '')
}

/** A .env text: comments, export, KEY, =, and the value. */
export function envHtml(text) {
  return text
    .split('\n')
    .map((line) => {
      if (/^\s*#/.test(line)) return tok('comment', line)
      const m = line.match(/^(\s*)(export\s+)?([A-Za-z_][\w.-]*)(\s*)=(.*)$/)
      if (!m) return line.trim() ? tok('bad', line) : esc(line)
      const [, ws, exp, key, sp, rest] = m
      return esc(ws) + (exp ? tok('kw', exp) : '') + tok('key', key) + esc(sp) + tok('op', '=') + envValueHtml(rest)
    })
    .join('\n')
}

function paint(field, mode) {
  const layer = field.previousElementSibling
  if (!layer) return
  // The trailing newline keeps the last empty line's height.
  layer.innerHTML = (mode === 'env' ? envHtml(field.value) : valueHtml(field.value, true)) + '\n'
  layer.scrollTop = field.scrollTop
  layer.scrollLeft = field.scrollLeft
}

/**
 * An input, or a textarea with `multiline`, coloured as a variable value or,
 * with mode="env", as a whole .env file. Other props go to the field.
 */
export function CodeField({ multiline, mode = 'value', class: cls = '', onInput, ...props }) {
  const Field = multiline ? 'textarea' : 'input'
  const sync = (e) => paint(e.currentTarget, mode)
  return (
    <div class={`code-field${multiline ? ' multi' : ''}`}>
      <pre class="code-layer" aria-hidden="true" />
      <Field
        {...props}
        class={`${multiline ? 'textarea' : 'input'} code-input ${cls}`}
        spellcheck={false}
        autocomplete="off"
        ref={(el) => el && paint(el, mode)}
        onInput={(e) => {
          paint(e.currentTarget, mode)
          if (onInput) onInput(e)
        }}
        onScroll={sync}
        onKeyUp={sync}
        onSelect={sync}
      />
    </div>
  )
}

/** A value shown, not edited: the same colours as in the fields. */
export function CodeText({ text }) {
  return <span class="code-text" dangerouslySetInnerHTML={{ __html: valueHtml(text, true) }} />
}
