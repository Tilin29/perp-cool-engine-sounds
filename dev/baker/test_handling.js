/*
  Offline checks of sv_handling.lua with a fake vehicle (no Garry's Mod needed):
    - a PERP car spawned on the generic test script gets its PERP base-script physics, and no
      other change to its script's handling than Source's steering fitted to the model (no throttle
      cut while steering, the wheel angle at speed); on its own script only that; spiked: none at all
    - the handling model (sh_handling.lua): steering turns the car, the turn never asks more than the
      tyres' grip, sideways speed goes at the grip limit, the speed along the nose is never touched,
      the handbrake lets the rear go, the model off (controlShare 0) does nothing; grip per kind of car

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
    util = util or {}
    util.AddNetworkString = function() end
    IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP = 8, 16, 512, 1024, 2
    -- (hooks kept, so a check can run one; game / bit as GMod's)
    HOOKS = {}
    hook.Add = function(event, name, callback) HOOKS[event] = HOOKS[event] or {} HOOKS[event][name] = callback end
    game = game or { SinglePlayer = function() return false end }
    bit = bit or { band = function(a, b) return a & b end }
    AUDIO_ENGINE = {}`)
  for (const f of ['sh_config.lua', 'sh_presets.lua', 'sh_drivetrain.lua', 'sh_handling.lua', 'sh_carlist.lua', 'sv_perp_physics.lua', 'sv_handling.lua'])
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
      function veh:AddCallback(name, callback) self.callbacks = self.callbacks or {}; self.callbacks[name] = callback end
      function veh:GetKeyValues() return self.kv end
      function veh:LookupAttachment() return 0 end   -- (no wheel attachments: the default wheelbase)
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
        tostring(veh.audioPerpPhysics or false), tostring(veh.callbacks and veh.callbacks.PhysicsCollide ~= nil), tostring(veh.audioSpiked or false),
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

  // 1. SL65 on the test script: PERP's numbers, nothing else
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", E.TEST_SCRIPT, TESTCAR))`)
  let c = parse(res)
  console.log('SL65 on the test script:', c)
  check(c.perp === 'true', 'expected PERP physics on the test script')
  check(c.anti === 'true', 'expected the impact callback (PhysicsCollide)')
  check(near(c.hp, 260) && near(c.mph, 94), 'expected 260 hp / 94 mph from sl65amg.txt')
  check(c.gears === '5.5,4.2,3.7,2.2,1', 'expected the SL65 gears')
  check(near(c.mass, 2050), 'expected 2050 kg')
  check(near(c.bf, 0.5) && near(c.br, 0.5), 'brakes as PERP has them (50/50)')
  check(c.trf === 0, 'no throttle cut while steering under the model (PERP has 0.75)')
  check(near(c.cz, -1), 'centre of mass as PERP has it')
  check(near(c.psa, 150), 'handbrake slide as the PERP script has it')
  check(near(c.deg, 38.5), 'parking lock from the PERP script')
  check(c.dfast > 5 && c.dfast < c.deg, "Source's wheel angle at speed fitted to the model's turn at 35 mph (+10% + 0.5), under its lock")

  // 2. SL65 on its own PERP script (the server): untouched
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", "scripts/vehicles/tdmcars/sl65amg.txt", SL65))`)
  c = parse(res)
  console.log('SL65 on its PERP script:  ', c)
  check(c.perp === 'false', 'on its own script: no PERP physics put on')
  check(near(c.hp, 260) && near(c.mph, 94) && near(c.bf, 0.5), 'its script untouched')
  check(c.trf === 0 && c.dfast > 5 && c.dfast < c.deg, "but Source's steering fitted to the model (under its lock)")

  // 3. spiked: nothing
  await L.doString(`__result(Spawn("models/tdmcars/sl65amg.mdl", "scripts/vehicles/tdmcars/spiked/sl65amg.txt", SL65))`)
  c = parse(res)
  console.log('SL65 on spiked tyres:     ', c)
  check(c.spiked === 'true' && c.perp === 'false' && near(c.trf, 0.75) && near(c.dfast, 14), 'spiked: left alone')

  // 4. the handling model on a body going along +y (the TDM nose) at `speed` m/s, `side` m/s sideways
  await L.doString(`
    H = E.Handling
    SPEC = { settings = H.SettingsFor("test"), wheelbase = 2.7, noseX = 0, noseY = 1, noseZ = 0 }
    function Body(speed, side, yawRate, share)
      return { px = 0, py = 0, pz = 0, vx = (side or 0) / H.INCH, vy = speed / H.INCH, vz = 0, ax = 1, ay = 0, az = 0, bx = 0, by = 1, bz = 0,
        cx = 0, cy = 0, cz = 1, yawRate = yawRate or 0, groundShare = 1, controlShare = share or 1 }
    end
    -- run the model n ticks with the keys held, applying it; returns the yaw rate, sideways and forward speed (m/s)
    function Run(body, buttons, ticks, steer)
      local state = { steer = steer or 0, drift = false }
      local asked = 0
      for _ = 1, ticks do
        local yawChange, sideChange
        local forwardChange
        yawChange, sideChange, asked, forwardChange = H.Control(body, state, buttons, SPEC, 1 / 66)
        H.ApplyControl(body, SPEC, yawChange, sideChange, forwardChange)
      end
      local nx, ny, nz, rx, ry, rz = H.NoseOf(body, SPEC)
      return body.yawRate, (body.vx * rx + body.vy * ry) * H.INCH, (body.vx * nx + body.vy * ny) * H.INCH, asked, state
    end
    local L, R, J = H.KEY_LEFT, H.KEY_RIGHT, H.KEY_HANDBRAKE
    local out = {}
    local yaw = Run(Body(10), L, 40)
    out[#out + 1] = yaw                                     -- 1 left at 10 m/s: turns left (+)
    yaw = Run(Body(10), R, 40)
    out[#out + 1] = yaw                                     -- 2 right: (-)
    local yaw30, _, _, asked30 = Run(Body(30), L, 120)
    out[#out + 1] = yaw30                                   -- 3 at 30 m/s, held
    out[#out + 1] = H.TurnLimit(SPEC.settings, 30)            -- 4 the turn limit there (grip or the turn floor)
    local _, side, forward = Run(Body(20, 5), 0, 1)
    out[#out + 1] = side                                    -- 5 sideways after one tick (from 5 m/s)
    out[#out + 1] = forward                                 -- 6 forward after it (20 m/s)
    local _, sideHandbrake = Run(Body(20, 5), J, 1)
    out[#out + 1] = sideHandbrake                           -- 7 with the handbrake: less taken away
    local yawOff, sideOff = Run(Body(20, 5, 15, 0), L, 30)
    out[#out + 1] = yawOff                                  -- 8 model off: the yaw rate stays 15
    out[#out + 1] = sideOff                                 -- 9 ... and the slide 5 m/s
    local yawBack = Run(Body(-5), L, 60)
    out[#out + 1] = yawBack                                 -- 10 reversing, steering left: turns the other way
    local yawParked = Run(Body(0.5, 0, 7), L, 30)
    out[#out + 1] = yawParked                               -- 11 under minSpeed: Source alone (7 stays)
    out[#out + 1] = H.SettingsFor("Bugatti Veyron 16.4").grip  -- 12
    out[#out + 1] = H.SettingsFor("Chevrolet Spark").grip      -- 13
    out[#out + 1] = H.SettingsFor("Ford Crown Victoria").grip  -- 14
    -- downforce: a fast car's grip at 50 m/s and at 10 m/s, and the turn it holds at 50
    local fast = H.SettingsFor("Bugatti Veyron 16.4")
    out[#out + 1] = H.SlideGripAt(fast, 50)                    -- 15
    out[#out + 1] = H.SlideGripAt(fast, 10)                    -- 16
    out[#out + 1] = H.SlideGripAt(H.SettingsFor("Ford Crown Victoria"), 50)  -- 17
    local saved = SPEC.settings
    SPEC.settings = fast
    out[#out + 1] = Run(Body(50), L, 200)                      -- 18 held at 50 m/s
    SPEC.settings = saved
    out[#out + 1] = H.GripAt(SPEC.settings, 20) * SPEC.settings.sideHold  -- 19 the sideways hold at 20 m/s
    -- the keys' turn at full lock, 20 / 25 / 30 / 40 / 50 / 60 mph (deg/s): progressive, no cliff
    for _, mph in ipairs({ 20, 25, 30, 40, 50, 60 }) do
      out[#out + 1] = math.deg(math.min(mph * 0.44704 * math.tan(math.rad(H.Lock(SPEC.settings, mph * 0.44704))) / 2.7, math.rad(H.TurnLimit(SPEC.settings, mph * 0.44704))))
    end
    __result(table.concat(out, "|"))`)
  const v = res.split('|').map(Number)
  console.log('model:', v.map((x) => +x.toFixed(3)).join(' | '))
  check(v[0] > 5, 'steering left turns the car left')
  check(v[1] < -5, 'steering right turns it right')
  check(v[2] > v[3] * 0.9 && v[2] <= v[3] * 1.001, `at 30 m/s the turn sits at the turn limit (${v[2].toFixed(1)} of ${v[3].toFixed(1)} deg/s)`)
  check(near(v[4], 5 - v[18] * 9.81 / 66, 0.01), 'a slide loses grip x sideHold x g of sideways speed a second')
  check(near(v[5], 20, 0.001), 'taking a slide out costs its speed (the speed along the nose untouched, never raised)')
  check(v[6] > v[4] && v[6] < 5, 'the handbrake lets the rear go (less sideways grip)')
  check(near(v[7], 15, 0.001) && near(v[8], 5, 0.001), 'with the model off nothing changes')
  check(v[9] < -1, 'reversing, the steering turns the car the other way')
  check(near(v[10], 7, 0.001), 'parking speeds are left to Source')
  check(near(v[11], 1.3) && near(v[12], 1.05) && near(v[13], 1.15), 'grip: high-powered 1.3, economy 1.05, others 1.15')

  // 4b. every way out of Control gives all four changes as numbers (the server adds them up: a nil
  // fourth from the early exit, standing / in the air / model off, errored every tick)
  await L.doString(`
    local out = {}
    for _, case in ipairs({ { 0.5, 1 }, { 20, 0 }, { 20, 1 } }) do
      local results = { H.Control(Body(case[1], 0, 0, case[2]), { steer = 0, drift = false }, H.KEY_LEFT, SPEC, 1 / 66) }
      local ok = #results == 4
      for i = 1, 4 do ok = ok and type(results[i]) == "number" end
      out[#out + 1] = ok and 1 or 0
    end
    __result(table.concat(out, "|"))`)
  check(res === '1|1|1', `Control returns four numbers on every path (parked / model off / driving): ${res}`)

  // 4c. a car's settings are read live: a value added to its CAR_HANDLING entry after the car took its
  // settings (a Lua refresh on a running server) reaches it
  await L.doString(`
    local settings = H.SettingsFor("Mercedes McLaren SLR")
    local before = settings.turnFloor
    E.CAR_HANDLING["Mercedes McLaren SLR"].testValue = 42
    local seen = settings.testValue
    E.CAR_HANDLING["Mercedes McLaren SLR"].testValue = nil
    __result(before .. "|" .. tostring(seen))`)
  check(res === '75|42', `a car's settings follow CAR_HANDLING live (turn floor ${res.split('|')[0]}, added value ${res.split('|')[1]})`)

  // 4e. obstructed: the rotation stopped every tick (a wall at the front corner): after the first tick
  // the model only follows gently instead of setting the full turn again
  await L.doString(`
    local body = Body(15)
    body.touching = true
    local state = { steer = 1, drift = false }
    local changes = {}
    for tick = 1, 10 do
      local yawChange = H.Control(body, state, H.KEY_LEFT, SPEC, 1 / 66)
      changes[tick] = yawChange
      body.yawRate = 0      -- the wall: no rotation got through
    end
    -- not touching anything: Source's tyres taking the rotation back is no wall, the turn is still set
    local open, openState = Body(15), { steer = 1, drift = false }
    local openChange = 0
    for tick = 1, 10 do openChange = H.Control(open, openState, H.KEY_LEFT, SPEC, 1 / 66); open.yawRate = 0 end
    -- free: the same without the wall, tick 10
    local free, freeState = Body(15), { steer = 1, drift = false }
    local freeChange = 0
    for tick = 1, 10 do freeChange = H.Control(free, freeState, H.KEY_LEFT, SPEC, 1 / 66); H.ApplyControl(free, SPEC, freeChange, 0, 0) end
    __result(string.format("%.2f|%.2f|%.2f|%.2f", changes[2], changes[10], free.yawRate, openChange))`)
  const blocked = res.split('|').map(Number)
  check(blocked[1] < blocked[2] * 0.2, `against a wall the turn is no longer forced every tick (tick 10: ${blocked[1]} deg/s set, free car turning ${blocked[2]})`)
  check(blocked[3] > blocked[2] * 0.5, `not touching anything, a rotation taken back is still forced (tick 10: ${blocked[3]} deg/s set)`)

  // 4g. a Lua refresh on a running server: values left from an older file (the turn floor off, a
  // per-car copy) give way to the file's, and cars keep reading the same table
  g.set('__shHandling', fs.readFileSync(path.join(LUA, 'sh_handling.lua'), 'utf8'))
  g.set('__shCarlist', fs.readFileSync(path.join(LUA, 'sh_carlist.lua'), 'utf8'))
  await L.doString(`
    local handling = E.HANDLING
    handling.turnFloor = 0
    E.HANDLING_DEFAULTS = { turnFloor = 75 }
    E.CAR_HANDLING["Dodge Charger SRT-8"].turnFloor = 0
    local settings = H.SettingsFor("Dodge Charger SRT-8")
    load(__shHandling)()
    load(__shCarlist)()
    __result(string.format("%s|%s|%s", tostring(E.HANDLING == handling), tostring(E.HANDLING.turnFloor), tostring(H.SettingsFor("Dodge Charger SRT-8").turnFloor)))`)
  check(res === 'true|75|75', `a refresh brings the file's values (same table, turn floor, SRT-8's): ${res}`)

  // 5. Source's front wheels over FastCarSpeed matched to the model's turn (sv_handling
  // MatchedSteering / SourceSteerAngle; the params' speeds are mph): PERP's line 38 deg at a
  // standstill to the fitted 8 at 35 mph, then held
  await L.doString(`
    local steering = { degreesSlow = 38, degreesFast = 8, speedSlow = 0, speedFast = 35 }
    local spec = { settings = H.SettingsFor("Bugatti Veyron 16.4"), wheelbase = 2.7 }
    local out = {}
    for _, mph in ipairs({ 0, 10, 35, 67, 112 }) do
      local o = E.MatchedSteering(steering, spec, mph)
      out[#out + 1] = o and E.SourceSteerAngle({ degreesSlow = 38, speedSlow = 0, degreesFast = o.degreesFast, speedFast = o.speedFast }, mph)
        or E.SourceSteerAngle(steering, mph)
      out[#out + 1] = o and 1 or 0
    end
    out[#out + 1] = H.TurnAngle(spec.settings, spec.wheelbase, 112 * 0.44704)
    __result(table.concat(out, "|"))`)
  const st = res.split('|').map(Number)
  console.log('steering matched (deg, override on, at 0 / 10 / 35 / 67 / 112 mph | model at 112):', st.map((x) => +x.toFixed(2)).join(' | '))
  check(near(st[0], 38) && near(st[2], 38 - 30 * 10 / 35) && near(st[4], 8) && !st[1] && !st[3] && !st[5],
    "up to FastCarSpeed: Source's own line, no override (the params' speeds are mph)")
  check(st[7] && st[9] && st[8] < st[6] && st[8] < st[10] * 1.1 + 0.5 + 1e-6, "over it: the wheels follow the model's turn down, not held at DegreesFast")
  check(st[8] >= st[10], "never less than the model's turn")
  check(near(v[14], 1.95) && near(v[15], 1.3 * 1.02) && near(v[16], 1.15), `downforce: high-powered 1.95 g at 50 m/s, ${v[15].toFixed(3)} at 10, others none`)
  check(v[17] > 0.95 * Math.min(1.95 * 9.81 / 50 * 180 / Math.PI, 50 * Math.tan(5 * Math.PI / 180) / 2.6 * 180 / Math.PI) && v[17] > 1.4 * 1.3 * 9.81 / 50 * 180 / Math.PI,
    `downforce: at 50 m/s a high-powered car turns ${v[17].toFixed(1)} deg/s (grip alone ${(1.3 * 9.81 / 50 * 180 / Math.PI).toFixed(1)})`)
  const turns = v.slice(19, 25)
  console.log('full-lock turn at 20/25/30/40/50/60 mph:', turns.map((x) => x.toFixed(1)).join(' | '))
  check(turns.slice(1).every((x, i) => x > turns[i] * 0.8 && x < turns[i] * 1.2) && turns[5] < turns[2],
    'the turn eases off with speed, no cliff: each step (20/25/30/40/50/60 mph) keeps over 80% of the one before')

  console.log(fail ? `${fail} check(s) FAILED` : 'all checks passed')
  process.exit(fail ? 1 : 0)
})().catch((e) => { console.error(e); process.exit(1) })
