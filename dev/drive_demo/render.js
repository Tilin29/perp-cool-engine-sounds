/*
  Offline drive demo: the addon's real drivetrain (sh_drivetrain.lua, fitted gears from
  sh_presets.lua) runs a scripted drive, and the car's baked WAVs are mixed the way cl_engine.lua
  plays them (log-spaced band cross-fade with pitch, on/off throttle layers, limiter loop, turbo
  whistle and blow-off, supercharger whine, road and wind, start-up one-shot, pops on a lift).
  The car's speed comes from the gear spacing's acceleration model (E.GearAccel), not Source.
  Heard from the driver's seat: no Doppler, pass-by or headroom.

    node dev/drive_demo/render.js "Audi S5" "Volvo S60" ...   -> dev/drive_demo/out/<car>.wav
*/
const fs = require('fs'), path = require('path')
const { LuaFactory } = require(path.resolve(__dirname, '../baker/node_modules/wasmoon'))
const ADDON = path.resolve(__dirname, '../..'), LUA = path.join(ADDON, 'lua/audio_engine')
const OUT = path.join(__dirname, 'out'); fs.mkdirSync(OUT, { recursive: true })
const SR = 44100, FPS = 60

function readWav(f) {
  const b = fs.readFileSync(f); let o = 12, sr = 44100, ch = 1, bits = 16, data
  while (o < b.length) { const id = b.toString('ascii', o, o + 4), n = b.readUInt32LE(o + 4)
    if (id === 'fmt ') { ch = b.readUInt16LE(o + 10); sr = b.readUInt32LE(o + 12); bits = b.readUInt16LE(o + 22) }
    if (id === 'data') data = b.subarray(o + 8, o + 8 + n)
    o += 8 + n + (n & 1) }
  const len = data.length / (bits / 8) / ch, s = new Float32Array(len)
  for (let i = 0; i < len; i++) s[i] = bits === 16 ? data.readInt16LE(i * 2 * ch) / 32768 : (data[i * ch] - 128) / 128
  return { s, sr }
}
function writeWav(f, x) {
  const b = Buffer.alloc(44 + x.length * 2)
  b.write('RIFF', 0); b.writeUInt32LE(36 + x.length * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16)
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28)
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(x.length * 2, 40)
  for (let i = 0; i < x.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, x[i])) * 32767), 44 + i * 2)
  fs.writeFileSync(f, b)
}

const LUA_DRIVE = `
local E, DT = AUDIO_ENGINE, AUDIO_ENGINE.Drivetrain
local name = CAR_NAME
local m = E.CAR_MODELS[name]; local car = m and E.Cars[m[1]]
if not car then __result("ERR no car " .. name) return end
local p = PHYS[m[2]]
local c = {} for k, v in pairs(car) do c[k] = v end
c.topSpeed = math.min(400, math.max(40, math.floor(p.mph * 1.609344 / 5 + 0.5) * 5))
c.powerKg = math.floor(p.hp * 745.7 / p.mass + 0.5)
local cfg = E.ResolveProfile(c)
local bk = E.BAKED[cfg.soundKey] or (cfg.familyKey and E.BAKED[E.BAKED_FAMILY[cfg.familyKey] or ""])
if not bk then __result("ERR no baked bank") return end
local st = DT.New(); DT.Start(st, cfg.emotionStart)
local dt, t, v, out = 1 / ${FPS}, 0, 0, {}
local vmax = cfg.topSpeed / 3.6
-- the drive: start-up, idle, full throttle to ~93% of top speed (at most 26 s), lift and coast, brake to a stop, idle
local stage, stageT, pullT = "start", 0, 0
while t < 60 do
	local inp = { v = v }
	if stage == "start" then if st.phase == "run" then stageT = stageT + dt end if stageT > 1.2 then stage, stageT = "pull", 0 end
	elseif stage == "pull" then inp.fwd = true; pullT = pullT + dt
		if v > vmax * 0.93 or pullT > 26 then stage, stageT = "coast", 0 end
	elseif stage == "coast" then stageT = stageT + dt; if stageT > 3 then stage, stageT = "brake", 0 end
	elseif stage == "brake" then inp.back = v > 0.3; if v < 0.05 then stage, stageT = "idle", 0 end
	elseif stage == "idle" then stageT = stageT + dt; if stageT > 2 then break end end
	DT.Step(st, cfg, dt, inp)
	local drive = st.phase == "run" and st.on
	if inp.fwd and drive then v = v + E.GearAccel(v, vmax, cfg.powerKg) * dt * (st.shiftT > 0 and 0.3 or 1)
	elseif inp.back then v = math.max(0, v - 7 * dt)
	else v = math.max(0, v - (0.4 + 0.0006 * v * v) * dt) end
	local limTarget = (drive and st.gear == 0 and st.limHold > 0 and st.lastPedal and st.rpm > cfg.redline * 0.9) and 1 or 0
	out[#out + 1] = string.format("%.1f,%.3f,%d,%.3f,%d,%.3f,%.3f,%d,%.3f", st.rpm, st.soundThr, st.gear, v, limTarget,
		st.boost or 0, st.bovEvent or 0, (st.phase == "run") and 1 or 0, st.cut and 1 or 0)
	t = t + dt
end
local L = {} for i, r in ipairs(bk.layers) do L[i] = r end
local tr = {} for i, r in ipairs(bk.trims or {}) do tr[i] = r end
local se = {} for fk, s in pairs(bk.startEmoAt or {}) do se[#se + 1] = fk .. ":" .. s.fadeAt .. ":" .. s.dur end
local ends, K = {}, 60 / (2 * math.pi * cfg.wheelRadius)
for i, g in ipairs(cfg.gears) do ends[i] = string.format("%.0f", cfg.redline / (K * g * cfg.final) * 3.6) end
__result(table.concat({ bk.dir, table.concat(L, " "), table.concat(tr, " "), bk.limiter or cfg.redline, cfg.redline,
	bk.start.fadeAt, bk.start.dur, bk.startEmo and bk.startEmo.fadeAt or 0, bk.startEmo and bk.startEmo.dur or 0, table.concat(se, " "),
	cfg.emotionStart and 1 or 0, string.format("%.0f", DT.EmotionFlare(cfg)), cfg.turbo and 1 or 0, cfg.profile.bov and 1 or 0,
	cfg.supercharger or "", cfg.scPitch or 1, cfg.profile.pops or 0, bk.pops or 0, cfg.volume or 1, cfg.topSpeed, table.concat(ends, "/"),
	cfg.engineName, table.concat(out, ";") }, "|"))
`

;(async () => {
  const L = await new LuaFactory().createEngine(); let res = ''; L.global.set('__result', v => { res = v })
  await L.doString(`math.Clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
    IsValid=function(e) return e~=nil end; ErrorNoHalt=print; CLIENT=true; SERVER=false; table.Copy=function(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
    AUDIO_ENGINE={}; local E=AUDIO_ENGINE; E.Cars={}; function E.RegisterCar(m,c) c.model=m; E.Cars[m]=c; return c end`)
  for (const f of ['sh_presets.lua', 'sh_drivetrain.lua', 'sh_carlist.lua', 'cl_baked.lua']) await L.doString(fs.readFileSync(path.join(LUA, f), 'utf8'))
  const phys = fs.readFileSync(path.join(LUA, 'sv_perp_physics.lua'), 'utf8'); let pl = 'PHYS={}\n'
  for (const b of phys.split('\n\t["').slice(1)) { const s = b.split('"]')[0], g = k => { const m = b.match(new RegExp(k + ' = ([\\d.]+)')); return m ? +m[1] : 0 }
    pl += `PHYS[${JSON.stringify(s)}]={hp=${g('horsepower')},mph=${g('maxspeed')},mass=${g('massoverride') || 1500}}\n` }
  await L.doString(pl)
  const env = path.join(ADDON, 'sound/audio_engine', (fs.readdirSync(path.join(ADDON, 'sound/audio_engine')).find(d => d.startsWith('env_'))))
  const cache = {}; const W = f => cache[f] || (cache[f] = readWav(f))
  for (const name of process.argv.slice(2)) {
    L.global.set('CAR_NAME', name); res = ''
    await L.doString(LUA_DRIVE)
    if (res.startsWith('ERR')) { console.log(name, res); continue }
    const f = res.split('|')
    const [dir, layersS, trimsS, limRpm, redline, sFade, sDur, eFade, eDur, emoS, emo, flare, turbo, bov, sc, scPitch, pops, nPops, volume, top, ends, engine, framesS] = f
    const layers = layersS.split(' ').map(Number), trims = trimsS ? trimsS.split(' ').map(Number) : layers.map(() => 1)
    const frames = framesS.split(';').map(r => r.split(',').map(Number))
    const D = path.join(ADDON, 'sound/audio_engine', dir), red = +redline
    const on = layers.map((_, i) => W(path.join(D, `b${i + 1}on.wav`))), off = layers.map((_, i) => W(path.join(D, `b${i + 1}off.wav`)))
    const lim = W(path.join(D, 'lim.wav')), road = W(path.join(env, 'road.wav')), wind = W(path.join(env, 'wind.wav')), turboW = W(path.join(env, 'turbo.wav'))
    // the start-up one-shot: the emotion start's closest flare variant
    let startF = path.join(D, 'start.wav'), fadeAt = +sFade, sdur = +sDur
    if (+emo) { startF = path.join(D, 'starte.wav'); fadeAt = +eFade; sdur = +eDur
      let best = null; for (const s of emoS ? emoS.split(' ') : []) { const [fk, fa, du] = s.split(':').map(Number); if (!best || Math.abs(fk - flare) < Math.abs(best[0] - flare)) best = [fk, fa, du] }
      if (best && Math.abs(best[0] - flare) < Math.abs(+flare - 0)) { const p = path.join(D, `starte_${best[0]}.wav`); if (fs.existsSync(p)) { startF = p; fadeAt = best[1]; sdur = best[2] } } }
    const start = W(startF)
    const SCB = [375, 750, 1500, 3000, 6000]
    const scOn = sc ? SCB.map((_, k) => W(path.join(env, `sc_${sc}_${k + 1}.wav`))) : null, scOff = sc ? SCB.map((_, k) => W(path.join(env, `sc_${sc}_${k + 1}_off.wav`))) : null
    const popsW = []; for (let i = 1; i <= +nPops; i++) popsW.push(W(path.join(D, `pop${i}.wav`)))
    const N = Math.ceil(frames.length * SR / FPS) + SR, out = new Float32Array(N)
    // a voice: a loop (or one-shot) played at a pitch, its volume gliding per sample
    const voices = new Map()
    function voice(key, w, loop) { let vo = voices.get(key); if (!vo) { vo = { w, pos: 0, vol: 0, loop, pitch: 1 }; voices.set(key, vo) } return vo }
    const shots = []
    const spf = SR / FPS; let thrS = 0, limW = 0, xr = null, loopGain = 0, scThr = 0, lastThr = 0, popUntil = -1, nextPop = 0, rr = Math.random
    let seed = 7; rr = () => (seed = (seed * 16807) % 2147483647) / 2147483647
    shots.push({ w: start, pos: 0, vol: 0.9, pitch: 1 })
    let tPhase = null
    for (let fi = 0; fi < frames.length; fi++) {
      const [rpm0, sThr, gear, v, limT, boost, bovE, run, cut] = frames[fi]; const dt = 1 / FPS, t = fi * dt
      const rpm = Math.max(rpm0, 50)
      // loops muted until the start one-shot reaches its fade point
      const target = t < fadeAt ? 0 : 1; const rate = t < fadeAt ? 8 : 1 / Math.max(0.05, sdur - fadeAt)
      loopGain += Math.max(-rate * dt, Math.min(rate * dt, target - loopGain))
      thrS += (sThr - thrS) * Math.min(1, dt * 12)
      limW += Math.max(-dt / 0.03, Math.min(dt / 0.06, limT - limW))
      const lr = Math.log(rpm); xr = xr == null ? lr : xr + (lr - xr) * Math.min(1, dt * 20)
      const w = new Array(layers.length).fill(0), n = layers.length
      if (Math.exp(xr) <= layers[0]) w[0] = 1; else if (Math.exp(xr) >= layers[n - 1]) w[n - 1] = 1
      else for (let i = 0; i < n - 1; i++) if (Math.exp(xr) < layers[i + 1]) { const x = (xr - Math.log(layers[i])) / (Math.log(layers[i + 1]) - Math.log(layers[i])); w[i] = Math.cos(x * Math.PI / 2); w[i + 1] = Math.sin(x * Math.PI / 2); break }
      const g = 0.62 * loopGain * +volume
      for (let i = 0; i < n; i++) {
        const wi = w[i] * (1 - limW) * g * trims[i], pitch = Math.min(2.5, rpm / layers[i])
        const a = voice('on' + i, on[i], true), b = voice('off' + i, off[i], true)
        a.target = wi * thrS; b.target = wi * (1 - thrS); a.pitch = b.pitch = pitch
      }
      const lv = voice('lim', lim, true); lv.target = limW * g; lv.pitch = red / +limRpm
      const kmh = v * 3.6, rrd = Math.min(1, Math.max(0, (kmh - 3) / 120))
      const rv = voice('road', road, true); rv.target = 0.5 * rrd ** 1.2 * 0.7 * (1 - 0.45 * Math.min(1, Math.max(0, (kmh - 60) / 100))) * loopGain; rv.pitch = 0.8 + 0.3 * rrd
      const wv = voice('wind', wind, true); wv.target = 0.5 * Math.min(1, Math.max(0, (kmh - 80) / 240)) ** 2 * 0.015; wv.pitch = 1
      if (+turbo) { const tv = voice('turbo', turboW, true); tv.target = g * boost ** 1.5 * 0.5; tv.pitch = (0.45 + 0.55 * boost) * (0.9 + 0.2 * rpm / red)
        if (bovE > 0 && +bov) shots.push({ w: W(path.join(env, rr() < 0.5 ? 'bov1.wav' : 'bov2.wav')), pos: 0, vol: g * Math.min(1, bovE * 1.2) * 0.5, pitch: 0.95 + 0.1 * rr(), at: fi }) }
      if (scOn) {
        const scRpm = rpm + (red * 0.985 - rpm) * limW, scE = +scPitch * scRpm
        let lo = 0, wl = 1, wh = 0
        if (scE >= SCB[SCB.length - 1]) lo = SCB.length - 1; else if (scE > SCB[0]) for (let k = 0; k < SCB.length - 1; k++) if (scE < SCB[k + 1]) { const x = Math.log(scE / SCB[k]) / Math.log(SCB[k + 1] / SCB[k]); lo = k; wl = Math.cos(x * Math.PI / 2); wh = Math.sin(x * Math.PI / 2); break }
        const share = kmh / Math.max(+top, 30), fast = Math.min(1, Math.max(0, (share - 0.4) / 0.4))
        const scVol = g * 0.7 * Math.min(1, scRpm / red) ** 0.9 * (1 - 0.6 * fast) * (run ? 1 : 0)
        const bypT = Math.max(sThr, cut ? 1 : 0); scThr += Math.max(-dt / 0.1, Math.min(dt / 0.15, bypT - scThr))
        for (let k = 0; k < SCB.length; k++) { const wk = k === lo ? wl : k === lo + 1 ? wh : 0
          const a = voice('sc' + k, scOn[k], true), b = voice('sco' + k, scOff[k], true)
          a.target = scVol * wk * scThr; b.target = scVol * wk * (1 - scThr) * 0.5; a.pitch = b.pitch = Math.min(2.55, scE / SCB[k]) }
      }
      // pops: lifting off above half redline starts a burble that thins out over (0.8 + 2.2 x pops) s
      if (+pops > 0 && popsW.length) {
        if (lastThr > 0.5 && sThr < 0.2 && rpm > red * 0.5) { popUntil = t + 0.8 + 2.2 * pops; nextPop = t + 0.12 + 0.18 * rr() }
        if (t < popUntil && t >= nextPop && sThr < 0.2 && rpm > red * 0.3) {
          const left = (popUntil - t) / (0.8 + 2.2 * pops)
          if (rr() < 0.35 + 0.6 * pops) shots.push({ w: popsW[Math.floor(rr() * popsW.length)], pos: 0, vol: 0.7 * g * (0.5 + 0.5 * left), pitch: 0.92 + 0.16 * rr(), at: fi })
          nextPop = t + (0.04 + 0.2 * rr()) / Math.max(0.3, left)
        }
      }
      lastThr = sThr
      // render this frame
      const s0 = Math.round(fi * spf), s1 = Math.round((fi + 1) * spf)
      for (const vo of voices.values()) {
        const tg = vo.target || 0, step = vo.w.sr / SR * vo.pitch, len = vo.w.s.length
        if (tg === 0 && vo.vol < 1e-4) { vo.vol = 0; vo.pos = (vo.pos + step * (s1 - s0)) % len; continue }
        const dv = (tg - vo.vol) / (s1 - s0)
        for (let i = s0; i < s1; i++) { let p = vo.pos, k = Math.floor(p), fr = p - k
          out[i] += vo.vol * (vo.w.s[k % len] * (1 - fr) + vo.w.s[(k + 1) % len] * fr)
          vo.pos = (p + step) % len; vo.vol += dv }
      }
      for (const sh of shots) { if (sh.done || (sh.at != null && sh.at > fi)) continue
        const step = sh.w.sr / SR * sh.pitch
        for (let i = s0; i < s1; i++) { const k = Math.floor(sh.pos); if (k + 1 >= sh.w.s.length) { sh.done = true; break }
          const fr = sh.pos - k; out[i] += sh.vol * (sh.w.s[k] * (1 - fr) + sh.w.s[k + 1] * fr); sh.pos += step } }
    }
    // a gentle bus limiter so peaks lining up don't clip, then a short fade at the end
    let env2 = 0, pk = 0
    for (let i = 0; i < N; i++) { const a = Math.abs(out[i]); env2 = a > env2 ? a : env2 * 0.9995; const gg = env2 > 0.9 ? 0.9 / env2 : 1; out[i] *= gg; pk = Math.max(pk, Math.abs(out[i])) }
    const endS = Math.round(frames.length * spf); for (let i = 0; i < SR / 4; i++) { const j = endS - SR / 4 + i; if (j >= 0 && j < N) out[j] *= 1 - i / (SR / 4) }
    const file = path.join(OUT, name.replace(/[^\w]+/g, '_') + '.wav')
    writeWav(file, out.subarray(0, endS))
    if (process.env.TRACE) for (let fi = 0; fi < frames.length; fi += 30) console.log((fi / FPS).toFixed(1), frames[fi].slice(0, 4).map(x => x.toFixed(2)).join(" "))
    const gearsUsed = new Set(frames.map(r => r[2]).filter(x => x > 0))
    console.log(`${name}: ${engine}, top ${top} km/h, gears end at ${ends} km/h, used ${Math.max(...gearsUsed)}; ${(endS / SR).toFixed(1)} s -> ${path.relative(ADDON, file)}`)
  }
})()
