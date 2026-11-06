/*
  Tone Studio worker: runs the addon's Lua (Lua 5.4 in WebAssembly, wasmoon) and streams the live
  engine to the page's audio worklet. Works in a Web Worker, on the page (if workers are blocked)
  or in Node (the build's self-test).
  Messages in: init, port, play, stop, config, input, ignition, pop, rhythm.
  Out: ready, config, stat, rhythm, error.
*/
function StudioHost(post, wasmoonLib) {
  let L = null
  let res = null
  const queue = []
  let busy = false

  const RATE = 44100, CHUNK = 735
  // audio queued ahead of the speakers: every change is heard this late. Enough for the Lua
  // collector's pauses (under 20 ms); it grows if the stream still runs dry
  const LEAD_MIN = RATE * 0.16 | 0, LEAD_MAX = RATE * 0.4 | 0
  const live = { port: null, on: false, produced: 0, played: 0, under: 0, lead: LEAD_MIN, timer: null, chunk: null, pos: 0, renderMs: 0, renderN: 0 }
  let stat = null, statN = 0

  /*
    The sound bank evens the bands out and sets the engine's loudness (cl_soundbank: rms above
    250 Hz at TARGET_DB, ~3 dB up from the lowest band to the highest). A live engine has no bands,
    so this does the same by ear: it follows the loudness while on the throttle and holds its gain
    off it, so a lift falls away as it does in game. Electric motors keep their natural levels.
  */
  const lev = { a: Math.exp(-2 * Math.PI * 250 / RATE), x1: 0, y1: 0, ms: 0.0025, gain: 2 }
  function level(d, redFrac, on, electric) {
    let sum = 0
    for (let i = 0; i < d.length; i++) {
      const y = lev.a * (lev.y1 + d[i] - lev.x1)
      lev.x1 = d[i]; lev.y1 = y; sum += y * y
    }
    let want = lev.gain
    if (electric) want = 2
    else if (on) {
      lev.ms += (sum / d.length - lev.ms) * 0.08
      const target = Math.pow(10, (-22.5 + 3 * redFrac) / 20)
      want = Math.min(30, Math.max(0.5, target / (Math.sqrt(lev.ms) + 1e-6)))
    }
    // at most ~12 dB/s, spread over the chunk: a step would click
    const step = lev.gain * 0.03
    const next = lev.gain + Math.max(-step, Math.min(step, want - lev.gain))
    for (let i = 0; i < d.length; i++) {
      const x = d[i] * (lev.gain + (next - lev.gain) * (i / d.length)), m = Math.abs(x)
      // the bank's limitPeaks holds the loudest pulses under 0.95; live there's no look-ahead,
      // so round them off over 0.8 instead
      d[i] = m > 0.8 ? Math.sign(x) * (0.8 + 0.15 * Math.tanh((m - 0.8) / 0.15)) : x
    }
    lev.gain = next
  }

  // a JS value as a Lua literal (car names may hold any character)
  function lua(v) {
    if (v === null || v === undefined) return 'nil'
    if (typeof v === 'boolean') return v ? 'true' : 'false'
    if (typeof v === 'number') return isFinite(v) ? String(v) : '0'
    if (typeof v === 'string') {
      let s = '"'
      for (const b of new TextEncoder().encode(v)) {
        s += (b >= 32 && b < 127 && b !== 34 && b !== 92) ? String.fromCharCode(b) : '\\' + String(b).padStart(3, '0')
      }
      return s + '"'
    }
    if (Array.isArray(v)) return '{' + v.map(lua).join(',') + '}'
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined && v[k] !== null)
      .map((k) => '[' + lua(k) + ']=' + lua(v[k])).join(',') + '}'
  }

  async function call(code) {
    res = null
    await L.doString(code)
    return res
  }

  async function init(files, wasmBinary) {
    if (wasmBinary) globalThis.__WASMOON_BINARY = new Uint8Array(wasmBinary)
    L = await new wasmoonLib.LuaFactory().createEngine()
    const g = L.global
    const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now())
    g.set('__now', now)
    g.set('__log', (s) => post({ type: 'log', text: String(s) }))
    // never hand Lua a JS null (wasmoon crashes): these return nothing
    g.set('__result', (s) => { res = s })
    g.set('__push', (...xs) => { const d = live.chunk; for (let i = 0; i < xs.length; i++) d[live.pos++] = xs[i] })
    g.set('__live', (rpm, gear, kmh, thr, running, electric) => { stat = { rpm, gear, kmh, thr, running, electric } })
    for (const f of files) {
      try { await L.doString(f.src) } catch (e) { throw new Error(f.name + ': ' + e.message) }
    }
    const data = JSON.parse(await call('STUDIO.data()'))
    post({ type: 'ready', data })
  }

  async function step() {
    live.chunk = new Float32Array(CHUNK); live.pos = 0
    const t0 = Date.now()
    await L.doString('LIVE.step()')
    live.renderMs += Date.now() - t0; live.renderN++
    const d = live.chunk
    level(d, stat.rpm / redline, stat.thr > 0.5, stat.electric === 1)
    live.produced += CHUNK
    live.port.postMessage(d, [d.buffer])
    if (++statN >= 4) {
      statN = 0
      post({ type: 'stat', ...stat, ahead: (live.produced - live.played) / RATE, under: live.under,
        speed: live.renderMs ? (live.renderN * CHUNK / RATE * 1000) / live.renderMs : 0 })
      if (live.renderN > 240) { live.renderMs = 0; live.renderN = 0 }
    }
  }

  let redline = 7000
  async function run(m) {
    try {
      if (m.type === 'init') return await init(m.files, m.wasm)
      if (m.type === 'config') {
        const r = JSON.parse(await call('LIVE.config(' + lua(m.req) + ')'))
        redline = r.redline
        return post({ type: 'config', data: r })
      }
      if (m.type === 'input') return await L.doString('LIVE.input(' + lua(m.req) + ')')
      if (m.type === 'ignition') return await L.doString('LIVE.ignition()')
      if (m.type === 'pop') return await L.doString('LIVE.pop(' + lua(m.kind) + ')')
      if (m.type === 'rhythm') {
        const r = JSON.parse(await call('STUDIO.rhythm(' + lua(m.req) + ')'))
        return post({ type: 'rhythm', id: m.id, data: r })
      }
    } catch (e) {
      post({ type: 'error', id: m.id, text: String(e && e.message || e) })
    }
  }

  // one job at a time, between chunks; a newer retune replaces one still waiting
  async function pump() {
    if (busy) return
    busy = true
    while (queue.length) await run(queue.shift())
    busy = false
  }

  // keep the worklet's queue topped up, then do whatever came in meanwhile
  async function tick() {
    if (!live.on) return
    if (!busy) {
      busy = true
      try {
        for (let n = 0; n < 8 && live.on && live.produced - live.played < live.lead; n++) await step()
      } catch (e) {
        live.on = false
        post({ type: 'error', text: String(e && e.message || e) })
      }
      busy = false
      await pump()
    }
    live.timer = setTimeout(tick, 5)
  }

  function onPort(port) {
    live.port = port
    port.onmessage = (e) => {
      live.played = e.data.played
      if (e.data.under > live.under) live.lead = Math.min(LEAD_MAX, live.lead + (RATE * 0.03 | 0))
      live.under = e.data.under
    }
  }

  function onMessage(m) {
    if (m.type === 'port') return onPort(m.port)
    if (m.type === 'play') {
      if (live.on) return
      live.on = true; live.produced = 0; live.played = 0; live.under = 0
      return tick()
    }
    if (m.type === 'stop') { live.on = false; clearTimeout(live.timer); return }
    if (m.type === 'config') {
      for (let i = queue.length - 1; i >= 0; i--) if (queue[i].type === 'config') queue.splice(i, 1)
    }
    queue.push(m)
    pump()
  }
  return { onMessage, lua, live }
}
if (typeof module !== 'undefined') module.exports = { StudioHost }
