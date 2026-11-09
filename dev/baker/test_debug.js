/*
  Offline checks of the gearing / rev response core (sh_presets E.ApplyGearing, sh_drivetrain shift
  plan and DT.REV) and the debug module's shared code (lua/audio_engine_debug: sh_kv, sh_debug):
    - vehicle scripts parse and rebuild byte for byte; edited values land where they belong
    - an edited value scales into the params by new / file value (any unit), vectors, gears, bools
    - gearing by shift speed: a full-throttle run changes up at the set speeds, braking changes
      down under the set speeds, every upshift drops the revs by at least GEAR_MIN_STEP
    - the gearing text round-trips, and a config's gearing read back gives the same ratios
    - the debug overrides (NW2 strings) reach E.GetEngineConfig
    - rev response: time to blip and fall back, old (TMAX 320) and new (DT.REV) values

    node test_debug.js
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.join(ADDON, 'lua')

;(async () => {
  const L = await new LuaFactory().createEngine()
  const g = L.global
  let failed = 0
  g.set('__now', () => performance.now())
  g.set('__log', (s) => console.log('  ' + String(s)))
  g.set('__fail', (s) => { failed++; console.log('FAIL ' + String(s)) })
  g.set('__read', (p) => fs.readFileSync(path.join(ADDON, p), 'utf8'))
  const run = async (name, src) => { try { await L.doString(src) } catch (e) { throw new Error(name + ': ' + e.message) } }
  await run('bake_shim.lua', fs.readFileSync(path.join(__dirname, 'bake_shim.lua'), 'utf8'))
  await run('test shim', `
    SERVER, CLIENT = false, true
    FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 128, 8192, 256
    function istable(x) return type(x) == "table" end
    function isstring(x) return type(x) == "string" end
    function isnumber(x) return type(x) == "number" end
    function table.Copy(t)
      if type(t) ~= "table" then return t end
      local o = {}
      for k, v in pairs(t) do o[k] = table.Copy(v) end
      return setmetatable(o, getmetatable(t))
    end
    function string.Explode(sep, s)
      local t, start = {}, 1
      while true do
        local i = string.find(s, sep, start, true)
        if not i then t[#t + 1] = s:sub(start) break end
        t[#t + 1] = s:sub(start, i - 1)
        start = i + 1
      end
      return t
    end
    local V = {}
    V.__index = V
    function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
    GLOBAL2 = {}
    function GetGlobal2String(k, d) return GLOBAL2[k] or d end
    AUDIO_ENGINE = {}`)
  for (const f of ['audio_engine/sh_config.lua', 'audio_engine/sh_presets.lua', 'audio_engine/sh_drivetrain.lua', 'audio_engine/sh_carlist.lua',
    'audio_engine_debug/sh_kv.lua', 'audio_engine_debug/sh_debug.lua'])
    await run(f, fs.readFileSync(path.join(LUA, f), 'utf8'))

  await run('tests', `
    local E = AUDIO_ENGINE
    local KV, DBG, DT = E.KV, E.Debug, E.Drivetrain
    local function check(ok, what) if not ok then __fail(what) end end
    local function near(a, b, tol) return math.abs(a - b) <= tol end

    ---------------------------------------------------------------- KeyValues
    for _, p in ipairs({ "scripts/vehicles/audio_engine/test_car.txt", "scripts/vehicles/plpd/sl65amg_rtu.txt" }) do
      local txt = __read(p)
      local es = KV.Parse(txt)
      check(#es > 40, p .. ": parsed " .. #es .. " entries")
      check(KV.Rebuild(txt, es, {}) == txt, p .. ": unchanged rebuild is byte for byte")
      local hp, gear3, spring2, mc
      for _, e in ipairs(es) do
        if e.path == "engine" and e.lkey == "horsepower" then hp = e end
        if e.path == "engine" and e.lkey == "gear" and e.occ == 3 then gear3 = e end
        if e.path == "axle/suspension" and e.axle == 2 and e.lkey == "springconstant" then spring2 = e end
        if e.path == "body" and e.lkey == "masscenteroverride" then mc = e end
      end
      check(hp and gear3 and spring2, p .. ": found horsepower, 3rd gear, rear spring")
      local edited = KV.Rebuild(txt, es, { [hp.idx] = "400", [gear3.idx] = "1.75", [spring2.idx] = "99" })
      local es2 = KV.Parse(edited)
      check(KV.SameShape(es, es2), p .. ": same shape after editing")
      check(es2[hp.idx].value == "400" and es2[gear3.idx].value == "1.75" and es2[spring2.idx].value == "99", p .. ": edits landed")
      local changed = 0
      for i = 1, #es do if es[i].value ~= es2[i].value then changed = changed + 1 end end
      check(changed == 3, p .. ": only the 3 edited values changed (" .. changed .. ")")
      __log(string.format("%s: %d entries, labels e.g. '%s', '%s'", p, #es, spring2.label, gear3.label))
      if mc then __log("  mass centre '" .. mc.value .. "'" .. (mc.comment and (" // " .. mc.comment) or "")) end
    end
    check(KV.ValidValue("0 0 -5") and KV.ValidValue("1.5") and not KV.ValidValue('1"') and not KV.ValidValue("}"), "value validation")

    -- values scale into params whatever their unit
    local params = { engine = { horsepower = 320 * 7, maxSpeed = 125 * 17.6, gearRatio = { 3.5, 2.2, 1.5 }, isAutoTransmission = true },
      body = { massCenterOverride = Vector(0, 0, -5 * 2.54) }, axles = { { torqueFactor = 0.4 }, { suspension_stabilizerConstant = 0 } } }
    local function e(path, key, occ, axle) return { path = path, lkey = key, occ = occ or 1, axle = axle } end
    check(KV.ApplyValue(params, e("engine", "horsepower"), "320", "400") and near(params.engine.horsepower, 400 * 7, 1e-6), "horsepower scales")
    check(KV.ApplyValue(params, e("engine", "maxspeed"), "125", "100") and near(params.engine.maxSpeed, 100 * 17.6, 1e-6), "speed scales")
    check(KV.ApplyValue(params, e("engine", "gear", 2), "2.2", "2.0") and near(params.engine.gearRatio[2], 2.0, 1e-9), "2nd gear")
    check(KV.ApplyValue(params, e("engine", "autotransmission"), "1", "0") and params.engine.isAutoTransmission == false, "bool")
    check(KV.ApplyValue(params, e("body", "masscenteroverride"), "0 0 -5", "0 1 -8") and near(params.body.massCenterOverride.z, -8 * 2.54, 1e-9)
      and near(params.body.massCenterOverride.y, 2.54, 1e-9), "vector in the car's unit")
    check(KV.ApplyValue(params, e("axle/suspension", "stabilizerconstant", 1, 2), "0", "50") and params.axles[2].suspension_stabilizerConstant == 50, "zero original taken as is")
    check(not KV.ApplyValue(params, e("axle/wheel", "radius", 1, 1), "15", "16"), "wheel radius isn't live")
    check(not KV.ApplyValue(params, e("engine", "gear", 5), "1", "2"), "a gear the params don't have isn't live")

    ---------------------------------------------------------------- gearing
    local car
    for _, c in pairs(E.Cars) do if c.name == "BMW 1M" then car = c end end
    local carEff = {}
    for k, v in pairs(car) do carEff[k] = v end
    carEff.topSpeed, carEff.powerKg = 250, 120
    local cfg0 = E.ResolveProfile(carEff)
    local red = cfg0.redline
    -- uneven on purpose: a short 1st, a long 3rd
    local spec = { topRpm = red - 900, { mph = 28, rpm = red - 400 }, { mph = 45, rpm = red - 300, down = 18 },
      { mph = 80, rpm = red - 300, down = 32 }, { mph = 108, rpm = red - 500, down = 55 }, { down = 80 } }
    local cfg = {}
    for k, v in pairs(cfg0) do cfg[k] = v end
    E.ApplyGearing(cfg, spec)
    check(#cfg.gears == 5 and cfg.final == 1 and cfg.shiftPlan, "5 gears applied")
    for i = 2, #cfg.gears do check(cfg.gears[i] <= cfg.gears[i - 1] / E.GEAR_MIN_STEP + 1e-9, "gear " .. i .. " at least GEAR_MIN_STEP taller") end
    local K = 60 / (2 * math.pi * cfg.wheelRadius)
    check(near(cfg.topSpeed / 3.6 * K * cfg.gears[5], spec.topRpm, 1), "top gear turns topRpm at the top speed")

    -- full throttle from a standstill, pulling hard (so every upshift is at the set rpm)
    local st = DT.New()
    DT.SkipStart(st, cfg)
    local v, dt, vmax = 0, 1 / 60, cfg.topSpeed / 3.6
    local ups = {}
    for _ = 1, 60 * 60 do
      local a = math.max(0.3, 4.5 * (1 - (v / vmax) ^ 3))
      v = math.min(vmax, v + a * dt)
      local g0 = st.gear
      DT.Step(st, cfg, dt, { fwd = true, v = v })
      if st.gear > g0 and g0 >= 1 then ups[#ups + 1] = { g0, v / 0.44704 } end
    end
    local line = {}
    for _, u in ipairs(ups) do line[#line + 1] = string.format("%d>%d %.1f mph", u[1], u[1] + 1, u[2]) end
    __log("upshifts: " .. table.concat(line, ", "))
    check(#ups == 4, "4 upshifts on the way to the top speed (" .. #ups .. ")")
    for i = 1, math.min(2, #ups) do
      check(ups[i][1] == i and near(ups[i][2], spec[i].mph, 2.5), string.format("upshift %d at %.1f mph (set %.1f)", i, ups[i][2], spec[i].mph))
    end
    for _, u in ipairs(ups) do check(u[2] <= spec[u[1]].mph + 1, string.format("upshift %d not later than set (%.1f vs %.1f)", u[1], u[2], spec[u[1]].mph)) end

    -- braking from the top speed: down under each gear's downshift speed
    local downs = {}
    for _ = 1, 60 * 30 do
      v = math.max(0, v - 5 * dt)
      local g0 = st.gear
      DT.Step(st, cfg, dt, { back = true, v = v })
      if st.gear < g0 and st.gear >= 1 then downs[#downs + 1] = { g0, v / 0.44704 } end
      if v <= 0.5 then break end
    end
    line = {}
    for _, d in ipairs(downs) do line[#line + 1] = string.format("%d>%d %.1f mph", d[1], d[1] - 1, d[2]) end
    __log("braking downshifts: " .. table.concat(line, ", "))
    check(#downs == 4, "4 downshifts braking to a stop (" .. #downs .. ")")
    for _, d in ipairs(downs) do
      local want = spec[d[1]].down
      check(d[2] <= want + 0.2 and d[2] >= want - 2, string.format("downshift from %d at %.1f mph (set under %.1f)", d[1], d[2], want))
    end

    -- the text form and reading a config back
    local s1 = DBG.EncodeGearing(spec)
    local back = DBG.DecodeGearing(s1)
    check(DBG.EncodeGearing(back) == s1, "gearing text round-trips: " .. s1)
    local spec2 = DBG.GearingFromConfig(cfg)
    local cfg2 = {}
    for k, v2 in pairs(cfg0) do cfg2[k] = v2 end
    E.ApplyGearing(cfg2, spec2)
    for i = 1, #cfg.gears do check(math.abs(cfg2.gears[i] / cfg.gears[i] - 1) < 0.01, "read-back gear " .. i .. " matches") end
    __log("sh_carlist entry: " .. DBG.GearingLua(car.name, back))

    -- a car with CAR_GEARING gets it through ResolveProfile
    local carG = {}
    for k, v2 in pairs(carEff) do carG[k] = v2 end
    carG.gearing = spec
    local cfgG = E.ResolveProfile(carG)
    check(#cfgG.gears == 5 and cfgG.shiftPlan ~= nil and math.abs(cfgG.gears[1] / cfg.gears[1] - 1) < 1e-9, "E.CAR_GEARING reaches the config")
    -- (a profile with hand-set ratios, fit 0, keeps them)
    local prof = E.CarStockProfile(carG)
    prof.fit = 0
    check(E.ResolveProfile(carG, prof).shiftPlan == nil, "fit 0 keeps the profile's own ratios")

    ---------------------------------------------------------------- the debug overrides
    local nw = {}
    local ent = { GetModel = function() return car.model end,
      GetNW2String = function(_, k, d) return nw[k] or d end, GetNW2Float = function(_, k, d) return d end }
    local plain = E.GetEngineConfig(ent)
    check(plain.shiftPlan == nil and DBG.BaseConfig(ent) == plain, "no override: the core's config")
    nw.audio_dbg_gear = DBG.EncodeGearing({ topRpm = 5000, { mph = 30, rpm = 6000 }, { mph = 60, rpm = 6200 }, {} })
    nw.audio_dbg_rev = "650,900"
    local o = E.GetEngineConfig(ent)
    check(#o.gears == 3 and o.shiftPlan and o.revRise == 650 and o.revFall == 900, "NW2 gearing and rev overrides reach the config")
    check(E.GetEngineConfig(ent) == o, "override config is cached")
    check(DBG.BaseConfig(ent) == plain, "the base config is untouched")
    GLOBAL2.audio_dbg_rev = "700,1100"
    E.GetEngineConfig(ent)
    check(DT.REV.rise == 700 and DT.REV.fall == 1100, "global rev response reaches DT.REV")
    GLOBAL2.audio_dbg_rev = ""
    E.GetEngineConfig(ent)
    check(DT.REV.rise == 500 and DT.REV.fall == 500, "cleared: DT.REV back to the file's")

    ---------------------------------------------------------------- rev response
    local function blip(c, rise, fall)
      local sim = { redline = c.redline, idle = c.idle, revRise = rise, revFall = fall }
      local rpm, thr, t, up, down, want, t0 = c.idle, 0, 0, nil, nil, 1, 0
      while t < 15 do
        thr = thr + DT.clamp(want - thr, -dt * 7, dt * 5)
        local idleThr = DT.clamp((c.idle - rpm) / 400, 0, 0.3)
        rpm = DT.clamp(rpm + DT.FreeSpinRate(sim, rpm, math.max(thr, idleThr)) * dt, 0, c.redline)
        t = t + dt
        if want == 1 and rpm >= c.redline * 0.9 then up, want, t0 = t, 0, t
        elseif want == 0 and rpm <= c.idle + (c.redline - c.idle) * 0.08 then down = t - t0 break end
      end
      return up, down
    end
    for _, rf in ipairs({ { 320, 320 }, { 500, 500 }, { 500, 800 } }) do
      local up, down = blip(cfg0, rf[1], rf[2])
      __log(string.format("rev %d/%d on the %s (%s rpm): idle to 90%% %.2f s, back down %.2f s", rf[1], rf[2], car.name, cfg0.redline, up or -1, down or -1))
    end
    local u1, d1 = blip(cfg0, 320, 320)
    local u2, d2 = blip(cfg0, 500, 500)
    check(d2 < d1 * 0.75 and u2 < u1, "500 / 500 drops back faster than the old 320")
    -- driving in neutral uses DT.REV
    local stN = DT.New()
    DT.SkipStart(stN, cfg0)
    stN.rpm = cfg0.redline * 0.9
    DT.Step(stN, cfg0, dt, { hand = true, v = 0 })
    local r1 = stN.rpm
    local cfgF = {}
    for k, v2 in pairs(cfg0) do cfgF[k] = v2 end
    cfgF.revFall = 1200
    local stF = DT.New()
    DT.SkipStart(stF, cfgF)
    stF.rpm = cfg0.redline * 0.9
    DT.Step(stF, cfgF, dt, { hand = true, v = 0 })
    check(stF.rpm < r1, "a car's own revFall drops the revs faster in neutral")
  `)
  console.log(failed ? `${failed} check(s) failed` : 'all checks passed')
  process.exit(failed ? 1 : 0)
})()
