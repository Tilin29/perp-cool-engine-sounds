--[[
	Emergency lights. The marked police cars and the fire and medical job vehicles
	(AudioEngine.JOB_VEHICLES entries named here) get PERP's lightbar
	(models/perpheads/props/police_lightbar.mdl) on the roof and spawn in their livery; the
	ambulances and the fire truck have lights of their own in the model (AudioEngine.BUILTIN_LIGHTS), which
	light up instead. The LEDs and lenses are plain textures, so the flashing is drawn by
	cl_police.lua (glows on the lenses plus a dynamic light); sv_police.lua attaches the bar and
	switches the lights.

	scheme: the colours and the siren's tones: "police" (red / white / blue, the default),
	"fire" (red / yellow), "medical" (red / white). Networked as NW2 audio_lightscheme.

	Lightbar model space: long axis X (-29.7..29.7), front +Y, the message board at the rear,
	base at z 0, lenses z 3.3..5.0: the same way round as the TDM cars (nose +Y, -X the
	driver's side), so it mounts unturned.
]]
local AudioEngine = AUDIO_ENGINE

AudioEngine.LIGHTBAR_MODEL = "models/perpheads/props/police_lightbar.mdl"
AudioEngine.LIGHTBAR_ANGLE = Angle(0, 0, 0)

-- spawn name (AudioEngine.JOB_VEHICLES) -> where the bar sits, in the car's model space: centre line,
-- just behind the windscreen, on the roof (measured from the meshes: highest painted surface, which
-- sits ~10.5 lower than in game on the TDM models: the 340i was fixed in game from 57.5 to 68.5)
-- bodygroups: by name, set on spawn (the Crown Vic shares its model with the taxi: no roof sign, no meter)
-- builtin: the model's own lights (AudioEngine.BUILTIN_LIGHTS), no bar
AudioEngine.POLICE_VEHICLES = {
	["BMW 340i Police"] = { mount = Vector(0, -11, 68.5) },
	["BMW M5 E60 Police"] = { mount = Vector(0, -12, 72.5) },
	["Dodge Charger 2012 Police"] = { mount = Vector(0, -16, 73.5) },
	["Dodge Charger SRT-8 Police"] = { mount = Vector(0, -8, 68.5) },
	["Ford Crown Victoria Police"] = { mount = Vector(0, -12, 70.5), bodygroups = { sign = 1, stuff = 1 } },
	["Ford Transit 2016 (Police)"] = { mount = Vector(0, -8, 110) },
	["Land Rover Range Rover 2012 Police"] = { mount = Vector(0, -24, 91.5) },
	["Mercedes SL65 AMG Police"] = { mount = Vector(0, -16, 60.5) },
	["Porsche Cayenne Turbo S Police"] = { mount = Vector(0, -24, 83) },
	-- fire (the F350's own roof lights are amber clearance lights: it gets a bar behind them)
	["Dodge RAM SRT10 Fire Rescue"] = { mount = Vector(0, -12, 98), scheme = "fire" },
	["Ford F350 Fire Rescue"] = { mount = Vector(0, 8, 92.5), scheme = "fire" },
	["Land Rover Defender Fire"] = { mount = Vector(0, -2, 115), scheme = "fire" },
	["Fire Truck"] = { builtin = true, scheme = "fire" },
	-- medical
	["Audi RS4 Avant First Responder"] = { mount = Vector(0, -6, 80), scheme = "medical" },
	["Toyota Prius Medic"] = { mount = Vector(0, -12, 83.5), scheme = "medical" },
	["Ambulance"] = { builtin = true, scheme = "medical" },
	["Ford F450 Ambulance"] = { builtin = true, scheme = "medical" },
}

--[[
	Lights built into the model (lower-case model path), placed from the meshes: each lamp's lens
	(pos, n = outward normal, w x h) in the space of the model's body bone, so in game they follow
	the bone (cl_police.lua, GetBoneMatrix): the GTA IV ports have their body bone turned 90 deg,
	and TDM models move theirs in the idle pose. color: a lamp colour of cl_police.lua (the lens
	texture's own); side -1 = driver's side, 1 = passenger's, 0 = centre; group as the bar's
	modules (o / i: the two halves of the wig-wag, c: centre). Headlights, tail lights and
	indicators are left out. Made with an MDL/VVD reader from the lens material's vertices.
]]
AudioEngine.BUILTIN_LIGHTS = {
	["models/sickness/meatwagon.mdl"] = { bone = "car.body", lamps = {
		{ position = Vector(41.52, 78.31, -20.52), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = -1, group = "o" },
		{ position = Vector(32.02, 78.31, -20.52), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = -1, group = "o" },
		{ position = Vector(45.02, 78.31, -13.62), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = -1, group = "o" },
		{ position = Vector(35.52, 78.31, -13.62), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = -1, group = "o" },
		{ position = Vector(48.42, 78.31, -6.82), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = -1, group = "i" },
		{ position = Vector(38.92, 78.31, -6.82), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = -1, group = "i" },
		{ position = Vector(51.82, 78.31, -0.02), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = 0, group = "c" },
		{ position = Vector(42.32, 78.31, -0.02), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = 0, group = "c" },
		{ position = Vector(48.42, 78.31, 6.78), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = 1, group = "i" },
		{ position = Vector(38.92, 78.31, 6.78), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = 1, group = "i" },
		{ position = Vector(45.02, 78.31, 13.58), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = 1, group = "o" },
		{ position = Vector(35.52, 78.31, 13.58), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "white", side = 1, group = "o" },
		{ position = Vector(41.52, 78.31, 20.48), normal = Vector(0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = 1, group = "o" },
		{ position = Vector(32.02, 78.31, 20.48), normal = Vector(-0.97, 0.24, -0), width = 6.5, height = 4.5, color = "red", side = 1, group = "o" },
		{ position = Vector(-144.98, 86.21, -5.22), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "white", side = -1, group = "i" },
		{ position = Vector(-144.98, 86.21, 5.58), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "white", side = 1, group = "i" },
		{ position = Vector(-144.98, 86.21, -15.92), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(-144.98, 86.21, 16.28), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(-144.98, 86.21, -26.32), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "white", side = -1, group = "i" },
		{ position = Vector(-144.98, 86.21, 26.68), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "white", side = 1, group = "i" },
		{ position = Vector(-144.98, 86.21, -34.92), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(-144.98, 86.21, 35.28), normal = Vector(-1, 0.1, -0), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(-144.98, 86.21, -44.72), normal = Vector(-1, 0.1, -0), width = 6, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(-144.98, 86.21, 45.08), normal = Vector(-1, 0.1, -0), width = 6, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(-144.48, 80.21, -37.62), normal = Vector(-1, 0, -0), width = 7, height = 5.5, color = "red", side = -1, group = "i" },
		{ position = Vector(-144.48, 80.21, 37.98), normal = Vector(-1, 0, -0), width = 7, height = 5.5, color = "red", side = 1, group = "i" },
		{ position = Vector(1.82, 77.51, -49.22), normal = Vector(0, 0, -1), width = 7, height = 5.5, color = "red", side = -1, group = "o" },
		{ position = Vector(1.82, 77.51, 49.58), normal = Vector(0, 0, 1), width = 7, height = 5.5, color = "red", side = 1, group = "o" },
		{ position = Vector(-17.38, 77.51, -49.22), normal = Vector(0, 0, -1), width = 7, height = 5.5, color = "white", side = -1, group = "i" },
		{ position = Vector(-17.38, 77.51, 49.58), normal = Vector(0, 0, 1), width = 7, height = 5.5, color = "white", side = 1, group = "i" },
		{ position = Vector(-111.18, 77.51, -49.22), normal = Vector(0, 0, -1), width = 7, height = 5.5, color = "white", side = -1, group = "i" },
		{ position = Vector(-111.18, 77.51, 49.58), normal = Vector(0, 0, 1), width = 7, height = 5.5, color = "white", side = 1, group = "i" },
		{ position = Vector(-130.38, 77.51, -49.22), normal = Vector(0, 0, -1), width = 7, height = 5.5, color = "red", side = -1, group = "o" },
		{ position = Vector(-130.38, 77.51, 49.58), normal = Vector(0, 0, 1), width = 7, height = 5.5, color = "red", side = 1, group = "o" },
		{ position = Vector(117.92, 30.01, -17.32), normal = Vector(1, 0, -0), width = 5, height = 3, color = "red", side = -1, group = "o" },
		{ position = Vector(117.92, 30.01, 17.68), normal = Vector(1, 0, -0), width = 5, height = 3, color = "red", side = 1, group = "o" },
		{ position = Vector(117.92, 30.01, -10.62), normal = Vector(1, 0, -0), width = 5, height = 3, color = "red", side = -1, group = "i" },
		{ position = Vector(117.92, 30.01, 10.98), normal = Vector(1, 0, -0), width = 5, height = 3, color = "red", side = 1, group = "i" },
	} },
	["models/sickness/truckfire.mdl"] = { bone = "car.body", lamps = {
		{ position = Vector(175.3, 99.87, 0.06), normal = Vector(0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = 0, group = "c" },
		{ position = Vector(164.3, 99.87, 0.06), normal = Vector(-0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = 0, group = "c" },
		{ position = Vector(175.3, 99.87, -12.54), normal = Vector(0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = -1, group = "i" },
		{ position = Vector(164.3, 99.87, -12.54), normal = Vector(-0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = -1, group = "i" },
		{ position = Vector(175.3, 99.87, 13.06), normal = Vector(0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = 1, group = "i" },
		{ position = Vector(164.3, 99.87, 13.06), normal = Vector(-0.98, 0.2, -0), width = 7, height = 4, color = "yellow", side = 1, group = "i" },
		{ position = Vector(175.3, 99.87, -30.74), normal = Vector(0.98, 0.2, -0), width = 7, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(147.8, 99.87, -39.24), normal = Vector(-0.98, 0.2, -0), width = 7, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(175.3, 99.87, 31.26), normal = Vector(0.98, 0.2, -0), width = 7, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(147.8, 99.87, 39.76), normal = Vector(-0.98, 0.2, -0), width = 7, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(154.8, 99.87, -48.24), normal = Vector(0, 0.2, -0.98), width = 7, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(154.8, 99.87, 48.76), normal = Vector(0, 0.2, 0.98), width = 7, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(82.3, 99.87, -35.34), normal = Vector(0.98, 0.2, -0), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(54.3, 99.87, -35.34), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(68.3, 99.87, -41.74), normal = Vector(0, 0.2, -0.98), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(82.3, 99.87, 35.86), normal = Vector(0.98, 0.2, -0), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(54.3, 99.87, 35.86), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(68.3, 99.87, 42.26), normal = Vector(0, 0.2, 0.98), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(-167.7, 98.97, -26.14), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4.5, color = "yellow", side = -1, group = "i" },
		{ position = Vector(-167.7, 98.97, 26.66), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4.5, color = "yellow", side = 1, group = "i" },
		{ position = Vector(-167.7, 98.97, -44.54), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4.5, color = "yellow", side = -1, group = "o" },
		{ position = Vector(-167.7, 98.97, 45.06), normal = Vector(-0.98, 0.2, -0), width = 8, height = 4.5, color = "yellow", side = 1, group = "o" },
		{ position = Vector(199.1, 44.27, -18.44), normal = Vector(1, 0, -0), width = 4, height = 8, color = "red", side = -1, group = "i" },
		{ position = Vector(199.1, 44.27, 18.96), normal = Vector(1, 0, -0), width = 4, height = 8, color = "red", side = 1, group = "i" },
		{ position = Vector(199.1, 44.27, -23.24), normal = Vector(1, 0, -0), width = 4, height = 8, color = "yellow", side = -1, group = "o" },
		{ position = Vector(199.1, 44.27, 23.76), normal = Vector(1, 0, -0), width = 4, height = 8, color = "yellow", side = 1, group = "o" },
	} },
	["models/forest/f450_ambo.mdl"] = { bone = "Bone001", lamps = {
		{ position = Vector(-35.5, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 8, height = 4.5, color = "red", side = -1, group = "o" },
		{ position = Vector(-26, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "red", side = -1, group = "o" },
		{ position = Vector(-21.6, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "white", side = -1, group = "o" },
		{ position = Vector(-17.2, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "red", side = -1, group = "i" },
		{ position = Vector(-6, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "white", side = -1, group = "i" },
		{ position = Vector(6, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "white", side = 1, group = "i" },
		{ position = Vector(18.6, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "red", side = 1, group = "i" },
		{ position = Vector(23, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "white", side = 1, group = "o" },
		{ position = Vector(27.3, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 5, height = 4.5, color = "red", side = 1, group = "o" },
		{ position = Vector(36, 23.5, 95.6), normal = Vector(0, 0.99, 0.15), width = 8, height = 4.5, color = "red", side = 1, group = "o" },
		{ position = Vector(-44.2, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(-34.4, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "white", side = -1, group = "o" },
		{ position = Vector(-25.8, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = -1, group = "o" },
		{ position = Vector(-15.5, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "white", side = -1, group = "i" },
		{ position = Vector(-4.7, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = -1, group = "i" },
		{ position = Vector(6, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "white", side = 1, group = "i" },
		{ position = Vector(16.8, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = 1, group = "i" },
		{ position = Vector(27.2, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "white", side = 1, group = "o" },
		{ position = Vector(35.7, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(45.6, -148, 106.5), normal = Vector(0, -1, 0.1), width = 8, height = 4, color = "red", side = 1, group = "o" },
		{ position = Vector(-48.6, -133.5, 98), normal = Vector(-1, 0, 0), width = 7, height = 6, color = "red", side = -1, group = "o" },
		{ position = Vector(-48.6, -114.3, 98), normal = Vector(-1, 0, 0), width = 7, height = 6, color = "white", side = -1, group = "i" },
		{ position = Vector(-48.6, -20.5, 98), normal = Vector(-1, 0, 0), width = 7, height = 6, color = "white", side = -1, group = "i" },
		{ position = Vector(-48.6, -1.3, 98), normal = Vector(-1, 0, 0), width = 7, height = 6, color = "red", side = -1, group = "o" },
		{ position = Vector(49.9, -133.5, 98), normal = Vector(1, 0, 0), width = 7, height = 6, color = "red", side = 1, group = "o" },
		{ position = Vector(49.9, -114.3, 98), normal = Vector(1, 0, 0), width = 7, height = 6, color = "white", side = 1, group = "i" },
		{ position = Vector(49.9, -1.3, 98), normal = Vector(1, 0, 0), width = 7, height = 6, color = "red", side = 1, group = "o" },
	} },
}

-- the livery: the job vehicle's skin (11 on the TDM models; the Crown Vic's police one is 12, 11 is
-- its taxi; the Transit has only one)
AudioEngine.POLICE_BY_SCRIPT = {}
for _, job in ipairs(AudioEngine.JOB_VEHICLES) do
	local police = AudioEngine.POLICE_VEHICLES[job[1]]
	if police then
		police.script = job[3]
		police.skin = job[4]
		AudioEngine.POLICE_BY_SCRIPT[job[3]] = police
	end
end

AudioEngine.LIGHT_MODES = { "CODE 2", "CODE 3" }

--[[
	LED modules of the bar: pos = lens centre, n = outward normal, w = width.
	group: o outer, i inner, c centre, k corner; side -1 = driver's side (red), 1 = passenger's
	side (blue), 0 = centre (white)
	Written as read from the mesh, which is in the root bone's frame (turned -90 deg about Z:
	x = rear, y = passenger's side); module() turns them into model space (x, y) -> (y, -x)
]]
local MODULE_HEIGHT = 4.15
local function lightbarModule(meshX, meshY, normalX, normalY, width, group, side)
	return { position = Vector(meshY, -meshX, MODULE_HEIGHT), normal = Vector(normalY, -normalX, 0), width = width, group = group, side = side }
end

AudioEngine.LIGHTBAR_MODULES = {}
for _, faceSide in ipairs({ -1, 1 }) do
	local faceX = 7.6 * faceSide
	table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(faceX, 0, faceSide, 0, 10, "c", 0))
	for _, side in ipairs({ -1, 1 }) do
		table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(faceX, 10 * side, faceSide, 0, 9.5, "i", side))
		table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(faceX, 19.35 * side, faceSide, 0, 9, "o", side))
	end
end
for _, side in ipairs({ -1, 1 }) do
	table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(-6.2, 26.6 * side, -0.88, 0.48 * side, 4.8, "k", side))
	table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(-1, 29.6 * side, 0.05, side, 5, "k", side))
	table.insert(AudioEngine.LIGHTBAR_MODULES, lightbarModule(5.2, 26.7 * side, 0.71, 0.7 * side, 4.9, "k", side))
end
