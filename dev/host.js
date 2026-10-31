/*
  Audio Engine host: runs the addon's Lua (Lua 5.4 in WebAssembly) and a simple stand-in for
  the car's driving physics. Runs in a Web Worker (or on the page if workers are blocked) and
  talks to the page by messages: sound commands and generated buffers out, keys and settings in.
*/
function AudioHost(post, wasmoonLib) {
  const MPH = 1.609344, IN_PER_M = 39.3701
  // the two vehicle scripts the car can run on
  const SCRIPTS = {
    addon: { name: 'sl65amg_rtu.txt (this addon)', hp: 480, vmax: 155 * MPH, mass: 1950, rev: 20 * MPH },
    server: { name: 'sl65amg_cop.txt (server)', hp: 325, vmax: 200 * MPH, mass: 1550, rev: 25 * MPH },
  }
  let L = null, tick = null, ready = false
  let keys = { f: false, b: false, h: false }
  let mode = 'car', scriptId = 'addon'
  let perf = { accel: 1, vmax: 0 }
  const car = { y: 0, v: 0 }               // metres, m/s along the road
  let t = 0, last = 0, cmds = [], genCur = null, genPos = 0, st = null
  let timer = null

  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now())

  async function init(files, wasmBinary) {
    if (wasmBinary) (typeof self !== 'undefined' ? self : globalThis).__WASMOON_BINARY = new Uint8Array(wasmBinary)
    const factory = new wasmoonLib.LuaFactory()
    L = await factory.createEngine()
    const g = L.global
    g.set('__now', now)
    g.set('__log', (s) => post({ type: 'log', text: String(s) }))
    g.set('__genBegin', (name, rate, loop, n) => { genCur = { name, rate, loop, data: new Float32Array(n) }; genPos = 0 })
    g.set('__push', (...xs) => { const d = genCur.data; for (let i = 0; i < xs.length; i++) d[genPos++] = xs[i] })
    g.set('__genEnd', () => {
      const c = genCur; genCur = null
      post({ type: 'gen', name: c.name, rate: c.rate, loop: c.loop, data: c.data }, [c.data.buffer])
    })
    g.set('__snd', (op, id, a, b) => { cmds.push([op, id, a, b]) })
    g.set('__state', (...s) => { st = s })
    for (const f of files) {
      try { await L.doString(f.src) } catch (e) { post({ type: 'error', text: f.name + ': ' + e.message }); throw e }
    }
    await L.doString(`CAR.nw.audio_vmax = ${SCRIPTS[scriptId].vmax}`)
    await L.doString(`hook.Run("InitPostEntity")`)
    tick = g.get('BR').tick
    ready = true
    const menu = await L.doString('return BR.menuData()')
    post({ type: 'ready', menu: JSON.parse(menu), scripts: SCRIPTS })
    last = now()
    timer = setInterval(frame, 1000 / 60)
  }

  // driving: power-limited, traction-limited, capped at the script's top speed like Source
  function physics(dt) {
    const s = SCRIPTS[scriptId]
    const vmax = (perf.vmax > 0 ? perf.vmax : s.vmax) / 3.6
    const P = s.hp * 745.7 * perf.accel * 0.55
    const m = s.mass
    const kDrag = Math.max(0, (P / (m * vmax * 1.04) - 0.15) / Math.pow(vmax * 1.04, 2))
    let v = car.v, a = 0
    // the server holds the car while the engine is off or still starting (sv_engine.lua)
    const drivable = st && st[2] === 1 && st[3] === 'run'
    const fwd = drivable && keys.f && !keys.h, back = drivable && keys.b && !keys.h
    const drag = kDrag * v * Math.abs(v) + 0.15 * Math.sign(v)
    if (keys.h) {
      a = -Math.sign(v) * Math.min(5, Math.abs(v) / dt)
    } else if (fwd && v > -0.5) {
      a = Math.min(8, P / (m * Math.max(v, 3))) - drag
    } else if (fwd) {
      a = 9                                                   // braking out of reverse
    } else if (back && v > 0.5) {
      a = -9
    } else if (back) {
      a = v > -s.rev / 3.6 ? -3 - drag : -drag
    } else {
      a = -drag - 0.5 * Math.sign(v)                          // coasting, engine braking
      if (Math.abs(v) < 0.6) { a = 0; v = 0 }
    }
    v += a * dt
    if (v > vmax) v = vmax
    car.v = v
    car.y += v * dt
    if (mode === 'road') {
      if (car.y > 250) car.y -= 500                           // the next lap comes round again
      if (car.y < -250) car.y += 500
    }
  }

  function frame() {
    if (!ready) return
    const tn = now()
    let dt = Math.min(0.05, (tn - last) / 1000)
    last = tn
    if (dt <= 0) return
    t += dt
    physics(dt)
    const px = 0, py = car.y * IN_PER_M, pz = 0
    let ex, ey, ez
    if (mode === 'car') { ex = px; ey = py + 10; ez = pz + 40 }      // driver's seat
    else { ex = -8 * IN_PER_M; ey = 0; ez = 64 }                     // standing 8 m from the road
    try {
      tick(dt, t, keys.f, keys.b, keys.h, mode === 'car', px, py, pz, 0, ex, ey, ez)
    } catch (e) {
      post({ type: 'error', text: e.message }); clearInterval(timer); return
    }
    const dx = px - ex, dy = py - ey, dz = pz - ez
    const dist = Math.sqrt(dx * dx + dy * dy + dz * dz)
    // listener faces the road (+x); its right is -y in Source's axes
    const pan = mode === 'car' ? 0 : Math.max(-1, Math.min(1, -dy / Math.max(dist, 1)))
    post({ type: 'frame', cmds, dist, pan, st, keys: { ...keys }, mode })
    cmds = []
  }

  async function onMessage(m) {
    switch (m.type) {
      case 'init': return init(m.files, m.wasm)
      case 'keys': keys = m.keys; break
      case 'mode':
        if (m.mode !== mode) { mode = m.mode; car.y = mode === 'road' ? -200 : car.y }
        break
      case 'script':
        scriptId = m.script
        if (L) await L.doString(`CAR.nw.audio_vmax = ${SCRIPTS[scriptId].vmax}`)
        break
      case 'engine': if (L) await L.doString(`BR.engine(${m.on ? 'true' : 'false'}, ${m.emotion ? 'true' : 'false'})`); break
      case 'apply':
        if (!L) break
        L.global.get('BR').apply(m.profile)
        perf = { accel: m.accel ?? 1, vmax: m.vmax ?? 0 }
        break
      case 'cv': if (L) L.global.get('SetCV')(m.name, String(m.value)); break
      case 'cmd': if (L) L.global.get('BR').command(m.name); break
      case 'resolve': {
        if (!L) break
        const r = L.global.get('BR').resolve(m.profile)
        post({ type: 'resolved', id: m.reqId, data: JSON.parse(r) })
        break
      }
      case 'preset': {
        if (!L) break
        const r = L.global.get('BR').presetProfile(m.preset)
        post({ type: 'presetProfile', id: m.reqId, data: JSON.parse(r) })
        break
      }
    }
  }
  return { onMessage }
}
if (typeof module !== 'undefined') module.exports = { AudioHost }
