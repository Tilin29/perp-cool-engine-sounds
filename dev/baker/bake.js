/*
  Audio Engine baker: renders every registered car's stock engine to WAV files, using the addon's
  own Lua (synth + sound bank) in Lua 5.4 / wasmoon, and writes the manifest the game reads.

    cd dev/baker && npm install        (once: wasmoon@1.16.0)
    node bake.js                       all engines, 44100 Hz, one worker per CPU core
    node bake.js --rate 22050          half the size
    node bake.js --jobs 4 --only 3     limit workers / bake just engine #3 (no manifest, for testing)
    node bake.js --list                print the engine numbers and exit

  Output (inside the addon):
    sound/audio_engine/<dir>/*.wav      one folder per engine (+ env_<hash>/ for road, wind, turbo)
    lua/audio_engine/cl_baked.lua       what each folder holds (loop rpm points, peaks, timings)

  One bank per engine family: cars whose engines differ only in redline share the bank baked at
  the family's highest redline (plus an emotion start per flare rpm, which follows redline).
  Folders are <preset>_<redline>_<hash> (cars with the same engine share one). The hash covers the
  sound key and the synth sources, so after any synth change a re-bake gives new file names and
  clients never play a stale cached copy.
*/
const fs = require('fs')
const path = require('path')
const os = require('os')
const crypto = require('crypto')
const { fork } = require('child_process')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.join(ADDON, 'lua', 'audio_engine')
const SOUND_OUT = path.join(ADDON, 'sound', 'audio_engine')
const MANIFEST = path.join(LUA, 'cl_baked.lua')
const ADDON_FILES = ['sh_config.lua', 'sh_presets.lua', 'sh_drivetrain.lua', 'sh_carlist.lua', 'cl_synth.lua', 'cl_soundbank.lua']

function arg(name, def) {
  const i = process.argv.indexOf('--' + name)
  return i > 0 ? process.argv[i + 1] : def
}
const RATE = parseInt(arg('rate', '44100'), 10)
const JOBS = parseInt(arg('jobs', String(Math.max(1, os.cpus().length - 1))), 10)
const ONLY = arg('only', null)

// anything that changes how the sound is rendered
function synthVersion() {
  const h = crypto.createHash('sha1')
  for (const f of ['cl_synth.lua', 'cl_soundbank.lua', 'sh_presets.lua']) h.update(fs.readFileSync(path.join(LUA, f)))
  h.update(String(RATE))
  return h.digest('hex').slice(0, 10)
}

// 16-bit mono PCM; a loop gets a 'cue ' point where sound.Generate would start its loop
function writeWav(file, rate, loopStart, data) {
  const n = data.length
  const pcm = Buffer.alloc(n * 2)
  for (let i = 0; i < n; i++) {
    let v = Math.round(Math.max(-1, Math.min(1, data[i])) * 32767)
    pcm.writeInt16LE(v, i * 2)
  }
  const chunks = []
  const fmt = Buffer.alloc(24)
  fmt.write('fmt ', 0); fmt.writeUInt32LE(16, 4); fmt.writeUInt16LE(1, 8); fmt.writeUInt16LE(1, 10)
  fmt.writeUInt32LE(rate, 12); fmt.writeUInt32LE(rate * 2, 16); fmt.writeUInt16LE(2, 20); fmt.writeUInt16LE(16, 22)
  chunks.push(fmt)
  if (loopStart >= 0) {
    const cue = Buffer.alloc(8 + 4 + 24)
    cue.write('cue ', 0); cue.writeUInt32LE(4 + 24, 4); cue.writeUInt32LE(1, 8)
    cue.writeUInt32LE(1, 12)            // cue id
    cue.writeUInt32LE(loopStart, 16)    // play order position
    cue.write('data', 20)               // chunk id
    cue.writeUInt32LE(0, 24)            // chunk start
    cue.writeUInt32LE(0, 28)            // block start
    cue.writeUInt32LE(loopStart, 32)    // sample offset
    chunks.push(cue)
  }
  const dh = Buffer.alloc(8)
  dh.write('data', 0); dh.writeUInt32LE(pcm.length, 4)
  chunks.push(dh, pcm)
  const body = Buffer.concat(chunks)
  const riff = Buffer.alloc(12)
  riff.write('RIFF', 0); riff.writeUInt32LE(4 + body.length, 4); riff.write('WAVE', 8)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, Buffer.concat([riff, body]))
  return 12 + body.length
}

async function newLua() {
  const { LuaFactory } = require('wasmoon')
  const L = await new LuaFactory().createEngine()
  const g = L.global
  let cur = null, pos = 0, bytes = 0
  g.set('__now', () => performance.now())
  g.set('__log', (s) => { if (!String(s).startsWith('[Audio Engine]')) console.log('  lua:', String(s)) })
  g.set('__genBegin', (name, rate, loop, n) => { cur = { name, rate, loop, data: new Float32Array(n) }; pos = 0 })
  g.set('__push', (...xs) => { const d = cur.data; for (let i = 0; i < xs.length; i++) d[pos++] = xs[i] })
  g.set('__genEnd', () => { bytes += writeWav(path.join(SOUND_OUT, cur.name + '.wav'), cur.rate, cur.loop, cur.data); cur = null })
  let res = null
  g.set('__result', (v) => { res = v })
  // results come back through __result: wasmoon leaks stack slots on doString return values
  const call = async (lua) => { res = null; await L.doString(lua); return res }
  const run = async (file, src) => {
    try { await L.doString(src) } catch (e) { throw new Error(file + ': ' + e.message) }
  }
  await run('bake_shim.lua', fs.readFileSync(path.join(__dirname, 'bake_shim.lua'), 'utf8'))
  for (const f of ADDON_FILES) await run(f, fs.readFileSync(path.join(LUA, f), 'utf8'))
  await run('bake_main.lua', fs.readFileSync(path.join(__dirname, 'bake_main.lua'), 'utf8'))
  return { call, bytes: () => bytes }
}

// worker: bake the engines it is given and send back their manifest entries
async function worker() {
  const { call, bytes } = await newLua()
  const version = process.env.BAKE_VERSION
  await call(`BAKE.list(${JSON.stringify(version)})`)
  process.on('message', async (m) => {
    try {
      if (m.env) {
        await call(`BAKE.bakeEnv(${JSON.stringify(version)})`)
        process.send({ env: await call('__result(BAKE.envEntry())'), bytes: bytes() })
        return
      }
      const t0 = Date.now()
      const b0 = bytes()
      const bands = await call(`__result(BAKE.bake(${m.i}, ${RATE}))`)
      const entry = await call(`__result(BAKE.entry(${m.i}))`)
      process.send({ i: m.i, entry, bands, secs: (Date.now() - t0) / 1000, bytes: bytes() - b0 })
    } catch (e) {
      process.send({ i: m.i, error: e.message })
    }
  })
  process.send({ ready: true })
}

async function main() {
  const version = synthVersion()
  const { call } = await newLua()
  const n = await call(`__result(BAKE.list(${JSON.stringify(version)}))`)
  const items = []
  for (let i = 1; i <= n; i++) {
    const [dir, engine, cars, names] = (await call(`__result(BAKE.info(${i}))`)).split('\t')
    items.push({ i, dir, engine, cars, names })
  }
  if (process.argv.includes('--list')) {
    for (const it of items) console.log(`  #${it.i} ${it.dir} ${it.engine}: ${it.names}`)
    return
  }
  console.log(`${n} stock engine families at ${RATE} Hz, synth version ${version}, ${JOBS} workers`)
  let todo = items
  if (ONLY) todo = items.filter((it) => it.i === parseInt(ONLY, 10))
  else if (fs.existsSync(SOUND_OUT)) {
    // empty it rather than delete it (Windows refuses while anything has the folder open)
    for (const d of fs.readdirSync(SOUND_OUT)) fs.rmSync(path.join(SOUND_OUT, d), { recursive: true, force: true })
  }

  const entries = new Array(n + 1)
  let envEntry = null, total = 0, done = 0, failed = 0
  const queue = todo.slice()
  const t0 = Date.now()
  await new Promise((resolve) => {
    let live = 0
    const workers = Math.min(JOBS, queue.length + (ONLY ? 0 : 1))
    let envSent = !!ONLY
    for (let w = 0; w < workers; w++) {
      const cp = fork(__filename, ['--worker', '--rate', String(RATE)], { env: { ...process.env, BAKE_VERSION: version } })
      live++
      const next = () => {
        if (!envSent) { envSent = true; cp.send({ env: true }); return }
        const it = queue.shift()
        if (it) cp.send({ i: it.i }); else cp.kill()
      }
      cp.on('message', (m) => {
        if (m.ready) return next()
        if (m.env) { envEntry = m.env; total += m.bytes; console.log('  env bank done') }
        else if (m.error) { failed++; console.log(`  #${m.i} FAILED: ${m.error}`) }
        else {
          entries[m.i] = m.entry; total += m.bytes; done++
          const it = items[m.i - 1]
          console.log(`  [${done}/${todo.length}] ${it.engine} (${it.dir}, ${m.bands} bands) ${m.secs.toFixed(1)}s ` +
            `${(m.bytes / 1048576).toFixed(1)} MB: ${it.names}`)
        }
        next()
      })
      cp.on('exit', () => { if (--live === 0) resolve() })
    }
  })
  console.log(`baked ${done} engines, ${(total / 1048576).toFixed(1)} MB, ${((Date.now() - t0) / 1000).toFixed(0)} s` +
    (failed ? `, ${failed} FAILED` : ''))
  if (ONLY || failed) { console.log('manifest not written'); process.exit(failed ? 1 : 0) }
  const header = await call(`__result(BAKE.header(${JSON.stringify(version)}))`)
  const families = await call('__result(BAKE.familyEntry())')
  const body = [header + envEntry, families + 'E.BAKED = {', ...entries.slice(1), '}', ''].join('\n')
  fs.writeFileSync(MANIFEST, body)
  console.log('wrote', path.relative(ADDON, MANIFEST))
}

;(process.argv.includes('--worker') ? worker() : main()).catch((e) => { console.error(e); process.exit(1) })
