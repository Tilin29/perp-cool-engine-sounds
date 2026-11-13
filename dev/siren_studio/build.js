/*
  Builds dev/siren_studio.html: one self-contained page (wasmoon, its wasm, the siren's Lua and the
  page) that opens straight from disk. It runs lua/police_siren's own synth, so it plays what the
  game will. Rebuild after changing the siren's synth or its settings file.

    cd dev/baker && npm install      (once: wasmoon@1.16.0, shared with the baker)
    node dev/siren_studio/build.js           build
    node dev/siren_studio/build.js --test    also render every tone in Node and check the loops
*/
const fs = require('fs')
const path = require('path')

const HERE = __dirname
const ADDON = path.resolve(HERE, '..', '..')
const LUA = path.join(ADDON, 'lua', 'police_siren')
const WASMOON = path.join(ADDON, 'dev', 'baker', 'node_modules', 'wasmoon', 'dist')
const OUT = path.join(ADDON, 'dev', 'siren_studio.html')

const configSrc = fs.readFileSync(path.join(LUA, 'sh_siren_config.lua'), 'utf8')
const files = [
  { name: 'sh_siren_config.lua', src: configSrc },
  { name: 'cl_siren_synth.lua', src: fs.readFileSync(path.join(LUA, 'cl_siren_synth.lua'), 'utf8') },
  { name: 'studio.lua', src: fs.readFileSync(path.join(HERE, 'studio.lua'), 'utf8') },
]
// the settings file's header comment: the page writes it above the exported settings
const at = configSrc.indexOf('POLICE_SIREN.CONFIG =')
if (at < 0) throw new Error('sh_siren_config.lua has no POLICE_SIREN.CONFIG =')
const header = configSrc.slice(0, at)

let wasmoon = fs.readFileSync(path.join(WASMOON, 'index.js'), 'utf8')
// hand emscripten the embedded wasm bytes instead of letting it fetch glue.wasm
const hook = 'function Ta(a,b){var c=M;return '
if (wasmoon.split(hook).length !== 2) throw new Error('wasmoon changed: the wasm hook is not found once')
wasmoon = wasmoon.replace(hook, 'function Ta(a,b){var c=M;if(globalThis.__WASMOON_BINARY)return WebAssembly.instantiate(globalThis.__WASMOON_BINARY,a).then(b);return ')
const wasm = fs.readFileSync(path.join(WASMOON, 'glue.wasm'))

// every tone renders, stays finite, is as long as its pattern and loops without a step at the seam
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
  let bad = 0
  const fail = (t) => { bad++; console.log('FAIL', t) }
  for (const id of Object.keys(cfg.tones)) {
    buf = []
    const t0 = Date.now()
    await L.doString(`STUDIO.render(POLICE_SIREN.CONFIG.tones[${JSON.stringify(id)}], POLICE_SIREN.CONFIG)`)
    const ms = Date.now() - t0
    const sr = res, n = buf.length
    const T = cfg.tones[id].pattern.reduce((s, p) => s + (p.glide || 0) + (p.hold || 0), 0)
    let peak = 0
    for (let i = 0; i < n; i++) {
      if (!Number.isFinite(buf[i])) { fail(id + ': not finite'); break }
      peak = Math.max(peak, Math.abs(buf[i]))
    }
    // the step across the seam against the steps right beside it (a loop that doesn't line up jumps there)
    const seam = Math.abs(buf[0] - buf[n - 1])
    const near = Math.max(Math.abs(buf[1] - buf[0]), Math.abs(buf[n - 1] - buf[n - 2]))
    console.log(`${id.padEnd(8)} ${(n / sr).toFixed(3)} s, peak ${peak.toFixed(2)}, seam step ${seam.toFixed(3)} (beside it ${near.toFixed(3)}), ${ms} ms`)
    if (Math.abs(n / sr - Math.max(T, 0.05)) > 2 / sr) fail(id + ': loop length is not the pattern length')
    if (peak < 0.9 || peak > 0.96) fail(id + ': not normalized')
    if (seam > near * 1.5 + 0.01) fail(id + ': the loop jumps at the seam')
    // the pitch, a millisecond at a time and across the seam: a leap is heard as a cut (the wail's
    // old spin-up curve jumped 1.8 semitones in its first millisecond)
    await L.doString(`
      local Synth = POLICE_SIREN.Synth
      local tone = POLICE_SIREN.CONFIG.tones[${JSON.stringify(id)}]
      local segments, loopSeconds = Synth.Segments(tone.pattern)
      local function frequencyAt(time)
        for _, segment in ipairs(segments) do
          if time < segment.endTime or segment == segments[#segments] then
            if segment.startHz == segment.endHz then return segment.startHz end
            local progress = Synth.GlideShape((time - segment.startTime) / (segment.endTime - segment.startTime), segment.curve)
            if tone.logGlide ~= false then return segment.startHz * (segment.endHz / segment.startHz) ^ progress end
            return segment.startHz + (segment.endHz - segment.startHz) * progress
          end
        end
      end
      local worst, previous = 0, frequencyAt(loopSeconds - 0.001)
      for step = 0, math.floor(loopSeconds * 1000) - 1 do
        local frequency = frequencyAt(step / 1000)
        worst = math.max(worst, math.abs(12 * math.log(frequency / previous, 2)))
        previous = frequency
      end
      __result(worst)`)
    const leap = res
    console.log(`         pitch moves at most ${leap.toFixed(2)} semitones in a millisecond`)
    if (leap > 0.75) fail(id + ': the pitch leaps (heard as a cut)')
  }
  console.log(bad ? `${bad} check(s) FAILED` : 'all tones loop cleanly')
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
