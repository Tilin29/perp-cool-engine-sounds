/*
  Offline check of how cl_engine holds up with many cars around (no Garry's Mod needed):
    - 40 cars driving around the listener: the detail tiers keep the sounds playing under a budget
    - the car you sit in always gets full detail, far cars go silent, and they come back
    - the HUD and the tuning menu run on a fake vgui / surface

    node test_lod.js [lua folder] [global name]
  The two arguments run the check on another copy of the addon, to compare the numbers.
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.resolve(process.argv[2] || path.join(ADDON, 'lua'), 'audio_engine')
const GLOBAL = process.argv[3] || 'PerpAudioEngine'
const SOUND_BUDGET = 100 // sounds at once: well under what Source mixes, with room for the rest of the game

;(async () => {
  const L = await new LuaFactory().createEngine()
  const g = L.global
  const live = new Set()
  let peak = 0
  let res = null
  g.set('__result', (v) => { res = v })
  g.set('__now', () => performance.now())
  g.set('__log', (s) => { if (String(s).startsWith('ERROR')) console.log(String(s)) })
  g.set('__genBegin', () => {}); g.set('__push', () => {}); g.set('__genEnd', () => {})
  const names = new Map()
  const LOOP = /\/(b\d+(on|off)|lim|road|wind|turbo|evhum)\.wav$/
  g.set('__snd', (what, id, name) => {
    if (what === 'create') names.set(id, String(name))
    // (one-shots end by themselves, the fake can't tell when: only the loops are counted)
    if (what === 'play' && LOOP.test(names.get(id))) live.add(id)
    if (what === 'stop' || what === 'fade') live.delete(id)
    peak = Math.max(peak, live.size)
  })
  g.set('__live', () => live.size)
  g.set('__resetPeak', () => { peak = live.size })
  g.set('__peak', () => peak)
  const read = (f) => fs.readFileSync(path.join(LUA, f), 'utf8')
  await L.doString(fs.readFileSync(path.join(__dirname, '..', 'gmod_shim.lua'), 'utf8'))
  await L.doString(`${GLOBAL} = {}
    math.randomseed(1)
    table.Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    file = { Exists = function() return true end }
    list = { Set = function() end }
    util.PrecacheSound = function() end
    IN_MOVELEFT, IN_MOVERIGHT = 512, 1024

    function CAR:IsVehicle() return true end
    function CAR:GetModel() return self.model end
    CARS = {}
    function NewCar(i, model, x, y)
      local c = setmetatable({ i = i, model = model, pos = Vector(x, y, 0), yaw = 0, nw = {}, pose = {} }, { __index = CAR })
      c.nw.audio_on, c.nw.audio_on_t, c.nw.audio_in = true, -100, 1
      CARS[i] = c
      return c
    end
    ents.FindByClass = function() return CARS end
    function PLY:GetVehicle() return self.car end
    function Frame(t, dt)
      SIM.t, SIM.dt = t, dt
      for i, c in ipairs(CARS) do
        if c.drive then
          local a = t * 0.4 + i
          c.pos = c.home + Vector(math.cos(a) * 600, math.sin(a) * 600, 0)
        end
      end
      PLY.eye = PLY.car and PLY.car:GetPos() + Vector(0, 0, 40) or Vector(0, 0, 64)
      hook.Run("Think")
    end`)
  for (const f of ['sh_config', 'sh_presets', 'sh_drivetrain', 'sh_carlist', 'cl_baked', 'cl_synth', 'cl_soundbank', 'cl_engine'])
    await L.doString(read(f + '.lua'))

  let fail = 0
  const check = (ok, msg) => { if (!ok) { fail++; console.log('FAIL', msg) } }

  // 40 cars of every kind within 100 m (3900 inches), all driving
  await L.doString(`
    local E = ${GLOBAL}
    local models = {}
    for model, car in pairs(E.Cars) do if car.perp then models[#models + 1] = model end end
    table.sort(models)
    for i = 1, 40 do
      local c = NewCar(i, models[i * 3], (i % 8 - 4) * 900, (i // 8 - 2) * 900)
      c.home, c.drive = c.pos, true
    end
    PLY.car = CARS[20]
    CARS[20].drive = false
    __result(#CARS)`)
  const frames = 60 * 20
  const t0 = performance.now()
  let t = 0
  await L.doString(`RUN = function(n) for i = 1, n do T = (T or 0) + 1 / 60 Frame(T, 1 / 60) end end`)
  await L.doString(`RUN(300)`) // warm-up: every car starts from idle at once, a moment that doesn't repeat
  const warmup = g.get('__peak')()
  g.get('__resetPeak')()
  await L.doString(`RUN(${frames})`)
  const ms = (performance.now() - t0) / frames
  const crowd = g.get('__peak')()
  console.log(`40 cars driving: ${crowd} loops at the peak (${warmup} in the first 5 s), now ${g.get('__live')()}, ${ms.toFixed(2)} ms of Lua per frame (WASM, compare only)`)
  if (process.argv[2]) process.exit(0)
  check(crowd <= SOUND_BUDGET, `expected at most ${SOUND_BUDGET} sounds at once, got ${crowd}`)

  const tiers = async () => {
    await L.doString(`
      local n = { 0, 0, 0 }
      for _, c in pairs(${GLOBAL}.ClientCars) do n[c.tier] = n[c.tier] + 1 end
      __result(n[1] .. " " .. n[2] .. " " .. n[3] .. " " .. ${GLOBAL}.ClientCars[PLY.car].tier)`)
    return res.split(' ').map(Number)
  }
  let [full, light, silent, own] = await tiers()
  console.log(`tiers: ${full} full, ${light} light, ${silent} silent`)
  check(own === 1, 'the car you sit in must be in full detail')
  check(full <= 10, 'about audio_engine_maxcars other cars in full detail (a car can be mid-fade)')
  check(light <= 18, 'about twice that many light cars (a car or two can be mid-fade)')

  // everyone leaves: 2 km away, only your own car stays
  await L.doString(`
    for i, c in ipairs(CARS) do if c ~= PLY.car then c.drive = false c.pos = Vector(80000 + i * 100, 0, 0) end end
    RUN(120)`)
  ;[full, light, silent] = await tiers()
  check(full === 1 && light === 0, `far cars must go silent, got ${full} full, ${light} light`)
  console.log(`after the crowd left: ${g.get('__live')()} sounds playing`)
  check(g.get('__live')() <= 12, 'only your own car should still be playing')

  // and they come back
  await L.doString(`
    for i, c in ipairs(CARS) do if c ~= PLY.car then c.pos = Vector((i % 8) * 300, (i // 8) * 300, 0) end end
    RUN(120)`)
  ;[full, light, silent] = await tiers()
  check(full > 1 && light > 0, `cars coming back must be heard again, got ${full} full, ${light} light`)

  // HUD and menu on fakes
  await L.doString(`
    local E = ${GLOBAL}
    function ScrW() return 1920 end
    function ScrH() return 1080 end
    function Color(r, gr, b, a) return { r = r, g = gr, b = b, a = a } end
    local nothing = function() end
    surface = setmetatable({ GetTextSize = function() return 10, 10 end }, { __index = function() return nothing end })
    draw = setmetatable({}, { __index = function() return nothing end })
    TEXT_ALIGN_CENTER, TEXT_ALIGN_LEFT, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM = 1, 0, 2, 4
    TOP, LEFT, RIGHT, BOTTOM, FILL = 1, 2, 3, 4, 5
    PANELS = {}
    local panel = {}
    panel.__index = function(t, k) return panel[k] or nothing end
    function panel:GetTall() return 20 end
    function panel:GetWide() return 20 end
    function panel:Add() return vgui.Create("DPanel") end
    vgui.Create = function()
      local p = setmetatable({ Knob = setmetatable({}, panel) }, panel)
      PANELS[#PANELS + 1] = p
      return p
    end
    chat = { AddText = nothing }
    net = setmetatable({}, { __index = function() return nothing end })
    function PLY:GetEyeTrace() return { Entity = CARS[1], HitPos = Vector(0, 0, 0) } end
    function PLY:GetShootPos() return Vector(0, 0, 0) end
    function PLY:IsSuperAdmin() return true end

    local format = string.format
    string.format = function(f, ...) return format((f:gsub("%%d", "%%.0f")), ...) end -- LuaJIT's %d takes floats`)
  await L.doString(read('cl_hud.lua'))
  await L.doString(read('cl_menu.lua'))
  await L.doString(`
    local E = ${GLOBAL}
    for i = 1, 5 do hook.Run("HUDPaint") end
    E.OpenMenu(PLY.car)
    -- every slider and control callback once, and the presets
    local count = #PANELS
    for i = 1, count do
      local p = PANELS[i]
      if rawget(p, "TranslateValues") then p.TranslateValues(p, 0.7, 0.5) end
      if rawget(p, "OnSelect") then p.OnSelect(p, 1, "x", "v8x") end
      if rawget(p, "OnValueChanged") then p.OnValueChanged(p, 5) end
      if rawget(p, "OnValueChange") then p.OnValueChange(p, "3.1") end
      if rawget(p, "OnChange") then p.OnChange(p, true) end
    end
    for i = 1, count do
      local p = PANELS[i]
      if rawget(p, "DoClick") then p.DoClick(p) end
    end
    __result(count)`)
  console.log(`hud drawn, menu built with ${res} panels, every control pressed`)

  console.log(fail ? `${fail} check(s) FAILED` : 'all checks passed')
  process.exit(fail ? 1 : 0)
})().catch((e) => { console.error(e); process.exit(1) })
