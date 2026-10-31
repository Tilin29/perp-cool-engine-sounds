/*
  Offline checks of the PERP integration, running the addon's real Lua:
    1. sh_perp.lua against PERP's vehicle scripts: which TDM engine soundscripts get muted
    2. cl_soundbank.lua with cl_baked.lua: every car's stock engine loads from baked files,
       and every file a bank refers to exists

    node test_integration.js <mount folder>...

  Each mount folder stands for a mounted addon (holding models/, scripts/...), like the game's
  GAME path: e.g. the extracted PERP dev pack (its scripts/vehicles/) and the TDM content
  (workshop 2103606343/content, the car models). This addon is always mounted first.
  Without the dev pack, every car must fall back to the generic test script.
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.join(ADDON, 'lua', 'audio_engine')
const MOUNTS = [ADDON, ...process.argv.slice(2)]
if (MOUNTS.length < 2) { console.log('usage: node test_integration.js <mount folder>...'); process.exit(2) }

// GAME path lookup: the first mount holding the file (or, for file.Find, the folder)
function gamePath(p) {
  p = p.replace(/\\/g, '/').toLowerCase()
  for (const m of MOUNTS) if (fs.existsSync(path.join(m, p))) return path.join(m, p)
  for (const m of MOUNTS) if (fs.existsSync(path.dirname(path.join(m, p)))) return path.join(m, p)
  return path.join(ADDON, p)
}
// file.Find merges a folder across every mount
function findAll(pat) {
  pat = pat.replace(/\\/g, '/').toLowerCase()
  const re = new RegExp('^' + path.basename(pat).replace(/\./g, '\\.').replace(/\*/g, '.*') + '$', 'i')
  const out = new Set()
  for (const m of MOUNTS) {
    const dir = path.dirname(path.join(m, pat))
    try { for (const f of fs.readdirSync(dir)) if (re.test(f) && fs.statSync(path.join(dir, f)).isFile()) out.add(f) } catch {}
  }
  return [...out].join('\n')
}

;(async () => {
  const L = await new LuaFactory().createEngine()
  const g = L.global
  let res = null
  g.set('__result', (v) => { res = v })
  g.set('__now', () => performance.now())
  g.set('__log', (s) => console.log('  lua:', String(s)))
  // never hand Lua a JS null (wasmoon crashes on it): '' means "no such file"
  g.set('__read', (p) => { try { return fs.readFileSync(gamePath(p), 'latin1') } catch { return '' } })
  g.set('__exists', (p) => fs.existsSync(gamePath(p)))
  g.set('__find', findAll)
  const run = async (name, src) => { try { await L.doString(src) } catch (e) { throw new Error(name + ': ' + e.message) } }
  await run('bake_shim.lua', fs.readFileSync(path.join(__dirname, 'bake_shim.lua'), 'utf8'))
  await run('test shim', `
    FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY, CHAN_STATIC = 128, 8192, 256, 6
    player = { GetAll = function() return {} end }
    LISTED, FALLBACK, NOSCRIPT = 0, 0, {}
    list = { Set = function(kind, id, t)
      LISTED = LISTED + 1
      local s = t.KeyValues.vehiclescript
      if s:find("audio_engine/test_car", 1, true) then FALLBACK = FALLBACK + 1 end
      if not file.Exists(s, "GAME") then NOSCRIPT[#NOSCRIPT + 1] = id end
    end }
    SOUNDS = {}
    sound.Add = function(t) SOUNDS[t.name] = t end
    sound.GetProperties = function(n) return SOUNDS[n] end
    file = {
      Read = function(p) local s = __read(p) if s == "" then return nil end return s end,
      Exists = function(p) return __exists(p) end,
      Find = function(pat)
        local t = {}
        for f in (__find(pat) .. "\\n"):gmatch("([^\\n]*)\\n") do if f ~= "" then t[#t + 1] = f end end
        return t, {}
      end,
    }
    table.Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    AUDIO_ENGINE = {}`)
  for (const f of ['sh_config.lua', 'sh_presets.lua', 'sh_drivetrain.lua', 'sh_carlist.lua', 'sh_perp.lua',
    'cl_baked.lua', 'cl_synth.lua', 'cl_soundbank.lua']) await run(f, fs.readFileSync(path.join(LUA, f), 'utf8'))

  let fail = 0
  const check = (ok, msg) => { if (!ok) { fail++; console.log('FAIL', msg) } }

  // 1. stock mute
  await L.doString(`
    E = AUDIO_ENGINE
    E.ApplyStockMute()
    local names, n = {}, 0
    for low, name in pairs(E.PERP_MUTED) do n = n + 1 names[#names + 1] = name end
    table.sort(names)
    __result(n .. "\\t" .. LISTED .. "\\t" .. FALLBACK .. "\\t" .. table.concat(NOSCRIPT, " ") .. "\\t" ..
      table.concat(names, " ", 1, math.min(12, #names)))`)
  const [nMuted, listed, fallback, noScript, sample] = res.split('\t')
  console.log(`stock mute: ${nMuted} soundscripts muted, e.g. ${sample}`)
  console.log(`spawn menu: ${listed} PERP cars listed, ${fallback} on the generic test script`)
  check(+listed === 165, 'expected all 165 PERP cars in the spawn menu (are the TDM models mounted?)')
  check(noScript === '', 'spawn entries whose vehicle script is missing (no physics in game): ' + noScript)
  if (+nMuted > 0) {
    check(+nMuted > 100, 'expected the engine soundscripts of the registered cars to be muted')
    check(+fallback === 0, 'PERP scripts are mounted: no car should need the test script')
  } else {
    console.log('  (PERP vehicle scripts not mounted: nothing to mute, every car on the test script)')
    check(+fallback === +listed, 'every car should fall back to the test script')
  }
  // the bus and fire trucks must keep their engine sound
  await L.doString(`
    local keep, bad = {}, {}
    for _, s in ipairs({ "perp2/bus", "perp2/truckfire", "perp2/f350_firetruck", "perp2/towtruck", "jarheads/bearcat" }) do
      local t = {}
      local txt = file.Read("scripts/vehicles/" .. s .. ".txt", "GAME") or ""
      for block in txt:gmatch('"[Ss][Tt][Aa][Tt][Ee]"%s*(%b{})') do
        local snd = block:match('"[Ss][Oo][Uu][Nn][Dd]"%s*"([^"]*)"')
        if snd and E.PERP_MUTED[snd:lower()] then bad[#bad + 1] = s .. ":" .. snd end
      end
    end
    __result(table.concat(bad, " "))`)
  check(res === '', 'service vehicles lost sounds: ' + res)

  // 2. baked banks
  await L.doString(`
    local Bank = E.Bank
    local miss, nb, baked, cars = {}, 0, 0, 0
    local seen = {}
    for _, car in pairs(E.Cars) do
      cars = cars + 1
      local cfg = E.ResolveProfile(car)
      if not seen[cfg.id] then
        seen[cfg.id] = true
        nb = nb + 1
        local b = Bank.Get(cfg)
        if b.baked then
          baked = baked + 1
          local names = {}
          for _, l in ipairs(b.layers) do names[#names + 1] = l.on names[#names + 1] = l.off end
          for _, x in ipairs({ b.limiter.off, b.start.name, b.startEmo.name, b.stop.name }) do names[#names + 1] = x end
          for _, x in ipairs(b.pops) do names[#names + 1] = x end
          for _, x in ipairs(b.bangs) do names[#names + 1] = x end
          -- a family bank may be baked at a higher redline (more bands), never a lower one
          if b.limiter.rpm < cfg.redline then miss[#miss + 1] = cfg.id .. " limiter below redline" end
          if #b.layers < #cfg.bands then miss[#miss + 1] = cfg.id .. " band count" end
          for _, x in ipairs(names) do
            if not file.Exists("sound/" .. x, "GAME") then miss[#miss + 1] = x end
            if not b.peak[x] then miss[#miss + 1] = x .. " (no peak)" end
          end
        elseif car.model ~= "models/plpd/sl65amg_rtu.mdl" then
          miss[#miss + 1] = (car.name or car.model) .. " not baked"
        end
      end
    end
    local env = Bank.GetEnv()
    if not env.baked then miss[#miss + 1] = "env not baked" end
    for _, k in ipairs({ "road", "wind", "turbo", "evhum", "bov1", "bov2" }) do
      if not (env[k] and file.Exists("sound/" .. env[k], "GAME")) then miss[#miss + 1] = "env " .. k end
    end
    __result(cars .. "\\t" .. nb .. "\\t" .. baked .. "\\t" .. table.concat(miss, "\\n"))`)
  const [cars, nb, baked, missing] = res.split('\t')
  console.log(`baked banks: ${cars} cars, ${nb} distinct engines, ${baked} load from baked files`)
  check(missing === '', 'missing:\n' + missing)
  // 3. stock pops & blow-off: list names must be real cars, and only listed cars get them
  await L.doString(`
    local bad, pops, bov, turbo = {}, 0, 0, 0
    for name in pairs(E.CAR_POPS) do if not E.CAR_ENGINES[name] then bad[#bad + 1] = "CAR_POPS: " .. name end end
    for name in pairs(E.CAR_BOV) do if not E.CAR_ENGINES[name] then bad[#bad + 1] = "CAR_BOV: " .. name end end
    for _, car in pairs(E.Cars) do
      if car.perp then
        local p = E.CarStockProfile(car)
        if p.pops > 0 then pops = pops + 1 end
        if p.turbo then turbo = turbo + 1 end
        if p.bov then
          bov = bov + 1
          if not E.CAR_BOV[car.name] then bad[#bad + 1] = "unlisted BOV: " .. car.name end
        end
        if (p.pops > 0) ~= ((E.CAR_POPS[car.name] or 0) > 0) then bad[#bad + 1] = "pops mismatch: " .. car.name end
      end
    end
    __result(pops .. "\\t" .. bov .. "\\t" .. turbo .. "\\t" .. table.concat(bad, "\\n"))`)
  const [nPops, nBov, nTurbo, badLists] = res.split('\t')
  console.log(`stock pops & bangs on ${nPops} of 165 cars; blow-off valve on ${nBov} of ${nTurbo} turbo cars`)
  check(badLists === '', badLists)
  check(+nBov === 9, 'expected the 9 listed cars to have a blow-off valve')

  console.log(fail ? `${fail} check(s) FAILED` : 'all checks passed')
  process.exit(fail ? 1 : 0)
})().catch((e) => { console.error(e); process.exit(1) })
