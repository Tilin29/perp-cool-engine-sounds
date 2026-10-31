/*
  Builds dev/tone_studio.html: one self-contained page (wasmoon, its wasm, the addon's Lua and
  the page) that opens straight from disk. Rebuild after changing the synth, the presets or the
  car list so the page plays what a re-bake would ship.

    cd dev/baker && npm install     (once: wasmoon@1.16.0, shared with the baker)
    node dev/tone_studio/build.js            build
    node dev/tone_studio/build.js --test     also render a car in Node as a check
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

async function selfTest() {
  globalThis.__WASMOON_BINARY = null
  const { StudioHost } = require('./worker.js')
  const lib = require(path.join(WASMOON, 'index.js'))
  let ready, done
  const got = new Promise((r) => { done = r })
  const host = StudioHost((m) => {
    if (m.type === 'log') return
    if (m.type === 'error') throw new Error(m.text)
    if (m.type === 'ready') ready = m.data
    else done(m)
  }, lib)
  await new Promise((r) => {
    host.onMessage({ type: 'init', files })
    const t = setInterval(() => { if (ready) { clearInterval(t); r() } }, 20)
  })
  console.log(`self-test: ${ready.cars.length} cars, ${ready.presets.length} presets, ${ready.layouts.length} layouts`)
  host.onMessage({ type: 'render', id: 1, tag: 'a', req: { car: 'Bugatti Veyron 16.4', mode: 'rev', sr: 22050, sound: { pitch: 0.85 }, character: { o05: 0.4 } } })
  const m = await got
  let peak = 0, sum = 0
  for (const x of m.data) { peak = Math.max(peak, Math.abs(x)); sum += x * x }
  console.log(`self-test: rev ${(m.data.length / m.rate).toFixed(1)} s in ${m.ms} ms, peak ${peak.toFixed(3)}, rms ${Math.sqrt(sum / m.data.length).toFixed(4)}, key ${m.info.key}`)
}

function build() {
  const t = fs.readFileSync(path.join(HERE, 'template.html'), 'utf8')
  for (const [name, src] of [...files.map((f) => [f.name, f.src]), ['wasmoon', wasmoon], ['worker.js', worker]]) {
    if (src.toLowerCase().includes('</script')) throw new Error(name + " holds </script: it would end the page's script tag")
  }
  const lua = files.map((f) => `<script type="text/x-lua" data-name="${f.name}">${f.src}</script>`).join('\n')
  const parts = { '{{LUA_FILES}}': lua, '{{WASMOON}}': wasmoon, '{{WORKER}}': worker, '{{WASM_B64}}': wasm.toString('base64') }
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
})().catch((e) => { console.error(e); process.exit(1) })
