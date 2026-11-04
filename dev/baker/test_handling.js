/*
  Offline checks of sv_handling.lua with a fake vehicle (no Garry's Mod needed):
    - a PERP car spawned on the generic test script gets its PERP base-script physics
    - the anti-spin setup (front brake bias, throttle cut, lower centre, grip, handbrake slide)
    - a spiked/ tier car is left alone; PERP cars get the stability assist with their own steering

    node test_handling.js
  The fake keeps speeds in inches/s and takes mph in SetVehicleParams, like sv_engine assumes.
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.join(ADDON, 'lua', 'audio_engine')

;(async () => {
  const L = await new LuaFactory().createEngine()
  const g = L.global
  let res = null
  g.set('__result', (v) => { res = v })
  g.set('__now', () => performance.now())
  g.set('__log', (s) => console.log('  lua:', String(s)))
  const run = async (name, src) => { try { await L.doString(src) } catch (e) { throw new Error(name + ': ' + e.message) } }
  await run('bake_shim.lua', fs.readFileSync(path.join(__dirname, 'bake_shim.lua'), 'utf8'))
  await run('test shim', `
    SERVER, CLIENT = true, false
    FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY, HUD_PRINTCONSOLE = 128, 8192, 256, 2
    player = { GetAll = function() return {} end }
    file = { Exists = function() return true end, Read = function() return nil end, Find = function() return {}, {} end }
    list = { Set = function() end }
    function istable(x) return type(x) == "table" end
    function isstring(x) return type(x) == "string" end
    function table.Copy(t)
      if type(t) ~= "table" then return t end
      local o = {}
      for k, v in pairs(t) do o[k] = table.Copy(v) end
      return setmetatable(o, getmetatable(t))
    end
    local V = {}
    V.__index = V
    function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
    V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
    V.__tostring = function(a) return string.format("%g %g %g", a.x, a.y, a.z) end
    function V:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
    function isvector(x) return getmetatable(x) == V end
    AUDIO_ENGINE = {}`)
  for (const f of ['sh_config.lua', 'sh_presets.lua', 'sh_drivetrain.lua', 'sh_carlist.lua', 'sv_perp_physics.lua', 'sv_handling.lua'])
    await run(f, fs.readFileSync(path.join(LUA, f), 'utf8'))

  // a vehicle whose params start as a given script's values (speeds in inches/s)
  await run('fake vehicle', `
    E = AUDIO_ENGINE
    local HU = 17.6
    function NewCar(model, script, s)
      local veh = { kv = { vehiclescript = script }, mass = s.mass }
      veh.params = {
        engine = { horsepower = s.hp, maxRPM = s.rpm, maxSpeed = s.mph * HU, maxRevSpeed = 20 * HU, axleRatio = s.axle,
                   gearCount = #s.gears, gearRatio = table.Copy(s.gears), shiftUpRPM = 5600, shiftDownRPM = 2600 },
        body = { massOverride = s.mass, maxAngularVelocity = 200, addGravity = s.grav, counterTorqueFactor = 1,
                 massCenterOverride = Vector(0, 0, s.cz) },
        steering = { degreesSlow = 38, degreesFast = 14, degreesBoost = 10, powerSlideAccel = 150,
                     turnThrottleReduceSlow = 0.05, turnThrottleReduceFast = s.trf },
        axles = {
          { wheels_radius = 15, wheels_mass = 170, suspension_springConstant = 110, suspension_springDamping = 0.9,
            suspension_springDampingCompression = 5.5, suspension_stabilizerConstant = 120, suspension_maxBodyForce = 30,
            torqueFactor = s.tf[1], brakeFactor = s.bf[1] },
          { wheels_radius = 15, wheels_mass = 170, suspension_springConstant = 105, suspension_springDamping = 0.9,
            suspension_springDampingCompression = 5.5, suspension_stabilizerConstant = 110, suspension_maxBodyForce = 30,
            torqueFactor = s.tf[2], brakeFactor = s.bf[2] },
        },
      }
      function veh:GetModel() return model end
      function veh:GetKeyValues() return self.kv end
      function veh:GetVehicleParams() return table.Copy(self.params) end
      function veh:SetVehicleParams(p)
        p = table.Copy(p)
        for _, k in ipairs({ "maxSpeed", "maxRevSpeed" }) do if p.engine[k] then p.engine[k] = p.engine[k] * HU end end
        self.params = p
      end
      function veh:GetPhysicsObject()
        local o = { car = self }
        function o:IsValid() return true end
        function o:SetMass(m) self.car.mass = m end
        function o:GetMass() return self.car.mass end
        return o
      end
      return veh
    end
    function IsValid(x) return x ~= nil and x ~= false and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
    TESTCAR = { hp = 320, rpm = 6000, mph = 125, axle = 3.2, gears = { 3.5, 2.2, 1.5, 1.1, 0.85 }, mass = 1600, grav = 0.75,
                cz = -5, trf = 0.5, tf = { 0.4, 0.6 }, bf = { 0.6, 0.4 } }
    SL65 = { hp = 260, rpm = 4000, mph = 94, axle = 5, gears = { 5.5, 4.2, 3.7, 2.2, 1 }, mass = 2050, grav = 1,
             cz = -1, trf = 0.75, tf = { 0.5, 0.5 }, bf = { 0.5, 0.5 } }
    function Describe(veh)
      local p = veh.params
      local f, r = p.axles[1], p.axles[2]
      return string.format("%.0f|%.0f|%s|%.0f|%.2f|%.2f|%.2f|%.2f|%g|%.2f|%.1f|%s|%s|%s|%.2f",
        p.engine.horsepower, p.engine.maxSpeed / 17.6, table.concat(p.engine.gearRatio, ","), veh.mass,
        f.brakeFactor, r.brakeFactor, p.steering.turnThrottleReduceFast, p.body.addGravity,
        p.body.massCenterOverride.z, p.steering.powerSlideAccel, p.steering.degreesSlow,
        tostring(veh.audioPerpPhysics or false), tostring(veh.audioAntiSpin or false), tostring(veh.audioSpiked or false),
        p.steering.degreesFast)
    end
    -- E.GetCarConfig reads the model
    function Spawn(model, script, s)
      local veh = NewCar(model, script, s)
      E.PrepareHandling(veh)
      return Describe(veh)
    end`)

  let fail = 0
  const check = (ok, msg) => { if (!ok) { fail++; console.log('FAIL', msg) } }
  const parse = (s) => {
    const [hp, mph, gears, mass, bf, br, trf, grav, cz, psa, deg, perp, anti, spiked, dfast] = s.split('|')
    return { hp: +hp, mph: +mph, gears, mass: +mass, bf: +bf, br: +br, trf: +trf, grav: +grav, cz: +cz, psa: +psa, deg: +deg, perp, anti, spiked, dfast: +dfast }
  }
  const near = (a, b, tol = 0.01) => Math.abs(a - b) <= tol * Math.max(1, Math.abs(b))

  // 1. SL65 on the test script: PERP numbers + anti-spin
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", E.TEST_SCRIPT, TESTCAR))`)
  let c = parse(res)
  console.log('SL65 on the test script:', c)
  check(c.perp === 'true' && c.anti === 'true', 'expected PERP physics and anti-spin on the test script')
  check(near(c.hp, 260) && near(c.mph, 94), 'expected 260 hp / 94 mph from sl65amg.txt')
  check(c.gears === '5.5,4.2,3.7,2.2,1', 'expected the SL65 gears')
  check(near(c.mass, 2050), 'expected 2050 kg')
  check(near(c.bf, 0.6) && near(c.br, 0.4), 'expected 60/40 front brake bias (PERP 50/50)')
  check(near(c.trf, 0.2), 'turnThrottleReduceFast: PERP 0.75 capped at 0.2 (fast turns keep their revs)')
  check(near(c.cz, -1 - 0.25 * 15), 'centre: PERP -1, lowered by a quarter wheel radius')
  check(near(c.psa, 150), 'handbrake slide as the PERP script has it')
  check(near(c.deg, 38.5), 'steering lock from the PERP script')
  check(near(c.dfast, 11 * 1.3), 'steering at speed: PERP 11 degrees x1.3')

  // 2. SL65 on its own PERP script (the server): anti-spin only
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", "scripts/vehicles/tdmcars/sl65amg.txt", SL65))`)
  c = parse(res)
  console.log('SL65 on its PERP script:  ', c)
  check(c.perp === 'false' && c.anti === 'true', 'on its own script: anti-spin only')
  check(near(c.hp, 260) && near(c.mph, 94), 'PERP engine untouched')
  check(near(c.bf, 0.6) && near(c.br, 0.4), 'front brake bias on the PERP script too')

  // 3. spiked: nothing
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", "scripts/vehicles/tdmcars/spiked/sl65amg.txt", SL65))`)
  c = parse(res)
  console.log('SL65 on spiked tyres:     ', c)
  check(c.spiked === 'true' && c.anti === 'false' && c.perp === 'false', 'spiked: left alone')
  check(near(c.bf, 0.5) && near(c.br, 0.5), 'spiked: brakes untouched')

  // 4. stability for PERP cars, with their steering angles
  await L.doString(`
    local on, off, n = 0, 0, 0
    for _, car in pairs(E.Cars) do
      if car.perp then
        n = n + 1
        if type(car.stability) == "table" and car.stability.steerSlow then on = on + 1 else off = off + 1 end
      end
    end
    local sl = E.Cars["models/tdmcars/sl65amg.mdl"].stability
    __result(n .. "|" .. on .. "|" .. off .. "|" .. tostring(sl and sl.steerSlow) .. "|" .. tostring(sl and sl.steerFast))`)
  const [n, on, off, ss, sf] = res.split('|')
  console.log(`stability assist: ${on} of ${n} PERP cars (SL65 steering ${ss} / ${sf} degrees)`)
  check(+on === +n, 'every PERP car should get the stability assist')
  check(+ss === 38.5 && +sf === 11, 'SL65 steering angles from its script')

  console.log(fail ? `${fail} check(s) FAILED` : 'all checks passed')
  process.exit(fail ? 1 : 0)
})().catch((e) => { console.error(e); process.exit(1) })
