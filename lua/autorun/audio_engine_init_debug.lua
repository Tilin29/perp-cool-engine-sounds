--[[
	Audio Engine DEBUG module loader. The tuning tools: vehicle script editor, gearing editor, rev
	response, handling switches, settings (audio_engine_debug_menu / !enginedebug, superadmins,
	once the server sets audio_engine_debug 1).

	NOT part of the final addon: delete this file and lua/audio_engine_debug/ to ship without it.
	The core addon never refers to it. (Named so it loads after audio_engine_init.lua.)
]]
if not (AUDIO_ENGINE and AUDIO_ENGINE.Drivetrain) then include("autorun/audio_engine_init.lua") end

local base = "audio_engine_debug/"
local shared = { "sh_kv.lua", "sh_debug.lua" }
local client = { "cl_debug.lua" }

if SERVER then
	for _, f in ipairs(shared) do AddCSLuaFile(base .. f) end
	for _, f in ipairs(client) do AddCSLuaFile(base .. f) end
end
for _, f in ipairs(shared) do include(base .. f) end
if SERVER then
	include(base .. "sv_debug.lua")
else
	for _, f in ipairs(client) do include(base .. f) end
end
