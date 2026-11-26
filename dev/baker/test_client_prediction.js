/*
  Offline check of cl_handling.lua's Garry's Mod side (no Garry's Mod needed):

    node test_client_prediction.js

  test_prediction.js checks the prediction's numbers (sh_handling.lua and a copy of the client's
  steps). This runs the real client file in a mock of the parts of GMod it touches, with
  Source's own angle maths (AngleVectors, VectorAngles, LocalToWorld / WorldToLocal), a flat road
  and no walls, and drives it the way the game does: StartCommand for each command, the server's
  state through net.Receive every other tick, then per frame hook.Call("CalcView"),
  PreDrawOpaqueRenderables and PostRender. It checks that, in the default heading-only mode:
    - holding A turns the car shown left (D right), about its rear axle, while it stays where
      Source has it otherwise; the first-person camera turns with it, by the same angle about the
      same point; the third-person camera turns with it too
    - what's parented to the car (a lightbar) is drawn on the car shown, and DisplayPose agrees
    - the render origin / angles are off once the frame is drawn, and the position moved for the
      sound is put back
    - the other cars aren't moved
  and with audio_engine_predict_position 1 the whole car is drawn ahead, as before; nothing is
  moved with audio_engine_predict 0 or without a state.
*/
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const LUA = path.join(ADDON, 'lua', 'audio_engine')

;(async () => {
  const L = await new LuaFactory().createEngine()
  let result = null
  L.global.set('__result', (v) => { result = v })
  await L.doString(String.raw`
    unpack = unpack or table.unpack
    math.atan2 = math.atan2 or math.atan      -- (LuaJIT's, as GMod has it)
    -- Source's maths -------------------------------------------------------------------------
    local VectorMeta = {}
    VectorMeta.__index = VectorMeta
    function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VectorMeta) end
    VectorMeta.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
    VectorMeta.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
    VectorMeta.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
    VectorMeta.__mul = function(a, b)
      if type(a) == "number" then return Vector(b.x * a, b.y * a, b.z * a) end
      return Vector(a.x * b, a.y * b, a.z * b)
    end
    VectorMeta.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
    function VectorMeta:Dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
    function VectorMeta:Cross(o) return Vector(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x) end
    function VectorMeta:LengthSqr() return self:Dot(self) end
    function VectorMeta:Length() return math.sqrt(self:Dot(self)) end
    function VectorMeta:Distance(o) return (self - o):Length() end
    function VectorMeta:DistToSqr(o) return (self - o):LengthSqr() end
    function VectorMeta:GetNormalized() local l = self:Length() return l > 0 and self / l or Vector() end
    function VectorMeta:Normalize() local n = self:GetNormalized() self.x, self.y, self.z = n.x, n.y, n.z end
    function VectorMeta:SetUnpacked(x, y, z) self.x, self.y, self.z = x, y, z end
    function isvector(x) return getmetatable(x) == VectorMeta end

    local AngleMeta = {}
    AngleMeta.__index = AngleMeta
    function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, AngleMeta) end
    -- AngleVectors: forward, left (= -right), up (the matrix columns)
    local function axesOf(angles)
      local sp, cp = math.sin(math.rad(angles.p)), math.cos(math.rad(angles.p))
      local sy, cy = math.sin(math.rad(angles.y)), math.cos(math.rad(angles.y))
      local sr, cr = math.sin(math.rad(angles.r)), math.cos(math.rad(angles.r))
      return Vector(cp * cy, cp * sy, -sp), Vector(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp), Vector(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
    end
    -- MatrixAngles
    local function anglesOf(forward, left, up)
      local xy = math.sqrt(forward.x * forward.x + forward.y * forward.y)
      if xy > 0.001 then
        return Angle(math.deg(math.atan(-forward.z, xy)), math.deg(math.atan(forward.y, forward.x)), math.deg(math.atan(left.z, up.z)))
      end
      return Angle(math.deg(math.atan(-forward.z, xy)), math.deg(math.atan(-left.x, left.y)), 0)
    end
    function AngleMeta:Forward() local f = axesOf(self) return f end
    function AngleMeta:Right() local _, l = axesOf(self) return -l end
    function AngleMeta:Up() local _, _, u = axesOf(self) return u end
    -- Vector:AngleEx(up) (VectorAngles with a pseudo-up)
    function VectorMeta:AngleEx(up)
      local forward = self:GetNormalized()
      local left = up:Cross(forward):GetNormalized()
      return anglesOf(forward, left, forward:Cross(left))
    end
    function LocalToWorld(localPosition, localAngles, origin, originAngles)
      local f, l, u = axesOf(originAngles)
      local function toWorld(v) return f * v.x + l * v.y + u * v.z end
      local lf, ll, lu = axesOf(localAngles)
      return origin + toWorld(localPosition), anglesOf(toWorld(lf), toWorld(ll), toWorld(lu))
    end
    function WorldToLocal(position, angles, origin, originAngles)
      local f, l, u = axesOf(originAngles)
      local function toLocal(v) return Vector(v:Dot(f), v:Dot(l), v:Dot(u)) end
      local wf, wl, wu = axesOf(angles)
      return toLocal(position - origin), anglesOf(toLocal(wf), toLocal(wl), toLocal(wu))
    end
    function Lerp(t, a, b) return a + (b - a) * t end
    function LerpVector(t, a, b) return a + (b - a) * t end
    function LerpAngle(t, a, b)
      local function wrap(x) return (x + 540) % 360 - 180 end
      return Angle(a.p + wrap(b.p - a.p) * t, a.y + wrap(b.y - a.y) * t, a.r + wrap(b.r - a.r) * t)
    end
    function math.NormalizeAngle(x) return (x + 180) % 360 - 180 end
    function math.Approach(value, target, step) if value < target then return math.min(value + step, target) end return math.max(value - step, target) end
    function math.Clamp(x, a, b) return math.max(a, math.min(b, x)) end
    function math.Round(x) return math.floor(x + 0.5) end
    vector_origin, angle_zero = Vector(), Angle()
    MASK_SOLID_BRUSHONLY, MASK_SOLID = 16395, 33570827

    -- the world: a flat road at z = 0, no walls
    util = {
      TraceLine = function(data)
        local out = data.output or {}
        out.Hit, out.StartSolid = data.start.z >= 0 and data.endpos.z <= 0, false
        out.HitPos, out.HitNormal, out.Fraction = Vector(data.start.x, data.start.y, 0), Vector(0, 0, 1), 1
        return out
      end,
      TraceHull = function(data)
        local out = data.output or {}
        out.Hit, out.StartSolid, out.Fraction, out.HitNormal, out.HitPos = false, false, 1, Vector(0, 0, 1), data.endpos
        return out
      end,
    }

    -- entities --------------------------------------------------------------------------------
    local EntityMeta = {}
    EntityMeta.__index = EntityMeta
    function FindMetaTable(name) if name == "Entity" then return EntityMeta end end
    function EntityMeta:SetRenderOrigin(position) self.renderOrigin = position end
    function EntityMeta:SetRenderAngles(angles) self.renderAngles = angles end
    function EntityMeta:InvalidateBoneCache() end
    function EntityMeta:MarkShadowAsDirty() end
    function EntityMeta:GetPos() return self.pos end
    function EntityMeta:SetPos(position) self.pos = position end
    function EntityMeta:GetNetworkOrigin() return self.pos end
    function EntityMeta:GetAngles() return self.ang end
    function EntityMeta:GetClass() return self.class end
    function EntityMeta:GetModel() return self.model end
    function EntityMeta:EntIndex() return self.index end
    function EntityMeta:GetChildren() return self.children or {} end
    function EntityMeta:IsDormant() return false end
    function EntityMeta:IsPlayer() return self.isPlayer == true end
    function EntityMeta:IsVehicle() return self.isVehicle == true end
    function EntityMeta:GetParent() return self.parent end
    function EntityMeta:GetUp() return self.ang:Up() end
    function EntityMeta:OBBMins() return Vector(-40, -110, 0) end
    function EntityMeta:OBBMaxs() return Vector(40, 110, 60) end
    function EntityMeta:OBBCenter() return Vector(0, 0, 30) end
    function EntityMeta:GetRenderBounds() return self.renderMins or Vector(-40, -110, 0), self.renderMaxs or Vector(40, 110, 60) end
    function EntityMeta:SetRenderBounds(mins, maxs) self.renderMins, self.renderMaxs = mins, maxs end
    function EntityMeta:LocalToWorld(position) return (LocalToWorld(position, Angle(), self.pos, self.ang)) end
    function EntityMeta:GetNW2Float(_, default) return default end
    function EntityMeta:LookupPoseParameter() return -1 end
    local WHEELS = { wheel_fl = Vector(-32, 52, 14), wheel_fr = Vector(32, 52, 14), wheel_rl = Vector(-32, -54, 14), wheel_rr = Vector(32, -54, 14) }
    local WHEEL_IDS = { "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }
    function EntityMeta:LookupAttachment(name) for id, wheel in ipairs(WHEEL_IDS) do if wheel == name then return id end end return 0 end
    function EntityMeta:GetAttachment(id) return { Pos = (LocalToWorld(WHEELS[WHEEL_IDS[id]], Angle(), self.pos, self.ang)) } end
    function EntityMeta:WorldToLocal(position) return (WorldToLocal(position, Angle(), self.pos, self.ang)) end
    function EntityMeta:GetThirdPersonMode() return THIRD_PERSON == true end
    local function newEntity(fields) return setmetatable(fields, EntityMeta) end

    VEHICLE = newEntity({ class = "prop_vehicle_jeep", model = "models/test/car.mdl", index = 77, isVehicle = true, pos = Vector(100, 200, 20), ang = Angle(0, 0, 0) })
    LIGHTBAR = newEntity({ class = "prop_dynamic", model = "models/test/bar.mdl", index = 78, parent = VEHICLE, pos = Vector(100, 190, 90), ang = Angle(0, 0, 0) })
    VEHICLE.children = { LIGHTBAR }
    OTHER = newEntity({ class = "prop_vehicle_jeep", model = "models/test/car.mdl", index = 79, isVehicle = true, pos = Vector(400, 200, 20), ang = Angle(0, 0, 0) })
    PLAYER = newEntity({ isPlayer = true, index = 1, pos = Vector(100, 205, 40), ang = Angle(0, 90, 0), ping = 150, keys = {} })
    function PLAYER:GetVehicle() return VEHICLE end
    function PLAYER:Ping() return self.ping end
    function PLAYER:KeyDown(key) return self.keys[key] == true end
    function PLAYER:GetViewEntity() return self end
    function PLAYER:IsListenServerHost() return false end
    function PLAYER:EyePos() return self.pos end
    function LocalPlayer() return PLAYER end
    function IsValid(x) return x ~= nil and x ~= false end
    player = { GetAll = function() return { PLAYER } end }
    ents = { FindByClass = function() return { VEHICLE, OTHER } end }

    -- the rest of the API ----------------------------------------------------------------------
    IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP = 8, 16, 512, 1024, 2
    FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 128, 8192, 256
    CONVARS = {}
    local ConVarMeta = {}
    ConVarMeta.__index = ConVarMeta
    function ConVarMeta:GetBool() return (tonumber(self.value) or 0) ~= 0 end
    function ConVarMeta:GetFloat() return tonumber(self.value) or 0 end
    function CreateClientConVar(name, default) local c = setmetatable({ value = default }, ConVarMeta) CONVARS[name] = c return c end
    CreateConVar = CreateClientConVar
    function GetConVar(name) return CONVARS[name] end
    game = { SinglePlayer = function() return false end }
    engine = { TickInterval = function() return 1 / 66 end }
    NOW, FRAME = 10, 1000
    function RealTime() return NOW end
    function CurTime() return NOW end
    function FrameNumber() return FRAME end
    timer = { Create = function() end }
    COMMANDS = {}
    concommand = { Add = function(name, callback) COMMANDS[name] = callback end }
    render = { DrawWireframeBox = function() end }
    file = { Write = function() end }
    function Color(r, g, b) return { r = r, g = g, b = b } end
    function table.Empty(t) for k in pairs(t) do t[k] = nil end end
    PRINTED = ""
    print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end PRINTED = PRINTED .. table.concat(t, "\t") .. "\n" end

    HOOKS = {}
    hook = { Add = function(event, name, callback) HOOKS[event] = HOOKS[event] or {} HOOKS[event][name] = callback end }
    function hook.Call(event, gamemodeTable, ...)
      for _, callback in pairs(HOOKS[event] or {}) do
        local a, b, c = callback(...)
        if a ~= nil then return a, b, c end
      end
      if gamemodeTable and gamemodeTable[event] then return gamemodeTable[event](gamemodeTable, ...) end
    end

    local receivers, reading = {}, nil
    net = {
      Receive = function(name, callback) receivers[name] = callback end,
      ReadUInt = function() return table.remove(reading, 1) end,
      ReadInt = function() return table.remove(reading, 1) end,
      ReadFloat = function() return table.remove(reading, 1) end,
      ReadDouble = function() return table.remove(reading, 1) end,
      ReadBool = function() return table.remove(reading, 1) end,
    }
    -- sv_handling.lua's sendState, field by field in its order
    function SEND_STATE(state)
      reading = { VEHICLE:EntIndex(), state.command, 0, state.time, state.px, state.py, state.pz, state.p, state.y, state.r,
        state.vx, state.vy, state.vz, state.yawRate, state.yawRate, math.Round(state.steer * 127), state.drift, true, state.impact,
        100, 100, state.buttons, 0 }
      receivers.audio_engine_drive()
      assert(#reading == 0, "cl_handling read fewer fields than the server sends")
    end

    AUDIO_ENGINE = {}
    AUDIO_ENGINE.GetCarConfig = function(vehicle) return vehicle and vehicle.isVehicle and { name = "test" } or nil end
    AUDIO_ENGINE.RiddenCar = function(rider) return rider:GetVehicle() end
    -- the gamemode's own first-person car view: the eyes in the car, looking along its nose
    GAMEMODE = { CalcView = function(self, viewer, origin, angles, fov) return { origin = origin, angles = angles, fov = fov } end }
  `)
  const run = async (name, source) => { try { await L.doString(source) } catch (error) { throw new Error(name + ': ' + error.message) } }
  await run('sh_handling.lua', fs.readFileSync(path.join(LUA, 'sh_handling.lua'), 'utf8'))
  await run('cl_handling.lua', fs.readFileSync(path.join(LUA, 'cl_handling.lua'), 'utf8'))
  await run('checks', String.raw`
    local failures = {}
    local function check(ok, text) if not ok then failures[#failures + 1] = text end end
    local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 0.01) end
    local function wrap(angle) return (angle + 540) % 360 - 180 end
    local INCH = 0.0254
    local SPEED = 20 / INCH                       -- along the nose: model +y = world +y at yaw 0
    local EYES_LOCAL = Vector(-16, -8, 44)        -- the driver's eyes in the car
    local REAR_AXLE = Vector(0, -54, 14)
    local commandNumber = 0

    -- one client tick: a command with these keys through StartCommand (as prediction runs it)
    local function command(keys)
      commandNumber = commandNumber + 1
      local cmd = { number = commandNumber }
      function cmd:CommandNumber() return self.number end
      function cmd:KeyDown(key) return keys[key] == true end
      for _, callback in pairs(HOOKS.StartCommand) do callback(PLAYER, cmd) end
    end
    -- one frame: Source has the car at its pose, the game asks for the view, draws, ends the frame
    local function frame(dt)
      NOW, FRAME = NOW + dt, FRAME + 1
      local eyes = LocalToWorld(EYES_LOCAL, Angle(), VEHICLE.pos, VEHICLE.ang)
      local view = hook.Call("CalcView", GAMEMODE, PLAYER, eyes, Angle(VEHICLE.ang.p, VEHICLE.ang.y, VEHICLE.ang.r), 75, 3, 30000)
      for _, callback in pairs(HOOKS.PreDrawOpaqueRenderables) do callback(false, false) end
      local drawn = { origin = VEHICLE.renderOrigin, angles = VEHICLE.renderAngles, barOrigin = LIGHTBAR.renderOrigin,
        barPose = { AUDIO_ENGINE.DisplayPose(LIGHTBAR) }, otherOrigin = OTHER.renderOrigin }
      local sourcePosition = Vector(VEHICLE.pos.x, VEHICLE.pos.y, VEHICLE.pos.z)
      for _, callback in pairs(HOOKS.PostRender) do callback() end
      check(VEHICLE.renderOrigin == nil and VEHICLE.renderAngles == nil and LIGHTBAR.renderOrigin == nil, "the render origin / angles stayed on after the frame")
      -- (the sound's move: the car's position put where it was drawn, then back on Think)
      for _, callback in pairs(HOOKS.Think) do callback() end
      check(VEHICLE.pos:Distance(sourcePosition) < 0.01, "the car's position wasn't put back after the sound update")
      return view, drawn, eyes
    end
    -- the server's state for a command it ran (the car going straight where Source shows it)
    local function state(number)
      SEND_STATE({ command = number, time = NOW - 0.075, px = VEHICLE.pos.x, py = VEHICLE.pos.y, pz = VEHICLE.pos.z,
        p = VEHICLE.ang.p, y = VEHICLE.ang.y, r = VEHICLE.ang.r, vx = 0, vy = SPEED, vz = 0, yawRate = 0, steer = 0,
        drift = false, impact = false, buttons = 1 })
    end
    local view, drawn, eyes
    -- driving: a command and a frame a tick, every other tick the server's state for the command it
    -- ran 10 ticks ago (~150 ms of ping), the car still going straight there
    local function drive(keys, ticks)
      for i = 1, ticks do
        command(keys)
        if commandNumber % 2 == 0 then state(commandNumber - 10) end
        view, drawn, eyes = frame(1 / 66)
      end
    end
    local FORWARD, LEFT, RIGHT = { [IN_FORWARD] = true }, { [IN_FORWARD] = true, [IN_MOVELEFT] = true }, { [IN_FORWARD] = true, [IN_MOVERIGHT] = true }
    local function turnedBy() return drawn.angles and wrap(drawn.angles.y - VEHICLE.ang.y) or 0 end

    -- no state yet: nothing moved
    for i = 1, 10 do command(FORWARD) end
    view, drawn, eyes = frame(1 / 60)
    check(drawn.origin == nil and near(view.origin.x, eyes.x) and near(view.angles.y, 0), "moved without a state from the server")

    drive(FORWARD, 30)
    check(math.abs(turnedBy()) < 0.05, string.format("turned %.2f deg with no key held", turnedBy()))
    drive(LEFT, 30)
    local leftLead = turnedBy()
    check(drawn.origin ~= nil, "A held, states coming: the car was not drawn turned")
    check(leftLead > 3, string.format("A held: the car shown should turn left (yaw up), turned %.2f deg", leftLead))
    if drawn.origin then
      check(near(drawn.angles.p, 0, 1e-3) and near(drawn.angles.r, 0, 1e-3), "the car shown tipped over (only the heading may change)")
      -- about the rear axle: it stays where Source has it, the nose swings left (-x at yaw 0)
      local rearShown = LocalToWorld(REAR_AXLE, Angle(), drawn.origin, drawn.angles)
      local rearSource = LocalToWorld(REAR_AXLE, Angle(), VEHICLE.pos, VEHICLE.ang)
      check(rearShown:Distance(rearSource) < 0.01, string.format("the rear axle moved %.3f in (the car must turn about it, not move)", rearShown:Distance(rearSource)))
      check(LocalToWorld(Vector(0, 110, 30), Angle(), drawn.origin, drawn.angles).x < VEHICLE.pos.x - 5, "the nose shown didn't swing left")
      -- the first-person camera: turned by the same angle, its eyes where they sit in the car shown
      check(near(wrap(view.angles.y - VEHICLE.ang.y), leftLead, 1e-3), string.format("the camera turned %.3f deg, the car %.3f", wrap(view.angles.y - VEHICLE.ang.y), leftLead))
      local eyesShown = LocalToWorld(EYES_LOCAL, Angle(), drawn.origin, drawn.angles)
      check(view.origin:Distance(eyesShown) < 0.5, string.format("the camera is %.3f in off the eyes of the car shown", view.origin:Distance(eyesShown)))
      -- the lightbar on the car shown, DisplayPose agreeing; the other car where Source has it
      local barLocal = WorldToLocal(LIGHTBAR.pos, LIGHTBAR.ang, VEHICLE.pos, VEHICLE.ang)
      local barShown = LocalToWorld(barLocal, Angle(), drawn.origin, drawn.angles)
      check(drawn.barOrigin and drawn.barOrigin:Distance(barShown) < 0.01, "the lightbar wasn't drawn on the car shown")
      check(drawn.barPose[1] and drawn.barPose[1]:Distance(barShown) < 0.01, "DisplayPose disagrees with where the lightbar is drawn")
      check(drawn.otherOrigin == nil, "another car was moved in the heading-only mode")
    end

    -- the third-person camera turns with the car shown (it takes the server's corrections more
    -- slowly than the car, cameraSmoothTime: here the server never answers the keys, so every
    -- state is a big correction and the camera keeps more of them)
    THIRD_PERSON = true
    drive(LEFT, 4)
    local cameraTurned = view.angles and wrap(view.angles.y - VEHICLE.ang.y) or 0
    check(cameraTurned > 0.5 * turnedBy() and cameraTurned < turnedBy() + 10, string.format("third person: the camera turned %.2f deg, the car %.2f", cameraTurned, turnedBy()))
    check(view.drawviewer == true, "third person: the driver isn't drawn")
    THIRD_PERSON = false

    -- letting go: the lead goes back; then D turns right
    drive(FORWARD, 50)
    check(math.abs(turnedBy()) < 0.5, string.format("the lead stayed (%.2f deg) after the key was let go", turnedBy()))
    drive(RIGHT, 30)
    local rightLead = turnedBy()
    check(rightLead < -3, string.format("D held: the car shown should turn right (yaw down), turned %.2f deg", rightLead))

    -- the stats command runs
    COMMANDS.audio_engine_predict_stats()
    check(PRINTED and PRINTED:find("heading lead"), "audio_engine_predict_stats didn't print the heading lead")

    -- the whole car (audio_engine_predict_position 1): drawn ahead of Source's car along its path, as before
    CONVARS.audio_engine_predict_position.value = "1"
    drive(FORWARD, 40)
    local ahead = drawn.origin and (drawn.origin - VEHICLE.pos):Dot(Vector(0, 1, 0)) or 0
    check(ahead > 50, string.format("whole car: drawn only %.0f in ahead of Source's car", ahead))
    CONVARS.audio_engine_predict_position.value = "0"
    drive(FORWARD, 40)
    local rearShown = drawn.origin and LocalToWorld(REAR_AXLE, Angle(), drawn.origin, drawn.angles)
    check(not rearShown or rearShown:Distance(LocalToWorld(REAR_AXLE, Angle(), VEHICLE.pos, VEHICLE.ang)) < 0.01, "back to heading only: the car still drawn ahead")

    -- nothing moved with the prediction off
    CONVARS.audio_engine_predict.value = "0"
    drive(RIGHT, 3)
    check(drawn.origin == nil and near(view.angles.y, 0), "moved with audio_engine_predict 0")
    CONVARS.audio_engine_predict.value = "1"

    __result(string.format("%.2f|%.2f|", leftLead, rightLead) .. table.concat(failures, "\n"))
  `)
  const [left, right, ...rest] = result.split('|')
  const failures = rest.join('|')
  console.log(`heading only: A held turned the car shown ${left} deg left, D held ${right} deg (rear axle, cameras, lightbar, other car, sound checked)`)
  if (failures) { console.log('FAILED:\n  ' + failures.split('\n').join('\n  ')); process.exit(1) }
  console.log('all checks passed')
})().catch((error) => { console.error(error); process.exit(1) })
