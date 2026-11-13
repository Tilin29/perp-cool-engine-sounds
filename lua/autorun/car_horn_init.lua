-- Car horn loader. Separate from the audio engine: to drop the horns, delete this file,
-- lua/car_horn/ and dev/honk_studio/
CAR_HORN = CAR_HORN or {}

local folder = "car_horn/"
local sharedFiles = { "sh_horn_config.lua", "sh_horn.lua" }
local clientFiles = { "cl_horn_synth.lua", "cl_horn.lua" }

if SERVER then
	for _, fileName in ipairs(sharedFiles) do AddCSLuaFile(folder .. fileName) end
	for _, fileName in ipairs(clientFiles) do AddCSLuaFile(folder .. fileName) end
end

for _, fileName in ipairs(sharedFiles) do include(folder .. fileName) end

if SERVER then
	include(folder .. "sv_horn.lua")
else
	for _, fileName in ipairs(clientFiles) do include(folder .. fileName) end
end
