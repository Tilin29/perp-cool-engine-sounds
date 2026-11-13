/*
  Builds dev/honk_studio.html: one self-contained page (wasmoon, its wasm, the horn's Lua and the
  page) that opens straight from disk. It runs lua/car_horn's own synth, so it plays what the
  game will. Rebuild after changing the horn's synth or its settings file.

    cd dev/baker && npm install      (once: wasmoon@1.16.0, shared with the baker)
    node dev/honk_studio/build.js           build
    node dev/honk_studio/build.js --test    also render every horn in Node and check the loops
*/
const fs = require('fs')
const path = require('path')

const HERE = __dirname
const ADDON = path.resolve(HERE, '..', '..')
const LUA = path.join(ADDON, 'lua', 'car_horn')
const WASMOON = path.join(ADDON, 'dev', 'baker', 'node_modules', 'wasmoon', 'dist')
const OUT = path.join(ADDON, 'dev', 'honk_studio.html')

const configSrc = fs.readFileSync(path.join(LUA, 'sh_horn_config.lua'), 'utf8')
const files = [
  { name: 'sh_horn_config.lua', src: configSrc },
  { name: 'cl_horn_synth.lua', src: fs.readFileSync(path.join(LUA, 'cl_horn_synth.lua'), 'utf8') },
  { name: 'studio.lua', src: fs.readFileSync(path.join(HERE, 'studio.lua'), 'utf8') },
]
// the settings file's header comment: the page writes it above the exported settings
const at = configSrc.indexOf('CAR_HORN.CONFIG =')
if (at < 0) throw new Error('sh_horn_config.lua has no CAR_HORN.CONFIG =')
const header = configSrc.slice(0, at)

let wasmoon = fs.readFileSync(path.join(WASMOON, 'index.js'), 'utf8')
// hand emscripten the embedded wasm bytes instead of letting it fetch glue.wasm
const hook = 'function Ta(a,b){var c=M;return '
if (wasmoon.split(hook).length !== 2) throw new Error('wasmoon changed: the wasm hook is not found once')
wasmoon = wasmoon.replace(hook, 'function Ta(a,b){var c=M;if(globalThis.__WASMOON_BINARY)return WebAssembly.instantiate(globalThis.__WASMOON_BINARY,a).then(b);return ')
const wasm = fs.readFileSync(path.join(WASMOON, 'glue.wasm'))

// every horn renders, stays finite, holds its attack before the loop and loops without a step at the seam
async function selfTest() {
  globalThis.__WASMOON_BINARY = null
  const { LuaFactory } = require(path.join(WASMOON, 'index.js'))
  const L = await new LuaFactory().createEngine()
  let res = null, buf = []
  L.global.set('__result', (s) => { res = s })
  L.global.set('__push', (...xs) => { for (const x of xs) buf.push(x) })
  for (const f of files) await L.doString(f.src)
  await L.doString('STUDIO.defaults()')
  const cfg = JSON.parse(res)
  await L.doString('__result(CAR_HORN.Synth.LOOP_SECONDS)')
  const loopSeconds = res
  let bad = 0
  const fail = (t) => { bad++; console.log('FAIL', t) }
  for (const inside of [false, true]) {
    for (const id of Object.keys(cfg.horns)) {
      buf = []
      const t0 = Date.now()
      await L.doString(`STUDIO.render(CAR_HORN.CONFIG.horns[${JSON.stringify(id)}], CAR_HORN.CONFIG, ${inside})`)
      const ms = Date.now() - t0
      const { sr, loopStart } = JSON.parse(res)
      const n = buf.length
      const name = id + (inside ? ' (inside)' : '')
      let peak = 0
      for (let i = 0; i < n; i++) {
        if (!Number.isFinite(buf[i])) { fail(name + ': not finite'); break }
        peak = Math.max(peak, Math.abs(buf[i]))
      }
      // the step from the loop's end back to its start against the steps right beside it
      const seam = Math.abs(buf[loopStart] - buf[n - 1])
      const near = Math.max(Math.abs(buf[loopStart + 1] - buf[loopStart]), Math.abs(buf[n - 1] - buf[n - 2]))
      console.log(`${name.padEnd(18)} attack ${(loopStart / sr).toFixed(3)} s + loop ${((n - loopStart) / sr).toFixed(3)} s, peak ${peak.toFixed(2)}, seam step ${seam.toFixed(3)} (beside it ${near.toFixed(3)}), ${ms} ms`)
      if (n - loopStart !== Math.round(loopSeconds * sr)) fail(name + ': the loop is not LOOP_SECONDS long')
      if (loopStart < Math.round((cfg.horns[id].attack.time || 0) * sr)) fail(name + ': the loop starts inside the attack')
      if (peak < 0.9 || peak > 0.96) fail(name + ': not normalized')
      if (seam > near * 1.5 + 0.01) fail(name + ': the loop jumps at the seam')
      // stricter: the settle before the loop is fed what the loop's end is, so the two should match
      let settleDiff = 0
      for (let k = 1; k <= 64; k++) settleDiff = Math.max(settleDiff, Math.abs(buf[loopStart - k] - buf[n - k]))
      if (settleDiff > 0.002) fail(name + `: the sound before the loop differs from its end by ${settleDiff.toFixed(4)}`)
    }
  }
  console.log(bad ? `${bad} check(s) FAILED` : 'all horns loop cleanly')
  if (bad) process.exit(1)
}

function build() {
  const t = fs.readFileSync(path.join(HERE, 'template.html'), 'utf8')
  for (const [name, src] of [...files.map((f) => [f.name, f.src]), ['wasmoon', wasmoon]]) {
    if (src.toLowerCase().includes('</script')) throw new Error(name + " holds </script: it would end the page's script tag")
  }
  const lua = files.map((f) => `<script type="text/x-lua" data-name="${f.name}">${f.src}</script>`).join('\n')
  const parts = {
    '{{LUA_FILES}}': lua,
    '{{WASMOON}}': wasmoon,
    '{{WASM_B64}}': wasm.toString('base64'),
    '{{CONFIG_HEADER}}': JSON.stringify(header).replace(/</g, '\\u003c'),
  }
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
  build()
  process.exit(0)
})().catch((e) => { console.error(e); process.exit(1) })
