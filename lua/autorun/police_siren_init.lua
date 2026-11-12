-- Police siren loader. Separate from the audio engine: to drop the siren, delete this file,
-- lua/police_siren/ and dev/siren_studio/
POLICE_SIREN = POLICE_SIREN or {}

local base = "police_siren/"
local shared = { "sh_siren_config.lua", "sh_siren.lua" }
local client = { "cl_siren_synth.lua", "cl_siren.lua" }

if SERVER then
	for _, f in ipairs(shared) do AddCSLuaFile(base .. f) end
	for _, f in ipairs(client) do AddCSLuaFile(base .. f) end
end

for _, f in ipairs(shared) do include(base .. f) end

if SERVER then
	include(base .. "sv_siren.lua")
else
	for _, f in ipairs(client) do include(base .. f) end
end
