/*
  Offline check of the driving prediction (lua/audio_engine/sh_handling.lua), no Garry's Mod needed:

    node test_prediction.js [ping ms] [commands a packet]      (default 150, 1; 2 = cl_cmdrate 30 at 66 tick)

  A simulated server runs a car on "Source" physics that the client doesn't know (its own engine
  curve, brakes, tyre forces and steering, plus random bumps), with the handling model on top as
  sv_handling.lua runs it. The client sends a command per tick, gets the car's state every other
  tick, both ways half the ping late with jitter and 3% of states lost, and predicts at 144 fps as
  cl_handling.lua does (replay + learned acceleration + smoothing).

  It drives a lap of keys (launch, turns both ways, a lane change, braking, a handbrake turn) and
  reports, against where the server will have the car when it runs the newest key:
    - how far the predicted car is off (mean / 95th percentile / worst, inches and degrees)
    - how far plain Source (interpolated, cl_interp 0.1) is off, for comparison
    - how long a steering key takes to show, predicted vs plain
    - the largest jump a correction made on screen in one frame
  and the same for the default heading-only mode (audio_engine_predict_position 0: Source's car
  turned by Handling.HeadingLeadFrame, its position plain Source's): the heading shown, how soon a
  key shows, the lead itself (how far the nose runs ahead of the path), its steps, the crash.
  Fails if either isn't clearly better than plain Source.
*/
const path = require('path')
const fs = require('fs')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const PING = Number(process.argv[2] || 150)
const PER_PACKET = Math.max(1, Math.round(Number(process.argv[3] || 1)))

;(async () => {
  const L = await new LuaFactory().createEngine()
  let result = null
  L.global.set('__result', (v) => { result = v })
  await L.doString(`
    AUDIO_ENGINE = {}
    FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 128, 8192, 256
    IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP = 8, 16, 512, 1024, 2
    function CreateConVar() return { GetBool = function() return true end } end`)
  await L.doString(fs.readFileSync(path.join(ADDON, 'lua', 'audio_engine', 'sh_handling.lua'), 'utf8'))
  await L.doString(`PING = ${PING} PER_PACKET = ${PER_PACKET}`)
  // TICK (default 66; the test server runs 22), FPS (default 144): commands are made at the start of a
  // frame, as the game makes them. OLDCLOCK=1: the replay's length from the newest command's frame and
  // the server's raw command number, as before the command clocks
  await L.doString(`PATHLOG = ${!!process.env.PATHLOG}`)
  // WORLD=0: the replay without its world (road, walls), as before; the server's car still rides the road.
  // The road has a dip at x = -2600 (~80 mph) and a crest at x = -4100 (~87 mph, the car flies)
  await L.doString(`WORLD = ${process.env.WORLD !== '0'}`)
  // BOUNCE: inches the car's body rides over the road in the server's states (springs; default 1)
  await L.doString(`BOUNCE = ${Number(process.env.BOUNCE ?? 1)}`)
  await L.doString(`OLDCAMERA = ${!!process.env.OLDCAMERA}`)
  // OLDLEARN=1: the client learns from a state as it arrives and measures the correction from the state before the newest, as before
  await L.doString(`OLDLEARN = ${!!process.env.OLDLEARN}`)
  await L.doString(`NOTARGET = ${!!process.env.NOTARGET}`)
  // NOBUFFER=1: the server's model on the newest command's keys, its clock drawn to that number (as before the
  // input buffer, Handling.NextCommand); OLDCLOCK=server (or 1): that number itself as the clock, older still.
  // NOYAWLEARN=1: the client doesn't learn how much of the model's turn the server's car makes; AMOUNT: the heading lead's (1)
  await L.doString(`NOBUFFER = ${!!process.env.NOBUFFER || ['1','server'].includes(process.env.OLDCLOCK || '')} NOYAWLEARN = ${!!process.env.NOYAWLEARN} AMOUNT = ${Number(process.env.AMOUNT || 1)}`)
  await L.doString(`TICK = ${Number(process.env.TICK || 66)} FPS = ${Number(process.env.FPS || 144)} OLDCLOCK = ${['1','client'].includes(process.env.OLDCLOCK || '')} OLDSERVERCLOCK = ${['1','server'].includes(process.env.OLDCLOCK || '')}`)
  // SOURCE_STEER=script: Source's wheels at a script's own rates (3/s), as before sv_handling matched them
  await L.doString(`SOURCE_STEER_SCRIPT = ${process.env.SOURCE_STEER === 'script'}`)
  // SOURCE_PULL: how hard Source's tyres pull the yaw rate to their own turn between ticks (per s)
  await L.doString(`SOURCE_PULL = ${Number(process.env.SOURCE_PULL || 2.5)}`)
  await L.doString(String.raw`
    local H = AUDIO_ENGINE.Handling
    local DT = 1 / TICK
    local UP = PING / 2000            -- one way, s
    local INTERP = 0.1
    local seed = 12345
    local function random() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    local function jitter() return (random() - 0.5) * 0.02 end

    local spec = { settings = H.SettingsFor("test"), wheelbase = 2.7, noseX = 0, noseY = 1, noseZ = 0,
      pivotX = 0, pivotY = -0.5 * 2.7 / H.INCH, pivotZ = 0 }

    -- the keys over time
    local F, B, Lk, R, J = 1, 2, 4, 8, 16
    local SCRIPT = {
      { 0, 0 }, { 0.5, F }, { 4, F + Lk }, { 5.5, F }, { 6.5, F + R }, { 8, F }, { 9, F + Lk }, { 9.4, F + R }, { 9.8, F },
      { 11, B }, { 12.5, F }, { 15, F + J + Lk }, { 15.8, F + Lk }, { 16.4, F }, { 18, 0 }, { 19, B }, { 21, 0 },
    }
    local function keysAt(t) local k = 0 for _, e in ipairs(SCRIPT) do if t >= e[1] then k = e[2] end end return k end
    local function has(b, k) return math.floor(b / k) % 2 == 1 end

    -- the road (inches): a dip and a crest across the car's path, the same for the server and the client's traces
    local function roadAt(x, y)
      return -50 * math.exp(-((x + 2600) / 300) ^ 2) + 60 * math.exp(-((x + 4100) / 200) ^ 2)
    end
    local HALF = 2.7 / H.INCH * 0.5
    local function rideRoad(body, deltaTime)
      local nx, ny, nz = H.NoseOf(body, spec)
      H.RoadResponse(body, spec, roadAt(body.px + nx * HALF, body.py + ny * HALF), roadAt(body.px - nx * HALF, body.py - ny * HALF), HALF, 0, deltaTime)
    end
    local clientWorld = { move = function(body, fromX, fromY, fromZ, deltaTime) rideRoad(body, deltaTime) end }

    -- "Source": what the client doesn't know (a different engine, brakes, its own tyre forces and lock)
    local function sourceAcceleration(buttons, forward)
      local speed = math.abs(forward)
      if has(buttons, J) then return forward > 0.3 and -5 or 0 end
      if has(buttons, F) and not has(buttons, B) then
        if forward < -0.5 then return 9 end
        return math.max(0, math.min(6.5, 260 * 0.6 / math.max(speed, 2)) * (1 - (speed / 58) ^ 2.5))
      end
      if has(buttons, B) and not has(buttons, F) then
        if forward > 0.5 then return -9 end
        return speed < 9 and -3.2 or 0
      end
      return forward > 0.3 and -(0.5 + 0.0008 * speed * speed) or 0
    end

    local server = { body = { px = 0, py = 0, pz = 0, vx = 0, vy = 0, vz = 0, ax = 1, ay = 0, az = 0, bx = 0, by = 1, bz = 0,
      cx = 0, cy = 0, cz = 1, yawRate = 0, groundShare = 1, controlShare = 1 }, state = { steer = 0, drift = false }, sourceSteer = 0, command = 0, buttons = 0,
      -- (the newest command had and its keys, Source's own; every command's keys; the model's input buffer)
      newest = 0, newestButtons = 0, received = {}, input = H.NewInputBuffer(), applied = 0 }
    -- (the clock sv_handling sent before the input buffer: one command a tick, drawn to the newest number; NOBUFFER)
    local function oldCommandClock(clock, number)
      if not clock or math.abs(number - clock) > 4 then return number end
      clock = clock + 1
      return clock + (number - clock) * 0.1
    end

    local function serverTick(time)
      -- (Source's jeep takes the newest command's keys, the model the ones its input buffer gives it)
      local body, buttons = server.body, server.newestButtons
      local nx, ny, nz, rx, ry, rz = H.NoseOf(body, spec)
      local forward = (body.vx * nx + body.vy * ny) * H.INCH
      local side = (body.vx * rx + body.vy * ry)
      -- Source's own steering and tyres (slower, a different lock, no grip cap) and a bump now and then
      local wanted = (has(buttons, Lk) and 1 or 0) - (has(buttons, R) and 1 or 0)
      -- (sv_handling sets Source's steering rates to the model's: its wheels follow the model's steering)
      local settings = spec.settings
      local sourceRate = SOURCE_STEER_SCRIPT and 3 or (wanted == 0 and settings.steerReturn or settings.steerRate)
      server.sourceSteer = server.sourceSteer + math.max(-sourceRate * DT, math.min(sourceRate * DT, wanted - server.sourceSteer))
      local speed = math.abs(forward)
      -- (its wheel angle: a script's own, or as sv_handling matches it to the model: x1.1 + 0.5 deg)
      local lock = SOURCE_STEER_SCRIPT and 11 + 19 * math.max(0, 1 - speed / 15)
        or math.min(30, H.TurnAngle(settings, 2.7, speed) * 1.1 + 0.5)
      local sourceYaw = math.deg(forward * math.tan(math.rad(lock)) / 2.7) * server.sourceSteer
      body.yawRate = body.yawRate + (sourceYaw - body.yawRate) * math.min(1, SOURCE_PULL * DT) + (random() - 0.5) * 3
      local grip = (has(buttons, J) and 0.3 or 0.9) * 9.81 / H.INCH * DT
      local removed = math.min(math.abs(side), grip) * (side >= 0 and -1 or 1)
      body.vx, body.vy = body.vx + rx * removed, body.vy + ry * removed
      local push = (random() - 0.5) * 8
      body.vx, body.vy = body.vx + rx * push, body.vy + ry * push
      local mode = H.DriveMode(buttons, forward, true, 0)
      H.Integrate(body, spec, sourceAcceleration(buttons, forward), DT, H.STOPPING[mode])
      rideRoad(body, DT)
      -- then the handling model, as sv_handling.lua runs it
      local yawChange, sideChange, _, forwardChange = H.Control(body, server.state, server.buttons, spec, DT)
      H.ApplyControl(body, spec, yawChange, sideChange, forwardChange)
    end

    -- the network
    local toServer, toClient, unsent = {}, {}, {}
    local truth = {}            -- server time -> pose after its tick
    local appliedAt = {}        -- command number -> the tick the server's model first ran it in
    local client = { learner = H.NewLearner(260, 58), smoother = H.NewSmoother(), cameraSmoother = H.NewSmoother(), history = {}, newest = 0, newestAt = 0, base = nil, previous = nil,
      fresh = false, shown = false, commands = {}, earlierCommands = {}, predicted = {}, earlier = {}, display = {}, state = {}, earlierState = {},
      heading = H.NewHeadingLead(), receivedAt = -1, sourceBody = {}, turned = {}, learning = {} }
    local yawCommands, yawBody, yawState = {}, {}, {}
    local function learnYaw(previous, state)
      if not previous or state.impact or previous.impact then return end
      if state.groundShare < 1 or previous.groundShare < 1 or state.drift or previous.drift then return end
      if state.command <= previous.command or state.command - previous.command > 32 then return end
      local count = 0
      for number = previous.command + 1, state.command do
        count = count + 1
        yawCommands[count] = client.history[number] or yawCommands[count - 1] or previous.buttons or 0
      end
      local predicted = H.Predict(previous, yawCommands, count, 0, spec, client.learner, DT, yawBody, yawState)
      local unwindingSteps = yawState.unwindingSteps or 0
      if unwindingSteps > 0 and unwindingSteps < count then return end
      local unwinding = unwindingSteps > 0
      local previousYaw = math.deg(math.atan(previous.ay, previous.ax))
      local predictedTurn = ((math.deg(math.atan(predicted.ay, predicted.ax)) - previousYaw + 540) % 360) - 180
      if math.abs(predictedTurn) < 0.3 then return end
      local serverTurn = ((math.deg(math.atan(state.ay, state.ax)) - previousYaw + 540) % 360) - 180
      if serverTurn * predictedTurn <= 0 then return end
      local forwardSpeed = H.ForwardSpeed(previous, spec)
      H.LearnYaw(client.learner, forwardSpeed, H.YawShareAt(client.learner, forwardSpeed, unwinding) * serverTurn / predictedTurn, unwinding)
    end
    local function learn(previous, state)
      if not NOYAWLEARN then learnYaw(previous, state) end
      if previous and state.time - previous.time < 0.15 then
        local before, after = H.ForwardSpeed(previous, spec), H.ForwardSpeed(state, spec)
        H.Learn(client.learner, H.DriveMode(state.buttons, after, true, 0), (before + after) / 2, (after - before) / (state.time - previous.time) - H.SlopeAcceleration(state, spec))
      end
    end
    -- a level body whose nose (model +y) points along yaw, at (x, y)
    local function bodyAt(x, y, yaw, out)
      local radians = math.rad(yaw)
      out.px, out.py, out.pz = x, y, 0
      out.bx, out.by, out.bz = math.cos(radians), math.sin(radians), 0
      out.ax, out.ay, out.az = math.sin(radians), -math.cos(radians), 0
      out.cx, out.cy, out.cz = 0, 0, 1
      return out
    end
    local headingSamples = {}

    local function yawOf(b) return math.deg(math.atan(b.by, b.bx)) end   -- the nose (model +y) heading
    local function truthAt(t)
      local index = t / DT
      local low = math.floor(index)
      local a, b = truth[low], truth[low + 1]
      if not a or not b then return nil end
      local share = index - low
      return { px = a.px + (b.px - a.px) * share, py = a.py + (b.py - a.py) * share, pz = (a.pz or 0) + ((b.pz or 0) - (a.pz or 0)) * share,
        yaw = a.yaw + ((b.yaw - a.yaw + 540) % 360 - 180) * share, air = a.air or b.air }
    end
    -- what a frame at client time t is checked against: the server's car after the tick its model ran
    -- the command being made at t (command n is the tick from (n - 1) x DT), part way to the next.
    -- (It was the server's car half a ping after t, as if a command ran the moment it arrived:
    -- Source runs it in the next tick, and the model from its input buffer a tick after that)
    local function referenceAt(t)
      local clock = t / DT + 1
      local whole = math.floor(clock)
      local at = appliedAt[whole]
      if not at then return nil end
      return truthAt((at + clock - whole) * DT)
    end

    -- (as cl_handling's)
    local clientClock = H.NewClientClock()
    local function commandsAfter(base, list, now)
      local number, count = base.command, 0
      local last = base.buttons
      if OLDCLOCK then
        for n = number + 1, math.min(client.newest, number + 32) do
          count = count + 1
          last = client.history[n] or last
          list[count] = last
        end
        return count, math.max(0, math.min(1, (now - client.newestAt) / DT)), last
      end
      local span = H.ClientClockNow(clientClock, now, DT, client.newest) - number - (base.commandFraction or 0)
      span = math.max(0, math.min(32, span))
      local whole = math.floor(span)
      for n = number + 1, number + whole do
        count = count + 1
        last = client.history[n] or last
        list[count] = last
      end
      return count, span - whole, client.history[number + whole + 1] or last
    end

    local stats = { predicted = {}, plain = {}, predictedYaw = {}, plainYaw = {}, jump = 0, wobble = {}, cameraMove = {}, cameraTurn = {} }
    local response = { pressAt = nil, predicted = nil, plain = nil }
    local lastDisplay
    local samples = {}
    local serverTime, clientTime, nextTick, nextFrame, tickIndex = 0, 0, 0, 0, 0
    local FRAME = 1 / FPS
    local nextServerTick = 0
    truth[0] = { px = 0, py = 0, pz = 0, yaw = 90 }
    local endTime = 22

    while clientTime < endTime do
      -- the client makes the commands whose ticks have come at the start of a frame, and sends them
      if clientTime >= nextFrame then
        while nextTick <= clientTime do
          tickIndex = tickIndex + 1
          nextTick = nextTick + DT
          local buttons = keysAt(clientTime)
          client.history[tickIndex] = buttons
          client.newest, client.newestAt = tickIndex, clientTime
          H.ClientClockSeen(clientClock, tickIndex, clientTime, DT)
          -- (a packet every PER_PACKET commands, all of them in it)
          unsent[#unsent + 1] = { number = tickIndex, buttons = buttons }
          if #unsent >= PER_PACKET then
            local arrive = clientTime + UP + jitter()
            for _, command in ipairs(unsent) do toServer[#toServer + 1] = { arrive = arrive, number = command.number, buttons = command.buttons } end
            unsent = {}
          end
        end
      end
      if clientTime >= nextServerTick then
        nextServerTick = nextServerTick + DT
        -- the server's tick, one up-latency behind the client's clock (as Source keeps them)
        serverTime = clientTime
        local latest
        for i = #toServer, 1, -1 do
          if toServer[i].arrive <= serverTime then
            if not latest or toServer[i].number > latest.number then latest = toServer[i] end
            server.received[toServer[i].number] = toServer[i].buttons
            table.remove(toServer, i)
          end
        end
        if latest and latest.number > server.newest then server.newest, server.newestButtons = latest.number, latest.buttons end
        if NOBUFFER then
          if latest then server.command, server.buttons = latest.number, latest.buttons end
        elseif server.newest > 0 then
          -- (the keys of the command it runs, or of the nearest before it the server had)
          server.command = H.NextCommand(server.input, server.newest, DT)
          for n = server.command, server.command - 8, -1 do
            if server.received[n] then server.buttons = server.received[n] break end
          end
        end
        serverTick(serverTime)
        if server.command > 0 then
          if NOBUFFER then server.clock = OLDSERVERCLOCK and server.command or oldCommandClock(server.clock, server.command)
          else server.clock = server.command end
        end
        -- a crash nobody predicted: at 13 s the car stops dead against something (the model lets go, as
        -- sv_handling's impact callback makes it, easing back after impactHold + impactEase)
        if serverTime >= 13 and not server.crashed then
          server.crashed = true
          server.body.vx, server.body.vy, server.body.yawRate = 0, 0, 0
          server.impactAt = serverTime
        end
        local impact = false
        if server.impactAt then
          local settings = spec.settings
          local share = (serverTime - server.impactAt - settings.impactHold) / settings.impactEase
          server.body.controlShare = math.max(0, math.min(1, share))
          impact = share < 1
        end
        local serverTickIndex = math.floor(serverTime / DT + 0.5)
        truth[serverTickIndex] = { px = server.body.px, py = server.body.py, pz = server.body.pz, yaw = yawOf(server.body), air = server.body.groundShare < 1 }
        -- (the tick each command was first run in: what the prediction is checked against)
        for n = server.applied + 1, server.command do appliedAt[n] = serverTickIndex end
        server.applied = math.max(server.applied, server.command)
        if PATHLOG and (server.body.groundShare < 1 or serverTickIndex % math.floor(TICK / 2) == 0) then print(string.format("t=%.1f x=%.0f y=%.0f v=%.0f mph z=%.0f air=%s", serverTime, server.body.px, server.body.py, math.sqrt(server.body.vx ^ 2 + server.body.vy ^ 2) * H.INCH * 2.237, server.body.pz, tostring(server.body.groundShare < 1))) end
        if serverTickIndex % math.max(1, math.floor(0.03 / DT + 0.5)) == 0 and random() > 0.03 then
          local state = H.CopyBody(server.body)
          -- (the body on its springs: up to BOUNCE inches over the road in the states, as a car in a fast corner)
          state.pz = state.pz + BOUNCE * math.abs(math.sin(serverTime * 7.3))
          -- (sv_handling: the command the model ran, one a tick from the input buffer; NOBUFFER: the clock with its fraction)
          local clock = server.clock or 0
          state.command = math.floor(clock)
          if NOBUFFER then state.commandFraction = clock - state.command end
          state.time, state.steer, state.drift = serverTime, server.state.steer, server.state.drift
          -- (the eased turn the model holds the car on, as sv_handling sends it; NOTARGET=1: not sent, as before)
          if not NOTARGET then state.yawTarget = server.state.yawTarget end
          state.driving, state.limiter, state.impact, state.buttons = true, 0, impact, server.buttons
          toClient[#toClient + 1] = { arrive = serverTime + UP + jitter(), state = state }
        end
      end
      -- states arriving
      for i = #toClient, 1, -1 do
        local message = toClient[i]
        if message.arrive <= clientTime then
          table.remove(toClient, i)
          local state = message.state
          if not client.base or state.time > client.base.time then
            local previous = client.base
            -- (learnt from in the next frame, once its correction is worked out, as cl_handling; OLDLEARN=1: at once)
            if OLDLEARN then learn(previous, state) else client.learning[#client.learning + 1] = { previous, state } end
            client.previous, client.base, client.fresh, client.receivedAt = previous, state, true, clientTime
          end
        end
      end
      -- a frame
      if clientTime >= nextFrame then
        nextFrame = nextFrame + FRAME
        local base = client.base
        if base then
          -- (as cl_handling: the state drawn last frame's prediction for now, before the new states' learning)
          local earlier
          local drawn = OLDLEARN and client.previous or client.shownBase
          if client.fresh and client.shown and drawn and drawn ~= base then
            local c2, f2, b2 = commandsAfter(drawn, client.earlierCommands, clientTime)
            earlier = H.Predict(drawn, client.earlierCommands, c2, f2, spec, client.learner, DT, client.earlier, client.earlierState, b2, WORLD and clientWorld or nil)
          end
          for _, pair in ipairs(client.learning) do learn(pair[1], pair[2]) end
          client.learning = {}
          local count, fraction, lastButtons = commandsAfter(base, client.commands, clientTime)
          local predicted = H.Predict(base, client.commands, count, fraction, spec, client.learner, DT, client.predicted, client.state, lastButtons, WORLD and clientWorld or nil)
          if client.fresh then
            client.fresh = false
            if earlier then
              H.SmootherAbsorb(client.smoother, earlier, predicted)
              H.SmootherAbsorb(client.cameraSmoother, earlier, predicted)
            end
          end
          client.shown, client.shownBase = true, base
          -- (as cl_handling: the car's smoothing 0.1 s, the camera's 0.6 s; OLDCAMERA=1: the camera on the car)
          H.SmootherDecay(client.smoother, FRAME, base.impact and 0.04 or 0.1, 250)
          H.SmootherDecay(client.cameraSmoother, FRAME, base.impact and 0.04 or (OLDCAMERA and 0.1 or 0.6), 250)
          -- the camera's pose (the prediction + its smoothing): how far it moves off the car's own
          -- smooth motion from frame to frame (m/s, deg/s), what twitches the view; outside the crash
          client.cameraBody = H.SmootherApply(client.cameraSmoother, predicted, client.cameraBody)
          local camera = client.cameraBody
          if client.lastCamera and (clientTime < 12.9 or clientTime > 14.5) then
            local last = client.lastCamera
            local moveX, moveY = (camera.px - last.px) / FRAME - predicted.vx, (camera.py - last.py) / FRAME - predicted.vy
            stats.cameraMove[#stats.cameraMove + 1] = math.sqrt(moveX ^ 2 + moveY ^ 2) * H.INCH
            local turned = ((yawOf(camera) - last.yaw + 540) % 360 - 180) / FRAME
            stats.cameraTurn[#stats.cameraTurn + 1] = math.abs(turned - predicted.yawRate)
          end
          client.lastCamera = { px = camera.px, py = camera.py, yaw = yawOf(camera) }
          local display = H.SmootherApply(client.smoother, predicted, client.display)
          -- the heading-only mode: Source's car as shown now (half a ping + the interpolation late), turned by the lead
          local shown = truthAt(clientTime - UP - INTERP)
          if shown then
            local source = bodyAt(shown.px, shown.py, shown.yaw, client.sourceBody)
            local offset = H.HeadingLeadFrame(client.heading, source, display, base, spec, FRAME, AMOUNT, clientTime - client.receivedAt < H.HEADING_LEAD.staleTime)
            local pivotX, pivotY, pivotZ = H.PointOf(source, spec.pivotX, spec.pivotY, spec.pivotZ)
            local turned = H.TurnAbout(source, offset, pivotX, pivotY, pivotZ, client.turned)
            if clientTime > 1 then
              headingSamples[#headingSamples + 1] = { t = clientTime, yaw = yawOf(turned), plain = shown.yaw, offset = offset, predicted = yawOf(display),
                moved = math.sqrt((turned.px - shown.px) ^ 2 + (turned.py - shown.py) ^ 2) }
            end
          end
          if clientTime > 1 then
            samples[#samples + 1] = { t = clientTime, px = display.px, py = display.py, pz = display.pz, yaw = yawOf(display),
              underRoad = roadAt(display.px, display.py) - display.pz }
            if lastDisplay and (clientTime < 12.9 or clientTime > 14.5) then
              -- jump on screen beyond the car's own motion this frame
              local speed = math.sqrt(display.vx ^ 2 + display.vy ^ 2)
              local moved = math.sqrt((display.px - lastDisplay.px) ^ 2 + (display.py - lastDisplay.py) ^ 2)
              stats.jump = math.max(stats.jump, math.abs(moved - speed * FRAME))
              -- (how unevenly the car moves frame to frame at speed: what the camera shows as stutter)
              if speed > 20 / H.INCH then stats.wobble[#stats.wobble + 1] = math.abs(moved / FRAME - speed) / speed end
            end
            lastDisplay = { px = display.px, py = display.py }
          end
        end
      end
      clientTime = clientTime + 0.001
    end

    -- against where the server will have the car when it runs the newest key (known now)
    local function dyaw(a, b) return math.abs((a - b + 540) % 360 - 180) end
    for _, sample in ipairs(samples) do
      local reference, plain = referenceAt(sample.t), truthAt(sample.t - UP - INTERP)
      if reference and plain then
        stats.predicted[#stats.predicted + 1] = math.sqrt((sample.px - reference.px) ^ 2 + (sample.py - reference.py) ^ 2)
        stats.plain[#stats.plain + 1] = math.sqrt((plain.px - reference.px) ^ 2 + (plain.py - reference.py) ^ 2)
        stats.predictedYaw[#stats.predictedYaw + 1] = dyaw(sample.yaw, reference.yaw)
        stats.plainYaw[#stats.plainYaw + 1] = dyaw(plain.yaw, reference.yaw)
        -- after the crash: how long the car shown stays more than 0.5 m off
        if sample.t >= 13 + UP and sample.t < 15 then
          local off = math.sqrt((sample.px - reference.px) ^ 2 + (sample.py - reference.py) ^ 2)
          if off > 0.5 / H.INCH then stats.crashOff = sample.t - 13 - UP end
          stats.crashWorst = math.max(stats.crashWorst or 0, off)
        end
        -- over the dip and the crest (6.8 .. 9.6 s): height off the server's, and how far into the road the car is drawn
        if sample.t > 6.8 and sample.t < 9.6 then
          stats.heightOff = math.max(stats.heightOff or 0, math.abs(sample.pz - reference.pz))
          stats.intoRoad = math.max(stats.intoRoad or 0, sample.underRoad)
          stats.heightSum, stats.heightCount = (stats.heightSum or 0) + math.abs(sample.pz - reference.pz), (stats.heightCount or 0) + 1
        end
        -- just after a steering key is let go: how far the car shown is off the server's (the "snap")
        local keysNow, keysBefore = keysAt(sample.t), keysAt(sample.t - 0.4)
        if math.floor(keysBefore / 4) % 4 ~= 0 and math.floor(keysNow / 4) % 4 == 0 and not has(keysNow, J)
          and not has(keysAt(sample.t - 1), J) and not has(keysAt(sample.t - 0.5), J) then
          local off = dyaw(sample.yaw, reference.yaw)
          if off > (stats.releaseYaw or 0) then stats.releaseYaw, stats.releaseYawAt = off, sample.t end
        end
        if math.floor(keysNow / 4) % 4 ~= 0 and not has(keysNow, J) and not has(keysBefore, J) then
          local off = dyaw(sample.yaw, reference.yaw)
          if off > (stats.turnYaw or 0) then stats.turnYaw, stats.turnYawAt = off, sample.t end
        end
        -- steering response: the first left turn at 4 s; how long until the car shown has turned 2 degrees
        if sample.t >= 4 and not response.startPredicted then response.startPredicted, response.startPlain = sample.yaw, plain.yaw end
        if response.startPredicted and not response.predicted and dyaw(sample.yaw, response.startPredicted) > 2 then response.predicted = sample.t - 4 end
        if response.startPlain and not response.plain and dyaw(plain.yaw, response.startPlain) > 2 then response.plain = sample.t - 4 end
      end
    end

    -- the heading-only mode, against the same reference
    local heading = { yaw = {}, plainYaw = {}, lead = {}, step = 0, moved = 0, turnYaw = 0, releaseYaw = 0 }
    local onset, previousSample = {}, nil
    for _, sample in ipairs(headingSamples) do
      local reference = referenceAt(sample.t)
      if reference then
        -- (the crash's own turn reaches the reference before the client could know it)
        local inCrash = sample.t >= 13 - UP - 0.05 and sample.t < 15
        if not inCrash then
          heading.yaw[#heading.yaw + 1] = dyaw(sample.yaw, reference.yaw)
          heading.plainYaw[#heading.plainYaw + 1] = dyaw(sample.plain, reference.yaw)
          -- (how fast the lead itself changes, deg/s: a hard turn's own is up to ~150, a correction's jump far more)
          if previousSample then heading.step = math.max(heading.step, math.abs(sample.offset - previousSample.offset) / (sample.t - previousSample.t)) end
          local keysNow, keysBefore = keysAt(sample.t), keysAt(sample.t - 0.4)
          if math.floor(keysBefore / 4) % 4 ~= 0 and math.floor(keysNow / 4) % 4 == 0 and not has(keysNow, J)
            and not has(keysAt(sample.t - 1), J) and not has(keysAt(sample.t - 0.5), J) then
            heading.releaseYaw = math.max(heading.releaseYaw, dyaw(sample.yaw, reference.yaw))
          end
          if math.floor(keysNow / 4) % 4 ~= 0 and not has(keysNow, J) and not has(keysBefore, J) then
            heading.turnYaw = math.max(heading.turnYaw, dyaw(sample.yaw, reference.yaw))
          end
        end
        heading.lead[#heading.lead + 1] = math.abs(sample.offset)
        heading.moved = math.max(heading.moved, sample.moved)
        if sample.t >= 4 and not onset.start then onset.start = sample.yaw end
        if onset.start and not onset.at and dyaw(sample.yaw, onset.start) > 2 then onset.at = sample.t - 4 end
        -- the crash: when the lead is gone once the crash has reached the client
        if sample.t >= 13 + UP and sample.t < 15 then
          if math.abs(sample.offset) >= 1 then heading.crashGone = nil elseif not heading.crashGone then heading.crashGone = sample.t - 13 - UP end
        end
        previousSample = sample
      end
    end

    local function summary(list)
      table.sort(list)
      local sum = 0 for _, v in ipairs(list) do sum = sum + v end
      return { mean = sum / #list, p95 = list[math.floor(#list * 0.95)], worst = list[#list] }
    end
    -- the user's "it's done turning, then it snaps into the server's": after each release of a steering
    -- key (no handbrake), how far the heading turns back once it stopped
    local function turnBack(key)
      local worst = 0
      for i = 2, #headingSamples do
        local s, p = headingSamples[i], headingSamples[i - 1]
        local before, now = keysAt(p.t), keysAt(s.t)
        local steered = math.floor(before / 4) % 4
        if steered ~= 0 and math.floor(now / 4) % 4 == 0 and not has(now, J) and not has(before, J) and s.t < 12.5 then
          local direction = steered == 1 and 1 or -1
          local peak, low = -1e9, 1e9
          for j = i, #headingSamples do
            local o = headingSamples[j]
            if o.t > s.t + 1 then break end
            local turned = ((o[key] - s[key] + 540) % 360 - 180) * direction
            if turned > peak then peak, low = turned, turned end
            if turned < low then low = turned end
          end
          worst = math.max(worst, peak - low)
        end
      end
      return worst
    end
    -- and "it keeps jerking back and forth": in steady turns (the same steering keys held 0.4 s or
    -- more), the yaw rate against its own 0.2 s average (deg/s)
    local function rateWobble(key)
      local rates, out = {}, {}
      for i = 2, #headingSamples do
        local s, p = headingSamples[i], headingSamples[i - 1]
        rates[i] = ((s[key] - p[key] + 540) % 360 - 180) / (s.t - p.t)
      end
      for i = 2, #headingSamples do
        local s = headingSamples[i]
        local keys = keysAt(s.t)
        if math.floor(keys / 4) % 4 ~= 0 and not has(keys, J) and keysAt(s.t - 0.5) == keys and keysAt(s.t + 0.15) == keys and s.t < 12.5 then
          local total, count = 0, 0
          for j = math.max(2, i - 60), math.min(#headingSamples, i + 60) do
            if math.abs(headingSamples[j].t - s.t) <= 0.1 then total, count = total + rates[j], count + 1 end
          end
          out[#out + 1] = math.abs(rates[i] - total / count)
        end
      end
      return summary(out)
    end
    local wobbleShown, wobblePlain = rateWobble('yaw'), rateWobble('plain')
    HEADING_EXTRA = string.format('%.2f|%.2f|%.2f|%.2f|%.2f|%.2f', turnBack('yaw'), turnBack('predicted'), turnBack('plain'), wobbleShown.mean, wobbleShown.p95, wobblePlain.mean)
    local hy, hq, hl = summary(heading.yaw), summary(heading.plainYaw), summary(heading.lead)
    HEADING_RESULT = string.format('%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.1f',
      hy.mean, hy.p95, hy.worst, hq.mean, hq.p95, hq.worst, onset.at or -1, heading.turnYaw, heading.releaseYaw,
      hl.mean, hl.p95, hl.worst, heading.step, heading.crashGone or -1, heading.moved * H.INCH * 100)
    local p, q, py, qy = summary(stats.predicted), summary(stats.plain), summary(stats.predictedYaw), summary(stats.plainYaw)
    __result(string.format('%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.3f|%.1f|%d',
      p.mean, p.p95, p.worst, q.mean, q.p95, q.worst, py.mean, py.p95, py.worst, qy.mean, qy.p95, qy.worst,
      response.predicted or -1, response.plain or -1, stats.jump, client.learner.samples) .. string.format('|%.3f|%.1f', stats.crashOff or 0, stats.crashWorst or 0) .. string.format('|%.2f|%.2f|%.2f|%.2f', stats.releaseYaw or 0, stats.turnYaw or 0, stats.turnYawAt or 0, stats.releaseYawAt or 0)
      .. (function() local w = summary(stats.wobble) return string.format('|%.4f|%.4f', w.mean, w.p95) end)()
      .. string.format('|%.1f|%.1f|%.1f', stats.heightOff or 0, (stats.heightSum or 0) / math.max(1, stats.heightCount or 0), stats.intoRoad or 0)
      .. (function() local m, r = summary(stats.cameraMove), summary(stats.cameraTurn) return string.format('|%.3f|%.3f|%.2f|%.2f', m.p95, m.worst, r.p95, r.worst) end)())`)
  const [pm, p95, pw, qm, q95, qw, pym, py95, pyw, qym, qy95, qyw, rp, rq, jump, samples, crashOff, crashWorst, releaseYaw, turnYaw, turnYawAt, releaseYawAt, wobbleMean, wobble95, heightOff, heightMean, intoRoad, cameraMove95, cameraMoveWorst, cameraTurn95, cameraTurnWorst] = result.split('|').map(Number)
  const [hym, hy95, hyw, hqm, hq95, hqw, hOnset, hTurn, hRelease, hlm, hl95, hlw, hStep, hCrash, hMoved] = (await L.global.get('HEADING_RESULT')).split('|').map(Number)
  const [backShown, backPredicted, backPlain, wobbleShown, wobbleShown95, wobblePlain] = (await L.global.get('HEADING_EXTRA')).split('|').map(Number)
  const m = (inch) => (inch * 0.0254).toFixed(2) + ' m'
  console.log(`ping ${PING} ms, ${process.env.TICK || 66} tick, ${process.env.FPS || 144} fps, ${PER_PACKET} command${PER_PACKET > 1 ? 's' : ''} a packet${process.env.OLDCLOCK ? ' (old clocks)' : ''}, 3% of states lost, ${samples} acceleration samples learned`)
  console.log(`  position off where the server will be:  predicted mean ${m(pm)}, 95% ${m(p95)}, worst ${m(pw)}`)
  console.log(`                                          plain Source mean ${m(qm)}, 95% ${m(q95)}, worst ${m(qw)}`)
  console.log(`  heading off:                            predicted mean ${pym.toFixed(1)} deg, 95% ${py95.toFixed(1)}, worst ${pyw.toFixed(1)}`)
  console.log(`                                          plain Source mean ${qym.toFixed(1)} deg, 95% ${qy95.toFixed(1)}, worst ${qyw.toFixed(1)}`)
  console.log(`  steering key to 2 deg turned on screen: predicted ${(rp * 1000).toFixed(0)} ms, plain Source ${(rq * 1000).toFixed(0)} ms`)
  console.log(`  heading off, steering held / 0.4 s after letting go: worst ${turnYaw.toFixed(1)} (at ${turnYawAt.toFixed(1)} s) / ${releaseYaw.toFixed(1)} (at ${releaseYawAt.toFixed(1)} s) deg`)
  console.log(`  over the dip and the crest: height off the server's mean ${m(heightMean)}, worst ${m(heightOff)}; drawn into the road up to ${m(Math.max(0, intoRoad))}`)
  console.log(`  corrections moving the camera: 95% ${cameraMove95.toFixed(2)} m/s, worst ${cameraMoveWorst.toFixed(2)}; turning it 95% ${cameraTurn95.toFixed(1)} deg/s, worst ${cameraTurnWorst.toFixed(1)}`)
  console.log(`  frame-to-frame speed unevenness over 20 m/s: mean ${(wobbleMean * 100).toFixed(1)}%, 95% ${(wobble95 * 100).toFixed(1)}%`)
  console.log(`  largest correction jump in one frame:   ${m(jump)} (outside the crash)`)
  console.log(`  a crash at 13 s nobody predicted:       up to ${m(crashWorst)} off, back within 0.5 m after ${(crashOff * 1000).toFixed(0)} ms`)
  console.log(`heading only (audio_engine_predict_position 0, the default; amount ${process.env.AMOUNT || 1}): the car where plain Source has it, turned by the lead`)
  console.log(`  heading off:                            shown mean ${hym.toFixed(1)} deg, 95% ${hy95.toFixed(1)}, worst ${hyw.toFixed(1)}`)
  console.log(`                                          plain Source mean ${hqm.toFixed(1)} deg, 95% ${hq95.toFixed(1)}, worst ${hqw.toFixed(1)}`)
  console.log(`  steering key to 2 deg turned on screen: shown ${(hOnset * 1000).toFixed(0)} ms, plain Source ${(rq * 1000).toFixed(0)} ms`)
  console.log(`  heading off, steering held / 0.4 s after letting go: worst ${hTurn.toFixed(1)} / ${hRelease.toFixed(1)} deg`)
  console.log(`  the lead (nose ahead of the path):      mean ${hlm.toFixed(1)} deg, 95% ${hl95.toFixed(1)}, largest ${hlw.toFixed(1)}; changing at most ${hStep.toFixed(0)} deg/s`)
  console.log(`  turning about the rear axle moved the car up to ${(hMoved / 100).toFixed(2)} m (its position is otherwise Source's)`)
  console.log(`  the crash: the lead gone ${(hCrash * 1000).toFixed(0)} ms after it reaches the client`)
  console.log(`  after letting go, turning back once stopped: shown ${backShown.toFixed(2)} deg, the prediction ${backPredicted.toFixed(2)}, plain Source ${backPlain.toFixed(2)}`)
  console.log(`  yaw rate wobble in steady turns:        shown mean ${wobbleShown.toFixed(2)} deg/s, 95% ${wobbleShown95.toFixed(2)}; plain Source mean ${wobblePlain.toFixed(2)}`)
  const failures = []
  // (AMOUNT under 1 shows only that share of the lead: closer, not by half)
  const amount = Number(process.env.AMOUNT || 1)
  if (!(hym < hqm * (1 - amount * 0.5))) failures.push('heading only: the heading shown is not clearly closer than plain Source')
  if (!(hOnset >= 0 && rq > 0 && hOnset < rq - PING / 1000 * 0.6)) failures.push('heading only: steering does not show clearly sooner')
  if (!(hStep < 250)) failures.push('heading only: the lead jumped (changed faster than 250 deg/s)')
  if (!(hCrash >= 0 && hCrash < 0.25)) failures.push('heading only: the lead did not go quickly after the crash')
  // (the user: "it's done turning, then it snaps into the server's", and jerking back and forth in turns. Under 60 tick a
  // key change can still land a tick off when a command comes over a tick late: there 2 deg and 3x plain Source's, 2 deg/s at least)
  const tick = Number(process.env.TICK || 66)
  const sameSource = !process.env.SOURCE_PULL && !process.env.SOURCE_STEER
  // (and at 22 tick the replay starts each state from the server's yaw rate, bumps and all: 1.8-1.9 deg/s at 40 ms either way)
  const backLimit = tick >= 60 ? 0.5 : 2, wobbleAllowed = tick >= 60 ? wobblePlain * 2 : Math.max(wobblePlain * 3, 2)
  if (sameSource && !(backShown < backLimit)) failures.push(`heading only: the car turns back over ${backLimit} deg after a turn (snaps into the server's)`)
  if (sameSource && !(wobbleShown < wobbleAllowed)) failures.push(`heading only: the turn wobbles over ${wobbleAllowed.toFixed(2)} deg/s (plain Source ${wobblePlain.toFixed(2)})`)
  if (!(pm < qm * 0.35)) failures.push('the prediction is not clearly closer than plain Source')
  if (!(rp >= 0 && rq > 0 && rp < rq - PING / 1000 * 0.6)) failures.push('steering does not show clearly sooner')
  if (!(jump < 6)) failures.push('a correction jumped more than 6 inches in one frame')
  if (!(crashOff < PING / 1000 + 0.35)) failures.push('the crash took too long to show')
  if (process.env.WORLD !== '0' && !(heightOff < 8 && intoRoad < 2)) failures.push('over the dip and crest the car is drawn more than 8 inches off the server\'s height or 2 into the road')
  if (!process.env.SOURCE_STEER && !process.env.SOURCE_PULL && !(turnYaw < 2 && releaseYaw < 2))
    failures.push('the heading is off by 2 degrees or more in a turn or as the key is let go')
  if (failures.length) { console.log('FAILED: ' + failures.join('; ')); process.exit(1) }
  console.log('OK')
})().catch((error) => { console.error(error); process.exit(1) })
