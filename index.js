import { spawn } from 'node:child_process'
import { appendFile, readFile, mkdir, unlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const CAPTURE_SCRIPT = join(HERE, 'capture.ps1')
const CAPTURE_ROUTE = '/api/dsh-screenshot/capture'
// The browser half reports its registration outcome here; the plugin has no
// visible error surface, and a silent failure looks exactly like "no rows".
const DIAG_ROUTE = '/api/dsh-screenshot/diag'
const DIAG_FILE = join(tmpdir(), 'dsh-screenshot-client.log')
const OUT_DIR = join(tmpdir(), 'dsh-screenshot-tool')

// The overlay is a Windows PowerShell WinForms window (per-monitor DPI aware
// capture, window hit-testing, topmost form). Other platforms get an explicit
// refusal instead of a spawn failure.
const SUPPORTED = process.platform === 'win32'

// A cold powershell.exe spends ~1.2s before the first pixel is grabbed, and the
// two Add-Type compiles add another ~0.4s. Both are paid once per helper process
// instead of once per click.
const HELPER_START_TIMEOUT_MS = 20000
const CAPTURE_TIMEOUT_MS = 130000

/**
 * One-shot capture: spawn a throwaway process, run the whole gesture, exit.
 * Kept as the fallback so a broken preheat never takes the feature down.
 */
function runCapture() {
  return new Promise((resolve, reject) => {
    const args = [
      '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
      '-File', CAPTURE_SCRIPT, '-OutDir', OUT_DIR,
    ]
    let child
    try {
      child = spawn('powershell.exe', args, {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    } catch (error) {
      reject(error)
      return
    }
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    const timer = setTimeout(() => {
      try { child.kill() } catch { }
      reject(new Error('capture timed out'))
    }, CAPTURE_TIMEOUT_MS)
    child.on('error', (error) => {
      clearTimeout(timer)
      reject(error)
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      const lastLine = stdout.trim().split(/\r?\n/).pop() || ''
      if (code !== 0) {
        reject(new Error(stderr.trim() || `capture process exited with ${code}`))
        return
      }
      if (lastLine === 'CANCELLED') {
        resolve({ cancelled: true })
        return
      }
      if (!lastLine) {
        reject(new Error('capture produced no file path'))
        return
      }
      resolve({ cancelled: false, file: lastLine })
    })
  })
}

/** A resident helper: `capture.ps1 -Serve` waiting on stdin for gestures. */
let helper = null

function startHelper() {
  const child = spawn('powershell.exe', [
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', CAPTURE_SCRIPT, '-Serve', '-OutDir', OUT_DIR,
    // The helper closes any open overlay if this process disappears.
    '-ParentPid', String(process.pid),
  ], {
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  })

  const state = {
    child,
    buffer: '',
    stderr: '',
    pending: null,
    ready: null,
    resolveReady: null,
    rejectReady: null,
  }
  state.ready = new Promise((resolve, reject) => {
    state.resolveReady = resolve
    state.rejectReady = reject
  })
  // The rejection is awaited per request; keep node from flagging it as unhandled
  // when nothing is waiting at the moment the helper dies.
  state.ready.catch(() => {})

  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    state.buffer += chunk
    let index
    while ((index = state.buffer.indexOf('\n')) !== -1) {
      const line = state.buffer.slice(0, index).replace(/\r$/, '')
      state.buffer = state.buffer.slice(index + 1)
      handleHelperLine(state, line)
    }
  })
  child.stderr.on('data', (chunk) => {
    state.stderr = (state.stderr + chunk).slice(-2000)
  })
  child.on('error', (error) => {
    state.rejectReady(error)
    failPending(state, error)
    if (helper === state) helper = null
  })
  child.on('close', (code) => {
    const message = state.stderr.trim() || `capture helper exited with ${code}`
    state.rejectReady(new Error(message))
    failPending(state, new Error(message))
    if (helper === state) helper = null
  })

  const startTimer = setTimeout(() => {
    state.rejectReady(new Error('capture helper did not become ready'))
  }, HELPER_START_TIMEOUT_MS)
  startTimer.unref?.()
  state.ready.then(() => clearTimeout(startTimer), () => clearTimeout(startTimer))

  return state
}

function handleHelperLine(state, line) {
  if (line === 'READY') {
    state.resolveReady()
    return
  }
  // SHOWN carries the overlay's own timing; nothing to do with it.
  if (!line.startsWith('RESULT|')) { return }

  const [, status, detail = ''] = line.split('|')
  const pending = state.pending
  state.pending = null
  if (pending === null) { return }
  clearTimeout(pending.timer)
  if (status === 'OK') {
    pending.resolve({ cancelled: false, file: detail })
  } else if (status === 'CANCELLED') {
    pending.resolve({ cancelled: true })
  } else {
    pending.reject(new Error(detail || 'capture failed'))
  }
}

function failPending(state, error) {
  const pending = state.pending
  state.pending = null
  if (pending === null) { return }
  clearTimeout(pending.timer)
  pending.reject(error)
}

function stopHelper(state = helper) {
  if (state === null) { return }
  if (helper === state) { helper = null }
  try { state.child.stdin.write('QUIT\n') } catch { }
  // Give the overlay a moment to unwind, then make sure the process is gone: a
  // stuck full-screen topmost form would block the whole desktop.
  const timer = setTimeout(() => {
    try { state.child.kill() } catch { }
  }, 500)
  timer.unref?.()
}

function helperUnavailable(error) {
  const wrapped = error instanceof Error ? error : new Error(String(error))
  wrapped.code = 'helper-unavailable'
  return wrapped
}

/** Send one gesture to the warm helper, or throw helper-unavailable. */
async function captureResident() {
  if (helper === null) { helper = startHelper() }
  const state = helper

  try {
    await state.ready
  } catch (error) {
    stopHelper(state)
    throw helperUnavailable(error)
  }

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      state.pending = null
      reject(new Error('capture timed out'))
      // The overlay is still on screen; kill the process so it cannot outlive
      // the request and hold the desktop hostage.
      stopHelper(state)
    }, CAPTURE_TIMEOUT_MS)

    state.pending = { resolve, reject, timer }
    try {
      state.child.stdin.write('CAPTURE|0|0\n')
    } catch (error) {
      clearTimeout(timer)
      state.pending = null
      stopHelper(state)
      reject(error)
    }
  })
}

// One overlay at a time: a second capture would stack another full-screen
// topmost form over the first, and neither would be dismissible by the other.
let captureInFlight = false

/** Fetch-shaped handler for the authenticated /api channel. */
async function handleCapture() {
  if (!SUPPORTED) {
    return Response.json({
      ok: false,
      error: `screen capture needs Windows (running on ${process.platform})`,
    }, { status: 501 })
  }
  if (captureInFlight) {
    return Response.json({ ok: false, error: 'a capture is already running' }, { status: 409 })
  }
  captureInFlight = true
  let file
  try {
    await mkdir(OUT_DIR, { recursive: true })
    let result
    try {
      result = await captureResident()
    } catch (error) {
      // Only fall back when no gesture was ever delivered; a request that already
      // opened an overlay must not spawn a second one.
      if (error?.code !== 'helper-unavailable') { throw error }
      result = await runCapture()
    }

    if (result.cancelled) {
      return Response.json({ ok: true, cancelled: true })
    }
    file = result.file
    const bytes = await readFile(file)
    return Response.json({
      ok: true,
      cancelled: false,
      data: bytes.toString('base64'),
      mediaType: 'image/png',
      // The stamp in the file name keeps two shots in one draft distinguishable.
      name: basename(file),
    })
  } catch (error) {
    return Response.json({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }, { status: 500 })
  } finally {
    captureInFlight = false
    // The PNG only carries bytes to the renderer; the clipboard already holds a
    // copy, so keeping every frame would grow %TEMP% without bound.
    if (file !== undefined) await unlink(file).catch(() => {})
  }
}

/** Append one browser-side diagnostic line; never fails the caller. */
async function handleDiag(request) {
  try {
    const body = await request.text()
    await mkdir(tmpdir(), { recursive: true })
    await appendFile(DIAG_FILE, `${new Date().toISOString()} ${body}\n`, 'utf8')
  } catch { }
  return Response.json({ ok: true })
}

/**
 * Host half: registers the capture endpoint on the Connection fetch registry
 * (the authenticated /api channel), declaring POST explicitly.
 */
export const inject = ['connection']

export function apply(ctx) {
  const connection = ctx.get('connection')
  if (!connection || typeof connection.fetch?.register !== 'function') {
    return
  }

  const dispose = connection.fetch.register({
    path: CAPTURE_ROUTE,
    methods: ['POST'],
    requestBody: 'buffered',
    fetch: handleCapture,
  })

  const disposeDiag = connection.fetch.register({
    path: DIAG_ROUTE,
    methods: ['POST'],
    requestBody: 'buffered',
    fetch: handleDiag,
  })

  // Preheat one helper at load so the first click does not pay the process start.
  // It costs one idle powershell process; every later click lands in ~200ms.
  if (SUPPORTED) {
    try {
      if (helper === null) { helper = startHelper() }
    } catch { }
  }

  // ctx.effect runs the function now and keeps its return value as the disposer,
  // so the cleanup must be the inner function, not an immediate call.
  ctx.effect(() => () => {
    stopHelper()
    dispose()
    disposeDiag()
  })
}
