// What the data view asks each database, and how it reads the answer. Every
// request goes through POST /services/:id/data/query, which runs the
// database's own client inside its container; the queries below make the
// database itself answer in JSON, so the browser gets typed values.

import { enc, post } from '../api.js'

export class QueryError extends Error {}

/** Runs `text` with the database's client: { code, output, truncated }. */
export async function rawQuery(id, text) {
  return post(`/services/${enc(id)}/data/query`, { query: text })
}

// Output formats ---------------------------------------------------------

/** RFC 4180, as psql --csv writes it. A field left bare and empty is NULL. */
export function parseCsv(text) {
  const rows = []
  let row = []
  let field = ''
  let quoted = false
  let wasQuoted = false
  const push = () => {
    row.push(field === '' && !wasQuoted ? null : field)
    field = ''
    wasQuoted = false
  }
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"'
        i++
      } else if (ch === '"') quoted = false
      else field += ch
    } else if (ch === '"') {
      quoted = true
      wasQuoted = true
    } else if (ch === ',') push()
    else if (ch === '\n') {
      push()
      rows.push(row)
      row = []
    } else if (ch !== '\r') field += ch
  }
  if (field || wasQuoted || row.length) {
    push()
    rows.push(row)
  }
  return rows
}

/** MySQL's --batch: tabs between fields, \t \n \\ \0 escaped, NULL bare. */
export function parseTsv(text) {
  const unescape = (f) => (f === 'NULL' ? null : f.replace(/\\([tn0\\])/g, (_, c) => ({ t: '\t', n: '\n', 0: '\0', '\\': '\\' })[c]))
  return text
    .split('\n')
    .filter((line) => line.length)
    .map((line) => line.split('\t').map(unescape))
}

/** One line of redis-cli --no-raw: "quoted" with \" \\ \n \xHH escapes. */
export function redisUnquote(line) {
  const s = line.trim()
  if (!(s.startsWith('"') && s.endsWith('"'))) return s
  const bytes = []
  const enc8 = new TextEncoder()
  for (let i = 1; i < s.length - 1; i++) {
    const ch = s[i]
    if (ch !== '\\') {
      bytes.push(...enc8.encode(ch))
      continue
    }
    const next = s[++i]
    if (next === 'x') {
      bytes.push(parseInt(s.slice(i + 1, i + 3), 16))
      i += 2
    } else bytes.push(({ n: 10, r: 13, t: 9, a: 7, b: 8 })[next] ?? next.charCodeAt(0))
  }
  return new TextDecoder().decode(new Uint8Array(bytes))
}

/** An argument for redis-cli: quoted, with what its parser unescapes. */
export function redisArg(s) {
  return `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t')}"`
}

async function single(id, kind, text) {
  const r = await rawQuery(id, text)
  const out = r.output || ''
  if (r.code !== 0 || (kind === 'redis' && /^\(error\)/m.test(out))) throw new QueryError(out.trim() || 'the query failed')
  if (kind === 'postgres') {
    const rows = parseCsv(out)
    return rows.length > 1 ? rows[1][0] : null
  }
  if (kind === 'mysql') {
    const rows = parseTsv(out)
    return rows.length > 1 ? rows[1][0] : null
  }
  if (kind === 'redis') return redisUnquote(out.split('\n')[0] || '')
  // Mongo: the last line the script printed.
  const lines = out.trim().split('\n')
  return lines[lines.length - 1]
}

/** Runs a query that answers one JSON value, and parses it. */
export async function jsonQuery(id, kind, text) {
  const v = await single(id, kind, text)
  if (v === null || v === '') return null
  try {
    return JSON.parse(v)
  } catch {
    throw new QueryError(v)
  }
}

/** A query's output as a table when it is one: { head, rows } or null. */
export function tableOf(kind, output) {
  if (kind !== 'postgres' && kind !== 'mysql') return null
  const rows = kind === 'postgres' ? parseCsv(output) : parseTsv(output)
  if (rows.length === 0) return null
  const width = rows[0].length
  if (rows.some((r) => r.length !== width)) return null
  return { head: rows[0], rows: rows.slice(1) }
}

// SQL --------------------------------------------------------------------

const pg = {
  ident: (s) => `"${String(s).replace(/"/g, '""')}"`,
  lit: (v) => (v === null || v === undefined ? 'null' : `'${String(v).replace(/'/g, "''")}'`),
}
const my = {
  ident: (s) => `\`${String(s).replace(/`/g, '``')}\``,
  lit: (v) => (v === null || v === undefined ? 'null' : `'${String(v).replace(/\\/g, '\\\\').replace(/'/g, "''")}'`),
}

/** "schema.table" → ["schema", "table"]; MySQL names have no schema. */
export function splitName(kind, name) {
  if (kind !== 'postgres') return ['', name]
  const dot = name.indexOf('.')
  return dot < 0 ? ['public', name] : [name.slice(0, dot), name.slice(dot + 1)]
}

function target(kind, name) {
  const [schema, table] = splitName(kind, name)
  return kind === 'postgres' ? `${pg.ident(schema)}.${pg.ident(table)}` : my.ident(table)
}

/** A value as it goes into SQL from the grid: JSON values as text. */
export function cellText(v) {
  if (v === null || v === undefined) return null
  return typeof v === 'object' ? JSON.stringify(v) : String(v)
}

/** The columns of a table: [{name, type, nullable, default, pk}], and its kind. */
export async function tableMeta(id, kind, name) {
  if (kind === 'postgres') {
    const reg = pg.lit(target(kind, name))
    return jsonQuery(
      id,
      kind,
      `select json_build_object('kind', (select relkind from pg_class where oid = ${reg}::regclass), 'columns', (select json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'nullable', not a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid), 'pk', coalesce(a.attnum = any(i.indkey), false)) order by a.attnum) from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum left join pg_index i on i.indrelid = a.attrelid and i.indisprimary where a.attrelid = ${reg}::regclass and a.attnum > 0 and not a.attisdropped)) as meta;`,
    )
  }
  return jsonQuery(
    id,
    kind,
    `select json_object('kind', (select lower(table_type) from information_schema.tables where table_schema = database() and table_name = ${my.lit(name)}), 'columns', (select json_arrayagg(json_object('pos', ordinal_position, 'name', column_name, 'type', column_type, 'nullable', is_nullable = 'YES', 'default', column_default, 'pk', column_key = 'PRI')) from information_schema.columns where table_schema = database() and table_name = ${my.lit(name)})) as meta;`,
  ).then((meta) => {
    // JSON_ARRAYAGG keeps no order: the columns' positions put it back.
    if (meta && Array.isArray(meta.columns)) meta.columns.sort((a, b) => a.pos - b.pos)
    return meta
  })
}

/** Whether rows can be told apart: by primary key, or by ctid on PostgreSQL tables. */
export function identity(kind, meta) {
  const pk = (meta.columns || []).filter((c) => c.pk).map((c) => c.name)
  if (pk.length) return { cols: pk }
  if (kind === 'postgres' && (meta.kind === 'r' || meta.kind === 'p')) return { ctid: true }
  return null
}

/** Integers past 2^53 and exact decimals lose digits as JSON numbers in
 * JavaScript: they travel as text, so that a row is found again exactly. */
const WIDE = /^(bigint|int8|numeric|decimal|money|bigint unsigned|bigint\(\d+\)( unsigned)?|decimal\(.*\)( unsigned)?|numeric\(.*\))$/i

function selectList(kind, meta) {
  const q = kind === 'postgres' ? pg : my
  return (meta.columns || [])
    .map((c) => (WIDE.test(c.type || '') ? (kind === 'postgres' ? `r.${pg.ident(c.name)}::text as ${pg.ident(c.name)}` : `cast(r.${my.ident(c.name)} as char) as ${my.ident(c.name)}`) : `r.${q.ident(c.name)}`))
    .join(', ')
}

/** One page of rows: { total, rows: [{col: value}] }. */
export async function tablePage(id, kind, name, meta, { page = 1, size = 50, sort = '', dir = 'asc', filter = '' }) {
  const t = target(kind, name)
  const key = identity(kind, meta)
  const offset = (page - 1) * size
  if (kind === 'postgres') {
    const where = filter ? ` where r::text ilike ${pg.lit(`%${filter}%`)}` : ''
    // Ordered by the stored values, not by the text some travel as.
    const by = sort ? `r.${pg.ident(sort)} ${dir === 'desc' ? 'desc' : 'asc'}` : key && key.cols ? key.cols.map((c) => `r.${pg.ident(c)}`).join(', ') : key && key.ctid ? 'r.ctid' : ''
    const ctid = key && key.ctid ? 'r.ctid::text as "__ctid", ' : ''
    return jsonQuery(
      id,
      kind,
      `select json_build_object('total', (select count(*) from ${t} r${where}), 'rows', (select coalesce(json_agg(x), '[]') from (select ${ctid}${selectList(kind, meta) || 'r.*'} from ${t} r${where}${by ? ` order by ${by}` : ''} limit ${size} offset ${offset}) x)) as page;`,
    )
  }
  const cols = (meta.columns || []).map((c) => c.name)
  const where = filter && cols.length ? ` where concat_ws(' ', ${cols.map(my.ident).join(', ')}) like ${my.lit(`%${filter}%`)}` : ''
  const by = sort ? `r.${my.ident(sort)} ${dir === 'desc' ? 'desc' : 'asc'}` : key && key.cols ? key.cols.map((c) => `r.${my.ident(c)}`).join(', ') : ''
  const obj = cols.map((c) => `${my.lit(c)}, ${my.ident(c)}`).join(', ')
  // Each row carries its rank, which puts the page back in order.
  const result = await jsonQuery(
    id,
    kind,
    `select json_object('total', (select count(*) from ${t}${where}), 'rows', coalesce((select json_arrayagg(json_object('__n', __n, ${obj})) from (select row_number() over (${by ? `order by ${by}` : ''}) as __n, ${selectList(kind, meta) || 'r.*'} from ${t} r${where}${by ? ` order by ${by}` : ''} limit ${size} offset ${offset}) x), json_array())) as page;`,
  )
  if (result && Array.isArray(result.rows)) {
    result.rows.sort((a, b) => a.__n - b.__n)
    for (const row of result.rows) delete row.__n
  }
  return result
}

function rowMatch(kind, meta, row) {
  const q = kind === 'postgres' ? pg : my
  const key = identity(kind, meta)
  if (!key) throw new QueryError('this table has no primary key, so its rows cannot be told apart')
  if (key.ctid) return `ctid = ${pg.lit(row.__ctid)}::tid`
  return key.cols.map((c) => (row[c] === null ? `${q.ident(c)} is null` : `${q.ident(c)} = ${q.lit(cellText(row[c]))}`)).join(' and ')
}

/** Changes some cells of a row: `values` maps columns to text, or null. */
export async function updateRow(id, kind, name, meta, row, values) {
  const q = kind === 'postgres' ? pg : my
  const set = Object.entries(values)
    .map(([c, v]) => `${q.ident(c)} = ${q.lit(v)}`)
    .join(', ')
  return execOk(id, kind, `update ${target(kind, name)} set ${set} where ${rowMatch(kind, meta, row)};`)
}

export async function deleteRow(id, kind, name, meta, row) {
  return execOk(id, kind, `delete from ${target(kind, name)} where ${rowMatch(kind, meta, row)};`)
}

/** Adds a row: `values` maps the columns given to text or null; the others take their default. */
export async function insertRow(id, kind, name, values) {
  const q = kind === 'postgres' ? pg : my
  const cols = Object.keys(values)
  const text = cols.length
    ? `insert into ${target(kind, name)} (${cols.map(q.ident).join(', ')}) values (${cols.map((c) => q.lit(values[c])).join(', ')});`
    : kind === 'postgres'
      ? `insert into ${target(kind, name)} default values;`
      : `insert into ${target(kind, name)} () values ();`
  return execOk(id, kind, text)
}

const TYPE = /^[A-Za-z][A-Za-z0-9 _]*(\([0-9, ]+\))?(\[\])?$/

/** A default typed in a form: a function call, number or keyword as SQL, anything else as a string. */
function defaultSql(kind, v) {
  if (/^(-?\d+(\.\d+)?|true|false|null|current_timestamp|current_date)$/i.test(v) || /^[a-z_][a-z0-9_]*\(\)$/i.test(v)) return v
  return (kind === 'postgres' ? pg : my).lit(v)
}

function columnSql(kind, c, inline) {
  const q = kind === 'postgres' ? pg : my
  if (!c.name.trim()) throw new QueryError('every column needs a name')
  if (!TYPE.test(c.type.trim())) throw new QueryError(`"${c.type}" is not a column type`)
  let s = `${q.ident(c.name.trim())} ${c.type.trim()}`
  if (inline && c.pk) s += ' primary key'
  if (!c.nullable && !c.pk) s += ' not null'
  if (c.default && c.default.trim()) s += ` default ${defaultSql(kind, c.default.trim())}`
  return s
}

export async function addColumn(id, kind, name, column) {
  return execOk(id, kind, `alter table ${target(kind, name)} add column ${columnSql(kind, column, false)};`)
}

export async function createTable(id, kind, schema, table, columns) {
  if (!table.trim()) throw new QueryError('the table needs a name')
  if (columns.length === 0) throw new QueryError('add at least one column')
  const t = kind === 'postgres' ? `${pg.ident(schema || 'public')}.${pg.ident(table.trim())}` : my.ident(table.trim())
  const pk = columns.filter((c) => c.pk)
  const cols = columns.map((c) => columnSql(kind, c, pk.length === 1))
  if (pk.length > 1) cols.push(`primary key (${pk.map((c) => (kind === 'postgres' ? pg : my).ident(c.name.trim())).join(', ')})`)
  return execOk(id, kind, `create table ${t} (${cols.join(', ')});`)
}

export async function dropTable(id, kind, name) {
  return execOk(id, kind, `drop table ${target(kind, name)};`)
}

async function execOk(id, kind, text) {
  const r = await rawQuery(id, text)
  if (r.code !== 0) throw new QueryError((r.output || '').trim() || 'the query failed')
  return r
}

/** The SQL that shows a table, for the raw query bar. */
export function selectAll(kind, name) {
  return `SELECT * FROM ${kind === 'postgres' ? (name.startsWith('public.') ? name.slice(7) : name) : name}`
}

export const sqlTypes = {
  postgres: ['text', 'varchar(255)', 'integer', 'bigint', 'serial', 'bigserial', 'boolean', 'numeric', 'real', 'double precision', 'date', 'timestamp', 'timestamptz', 'uuid', 'json', 'jsonb', 'bytea'],
  mysql: ['varchar(255)', 'text', 'int', 'bigint', 'tinyint(1)', 'decimal(10,2)', 'double', 'date', 'datetime', 'timestamp', 'json', 'blob'],
}

// Statistics -------------------------------------------------------------

export async function stats(id, kind) {
  if (kind === 'postgres') {
    return jsonQuery(
      id,
      kind,
      `select json_build_object('version', current_setting('server_version'), 'connections', (select count(*) from pg_stat_activity where datname is not null), 'max', current_setting('max_connections')::int, 'active', (select count(*) from pg_stat_activity where state = 'active'), 'idle', (select count(*) from pg_stat_activity where state = 'idle'), 'idle_tx', (select count(*) from pg_stat_activity where state like 'idle in transaction%'), 'cache_hit', (select case when sum(blks_hit) + sum(blks_read) = 0 then null else round(100.0 * sum(blks_hit) / (sum(blks_hit) + sum(blks_read)), 2) end from pg_stat_database), 'database', pg_database_size(current_database()), 'wal', (select coalesce(sum(size), 0) from pg_ls_waldir()), 'tables', (select coalesce(json_agg(t order by t.data desc), '[]') from (select schemaname || '.' || relname as name, n_live_tup as rows, pg_relation_size(relid) as data, pg_indexes_size(relid) as indexes, seq_scan as seq, coalesce(idx_scan, 0) as idx from pg_stat_user_tables) t)) as stats;`,
    ).catch(() =>
      // pg_ls_waldir needs a superuser or pg_monitor; the rest does not.
      jsonQuery(
        id,
        kind,
        `select json_build_object('version', current_setting('server_version'), 'connections', (select count(*) from pg_stat_activity where datname is not null), 'max', current_setting('max_connections')::int, 'active', (select count(*) from pg_stat_activity where state = 'active'), 'idle', (select count(*) from pg_stat_activity where state = 'idle'), 'idle_tx', (select count(*) from pg_stat_activity where state like 'idle in transaction%'), 'database', pg_database_size(current_database()), 'tables', (select coalesce(json_agg(t order by t.data desc), '[]') from (select schemaname || '.' || relname as name, n_live_tup as rows, pg_relation_size(relid) as data, pg_indexes_size(relid) as indexes, seq_scan as seq, coalesce(idx_scan, 0) as idx from pg_stat_user_tables) t)) as stats;`,
      ),
    )
  }
  if (kind === 'mysql') {
    return jsonQuery(
      id,
      kind,
      `select json_object('version', version(), 'connections', (select count(*) from information_schema.processlist), 'max', @@max_connections, 'tables', coalesce((select json_arrayagg(json_object('name', table_name, 'rows', table_rows, 'data', data_length, 'indexes', index_length)) from information_schema.tables where table_schema = database()), json_array())) as stats;`,
    )
  }
  if (kind === 'redis') {
    const r = await rawQuery(id, 'INFO')
    if (r.code !== 0) throw new QueryError(r.output)
    const info = {}
    const out = r.output || ''
    const text = out.trimStart().startsWith('"') ? redisUnquote(out.split('\n')[0]) : out
    for (const line of text.split(/\r?\n/)) {
      const at = line.indexOf(':')
      if (at > 0 && !line.startsWith('#')) info[line.slice(0, at)] = line.slice(at + 1)
    }
    return info
  }
  return jsonQuery(
    id,
    kind,
    `print(JSON.stringify(db.adminCommand({listDatabases: 1}).databases.filter(function (d) { return ["admin", "config", "local"].indexOf(d.name) < 0 }).map(function (d) { var s = db.getSiblingDB(d.name).stats(); return {name: d.name, collections: s.collections, objects: s.objects, data: s.dataSize, storage: s.storageSize, indexes: s.indexSize} })))`,
  )
}

// Redis ------------------------------------------------------------------

const lua = (script) => `EVAL ${redisArg(script)}`

/** Keys matching `pattern`, at most `limit`: { keys: [[name, type, ttl]], more, total }. */
export async function redisKeys(id, pattern, limit = 500) {
  const r = await jsonQuery(
    id,
    'redis',
    `${lua("local out = {} local cursor = '0' local n = 0 local limit = tonumber(ARGV[2]) repeat local r = redis.call('SCAN', cursor, 'MATCH', ARGV[1], 'COUNT', 200) cursor = r[1] for _, k in ipairs(r[2]) do if n < limit then out[#out + 1] = {k, redis.call('TYPE', k).ok, redis.call('TTL', k)} n = n + 1 end end until cursor == '0' or n >= limit return cjson.encode({keys = out, more = cursor ~= '0', total = redis.call('DBSIZE')})")} 0 ${redisArg(pattern || '*')} ${limit}`,
  )
  return { keys: Array.isArray(r.keys) ? r.keys : [], more: r.more, total: r.total }
}

/** A key's type, TTL, size and value (the first 500 items of a collection). */
export async function redisKey(id, name) {
  const r = await jsonQuery(
    id,
    'redis',
    `${lua("local k = KEYS[1] local t = redis.call('TYPE', k).ok local v local len = 0 if t == 'string' then v = redis.call('GET', k) len = redis.call('STRLEN', k) elseif t == 'hash' then v = redis.call('HGETALL', k) len = redis.call('HLEN', k) elseif t == 'list' then v = redis.call('LRANGE', k, 0, 499) len = redis.call('LLEN', k) elseif t == 'set' then v = redis.call('SRANDMEMBER', k, 500) len = redis.call('SCARD', k) elseif t == 'zset' then v = redis.call('ZRANGE', k, 0, 499, 'WITHSCORES') len = redis.call('ZCARD', k) elseif t == 'stream' then v = redis.call('XRANGE', k, '-', '+', 'COUNT', 100) len = redis.call('XLEN', k) end return cjson.encode({type = t, ttl = redis.call('TTL', k), len = len, value = v})")} 1 ${redisArg(name)}`,
  )
  const v = r.value
  const list = Array.isArray(v) ? v : v && typeof v === 'object' ? [] : v
  return { ...r, value: list }
}

/** Runs Redis commands, each an array of arguments; fails on the first error. */
export async function redisRun(id, commands) {
  const r = await rawQuery(id, commands.map((c) => c.map(redisArg).join(' ')).join('\n'))
  if (r.code !== 0 || /^\(error\)/m.test(r.output || '')) throw new QueryError((r.output || '').trim())
  return r
}

// MongoDB ----------------------------------------------------------------

/** Turns shell values into JSON, keeping ids and dates recognisable. */
const NORM = `function __n(v) { if (v === null || v === undefined) return null; if (v instanceof Date) return {$date: v.toISOString()}; if (v._bsontype === "ObjectID" || v._bsontype === "ObjectId" || (typeof ObjectId !== "undefined" && v instanceof ObjectId)) return {$oid: v.str || v.toHexString()}; if (typeof NumberLong !== "undefined" && v instanceof NumberLong) return {$numberLong: String(v).replace(/^NumberLong\\(|"|\\)$/g, "")}; if (Array.isArray(v)) return v.map(__n); if (typeof v === "object") { var o = {}; for (var k in v) if (Object.prototype.hasOwnProperty.call(v, k)) o[k] = __n(v[k]); return o } return v }`
/** The other way: {$oid}, {$date}, {$numberLong} back to shell values. */
const HYDRATE = `function __h(v) { if (v === null || typeof v !== "object") return v; if (Array.isArray(v)) return v.map(__h); var ks = Object.keys(v); if (ks.length === 1 && ks[0] === "$oid") return ObjectId(v.$oid); if (ks.length === 1 && ks[0] === "$date") return new Date(v.$date); if (ks.length === 1 && ks[0] === "$numberLong") return NumberLong(v.$numberLong); var o = {}; ks.forEach(function (k) { o[k] = __h(v[k]) }); return o }`

function mongoColl(name) {
  const dot = name.indexOf('.')
  return `db.getSiblingDB(${JSON.stringify(name.slice(0, dot))}).getCollection(${JSON.stringify(name.slice(dot + 1))})`
}

/** One page of documents, with a filter as JSON: { total, docs }. */
export async function mongoPage(id, name, { page = 1, size = 50, filter = '{}' }) {
  const f = JSON.stringify(JSON.parse(filter || '{}'))
  return jsonQuery(
    id,
    'mongo',
    `${NORM}; ${HYDRATE}; var __c = ${mongoColl(name)}; var __f = __h(${f}); print(JSON.stringify({total: __c.countDocuments(__f), docs: __c.find(__f).skip(${(page - 1) * size}).limit(${size}).toArray().map(__n)}))`,
  )
}

async function mongoDo(id, script) {
  const r = await jsonQuery(id, 'mongo', `${NORM}; ${HYDRATE}; ${script}`)
  return r
}

export const mongoInsert = (id, name, doc) => mongoDo(id, `var __r = ${mongoColl(name)}.insertOne(__h(${JSON.stringify(doc)})); print(JSON.stringify({ok: true}))`)
export const mongoReplace = (id, name, docId, doc) =>
  mongoDo(id, `var __r = ${mongoColl(name)}.replaceOne({_id: __h(${JSON.stringify(docId)})}, __h(${JSON.stringify(doc)})); print(JSON.stringify({ok: __r.matchedCount === 1}))`)
export const mongoDelete = (id, name, docId) => mongoDo(id, `var __r = ${mongoColl(name)}.deleteOne({_id: __h(${JSON.stringify(docId)})}); print(JSON.stringify({ok: __r.deletedCount === 1}))`)
export const mongoFind = (name) => `${mongoColl(name)}.find().limit(20)`
