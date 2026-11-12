// The level of a log line, read from what the app wrote: a JSON field
// ("level":"INFO"), logfmt (level=info), a bracketed or capitalised word near
// the start ([ERROR], WARN), or the first word of a crash (panic:, Traceback).
// The level word is coloured by its level; only errors band the whole row.

const NAMES = {
  trace: 'debug',
  debug: 'debug',
  dbug: 'debug',
  info: 'info',
  inf: 'info',
  notice: 'info',
  warn: 'warn',
  warning: 'warn',
  wrn: 'warn',
  error: 'error',
  err: 'error',
  eror: 'error',
  fatal: 'error',
  panic: 'error',
  critical: 'error',
  crit: 'error',
  alert: 'error',
  emerg: 'error',
}

const FIELD = /"(?:level|lvl|severity|levelname)"\s*:\s*"([A-Za-z]+)"/i
const LOGFMT = /(?:^|\s)(?:level|lvl)=("?)([A-Za-z]+)\1(?=\s|$)/i
const WORD = /(?:^|[\s[(|:])(TRACE|DEBUG|DBUG|INFO|INF|NOTICE|WARN(?:ING)?|WRN|ERROR|ERR|EROR|FATAL|PANIC|CRITICAL|CRIT)(?=[\s\]):|,-]|$)/
const PREFIX = /^(\s*)(error|fatal|panic|warning|warn)(?=(\[[^\]]*\])?:)/i
const CRASH = /^\s*(Deployment failed:|fatal error:|Traceback \(most recent call last\)|Exception in thread|Uncaught |Unhandled |thread '.*' panicked)/

/** { level: 'debug'|'info'|'warn'|'error'|'', at, len }: where the level word is. */
export function levelOf(text) {
  let m = FIELD.exec(text)
  if (m && NAMES[m[1].toLowerCase()]) {
    const at = m.index + m[0].length - m[1].length - 1
    return { level: NAMES[m[1].toLowerCase()], at, len: m[1].length }
  }
  m = LOGFMT.exec(text)
  if (m && NAMES[m[2].toLowerCase()]) {
    const at = m.index + m[0].length - m[2].length - m[1].length
    return { level: NAMES[m[2].toLowerCase()], at, len: m[2].length }
  }
  // A capitalised level word in the first columns, after a date if any.
  m = WORD.exec(text.slice(0, 48))
  if (m) {
    const at = m.index + m[0].length - m[1].length
    return { level: NAMES[m[1].toLowerCase()], at, len: m[1].length }
  }
  // "Error: ...", "warning: ...", "panic: ...": the word that opens the line.
  m = PREFIX.exec(text)
  if (m) return { level: NAMES[m[2].toLowerCase()], at: m[1].length, len: m[2].length }
  if (CRASH.test(text)) return { level: 'error', at: -1, len: 0 }
  return { level: '', at: -1, len: 0 }
}

/** The line, its level word coloured; `mark` draws the other parts (search). */
export function LevelText({ text, info, mark }) {
  const draw = mark || ((t) => t)
  if (info.at < 0) return draw(text, 0)
  return (
    <>
      {draw(text.slice(0, info.at), 0)}
      <span class={`lv lv-${info.level}`}>{text.slice(info.at, info.at + info.len)}</span>
      {draw(text.slice(info.at + info.len), 1)}
    </>
  )
}
