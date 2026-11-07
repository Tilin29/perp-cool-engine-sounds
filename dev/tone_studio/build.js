/*
  Builds dev/tone_studio.html: one self-contained page (wasmoon, its wasm, the addon's Lua and
  the page) that opens straight from disk. Rebuild after changing the synth, the presets or the
  car list so the page plays what a re-bake would ship.

    cd dev/baker && npm install     (once: wasmoon@1.16.0, shared with the baker)
    node dev/tone_studio/build.js            build
    node dev/tone_studio/build.js --test     also run the live engine in Node as a check
*/
const fs = require('fs')
const path = require('path')

const HERE = __dirname
const ADDON = path.resolve(HERE, '..', '..')
const LUA = path.join(ADDON, 'lua', 'audio_engine')
const WASMOON = path.join(ADDON, 'dev', 'baker', 'node_modules', 'wasmoon', 'dist')
const OUT = path.join(ADDON, 'dev', 'tone_studio.html')

// the same files, in the same order, as the baker (dev/baker/bake.js), then the page's glue
const files = [{ name: 'bake_shim.lua', src: fs.readFileSync(path.join(ADDON, 'dev', 'baker', 'bake_shim.lua'), 'utf8') }]
for (const f of ['sh_config.lua', 'sh_presets.lua', 'sh_drivetrain.lua', 'sh_carlist.lua', 'cl_synth.lua', 'cl_soundbank.lua']) {
  files.push({ name: f, src: fs.readFileSync(path.join(LUA, f), 'utf8') })
}
files.push({ name: 'studio.lua', src: fs.readFileSync(path.join(HERE, 'studio.lua'), 'utf8') })

let wasmoon = fs.readFileSync(path.join(WASMOON, 'index.js'), 'utf8')
// hand emscripten the embedded wasm bytes instead of letting it fetch glue.wasm
const hook = 'function Ta(a,b){var c=M;return '
if (wasmoon.split(hook).length !== 2) throw new Error('wasmoon changed: the wasm hook is not found once')
wasmoon = wasmoon.replace(hook, 'function Ta(a,b){var c=M;if(globalThis.__WASMOON_BINARY)return WebAssembly.instantiate(globalThis.__WASMOON_BINARY,a).then(b);return ')
const wasm = fs.readFileSync(path.join(WASMOON, 'glue.wasm'))
const worker = fs.readFileSync(path.join(HERE, 'worker.js'), 'utf8')
const worklet = fs.readFileSync(path.join(HERE, 'worklet.js'), 'utf8')
const ideas = JSON.stringify(JSON.parse(fs.readFileSync(path.join(HERE, 'candidates.json'), 'utf8')))

/*
  Runs the live engine as the page does, with a stand-in for the audio worklet that takes each
  chunk straight away. Checks it stays faster than real time, stays finite, shifts gears, and
  keeps sounding through a retune mid-stream (other layouts, electric, a drawn firing pattern).
*/
async function selfTest() {
  globalThis.__WASMOON_BINARY = null
  const { StudioHost } = require('./worker.js')
  const lib = require(path.join(WASMOON, 'index.js'))
  let ready, stat
  const failed = (t) => { throw new Error('self-test: ' + t) }
  const host = StudioHost((m) => {
    if (m.type === 'error') failed(m.text)
    if (m.type === 'ready') ready = m.data
    if (m.type === 'stat') stat = m
  }, lib)
  const wait = (ms) => new Promise((r) => setTimeout(r, ms))
  host.onMessage({ type: 'init', files })
  while (!ready) await wait(20)
  console.log(`self-test: ${ready.cars.length} cars, ${ready.presets.length} presets, ${ready.layouts.length} layouts`)

  let chunks = [], port = null
  const take = (d) => {
    chunks.push(d)
    port.onmessage({ data: { played: host.live.produced, under: 0 } })
  }
  port = { postMessage: take }
  host.onMessage({ type: 'port', port })
  const car = 'Bugatti Veyron 16.4'
  const send = (type, req) => host.onMessage({ type, req })
  const stats = (d) => {
    let peak = 0, s = 0
    for (const c of d) for (const x of c) {
      if (!Number.isFinite(x)) failed('sound went non-finite')
      peak = Math.max(peak, Math.abs(x)); s += x * x
    }
    return { peak, rms: Math.sqrt(s / (d.length * 735)) }
  }
  const run = async (ms) => { chunks = []; await wait(ms); return stats(chunks) }

  send('config', { car })
  await wait(50)
  host.onMessage({ type: 'play' })
  send('input', { mode: 'rev', fwd: true })
  const t0 = Date.now()
  const rev = await run(1500)
  const speed = chunks.length * 735 / 44100 / ((Date.now() - t0) / 1000)
  console.log(`self-test: rev to limiter ${speed.toFixed(1)}x real time, peak ${rev.peak.toFixed(2)}, rms ${rev.rms.toFixed(3)}, ${Math.round(stat.rpm)} rpm`)
  if (speed < 2) failed('too slow to stream')

  send('input', { mode: 'drive', fwd: true })
  let topGear = 0
  for (let i = 0; i < 40; i++) { await run(100); topGear = Math.max(topGear, stat.gear) }
  console.log(`self-test: drive reached gear ${topGear}, ${Math.round(stat.kmh)} km/h`)
  if (topGear < 3) failed('the gearbox did not shift')
  const fast = stat.kmh
  send('input', { mode: 'drive', fwd: false, back: true })
  await run(500)
  console.log(`self-test: brake ${Math.round(fast)} -> ${Math.round(stat.kmh)} km/h`)
  if (fast - stat.kmh < 20) failed('S did not brake')

  send('input', { mode: 'hold', rpm: 4000, thr: 1, fwd: false })
  await run(300)
  const cases = [
    ['tone', { car, sound: { tone: 0.9, pitch: 1.2 } }],
    ['v8', { car, sound: { layout: 'v8cross' }, character: {} }],
    ['single', { car, sound: { layout: 'single' }, character: {} }],
    ['electric', { car, sound: { layout: 'electric' }, character: {} }],
    ['custom', { car, sound: { layout: 'custom' }, character: {}, custom: { base: 'i5', angles: [0, 90, 300, 400, 620], amp: [1, 0.7, 1.2, 0.9, 1], banks: 'LRLRL' } }],
    ['back', { car }],
  ]
  for (const [name, req] of cases) {
    send('config', req)
    const s = await run(300)
    console.log(`self-test: ${name.padEnd(8)} peak ${s.peak.toFixed(2)}, rms ${s.rms.toFixed(3)}`)
    if (s.rms < 0.01) failed(name + ': silent after the retune')
  }
  host.onMessage({ type: 'pop', kind: 'bang' })
  const bang = await run(300)
  console.log(`self-test: bang peak ${bang.peak.toFixed(2)}`)
  host.onMessage({ type: 'ignition' })
  await run(1500)
  host.onMessage({ type: 'ignition' })
  const started = await run(2500)
  console.log(`self-test: stop and start-up: running ${stat.running}, rms ${started.rms.toFixed(3)}`)
  if (started.rms < 0.005) failed('no sound after the start-up')
  host.onMessage({ type: 'stop' })
}

function build() {
  const t = fs.readFileSync(path.join(HERE, 'template.html'), 'utf8')
  for (const [name, src] of [...files.map((f) => [f.name, f.src]), ['wasmoon', wasmoon], ['worker.js', worker], ['worklet.js', worklet], ['candidates.json', ideas]]) {
    if (src.toLowerCase().includes('</script')) throw new Error(name + " holds </script: it would end the page's script tag")
  }
  const lua = files.map((f) => `<script type="text/x-lua" data-name="${f.name}">${f.src}</script>`).join('\n')
  const parts = { '{{LUA_FILES}}': lua, '{{WASMOON}}': wasmoon, '{{WORKER}}': worker, '{{WORKLET}}': worklet, '{{WASM_B64}}': wasm.toString('base64'), '{{IDEAS}}': ideas }
  let out = t
  for (const [k, v] of Object.entries(parts)) {
    if (!out.includes(k)) throw new Error('template has no ' + k)
    out = out.split(k).join(v)
  }
  fs.writeFileSync(OUT, out)
  console.log(`${path.relative(ADDON, OUT)} ${(out.length / 1024).toFixed(0)} KB`)
}

;(async () => {
  if (process.argv.includes('--test')) await selfTest()
  if (fs.existsSync(path.join(HERE, 'template.html'))) build()
  process.exit(0)
})().catch((e) => { console.error(e); process.exit(1) })
