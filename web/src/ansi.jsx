// Terminal colours in logs. Build tools and apps colour what they print with
// escape codes (ESC [ … m); a log shows them as colours, as a terminal would,
// instead of as "[0m[32m". Every other escape code is dropped.

// CSI (ESC [ params final), OSC (ESC ] … BEL or ESC \), or a two-byte escape.
const ESC = /\x1b(?:\[([0-?]*)[ -/]*([@-~])|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_])/g

// The console's palette, so that colours match the web terminal.
const PALETTE = [
  '#6f665a', '#e0705f', '#93c283', '#e0b255', '#7fa6cc', '#c995b3', '#83c2b7', '#d8d0c3',
  '#8a8073', '#f08a78', '#aad89a', '#f2c873', '#99bbde', '#dcaecb', '#9ad6cb', '#f6efe4',
]

/** A colour of the 256-colour table: the palette, a 6×6×6 cube, then greys. */
function color256(n) {
  if (n < 16) return PALETTE[n]
  if (n >= 232) {
    const v = 8 + (n - 232) * 10
    return `rgb(${v},${v},${v})`
  }
  const c = n - 16
  const level = (x) => (x === 0 ? 0 : 55 + x * 40)
  return `rgb(${level(Math.floor(c / 36))},${level(Math.floor(c / 6) % 6)},${level(c % 6)})`
}

/** The style after one SGR sequence's parameters, such as "1;38;5;245". */
function applySgr(style, params) {
  const codes = params === '' ? [0] : params.split(/[;:]/).map((p) => (p === '' ? 0 : Number(p)))
  let s = { ...style }
  for (let i = 0; i < codes.length; i++) {
    const c = codes[i]
    if (c === 0) s = {}
    else if (c === 1) s.bold = true
    else if (c === 2) s.dim = true
    else if (c === 3) s.italic = true
    else if (c === 4) s.underline = true
    else if (c === 22) s.bold = s.dim = false
    else if (c === 23) s.italic = false
    else if (c === 24) s.underline = false
    else if (c >= 30 && c <= 37) s.fg = PALETTE[c - 30]
    else if (c >= 90 && c <= 97) s.fg = PALETTE[c - 90 + 8]
    else if (c >= 40 && c <= 47) s.bg = PALETTE[c - 40]
    else if (c >= 100 && c <= 107) s.bg = PALETTE[c - 100 + 8]
    else if (c === 39) s.fg = undefined
    else if (c === 49) s.bg = undefined
    else if (c === 38 || c === 48) {
      let value
      if (codes[i + 1] === 5) {
        value = color256(codes[i + 2] || 0)
        i += 2
      } else if (codes[i + 1] === 2) {
        value = `rgb(${codes[i + 2] || 0},${codes[i + 3] || 0},${codes[i + 4] || 0})`
        i += 4
      }
      if (value) s[c === 38 ? 'fg' : 'bg'] = value
    }
  }
  return s
}

/**
 * The line as runs of text with their style, or null when it has no escape
 * code: [{ text, style: { fg, bg, bold, dim, italic, underline } }].
 */
export function parseAnsi(line) {
  if (!line.includes('\x1b')) return null
  const runs = []
  let style = {}
  let last = 0
  ESC.lastIndex = 0
  for (let m = ESC.exec(line); m; m = ESC.exec(line)) {
    if (m.index > last) runs.push({ text: line.slice(last, m.index), style })
    last = ESC.lastIndex
    if (m[2] === 'm') style = applySgr(style, m[1])
  }
  if (last < line.length) runs.push({ text: line.slice(last), style })
  return runs
}

/** The text a line shows, without its escape codes. */
export const plainOf = (line, runs = parseAnsi(line)) => (runs ? runs.map((r) => r.text).join('') : line)

function styleOf(s) {
  const css = []
  if (s.fg) css.push(`color:${s.fg}`)
  if (s.bg) css.push(`background:${s.bg}`)
  if (s.bold) css.push('font-weight:600')
  if (s.dim) css.push('opacity:.65')
  if (s.italic) css.push('font-style:italic')
  if (s.underline) css.push('text-decoration:underline')
  return css.join(';')
}

/** The runs, coloured; `mark` draws each run's text (search highlight). */
export function AnsiText({ runs, mark }) {
  const draw = mark || ((t) => t)
  return runs.map((r, i) => {
    const css = styleOf(r.style)
    return css ? (
      <span key={i} style={css}>
        {draw(r.text, i)}
      </span>
    ) : (
      draw(r.text, i)
    )
  })
}
