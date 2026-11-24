/*
  Offline check of the driving prediction (lua/audio_engine/sh_handling.lua), no Garry's Mod needed:

    node test_prediction.js [ping ms] [ticks per command packet]      (default 150, 1)

  Ticks per packet 2 is GMod's default cl_cmdrate 30 at 66 tick: commands reach the server two at
  a time, and the car's physics still steps once a tick (Handling.CommandClock evens that out;
  NOCLOCK=1 sends the raw command number, as before it, to compare).

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
  and fails if the prediction isn't clearly better than plain Source.
*/
const path = require('path')
const fs = require('fs')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const PING = Number(process.argv[2] || 150)
const BATCH = Math.max(1, Number(process.argv[3] || 1))
const CLOCK = process.env.NOCLOCK ? 0 : 1

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
  await L.doString(`PING = ${PING} BATCH = ${BATCH} CLOCK = ${CLOCK}`)
  await L.doString(String.raw`
    local H = AUDIO_ENGINE.Handling
    local DT = 1 / 66
    local UP = PING / 2000            -- one way, s
    local INTERP = 0.1
    local seed = 12345
    local function random() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    local function jitter() return (random() - 0.5) * 0.02 end

    local spec = { settings = H.SettingsFor("test"), wheelbase = 2.7, noseX = 0, noseY = 1, noseZ = 0 }

    -- the keys over time
    local F, B, Lk, R, J = 1, 2, 4, 8, 16
    local SCRIPT = {
      { 0, 0 }, { 0.5, F }, { 4, F + Lk }, { 5.5, F }, { 6.5, F + R }, { 8, F }, { 9, F + Lk }, { 9.4, F + R }, { 9.8, F },
      { 11, B }, { 12.5, F }, { 15, F + J + Lk }, { 15.8, F + Lk }, { 16.4, F }, { 18, 0 }, { 19, B }, { 21, 0 },
    }
    local function keysAt(t) local k = 0 for _, e in ipairs(SCRIPT) do if t >= e[1] then k = e[2] end end return k end
    local function has(b, k) return math.floor(b / k) % 2 == 1 end

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
      cx = 0, cy = 0, cz = 1, yawRate = 0, groundShare = 1, controlShare = 1 }, state = { steer = 0, drift = false }, sourceSteer = 0, command = 0, buttons = 0 }

    local function serverTick(time)
      local body, buttons = server.body, server.buttons
      local nx, ny, nz, rx, ry, rz = H.NoseOf(body, spec)
      local forward = (body.vx * nx + body.vy * ny) * H.INCH
      local side = (body.vx * rx + body.vy * ry)
      -- Source's own steering and tyres (slower, a different lock, no grip cap) and a bump now and then
      local wanted = (has(buttons, Lk) and 1 or 0) - (has(buttons, R) and 1 or 0)
      server.sourceSteer = server.sourceSteer + math.max(-3 * DT, math.min(3 * DT, wanted - server.sourceSteer))
      local speed = math.abs(forward)
      local lock = 11 + 19 * math.max(0, 1 - speed / 15)
      local sourceYaw = math.deg(forward * math.tan(math.rad(lock)) / 2.7) * server.sourceSteer
      body.yawRate = body.yawRate + (sourceYaw - body.yawRate) * math.min(1, 2.5 * DT) + (random() - 0.5) * 3
      local grip = (has(buttons, J) and 0.3 or 0.9) * 9.81 / H.INCH * DT
      local removed = math.min(math.abs(side), grip) * (side >= 0 and -1 or 1)
      body.vx, body.vy = body.vx + rx * removed, body.vy + ry * removed
      local push = (random() - 0.5) * 8
      body.vx, body.vy = body.vx + rx * push, body.vy + ry * push
      local mode = H.DriveMode(buttons, forward, true, 0)
      H.Integrate(body, spec, sourceAcceleration(buttons, forward), DT, H.STOPPING[mode])
      -- then the handling model, as sv_handling.lua runs it
      local yawChange, sideChange, _, forwardChange = H.Control(body, server.state, buttons, spec, DT)
      H.ApplyControl(body, spec, yawChange, sideChange, forwardChange)
    end

    -- the network
    local toServer, toClient = {}, {}
    local truth = {}            -- server time -> pose after its tick
    local client = { learner = H.NewLearner(260, 58), smoother = H.NewSmoother(), history = {}, newest = 0, newestAt = 0, base = nil, previous = nil,
      fresh = false, shown = false, commands = {}, earlierCommands = {}, predicted = {}, earlier = {}, display = {}, state = {}, earlierState = {} }

    local function yawOf(b) return math.deg(math.atan(b.by, b.bx)) end   -- the nose (model +y) heading
    local function truthAt(t)
      local index = t / DT
      local low = math.floor(index)
      local a, b = truth[low], truth[low + 1]
      if not a or not b then return nil end
      local share = index - low
      return { px = a.px + (b.px - a.px) * share, py = a.py + (b.py - a.py) * share, yaw = a.yaw + ((b.yaw - a.yaw + 540) % 360 - 180) * share }
    end

    -- (as cl_handling's)
    local function commandsAfter(base, list, now)
      local number, count = base.command, 0
      local last = base.buttons
      for n = number + 1, math.min(client.newest, number + 32) do
        count = count + 1
        last = client.history[n] or last
        list[count] = last
      end
      local fraction = math.max(0, math.min(1, (now - client.newestAt) / DT)) - (base.commandFraction or 0)
      if fraction < 0 then
        if count > 0 then count, fraction = count - 1, fraction + 1 else fraction = 0 end
      end
      return count, fraction, last
    end

    local stats = { predicted = {}, plain = {}, predictedYaw = {}, plainYaw = {}, jump = 0 }
    local response = { pressAt = nil, predicted = nil, plain = nil }
    local lastDisplay
    local samples = {}
    local serverTime, clientTime, nextTick, nextFrame, tickIndex = 0, 0, 0, 0, 0
    local FRAME = 1 / 144
    truth[0] = { px = 0, py = 0, yaw = 90 }
    local endTime = 22

    while clientTime < endTime do
      -- the client makes a command each tick and sends it
      if clientTime >= nextTick then
        tickIndex = tickIndex + 1
        nextTick = nextTick + DT
        local buttons = keysAt(clientTime)
        client.history[tickIndex] = buttons
        client.newest, client.newestAt = tickIndex, clientTime
        -- (commands go out BATCH at a time, in one packet)
        client.outgoing = client.outgoing or {}
        client.outgoing[#client.outgoing + 1] = { number = tickIndex, buttons = buttons }
        if tickIndex % BATCH == 0 then
          local arrive = clientTime + UP + jitter()
          for _, command in ipairs(client.outgoing) do toServer[#toServer + 1] = { arrive = arrive, number = command.number, buttons = command.buttons } end
          client.outgoing = {}
        end
        -- the server's tick, one up-latency behind the client's clock (as Source keeps them)
        serverTime = clientTime
        local latest
        for i = #toServer, 1, -1 do
          if toServer[i].arrive <= serverTime then
            if not latest or toServer[i].number > latest.number then latest = toServer[i] end
            table.remove(toServer, i)
          end
        end
        if latest then server.command, server.buttons = latest.number, latest.buttons end
        serverTick(serverTime)
        if server.command > 0 then server.clock = CLOCK == 1 and H.CommandClock(server.clock, server.command) or server.command end
        -- a crash nobody predicted: at 13 s the car stops dead against something (the model lets go, as
        -- sv_handling's impact callback makes it, easing back after impactHold + impactEase)
        if serverTime >= 13 and not server.crashed then
          server.crashed = true
          server.body.vx, server.body.vy, server.body.yawRate = 0, 0, 0
          server.impactAt = serverTime
        end
        local impact, impactAge = false, nil
        if server.impactAt then
          local share = H.ImpactShare(spec.settings, serverTime - server.impactAt)
          server.body.controlShare = share
          impact = share < 1
          if impact then impactAge = serverTime - server.impactAt end
        end
        local serverTickIndex = math.floor(serverTime / DT + 0.5)
        truth[serverTickIndex] = { px = server.body.px, py = server.body.py, yaw = yawOf(server.body) }
        if serverTickIndex % 2 == 0 and random() > 0.03 then
          local state = H.CopyBody(server.body)
          local clock = server.clock or 0
          state.command, state.commandFraction = math.floor(clock), clock - math.floor(clock)
          state.time, state.steer, state.drift = serverTime, server.state.steer, server.state.drift
          state.modelOn, state.impactAge, state.blockedFor = true, impactAge, server.state.blockedFor
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
            -- (as cl_handling's learnFrom: a straight run on the same keys)
            if previous and state.time - previous.time < 0.15 and state.buttons == previous.buttons and not state.impact and not previous.impact
              and math.abs(state.steer) <= 0.15 and math.abs(previous.steer) <= 0.15 and not state.drift and not previous.drift then
              local before, after = H.ForwardSpeed(previous, spec), H.ForwardSpeed(state, spec)
              H.Learn(client.learner, H.DriveMode(state.buttons, after, true, 0), (before + after) / 2, (after - before) / (state.time - previous.time) - H.SlopeAcceleration(state, spec))
            end
            client.previous, client.base, client.fresh = previous, state, true
          end
        end
      end
      -- a frame
      if clientTime >= nextFrame then
        nextFrame = nextFrame + FRAME
        local base = client.base
        if base then
          local count, fraction, lastButtons = commandsAfter(base, client.commands, clientTime)
          local predicted = H.Predict(base, client.commands, count, fraction, spec, client.learner, DT, client.predicted, client.state, lastButtons)
          if client.fresh then
            client.fresh = false
            if client.shown and client.previous then
              local c2, f2, b2 = commandsAfter(client.previous, client.earlierCommands, clientTime)
              local earlier = H.Predict(client.previous, client.earlierCommands, c2, f2, spec, client.learner, DT, client.earlier, client.earlierState, b2)
              H.SmootherAbsorb(client.smoother, earlier, predicted)
            end
          end
          client.shown = true
          H.SmootherDecay(client.smoother, FRAME, base.impact and 0.04 or 0.1, 250)
          local display = H.SmootherApply(client.smoother, predicted, client.display)
          if clientTime > 1 then
            samples[#samples + 1] = { t = clientTime, px = display.px, py = display.py, yaw = yawOf(display) }
            if lastDisplay and (clientTime < 12.9 or clientTime > 14.5) then
              -- jump on screen beyond the car's own motion this frame
              local speed = math.sqrt(display.vx ^ 2 + display.vy ^ 2)
              local moved = math.sqrt((display.px - lastDisplay.px) ^ 2 + (display.py - lastDisplay.py) ^ 2)
              stats.jump = math.max(stats.jump, math.abs(moved - speed * FRAME))
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
      local reference, plain = truthAt(sample.t + UP), truthAt(sample.t - UP - INTERP)
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
        -- steering response: the first left turn at 4 s; how long until the car shown has turned 2 degrees
        if sample.t >= 4 and not response.startPredicted then response.startPredicted, response.startPlain = sample.yaw, plain.yaw end
        if response.startPredicted and not response.predicted and dyaw(sample.yaw, response.startPredicted) > 2 then response.predicted = sample.t - 4 end
        if response.startPlain and not response.plain and dyaw(plain.yaw, response.startPlain) > 2 then response.plain = sample.t - 4 end
      end
    end

    local function summary(list)
      table.sort(list)
      local sum = 0 for _, v in ipairs(list) do sum = sum + v end
      return { mean = sum / #list, p95 = list[math.floor(#list * 0.95)], worst = list[#list] }
    end
    local p, q, py, qy = summary(stats.predicted), summary(stats.plain), summary(stats.predictedYaw), summary(stats.plainYaw)
    __result(string.format('%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.3f|%.1f|%d',
      p.mean, p.p95, p.worst, q.mean, q.p95, q.worst, py.mean, py.p95, py.worst, qy.mean, qy.p95, qy.worst,
      response.predicted or -1, response.plain or -1, stats.jump, client.learner.samples) .. string.format('|%.3f|%.1f', stats.crashOff or 0, stats.crashWorst or 0))`)
  const [pm, p95, pw, qm, q95, qw, pym, py95, pyw, qym, qy95, qyw, rp, rq, jump, samples, crashOff, crashWorst] = result.split('|').map(Number)
  const m = (inch) => (inch * 0.0254).toFixed(2) + ' m'
  console.log(`ping ${PING} ms, ${BATCH} command(s) a packet${CLOCK ? '' : ' (no command clock)'}, 3% of states lost, ${samples} acceleration samples learned`)
  console.log(`  position off where the server will be:  predicted mean ${m(pm)}, 95% ${m(p95)}, worst ${m(pw)}`)
  console.log(`                                          plain Source mean ${m(qm)}, 95% ${m(q95)}, worst ${m(qw)}`)
  console.log(`  heading off:                            predicted mean ${pym.toFixed(1)} deg, 95% ${py95.toFixed(1)}, worst ${pyw.toFixed(1)}`)
  console.log(`                                          plain Source mean ${qym.toFixed(1)} deg, 95% ${qy95.toFixed(1)}, worst ${qyw.toFixed(1)}`)
  console.log(`  steering key to 2 deg turned on screen: predicted ${(rp * 1000).toFixed(0)} ms, plain Source ${(rq * 1000).toFixed(0)} ms`)
  console.log(`  largest correction jump in one frame:   ${m(jump)} (outside the crash)`)
  console.log(`  a crash at 13 s nobody predicted:       up to ${m(crashWorst)} off, back within 0.5 m after ${(crashOff * 1000).toFixed(0)} ms`)
  const failures = []
  if (!(pm < qm * 0.35)) failures.push('the prediction is not clearly closer than plain Source')
  if (!(rp >= 0 && rq > 0 && rp < rq - PING / 1000 * 0.6)) failures.push('steering does not show clearly sooner')
  if (!(jump < 6)) failures.push('a correction jumped more than 6 inches in one frame')
  if (!(crashOff < PING / 1000 + 0.35)) failures.push('the crash took too long to show')
  if (failures.length) { console.log('FAILED: ' + failures.join('; ')); process.exit(1) }
  console.log('OK')
})().catch((error) => { console.error(error); process.exit(1) })
