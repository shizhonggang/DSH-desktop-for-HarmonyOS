#!/usr/bin/env node
/**
 * DSH ↔ ArkTS bridge server (node side).
 *
 * The ArkTS half lives in `entry/src/main/ets/bridge/BridgeAgent.ets` inside the
 * DshDesktop HAP. It long-polls this server, executes ArkTS-only ability APIs
 * (startAbilityByType / startAbility with flags / openLink) and posts results
 * back. Everything on this side is plain node, so `dsh` and shell tools can talk
 * to it with nothing more than an HTTP POST.
 *
 * Protocol
 *   GET  /poll?wait=<ms>   agent side long-poll: 200 {id,action,args} | 204
 *   POST /result           agent side reports {id,ok,data,error}
 *   POST /command          caller side submits {action,args} -> {ok,data|error}
 *   GET  /healthz          liveness + agent connection state
 *
 * Usage
 *   node bridge-server.mjs                 # run the server (foreground)
 *   node bridge-server.mjs status          # is the agent connected?
 *   node bridge-server.mjs call '<json>'   # one command, prints the result
 *   node bridge-server.mjs call -          # same, JSON read from stdin
 *
 * Examples
 *   # 导航：南京 -> 上海（sceneType 1 = 路线规划, 2 = 直接导航）
 *   node bridge-server.mjs call '{"action":"startAbilityByType","args":{"type":"navigation",
 *     "wantParam":{"sceneType":1,"destinationName":"上海","destinationLatitude":31.2304,
 *     "destinationLongitude":121.4737,"vehicleType":0}}}'
 *
 *   # 写邮件（桥自己会做 encodeURI，传明文即可）
 *   node bridge-server.mjs call '{"action":"startAbilityByType","args":{"type":"mail",
 *     "wantParam":{"email":["a@b.com"],"subject":"周报","body":"正文"}}}'
 *
 *   # 打开文件并授予读权限（flags:1 = FLAG_AUTH_READ_URI_PERMISSION）
 *   node bridge-server.mjs call '{"action":"startAbility","args":{"action":"ohos.want.action.viewData",
 *     "uri":"file://com.example.dshdesktop/data/storage/el2/base/files/report.pdf",
 *     "type":"general.pdf","flags":1}}'
 */

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
/** Optional type -> explicit target override map (see targets.json). */
const TARGETS_FILE = process.env.DSH_BRIDGE_TARGETS ?? path.join(HERE, 'targets.json')
/** Alias -> {bundleName, abilityName} table for the launchApp action. */
const APPS_FILE = process.env.DSH_BRIDGE_APPS ?? path.join(HERE, 'apps.json')

const PORT = Number(process.env.DSH_BRIDGE_PORT ?? 3131)
const HOST = process.env.DSH_BRIDGE_HOST ?? '127.0.0.1'
/** How long a /poll request is held open waiting for work. Must stay below the
 *  agent's read timeout (POLL_READ_TIMEOUT_MS = 30000 in BridgeAgent.ets). */
const POLL_HOLD_MS = Number(process.env.DSH_BRIDGE_POLL_HOLD ?? 25000)
/** How long a caller waits for the agent to finish a command. */
const COMMAND_TIMEOUT_MS = Number(process.env.DSH_BRIDGE_TIMEOUT ?? 30000)
const AGENT_STALE_MS = 20000
const VERSION = '1.0.0'

let seq = 0
/** Commands waiting to be picked up by the agent. */
const queue = []
/** Commands already picked up; id -> {resolve, timer}. */
const pending = new Map()
/** Outstanding long-poll responses. */
const waiters = []
let agent = { lastSeen: 0, polls: 0 }

const agentConnected = () => Date.now() - agent.lastSeen < AGENT_STALE_MS

function log (...parts) {
  process.stdout.write(`[${new Date().toISOString()}] ${parts.join(' ')}\n`)
}

function json (res, status, body) {
  const text = JSON.stringify(body ?? null)
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) })
  res.end(text)
}

function readBody (req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('payload too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

/** Hands queued work to whichever long-poll is waiting. */
function flushWaiters () {
  while (waiters.length > 0 && queue.length > 0) {
    const waiter = waiters.shift()
    clearTimeout(waiter.timer)
    waiter.respond(queue.shift())
  }
}

/** Submits a command and resolves with the agent's result. */
function enqueue (action, args) {
  const id = `c${++seq}-${Date.now().toString(36)}`
  const command = { id, action, args: args ?? {} }
  queue.push(command)
  log(`enqueue ${action} id=${id} queued=${queue.length} agent=${agentConnected() ? 'up' : 'down'}`)
  flushWaiters()
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(id)
      const i = queue.findIndex((c) => c.id === id)
      if (i >= 0) {
        queue.splice(i, 1)
      }
      resolve({
        ok: false,
        error: {
          code: 'timeout',
          message: `ArkTS agent did not answer within ${COMMAND_TIMEOUT_MS}ms. ` +
            'Is the DshDesktop window open (startAbilityByType needs the app in the foreground)?'
        }
      })
    }, COMMAND_TIMEOUT_MS)
    pending.set(id, { resolve, timer })
  })
}

/**
 * Explicit-target overrides.
 *
 * `startAbilityByType` always pops the system chooser (Intent Panel). When
 * targets.json maps a business type to a concrete app, we rewrite the call into
 * an explicit Want (bundleName + abilityName) instead: explicit wants never show
 * a panel. Tradeoff: chooser-style params (destination, ...) are merely forwarded
 * in `parameters`, not interpreted by the system's panel pipeline.
 */
function loadTargets () {
  try {
    return JSON.parse(fs.readFileSync(TARGETS_FILE, 'utf8'))
  } catch {
    return {}
  }
}

function loadApps () {
  try {
    return JSON.parse(fs.readFileSync(APPS_FILE, 'utf8')).apps ?? {}
  } catch {
    return {}
  }
}

/** Resolves an app alias or its human label (e.g. "calendar" / "日历"). */
function resolveApp (name) {
  const apps = loadApps()
  if (Object.prototype.hasOwnProperty.call(apps, name)) return { alias: name, entry: apps[name] }
  for (const [alias, entry] of Object.entries(apps)) {
    if (entry?.label === name) return { alias, entry }
  }
  return null
}

function resolveTarget (targets, args) {
  const type = typeof args?.type === 'string' ? args.type : ''
  if (type === '') return null
  const scene = args?.wantParam?.sceneType
  const keys = []
  if (typeof scene === 'number') keys.push(`${type}:${scene}`)
  keys.push(type)
  for (const key of keys) {
    const entry = targets[key]
    if (entry && typeof entry.bundleName === 'string' && entry.bundleName.length > 0) {
      return { key, entry }
    }
  }
  return null
}

function applyTargetOverride (action, args) {
  if (action !== 'startAbilityByType') return { action, args, via: 'direct' }
  const hit = resolveTarget(loadTargets(), args)
  if (hit === null) return { action, args, via: 'panel' }
  const { entry } = hit
  const explicit = { bundleName: entry.bundleName }
  if (typeof entry.abilityName === 'string') explicit.abilityName = entry.abilityName
  if (typeof entry.moduleName === 'string') explicit.moduleName = entry.moduleName
  if (typeof entry.action === 'string') explicit.action = entry.action
  if (typeof entry.uri === 'string') explicit.uri = entry.uri
  if (typeof entry.type === 'string') explicit.type = entry.type
  if (typeof entry.flags === 'number') explicit.flags = entry.flags
  if (entry.passParams !== false && args?.wantParam !== undefined) {
    explicit.parameters = args.wantParam
  }
  log(`target override: ${hit.key} -> explicit ${entry.bundleName}`)
  return { action: 'startAbility', args: explicit, via: 'explicit', target: hit.key }
}

/** Normalises the agent's reply, decoding the nested JSON `data` string. */
function normaliseResult (body) {
  if (!body || body.ok !== true) {
    return { ok: false, error: { code: 'agent_error', message: body?.error || 'agent reported failure' } }
  }
  let data = body.data
  if (typeof data === 'string' && data.length > 0) {
    try {
      data = JSON.parse(data)
    } catch {
      // keep the raw string
    }
  }
  return { ok: true, data }
}

function startServer () {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? HOST}`)

    if (req.method === 'GET' && (url.pathname === '/healthz' || url.pathname === '/health')) {
      json(res, 200, {
        ok: true,
        version: VERSION,
        port: PORT,
        agent: {
          connected: agentConnected(),
          lastSeenMsAgo: agent.lastSeen === 0 ? null : Date.now() - agent.lastSeen,
          polls: agent.polls
        },
        queueDepth: queue.length,
        pendingCommands: pending.size
      })
      return
    }

    if (req.method === 'GET' && url.pathname === '/poll') {
      agent.lastSeen = Date.now()
      agent.polls += 1
      if (queue.length > 0) {
        json(res, 200, queue.shift())
        return
      }
      const waitMs = Math.min(Math.max(Number(url.searchParams.get('wait') ?? POLL_HOLD_MS) || POLL_HOLD_MS, 1000), 60000)
      const waiter = {
        respond: (command) => json(res, 200, command),
        timer: -1
      }
      waiters.push(waiter)
      waiter.timer = setTimeout(() => {
        const i = waiters.indexOf(waiter)
        if (i >= 0) {
          waiters.splice(i, 1)
        }
        res.writeHead(204)
        res.end()
      }, waitMs)
      req.on('close', () => {
        const i = waiters.indexOf(waiter)
        if (i >= 0) {
          waiters.splice(i, 1)
        }
        clearTimeout(waiter.timer)
      })
      return
    }

    if (req.method === 'POST' && url.pathname === '/result') {
      let body
      try {
        body = JSON.parse(await readBody(req) || '{}')
      } catch (error) {
        json(res, 400, { ok: false, error: { code: 'bad_request', message: String(error?.message ?? error) } })
        return
      }
      agent.lastSeen = Date.now()
      const entry = pending.get(body.id)
      if (entry !== undefined) {
        clearTimeout(entry.timer)
        pending.delete(body.id)
        entry.resolve(normaliseResult(body))
      }
      json(res, 200, { ok: true })
      return
    }

    if (req.method === 'POST' && url.pathname === '/command') {
      let body
      try {
        body = JSON.parse(await readBody(req) || '{}')
      } catch (error) {
        json(res, 400, { ok: false, error: { code: 'bad_request', message: String(error?.message ?? error) } })
        return
      }
      if (typeof body.action !== 'string' || body.action.length === 0) {
        json(res, 400, { ok: false, error: { code: 'bad_request', message: 'action is required' } })
        return
      }
      // launchApp: alias -> explicit startAbility (no panel, no bundle name needed
      // on the caller side; the alias table lives in apps.json).
      if (body.action === 'launchApp') {
        const name = typeof body.args?.app === 'string' ? body.args.app : ''
        const hit = resolveApp(name)
        if (hit === null) {
          const known = Object.keys(loadApps())
          json(res, 200, {
            ok: false,
            error: { code: 'unknown_app', message: `apps.json 未收录 "${name}"；可用别名：${known.join(', ')}` }
          })
          return
        }
        log(`launchApp ${name} -> ${hit.entry.bundleName}/${hit.entry.abilityName}`)
        const launched = await enqueue('startAbility', {
          bundleName: hit.entry.bundleName,
          abilityName: hit.entry.abilityName
        })
        json(res, 200, { ...launched, via: 'explicit', target: hit.alias, label: hit.entry.label })
        return
      }

      const overridden = applyTargetOverride(body.action, body.args)
      const result = await enqueue(overridden.action, overridden.args)
      json(res, 200, {
        ...result,
        via: overridden.via,
        ...(overridden.target === undefined ? {} : { target: overridden.target })
      })
      return
    }

    if (req.method === 'GET' && url.pathname === '/apps') {
      json(res, 200, { ok: true, file: APPS_FILE, apps: loadApps() })
      return
    }

    if (req.method === 'GET' && url.pathname === '/targets') {
      json(res, 200, { ok: true, file: TARGETS_FILE, targets: loadTargets() })
      return
    }

    json(res, 404, { ok: false, error: { code: 'not_found', message: `no route for ${req.method} ${url.pathname}` } })
  })

  server.listen(PORT, HOST, () => {
    log(`DSH bridge listening on http://${HOST}:${PORT}`)
    log(`  healthz : curl http://${HOST}:${PORT}/healthz`)
    log(`  call    : node ${process.argv[1]} call '{"action":"ping"}'`)
  })
  return server
}

async function readStdin () {
  const chunks = []
  for await (const chunk of process.stdin) {
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

async function callOnce (raw) {
  let payload
  try {
    payload = JSON.parse(raw)
  } catch (error) {
    console.error(`invalid JSON payload: ${error.message}`)
    process.exit(2)
  }
  let response
  try {
    response = await fetch(`http://${HOST}:${PORT}/command`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload)
    })
  } catch (error) {
    console.error(`bridge server unreachable at http://${HOST}:${PORT} — start it with: node ${process.argv[1]}`)
    process.exit(3)
  }
  const result = await response.json()
  console.log(JSON.stringify(result, null, 2))
  process.exit(result?.ok === true ? 0 : 1)
}

async function statusOnce () {
  try {
    const response = await fetch(`http://${HOST}:${PORT}/healthz`)
    console.log(JSON.stringify(await response.json(), null, 2))
  } catch {
    console.error(`bridge server unreachable at http://${HOST}:${PORT}`)
    process.exit(3)
  }
}

const argv = process.argv.slice(2)
const mode = argv[0] ?? 'serve'

if (mode === 'call') {
  const raw = argv[1] === undefined || argv[1] === '-' ? await readStdin() : argv[1]
  await callOnce(raw)
} else if (mode === 'status') {
  await statusOnce()
} else if (mode === 'serve' || mode === '--serve') {
  startServer()
} else {
  console.error('usage: bridge-server.mjs [serve|status|call <json>|-]')
  process.exit(2)
}
