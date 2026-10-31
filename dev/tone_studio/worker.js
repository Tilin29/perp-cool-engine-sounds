/*
  Tone Studio worker: runs the addon's Lua (Lua 5.4 in WebAssembly, wasmoon) and renders engine
  sounds on request. Works in a Web Worker, on the page (if workers are blocked) or in Node (the
  build's self-test). Messages in: init, data, rhythm, render. Out: ready, data, rhythm, render, error.
*/
function StudioHost(post, wasmoonLib) {
  let L = null
  let res = null
  let gen = null, genPos = 0
  const queue = []
  let busy = false

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
    g.set('__genBegin', (name, rate, loop, n) => { gen = { rate, loop, data: new Float32Array(n) }; genPos = 0 })
    g.set('__push', (...xs) => { const d = gen.data; for (let i = 0; i < xs.length; i++) d[genPos++] = xs[i] })
    g.set('__genEnd', () => {})
    for (const f of files) {
      try { await L.doString(f.src) } catch (e) { throw new Error(f.name + ': ' + e.message) }
    }
    const data = JSON.parse(await call('STUDIO.data()'))
    post({ type: 'ready', data })
  }

  async function run(m) {
    try {
      if (m.type === 'init') return await init(m.files, m.wasm)
      if (m.type === 'rhythm') {
        const r = JSON.parse(await call('STUDIO.rhythm(' + lua(m.req) + ')'))
        return post({ type: 'rhythm', id: m.id, data: r })
      }
      if (m.type === 'render') {
        const t0 = Date.now()
        const info = JSON.parse(await call('STUDIO.render(' + lua(m.req) + ')'))
        const g = gen; gen = null
        return post({ type: 'render', id: m.id, tag: m.tag, info, rate: g.rate, loop: g.loop >= 0, data: g.data, ms: Date.now() - t0 }, [g.data.buffer])
      }
    } catch (e) {
      post({ type: 'error', id: m.id, tag: m.tag, text: String(e && e.message || e) })
    }
  }

  // one job at a time; a newer render of the same tag replaces one still waiting
  async function pump() {
    if (busy) return
    busy = true
    while (queue.length) await run(queue.shift())
    busy = false
  }
  function onMessage(m) {
    if (m.type === 'render' && m.tag) {
      for (let i = queue.length - 1; i >= 0; i--) if (queue[i].type === 'render' && queue[i].tag === m.tag) queue.splice(i, 1)
    }
    queue.push(m)
    pump()
  }
  return { onMessage, lua }
}
if (typeof module !== 'undefined') module.exports = { StudioHost }
