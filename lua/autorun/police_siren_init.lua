-- Police siren loader. Separate from the audio engine: to drop the siren, delete this file,
-- lua/police_siren/ and dev/siren_studio/
POLICE_SIREN = POLICE_SIREN or {}

local folder = "police_siren/"
local sharedFiles = { "sh_siren_config.lua", "sh_siren.lua" }
local clientFiles = { "cl_siren_synth.lua", "cl_siren.lua" }

if SERVER then
	for _, fileName in ipairs(sharedFiles) do AddCSLuaFile(folder .. fileName) end
	for _, fileName in ipairs(clientFiles) do AddCSLuaFile(folder .. fileName) end
end

for _, fileName in ipairs(sharedFiles) do include(folder .. fileName) end

if SERVER then
	include(folder .. "sv_siren.lua")
else
	for _, fileName in ipairs(clientFiles) do include(folder .. fileName) end
end
