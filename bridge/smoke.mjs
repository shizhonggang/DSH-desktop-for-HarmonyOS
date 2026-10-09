#!/usr/bin/env node
/**
 * Smoke test for the DSH <-> ArkTS bridge, with a *fake* ArkTS agent.
 *
 * Spawns bridge-server.mjs on a private port with a short command timeout,
 * plays the agent side (long-poll -> execute -> post result), then checks that
 * commands round-trip, arguments are forwarded untouched, and unanswered
 * commands time out. Run this before building the HAP: it proves the node half
 * and the wire protocol, so a failure after install can only be the ArkTS half.
 *
 *   node bridge/smoke.mjs
 */

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'

const PORT = Number(process.env.DSH_BRIDGE_TEST_PORT ?? 3139)
const BASE = `http://127.0.0.1:${PORT}`
const SERVER = fileURLToPath(new URL('./bridge-server.mjs', import.meta.url))
// Isolated targets file: absent at first (no override), created mid-test.
const TARGETS = fileURLToPath(new URL('./smoke-targets.tmp.json', import.meta.url))
try { fs.unlinkSync(TARGETS) } catch {}

let pass = 0
let fail = 0
function check (name, ok, extra) {
  if (ok) {
    pass += 1
    console.log(`  ok   ${name}`)
  } else {
    fail += 1
    console.log(`  FAIL ${name}${extra === undefined ? '' : ' :: ' + extra}`)
  }
}

const server = spawn(process.execPath, [SERVER], {
  env: { ...process.env, DSH_BRIDGE_PORT: String(PORT), DSH_BRIDGE_TIMEOUT: '1500', DSH_BRIDGE_TARGETS: TARGETS },
  stdio: ['ignore', 'ignore', 'pipe']
})
server.stderr.on('data', (chunk) => process.stderr.write(`[server] ${chunk}`))

let healthy = false
for (let i = 0; i < 50; i += 1) {
  try {
    const response = await fetch(`${BASE}/healthz`)
    if (response.ok) {
      healthy = true
      break
    }
  } catch {
    // not up yet
  }
  await new Promise((resolve) => setTimeout(resolve, 100))
}
check('server becomes healthy', healthy)
if (!healthy) {
  server.kill('SIGKILL')
  process.exit(1)
}

// ---- fake ArkTS agent -------------------------------------------------------
const seen = []
let agentStopped = false
const agentLoop = (async () => {
  while (!agentStopped) {
    let response
    try {
      response = await fetch(`${BASE}/poll?wait=4000`)
    } catch {
      break
    }
    if (response.status === 204) {
      continue
    }
    if (!response.ok) {
      continue
    }
    const command = await response.json()
    seen.push(command)
    if (command.action === 'never-answer') {
      continue
    }
    await fetch(`${BASE}/result`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        id: command.id,
        ok: true,
        data: JSON.stringify({ pong: command.action === 'ping' })
      })
    })
  }
})()

const call = async (payload) => {
  const response = await fetch(`${BASE}/command`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload)
  })
  return response.json()
}

// ---- checks -----------------------------------------------------------------
const ping = await call({ action: 'ping', args: {} })
check('ping round-trips through the agent', ping.ok === true && ping.data?.pong === true, JSON.stringify(ping))

const nav = {
  type: 'navigation',
  wantParam: {
    sceneType: 2,
    destinationName: '上海',
    destinationLatitude: 31.2304,
    destinationLongitude: 121.4737,
    vehicleType: 0
  }
}
const routed = await call({ action: 'startAbilityByType', args: nav })
check('startAbilityByType accepted', routed.ok === true, JSON.stringify(routed))
const forwarded = seen.find((command) => command.action === 'startAbilityByType')
check('wantParam forwarded untouched (incl. non-ASCII)',
  JSON.stringify(forwarded?.args) === JSON.stringify(nav),
  JSON.stringify(forwarded?.args))

const startedAt = Date.now()
const timedOut = await call({ action: 'never-answer', args: {} })
const elapsed = Date.now() - startedAt
check('unanswered command times out instead of hanging',
  timedOut.ok === false && timedOut.error?.code === 'timeout', JSON.stringify(timedOut))
check('timeout honours DSH_BRIDGE_TIMEOUT', elapsed < 6000, `${elapsed}ms`)

const health = await (await fetch(`${BASE}/healthz`)).json()
check('healthz reports the agent as connected', health.agent?.connected === true, JSON.stringify(health.agent))
check('queued work is not left behind', health.queueDepth === 0 && health.pendingCommands === 0, JSON.stringify(health))

// ---- explicit target override (targets.json appears at runtime) -----------
const args = { type: 'navigation', wantParam: { sceneType: 2, destinationName: '上海' } }
const unmapped = await call({ action: 'startAbilityByType', args })
check('unmapped type still routes to the system panel', unmapped.via === 'panel', JSON.stringify(unmapped))

fs.writeFileSync(TARGETS, JSON.stringify({ navigation: { bundleName: 'com.example.maps', abilityName: 'EntryAbility' } }))
seen.length = 0
const mapped = await call({ action: 'startAbilityByType', args })
check('mapped type is rewritten to an explicit want', mapped.via === 'explicit' && mapped.target === 'navigation', JSON.stringify(mapped))
const explicit = seen.find((command) => command.action === 'startAbility')
check('explicit want carries bundle + ability + forwarded params',
  explicit?.args?.bundleName === 'com.example.maps' &&
  explicit?.args?.abilityName === 'EntryAbility' &&
  explicit?.args?.parameters?.sceneType === 2,
  JSON.stringify(explicit?.args))
try { fs.unlinkSync(TARGETS) } catch {}

agentStopped = true
server.kill('SIGTERM')
await agentLoop.catch(() => {})

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
