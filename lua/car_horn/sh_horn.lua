--[[
	Car horn: which horn a car has and whether it sounds. Separate from the audio engine: any
	car (prop_vehicle_jeep) has a horn, CONFIG.models' for its model or CONFIG.default.

	The driver's honk key sets NW2 horn_on on the car (sv_horn.lua) and counts every press in
	horn_presses: a tap's press and release can land in the same tick, and the count still tells
	every client it was pressed.
]]
local CarHorn = CAR_HORN

CarHorn.ON_NW = "horn_on"
CarHorn.PRESSES_NW = "horn_presses"
CarHorn.PRESSES_WRAP = 1024
-- overuse (CONFIG.limit): on the car, how strong its horn sounds (1 full .. 0 its weakest); on the
-- player, their charge as the server last worked it out, the CurTime() it was at and whether it ran out
CarHorn.POWER_NW = "horn_power"
CarHorn.CHARGE_NW = "horn_charge"
CarHorn.CHARGE_AT_NW = "horn_charge_at"
CarHorn.EXHAUSTED_NW = "horn_exhausted"

CarHorn.LimitConVar = CreateConVar("car_horn_limit", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"1 = a player's horn runs out of breath when overused (CAR_HORN.CONFIG.limit), 0 = no limit")

function CarHorn.Limited()
	return CarHorn.LimitConVar:GetBool()
end

--[[
	A player's horn charge, worked out the same way by the server (which decides) and the driver's
	own client (which plays their horn at once): { charge (s), at (CurTime()), honking, exhausted,
	croakUntil }. Sounding drains it, a press costs pressCost, it refills while silent. Run dry, the
	horn croaks at its weakest for `croak` s, then it's exhausted: silent until back to `resume`.
]]
function CarHorn.NewCharge(now)
	return { charge = CarHorn.CONFIG.limit.charge, at = now, honking = false, exhausted = false }
end

function CarHorn.AdvanceCharge(state, now)
	local limit = CarHorn.CONFIG.limit
	local elapsed = math.max(now - state.at, 0)
	if state.honking then
		state.charge = math.max(0, state.charge - elapsed)
	else
		state.charge = math.min(limit.charge, state.charge + limit.refill * elapsed)
	end
	state.at = now
	if state.exhausted and not state.honking and state.charge >= limit.resume then state.exhausted = false end
end

-- a press: whether it sounds
function CarHorn.PressCharge(state, now)
	CarHorn.AdvanceCharge(state, now)
	if state.exhausted then return false end
	state.charge = math.max(0, state.charge - CarHorn.CONFIG.limit.pressCost)
	state.honking, state.croakUntil = true, nil

	return true
end

function CarHorn.ReleaseCharge(state, now)
	CarHorn.AdvanceCharge(state, now)
	state.honking, state.croakUntil = false, nil
end

-- while held: whether it still sounds (false once it has croaked its last). Exhausted the moment it
-- runs dry, not when the croak ends: taps let go inside the croak otherwise croaked on every press
function CarHorn.HoldCharge(state, now)
	CarHorn.AdvanceCharge(state, now)
	if state.charge > 0 then return true end
	if not state.croakUntil then
		state.croakUntil = now + CarHorn.CONFIG.limit.croak
		state.exhausted = true
		return true
	end
	if now < state.croakUntil then return true end
	state.honking, state.croakUntil = false, nil

	return false
end

-- how strong the horn sounds: 1, falling to 0 (its weakest) under weakBelow of a full charge; 0 while it croaks
function CarHorn.ChargeStrength(state)
	if state.croakUntil then return 0 end
	local limit = CarHorn.CONFIG.limit
	local weakFrom = limit.charge * limit.weakBelow
	if weakFrom <= 0 or state.charge >= weakFrom then return 1 end

	return state.charge / weakFrom
end

-- the volume and pitch factors of a horn at `strength` (CarHorn.ChargeStrength)
function CarHorn.WeakFactors(strength)
	local limit = CarHorn.CONFIG.limit

	return limit.weakVolume + (1 - limit.weakVolume) * strength, limit.weakPitch + (1 - limit.weakPitch) * strength
end

-- a held horn easing down: its volume factor after `heldFor` s
function CarHorn.RelaxFactor(heldFor)
	local limit = CarHorn.CONFIG.limit
	if heldFor <= limit.relaxAfter then return 1 end
	local progress = math.min((heldFor - limit.relaxAfter) / math.max(limit.relaxTime, 0.01), 1)

	return 1 - (1 - limit.relaxVolume) * progress * progress * (3 - 2 * progress)
end

-- the car's horn: an id of CONFIG.horns, or nil (not a car)
function CarHorn.HornOf(vehicle)
	if not IsValid(vehicle) or vehicle:GetClass() ~= "prop_vehicle_jeep" then return nil end
	local config = CarHorn.CONFIG
	local hornId = config.models[string.lower(vehicle:GetModel() or "")]
	if not config.horns[hornId or ""] then hornId = config.default end

	return config.horns[hornId] and hornId or nil
end
