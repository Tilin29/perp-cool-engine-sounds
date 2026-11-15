--[[
	SL65 AMG RTU: the Audio Engine addon's example police car (Mercedes SL65 AMG, RTU liveries), kept
	as its own addon while it's needed for testing: not part of the final Audio Engine. Delete this
	addon folder to drop it; the Audio Engine never refers to it.

	Spawn-menu entries (Vehicles > Police), one per livery, and (with the Audio Engine installed)
	the car's engine settings (lua/sl65amg_rtu/sh_car.lua) and its horn (the car_horn module).
]]

local MODEL = "models/plpd/sl65amg_rtu.mdl"

if SERVER then AddCSLuaFile("sl65amg_rtu/sh_car.lua") end

local function addSpawnEntry(class, name, skin)
	list.Set("Vehicles", class, {
		Name = name,
		Class = "prop_vehicle_jeep",
		Category = "Police",
		Author = "Tilin",
		Information = "Mercedes SL65 AMG, police RTU. Procedural V12 engine sound with speed/rpm HUD.",
		Model = MODEL,
		KeyValues = {
			vehiclescript = "scripts/vehicles/plpd/sl65amg_rtu.txt",
			skin = tostring(skin),
		},
	})
end

addSpawnEntry("rtu_sl65amg", "SL65 AMG (Police)", 0)
addSpawnEntry("rtu_sl65amg_blue", "SL65 AMG (RTU Blue)", 1)
addSpawnEntry("rtu_sl65amg_yellow", "SL65 AMG (RTU Yellow)", 2)

-- the Audio Engine's settings and the horn, once those addons are loaded (autorun runs in name
-- order, so audio_engine_init.lua normally comes first; else at Initialize)
local registered = false
local function register()
	if registered then return end
	if AUDIO_ENGINE and AUDIO_ENGINE.RegisterCar then
		include("sl65amg_rtu/sh_car.lua")
		registered = true
	end
	local hornConfig = CAR_HORN and CAR_HORN.CONFIG
	if hornConfig and istable(hornConfig.models) and hornConfig.models[MODEL] == nil then hornConfig.models[MODEL] = "trumpet" end
end
register()
hook.Add("Initialize", "sl65amg_rtu", register)
