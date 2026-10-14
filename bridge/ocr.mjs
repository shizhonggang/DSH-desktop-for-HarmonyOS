#!/usr/bin/env node
/**
 * OCR helper — Core Vision Kit (基础视觉服务) textRecognition via the ArkTS bridge.
 *
 * The OCR engine only exists inside an ArkTS runtime, so this script ships the
 * image to the DshDesktop HAP over the loopback bridge (`ocrImage` action) and
 * prints what came back. Any shell / DSH session can use it:
 *
 *   node bridge/ocr.mjs shot.png            # recognized text (one line per line)
 *   node bridge/ocr.mjs shot.png --json     # full result incl. per-line boxes
 *   node bridge/ocr.mjs shot.png --boxes    # text + "x,y,w,h" per line
 *
 * Verified 2026-10-10 on HAD-W32 (2in1): 1000x320 PNG with zh+en text,
 * 161 ms, exact text + boxes. No permission required.
 */

import fs from 'node:fs'
import path from 'node:path'

const PORT = Number(process.env.DSH_BRIDGE_PORT ?? 3131)
const HOST = process.env.DSH_BRIDGE_HOST ?? '127.0.0.1'
const TIMEOUT_MS = Number(process.env.DSH_BRIDGE_TIMEOUT ?? 60000)

const argv = process.argv.slice(2)
const flags = new Set(argv.filter((a) => a.startsWith('--')))
const file = argv.find((a) => !a.startsWith('--'))

if (!file || flags.has('--help') || flags.has('-h')) {
  console.error('usage: node ocr.mjs <image-path> [--json] [--boxes]')
  process.exit(file ? 0 : 2)
}

const abs = path.resolve(file)
if (!fs.existsSync(abs)) {
  console.error(`ocr.mjs: no such file: ${abs}`)
  process.exit(1)
}

const base64 = fs.readFileSync(abs).toString('base64')
const body = JSON.stringify({ action: 'ocrImage', args: { base64 } })

const ctrl = new AbortController()
const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS)
let payload
try {
  const res = await fetch(`http://${HOST}:${PORT}/command`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
    signal: ctrl.signal
  })
  payload = await res.json()
} catch (err) {
  console.error(`ocr.mjs: bridge call failed (${err.message}). Is the HAP running and ` +
    `bridge-server.mjs up? Try: node bridge-server.mjs status`)
  process.exit(1)
} finally {
  clearTimeout(timer)
}

if (!payload.ok) {
  console.error(`ocr.mjs: ${payload.error ?? 'unknown bridge error'}`)
  process.exit(1)
}

// The bridge wraps the action result as {ok:true,data:{ok:true,value,lines:[...]}}
let data = payload.data
if (typeof data === 'string') {
  try {
    data = JSON.parse(data)
  } catch {
    console.error(`ocr.mjs: unparsable bridge payload: ${String(data).slice(0, 200)}`)
    process.exit(1)
  }
}

if (flags.has('--json')) {
  console.log(JSON.stringify(data, null, 2))
  process.exit(0)
}

const lines = Array.isArray(data?.lines) ? data.lines : []
if (flags.has('--boxes')) {
  for (const line of lines) {
    const xs = (line.box ?? []).map((p) => p[0])
    const ys = (line.box ?? []).map((p) => p[1])
    const box = xs.length
      ? `${Math.min(...xs)},${Math.min(...ys)},${Math.max(...xs) - Math.min(...xs)},${Math.max(...ys) - Math.min(...ys)}`
      : ''
    console.log(`${box}\t${line.text}`)
  }
} else {
  for (const line of lines) console.log(line.text)
}

if (process.env.DSH_OCR_STATS === '1') {
  console.error(`[ocr] ${data?.width}x${data?.height} in ${data?.elapsedMs}ms, ${lines.length} lines`)
}
