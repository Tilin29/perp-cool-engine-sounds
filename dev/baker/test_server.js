/*
  Offline run of the server files on fake cars (no Garry's Mod needed):
    - 100 parked cars cost next to nothing, 20 driven ones run the assists
    - ignition, wheelspin under traction control, the speed limiter, getting out, the idle timeout
    - a profile string with "nan" in it can't get through

    node test_server.js [lua folder] [global name]
  The two arguments run it on another copy of the addon, to compare the numbers (no checks then).
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.resolve(process.argv[2] || path.join(ADDON, 'lua'), 'audio_engine')
const GLOBAL = process.argv[3] || 'PerpAudioEngine'
const COMPARE = !!process.argv[2]

;(async () => {
  const L = await new LuaFactory().createEngine()
  const g = L.global
  let res = null
  g.set('__result', (v) => { res = v })
  g.set('__now', () => performance.now())
  g.set('__log', (s) => { if (String(s).startsWith('ERROR')) console.log(String(s)) })
  g.set('__snd', () => {})
  const read = (f) => fs.readFileSync(path.join(LUA, f), 'utf8')
  await L.doString(fs.readFileSync(path.join(__dirname, '..', 'gmod_shim.lua'), 'utf8'))
  await L.doString(`${GLOBAL} = {}
    SERVER, CLIENT = true, false
    FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_NONE, HUD_PRINTCONSOLE, HUD_PRINTTALK = 1, 2, 4, 0, 2, 3
    MASK_SOLID, MOUSE_MIDDLE = 1, 109
    IN_MOVELEFT, IN_MOVERIGHT = 512, 1024
    math.atan2 = function(y, x) return math.atan(y, x) end
    function math.NormalizeAngle(a) return (a + 180) % 360 - 180 end
    function math.Round(x) return math.floor(x + 0.5) end
    function string.Trim(s) return s end
    function string.StartsWith(s, p) return s:sub(1, #p) == p end
    function istable(x) return type(x) == "table" end
    function isstring(x) return type(x) == "string" end
    function isvector(x) return false end
    local copies = 0
    function table.Copy(t)
      if type(t) ~= "table" then return t end
      copies = copies + 1
      local o = {}
      for k, v in pairs(t) do o[k] = table.Copy(v) end
      return setmetatable(o, getmetatable(t))
    end
    function Copies() return copies end
    table.Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    file = { Exists = function() return true end, Read = function() return nil end, Find = function() return {}, {} end }
    list = { Set = function() end }
    player = { GetAll = function() return {} end }
    net = { Receive = function() end }
    util.AddNetworkString = function() end
    util.TraceLine = function(t)
      local r = t.output or {}
      r.Hit = true
      return r
    end
    engine = { TickInterval = function() return 1 / 66 end }
    TIMERS = {}
    timer.Create = function(id, _, _, fn) TIMERS[id] = fn end
    timer.Remove = function() end
    ENTS = {}
    ents = {
      GetAll = function() return ENTS end,
      Iterator = function() return ipairs(ENTS) end,
    }
    local mt = getmetatable(Vector(0, 0, 0))
    function mt:Cross(b) return Vector(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
    function mt:GetNormalized() local v = Vector(self) v:Normalize() return v end

    local PHYS = {}
    PHYS.__index = PHYS
    function PHYS:IsValid() return true end
    function PHYS:IsMotionEnabled() return true end
    function PHYS:GetVelocity() return Vector(self.vel) end
    function PHYS:GetAngleVelocity() return Vector(0, 0, 0) end
    function PHYS:AddVelocity() end
    function PHYS:AddAngleVelocity() end
    function PHYS:ApplyForceCenter(f) self.pushed = (self.pushed or 0) + 1 end
    function PHYS:GetMass() return 1500 end
    function PHYS:SetMass() end

    SETS = 0
    local VEH = {}
    VEH.__index = VEH
    function VEH:IsValid() return true end
    function VEH:IsVehicle() return true end
    function VEH:GetClass() return "prop_vehicle_jeep" end
    function VEH:GetModel() return self.model end
    function VEH:GetPos() return Vector(0, 0, 0) end
    function VEH:GetUp() return Vector(0, 0, 1) end
    function VEH:LocalToWorld(p) return Vector(p) end
    function VEH:LookupAttachment() return 0 end
    function VEH:GetDriver() return self.driver end
    function VEH:GetPhysicsObject() return self.phys end
    function VEH:EnableEngine(on) self.enabled = on end
    function VEH:StartEngine() end
    function VEH:IsEngineEnabled() return self.enabled end
    function VEH:GetKeyValues() return { vehiclescript = "scripts/vehicles/x.txt" } end
    function VEH:GetWheel() return self.wheel end
    function VEH:SetPoseParameter() end
    function VEH:LookupBone() return 1 end
    function VEH:ManipulateBonePosition() end
    function VEH:ManipulateBoneAngles() end
    function VEH:GetVehicleParams()
      return {
        engine = { horsepower = 300, maxSpeed = 2000, maxRevSpeed = 300 },
        body = { addGravity = 1 },
        steering = { degreesSlow = 38, degreesFast = 11, turnThrottleReduceFast = 0.5, powerSlideAccel = 100 },
        axles = {
          { torqueFactor = 0, brakeFactor = 0.5, wheels_radius = 14 },
          { torqueFactor = 1, brakeFactor = 0.5, wheels_radius = 14 },
        },
      }
    end
    function VEH:SetVehicleParams() SETS = SETS + 1 end
    function VEH:SetNW2Bool(k, v) self.nw[k] = v end
    VEH.SetNW2Float, VEH.SetNW2Int, VEH.SetNW2String = VEH.SetNW2Bool, VEH.SetNW2Bool, VEH.SetNW2Bool
    local function nw(self, k, d) local v = self.nw[k] if v == nil then return d end return v end
    VEH.GetNW2Bool, VEH.GetNW2Float, VEH.GetNW2Int, VEH.GetNW2String = nw, nw, nw, nw

    function NewVehicle(model)
      local v = setmetatable({ model = model, nw = {}, enabled = false, driver = nil }, VEH)
      v.phys = setmetatable({ vel = Vector(0, 0, 0) }, PHYS)
      v.wheel = { IsValid = function() return true end, GetAngleVelocity = function() return Vector(0, 0, 0) end }
      ENTS[#ENTS + 1] = v
      hook.Run("OnEntityCreated", v)
      return v
    end
    function NewDriver()
      local p = { keys = {} }
      function p:IsValid() return true end
      function p:KeyDown(k) return self.keys[k] or false end
      function p:GetVehicle() return self.veh end
      return p
    end
    function GetIn(p, v) p.veh, v.driver = v, p hook.Run("PlayerEnteredVehicle", p, v) end
    function GetOut(p, v) p.veh, v.driver = nil, nil hook.Run("PlayerLeaveVehicle", p, v) end
    T = 0
    function Ticks(n)
      for i = 1, n do
        T = T + 1 / 66
        SIM.t, SIM.dt = T, 1 / 66
        hook.Run("Think")
        hook.Run("Tick")
        if T - (LAST or 0) >= 1 then
          LAST = T
          for _, fn in pairs(TIMERS) do fn() end
        end
      end
    end`)
  for (const f of ['sh_config', 'sh_presets', 'sh_drivetrain', 'sh_carlist', 'sv_handling', 'sv_engine', 'sv_stability', 'sv_cruise'])
    await L.doString(read(f + '.lua'))

  let fail = 0
  const check = (ok, msg) => { if (!ok) { fail++; console.log('FAIL', msg) } }
  const val = async (expr) => { await L.doString(`__result(tostring(${expr}))`); return res }

  await L.doString(`
    local E = ${GLOBAL}
    MODELS = {}
    for model, car in pairs(E.Cars) do if car.perp then MODELS[#MODELS + 1] = model end end
    table.sort(MODELS)
    PARKED = {}
    for i = 1, 100 do PARKED[i] = NewVehicle(MODELS[i]) end
    Ticks(66 * 5)`)

  let t0 = performance.now()
  await L.doString('Ticks(66 * 5)')
  const parkedMs = (performance.now() - t0) / (66 * 5)
  console.log(`100 parked cars: ${parkedMs.toFixed(3)} ms of Lua per tick (WASM, compare only)`)

  await L.doString(`
    DRIVERS, DRIVEN = {}, {}
    for i = 1, 20 do
      local p, v = NewDriver(), PARKED[i]
      DRIVERS[i], DRIVEN[i] = p, v
      GetIn(p, v)
      concommand.cmds.audio_engine_toggle(p)
    end
    Ticks(66 * 6)
    for i = 1, 20 do
      local p, v = DRIVERS[i], DRIVEN[i]
      p.keys[IN_FORWARD] = true
      v.phys.vel = Vector(0, 400, 0)
      -- spinning: about 3x what the car's speed would turn the wheels
      v.wheel.GetAngleVelocity = function() return Vector(0, 0, 8000) end
    end
    SETS0, COPIES0 = SETS, Copies()`)
  t0 = performance.now()
  await L.doString('Ticks(66 * 2)')
  const launchMs = (performance.now() - t0) / (66 * 2)
  await L.doString('__result((SETS - SETS0) .. " " .. (Copies() - COPIES0))')
  const [sets, copies] = res.split(' ').map(Number)
  console.log(`20 cars spinning their wheels, 2 s: ${sets} SetVehicleParams, ${copies} tables copied, `
    + `${launchMs.toFixed(3)} ms of Lua per tick`)
  if (COMPARE) process.exit(0)

  check(await val('DRIVEN[1].nw.audio_on') === 'true', 'the start key should start the engine')
  check(await val('DRIVEN[1].enabled') === 'true', 'the car should drive once the start-up reached idle')
  check(await val('DRIVEN[1].audioStart == nil') === 'true', 'the start-up should have finished')
  check(+(await val('DRIVEN[1].audioTC')) < 1, 'traction control should have cut the power')
  check(sets < 20 * 2 * 20 + 40, `SetVehicleParams at most ~20 times a second per car, got ${sets} in 2 s for 20 cars`)
  check(copies < 200, `params shouldn't be copied per change, got ${copies} tables`)

  // the speed limiter: on, wheel up, held, then getting out releases it
  await L.doString(`
    local p, v = DRIVERS[1], DRIVEN[1]
    v.wheel.GetAngleVelocity = function() return Vector(0, 0, 0) end
    v.phys.vel = Vector(0, 880, 0)
    hook.Run("PlayerButtonDown", p, MOUSE_MIDDLE)
    Ticks(10)
    hook.Run("StartCommand", p, { GetMouseWheel = function() return 1 end })
    NO_LIMIT = NewDriver()
    hook.Run("StartCommand", NO_LIMIT, { GetMouseWheel = function() return 1 end })
    Ticks(10)`)
  check(+(await val('DRIVEN[1].audioCruise')) === 55, 'limiter on at 50 mph, wheel up should give 55')
  check(+(await val('DRIVEN[1].nw.audio_cruise')) === 55, 'the limit should reach the HUD')
  await L.doString(`
    local v = DRIVEN[1]
    hook.Run("StartCommand", DRIVERS[1], { GetMouseWheel = function() return -1 end })
    hook.Run("StartCommand", DRIVERS[1], { GetMouseWheel = function() return -1 end })
    hook.Run("StartCommand", DRIVERS[1], { GetMouseWheel = function() return -1 end })
    v.phys.vel = Vector(0, 880, 0)
    Ticks(5)`)
  check(+(await val('DRIVEN[1].nw.audio_limst')) === 2, 'over a lowered limit it should shut the throttle')
  check(+(await val('DRIVEN[1].phys.pushed or 0')) > 0, 'over a lowered limit it should brake')

  // everyone out: the cars settle, go inactive, and their engines stop after the timeout
  await L.doString(`
    for i = 1, 20 do
      DRIVEN[i].phys.vel = Vector(0, 0, 0)
      DRIVERS[i].keys[IN_FORWARD] = false
      GetOut(DRIVERS[i], DRIVEN[i])
    end
    Ticks(66 * 6)`)
  check(await val('DRIVEN[1].audioCruise == nil') === 'true', 'getting out should release the limiter')
  check(+(await val(`table.Count(${GLOBAL}.ActiveVehicles)`)) === 0, 'parked cars should leave the active set')
  check(await val('DRIVEN[1].audioTC') === '1', 'traction trim should be back to full')
  check(await val('DRIVEN[1].nw.audio_in') === '0', 'the keys should read as released')
  check(await val('DRIVEN[1].nw.audio_on') === 'true', 'it keeps idling for a while')
  await L.doString('Ticks(66 * 180)')
  check(await val('DRIVEN[1].nw.audio_on') === 'false', 'the idle timeout should stop the engine')

  // a driver getting back in is picked up again
  await L.doString(`
    GetIn(DRIVERS[2], DRIVEN[2])
    Ticks(5)`)
  check(+(await val(`table.Count(${GLOBAL}.ActiveVehicles)`)) === 1, 'getting in should make the car active')

  // a tuned profile with nan in it
  await L.doString(`
    local E = ${GLOBAL}
    local p = E.DecodeProfile("x|i4|nan|nan|nan|nan|nan|nan|0|nan,2|nan|1|nan|nan|nan|0|nan|nan|nan|nan|nan")
    local bad = {}
    for k, v in pairs(p) do if v ~= v then bad[#bad + 1] = k end end
    for _, v in ipairs(p.gears) do if v ~= v then bad[#bad + 1] = "gear" end end
    __result(table.concat(bad, " "))`)
  check(res === '', 'nan got through SanitizeProfile: ' + res)

  console.log(fail ? `${fail} check(s) FAILED` : 'all checks passed')
  process.exit(fail ? 1 : 0)
})().catch((e) => { console.error(e); process.exit(1) })
