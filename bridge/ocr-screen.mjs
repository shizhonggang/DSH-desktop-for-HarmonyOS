#!/usr/bin/env node
/**
 * Screen OCR — read the text off any on-screen window (Core Vision Kit via the
 * ArkTS bridge), without screenshots-to-disk or clipboard tricks.
 *
 * Pipeline (three existing bridge actions, no HAP change needed):
 *   listMainWindows -> snapshotWindow (PixelMap -> PNG inside the app sandbox)
 *   -> fetchFile (base64 out of the sandbox) -> ocrImage (Core Vision Kit OCR)
 *
 * Usage:
 *   node bridge/ocr-screen.mjs                 # every *showing* window (max 3)
 *   node bridge/ocr-screen.mjs 349             # one window id
 *   node bridge/ocr-screen.mjs 349,84          # several
 *   node bridge/ocr-screen.mjs --all           # no 3-window cap
 *   node bridge/ocr-screen.mjs --json          # raw JSON per window
 *
 * Notes: the first snapshot may raise the system screen-capture consent dialog
 * (CUSTOM_SCREEN_CAPTURE is normal + user_grant). Windows that are minimized
 * report showing=false and are skipped unless their id is passed explicitly.
 */

const PORT = Number(process.env.DSH_BRIDGE_PORT ?? 3131)
const HOST = process.env.DSH_BRIDGE_HOST ?? '127.0.0.1'
const TIMEOUT_MS = Number(process.env.DSH_BRIDGE_TIMEOUT ?? 60000)

const argv = process.argv.slice(2)
const flags = new Set(argv.filter((a) => a.startsWith('--')))
const idArg = argv.find((a) => !a.startsWith('--'))

async function call(action, args = {}) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS)
  try {
    const res = await fetch(`http://${HOST}:${PORT}/command`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, args }),
      signal: ctrl.signal
    })
    const payload = await res.json()
    if (!payload.ok) throw new Error(payload.error ?? 'bridge error')
    let data = payload.data
    if (typeof data === 'string') data = JSON.parse(data)
    if (data && data.ok === false) throw new Error(JSON.stringify(data))
    return data
  } finally {
    clearTimeout(timer)
  }
}

let targets = []
if (idArg) {
  targets = idArg.split(',').map((s) => ({ windowId: Number.parseInt(s.trim(), 10), label: '' }))
} else {
  const listed = await call('listMainWindows')
  targets = (listed.windows ?? []).filter((w) => w.showing === true)
  if (!flags.has('--all')) targets = targets.slice(0, 3)
  if (targets.length === 0) {
    console.error('ocr-screen: no window is currently showing; pass a window id explicitly')
    process.exit(1)
  }
}

let failed = 0
for (const win of targets) {
  try {
    const shot = await call('snapshotWindow', { windowIds: String(win.windowId) })
    const file = (shot.files ?? []).find((f) => f.ok === true)?.file
    if (!file) throw new Error('snapshot failed (permission not granted?)')
    const fetched = await call('fetchFile', { path: file })
    const ocr = await call('ocrImage', { base64: fetched.base64 })
    if (flags.has('--json')) {
      console.log(JSON.stringify({ windowId: win.windowId, label: win.label, ocr }, null, 2))
    } else {
      console.log(`===== window ${win.windowId}${win.label ? ` (${win.label})` : ''} ` +
        `— ${ocr.width}x${ocr.height}, ${ocr.elapsedMs}ms =====`)
      for (const line of ocr.lines ?? []) console.log(line.text)
    }
  } catch (err) {
    failed++
    console.error(`window ${win.windowId}: ${err.message}`)
  }
}
process.exit(failed === targets.length ? 1 : 0)
