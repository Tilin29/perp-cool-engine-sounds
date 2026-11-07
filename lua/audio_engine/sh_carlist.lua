--[[
	Audio Engine - which engine preset each car on the server uses (shared)

	From the engine list (Engine Types.xlsx): every car, its engine preset (sh_presets.lua), and where the
	real car differs a lot from the preset, a few per-car changes ("stock"). Turbo cars use a
	turbo preset; the turbo itself is a shared sound, so it never costs a new engine.

	Cars only get the procedural engine once they are registered with their model. All of them
	are, from E.CAR_MODELS at the bottom of this file. To add another car, register it by name:

	    AUDIO_ENGINE.RegisterCarNamed("models/tdmcars/458spider.mdl", "Ferrari 458 Spider")

	and optionally pass anything sh_config.lua takes (wheelRadius, soundLevel, stability...):

	    AUDIO_ENGINE.RegisterCarNamed("models/tdmcars/c10.mdl", "Chevrolet C10", { wheelRadius = 0.37 })

	Each different preset + "stock" combination is its own set of sounds, so cars that share
	one share their sounds. Diesels (Transit, Defender, Range Rover 08, Hummer H1) use the
	closest petrol engine, slowed and softened.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local E = AUDIO_ENGINE

-- character: the car's own exhaust voice over its engine type's (cl_synth.lua CHARACTER: f1, f2,
-- f3, w, o1, o05; any left out keep the type's). A new sound: re-bake. dev/tone_studio.html edits it
local function P(preset, stock, character) return { preset = preset, stock = stock, character = character } end

E.CAR_ENGINES = {
	["Alfa Romeo 33 Stradale (1967)"] = P("v8flat", { redline = 8800 }),
	["Alfa Romeo Giulietta"] = P("i4t"),
	["Aston Martin DB5"] = P("i6", { redline = 5500 }),
	["Aston Martin DBS"] = P("v12na", { redline = 7000 }),
	["Aston Martin Rapide"] = P("v12na", { redline = 7000 }),
	["Aston Martin V12 Vantage"] = P("v12na", { redline = 7000 }),
	["Audi R8 Plus"] = P("v10"),
	["Audi R8 Spyder"] = P("v10"),
	["Audi R8 V10"] = P("v10"),
	["Audi RS4 Avant"] = P("v8s"),
	["Audi S5"] = P("v8s", { redline = 7000 }),
	["Audi TT 2007"] = P("i4t"),
	["BMW 1M"] = P("i6t"),
	["BMW 340i"] = P("i6t"),
	["BMW 507"] = P("v8r", { redline = 5000 }),
	["BMW M1"] = P("i6"),
	["BMW M3 E92"] = P("v8s", { redline = 8400 }),
	["BMW M5 E34"] = P("i6"),
	["BMW M5 E60"] = P("v10"),
	["BMW M6 2013"] = P("v8xt"),
	["Bowler EXR-S"] = P("v8p"),
	["Bugatti EB110"] = P("v12t"),
	-- tuned in dev/tone_studio.html
	["Bugatti Veyron 16.4"] = P("w16", { popTone = 0.65, tone = 0.4, gurgle = 0.2 },
		{ f1 = 66, f2 = 486, f3 = 224, w = 0.88, o1 = 0.23, o05 = 0.42 }),
	["Bugatti Veyron SS"] = P("w16"),
	["Cadillac Escalade 2012"] = P("v8x"),
	["Chevrolet Blazer"] = P("v6", { redline = 5000 }),
	["Chevrolet C10"] = P("v8x", { redline = 5000 }),
	["Chevrolet Camaro SS 69"] = P("v8m"),
	["Chevrolet Camaro ZL1"] = P("v8p"),
	["Chevrolet Chevelle SS"] = P("v8m"),
	["Chevrolet Corvette GSC"] = P("v8p"),
	["Chevrolet Corvette Stingray 427"] = P("v8m"),
	["Chevrolet Impala SS 96"] = P("v8r", { redline = 5000 }),
	["Chevrolet Spark"] = P("i4q"),
	["Chrysler 300C"] = P("v8r"),
	["Chrysler PT Cruiser"] = P("i4w"),
	["Citroen C1"] = P("i3"),
	["Citroen C4"] = P("i4w"),
	["DeLorean DMC-12"] = P("v6odd"),
	["Dodge Challenger 1970"] = P("v8m"),
	["Dodge Challenger 2015"] = P("v8p"),
	["Dodge Charger 2012"] = P("v8p"),
	["Dodge Charger SRT-8"] = P("v8p"),
	["Dodge RAM SRT10"] = P("v10l"),
	["Dodge Viper GTS"] = P("v10l"),
	["Dundreary Limousine"] = P("v8r"),
	["Ferrari 250 GTO"] = P("v12na", { redline = 7500 }),
	["Ferrari 250GT"] = P("v12na", { redline = 7000 }),
	["Ferrari 458 Spider"] = P("v8flat", { redline = 9000 }),
	["Ferrari 512 TR"] = P("f12"),
	["Ferrari Enzo"] = P("v12na"),
	["Ferrari F12 Berlinetta"] = P("v12na", { redline = 8700 }),
	["Ferrari F430"] = P("v8flat"),
	["Ferrari F50"] = P("v12na", { redline = 8500 }),
	["Ferrari LaFerrari"] = P("v12na", { redline = 9200 }),
	["Ford Crown Victoria"] = P("v8r", { redline = 5000 }),
	["Ford Deluxe Coupe 1940"] = P("v8m", { redline = 4000 }),
	["Ford F100"] = P("v8x", { redline = 5000 }),
	["Ford F350"] = P("v8x", { redline = 5000 }),
	["Ford Focus RS"] = P("i5t"),
	["Ford Focus SVT"] = P("i4s", { redline = 7200 }),
	["Ford GT 05"] = P("v8p", { redline = 6500 }),
	["Ford Mustang GT"] = P("v8p", { redline = 7000 }),
	["Ford Raptor SVT"] = P("v8x"),
	["Ford Shelby GT500"] = P("v8m"),
	["Ford Transit"] = P("i4t", { redline = 4500, tone = 0.3 }),
	["GMC Sierra"] = P("v8x"),
	["GMC Syclone"] = P("v6t", { redline = 5000 }),
	["GMC Vandura"] = P("v8x", { redline = 5000 }),
	["Holden HSV GTS"] = P("v8p"),
	["Holden HSV W427"] = P("v8p", { redline = 6500 }),
	["Honda CR-X SiR"] = P("i4s", { redline = 8000 }),
	["Honda Civic Type R"] = P("i4s"),
	["Honda Civic Type R 1997"] = P("i4s"),
	["Honda S2000"] = P("i4s", { redline = 9000 }),
	["Hudson Hornet"] = P("i6", { redline = 4500, tone = 0.4 }),
	["Hummer H1"] = P("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),
	["Jaguar E-Type"] = P("i6", { redline = 6000 }),
	["Jaguar F-Type"] = P("v8p", { redline = 6500 }),
	["Jeep Grand Cherokee"] = P("v8x"),
	["Jeep Wrangler"] = P("i6", { redline = 5000 }),
	["Kia Ceed"] = P("i4q"),
	["Kia Forte Koup"] = P("i4q"),
	["Lamborghini Diablo"] = P("v12na", { redline = 7000 }),
	["Lamborghini Gallardo"] = P("v10"),
	["Lamborghini Gallardo LP570-4 Spyder Performante"] = P("v10"),
	["Lamborghini Miura"] = P("v12na", { redline = 7500 }),
	["Lamborghini Murcielago"] = P("v12na"),
	["Lamborghini Murcielago LP670-4 SV"] = P("v12na"),
	["Lamborghini Reventon Roadster"] = P("v12na"),
	["Land Rover Defender"] = P("i4t", { redline = 4500, tone = 0.3 }),
	["Land Rover Range Rover 08"] = P("v8xt", { redline = 4500, tone = 0.4 }),
	["Land Rover Range Rover 2012"] = P("v8xt", { redline = 6000 }),
	["Lexus IS 300"] = P("i6"),
	["Lexus IS F"] = P("v8s", { redline = 7000 }),
	["Maserati Ghibli S"] = P("v6t", { redline = 6500 }),
	["Maserati Quattroporte Sport GT S"] = P("v8s", { redline = 7200 }),
	["Mazda Furai"] = P("r3"),
	["Mazda MX-5 2007"] = P("i4", { redline = 7000 }),
	["Mazda RX-8"] = P("r2"),
	["Mazda RX7"] = P("r2t"),
	["Mazda Speed 3 2009"] = P("i4t"),
	["McLaren F1"] = P("v12na", { redline = 7500 }),
	["McLaren P1"] = P("v8h", { turbo = true, bov = true, redline = 8500 }),
	["Mercedes 300 SEL"] = P("v8r", { redline = 5000 }),
	["Mercedes 300SL Gullwing Coupe"] = P("i6", { redline = 6000 }),
	["Mercedes C32 AMG"] = P("v6", { redline = 6200 }),
	["Mercedes E63 AMG"] = P("v8s", { redline = 7200 }),
	["Mercedes G-Class"] = P("v8x"),
	["Mercedes ML63 AMG"] = P("v8s", { redline = 7200 }),
	["Mercedes McLaren SLR"] = P("v8r", { redline = 6500 }),
	["Mercedes SL65 AMG"] = P("sl65"),
	["Mercedes SLS AMG"] = P("v8s", { redline = 7200 }),
	["Mini Clubman"] = P("i4w"),
	["Mini Cooper 1965"] = P("i4", { redline = 6000 }),
	["Mini Cooper S 2011"] = P("i4st"),
	["Mini Coupe"] = P("i4st"),
	["Mitsubishi Colt Ralliart"] = P("i4st"),
	["Mitsubishi Eclipse GSX"] = P("i4t"),
	["Mitsubishi Eclipse GT"] = P("v6"),
	["Mitsubishi Lancer Evo VIII"] = P("i4t"),
	["Mitsubishi Lancer Evo X"] = P("i4t"),
	["Morgan Aero SS"] = P("v8p", { redline = 6500 }),
	["Nissan 350z"] = P("v6", { redline = 7000 }),
	["Nissan 370Z"] = P("v6", { redline = 7500 }),
	["Nissan GT-R SpecV"] = P("v6t"),
	["Nissan Leaf"] = P("ev", { redline = 10400 }),
	["Nissan Silvia"] = P("i4t"),
	["Nissan Skyline R34"] = P("i6t", { redline = 8000 }),
	["Noble M600"] = P("v8xt"),
	["Pagani Zonda C12"] = P("v12na", { redline = 7500 }),
	["Pontiac Fiero GT"] = P("v6", { redline = 5500 }),
	["Pontiac Firebird Trans Am"] = P("v8m"),
	["Porsche 911 GT3"] = P("f6"),
	["Porsche 918 Spyder"] = P("v8h"),
	["Porsche 997 GT3"] = P("f6", { redline = 8400 }),
	["Porsche Carrera GT"] = P("v10"),
	["Porsche Cayenne Turbo 2012"] = P("v8xt"),
	["Porsche Cayenne Turbo S"] = P("v8xt"),
	["Scion FR-S"] = P("f4"),
	["Scion tC"] = P("i4w"),
	["Scion xD"] = P("i4q"),
	["Shelby 1000"] = P("v8m", { redline = 6500 }),
	["Subaru Impreza WRX STI"] = P("boxer"),
	["Subaru Legacy GT 2010"] = P("boxer"),
	["Subaru Legacy RS 1990"] = P("boxer"),
	["Tesla Model S"] = P("ev"),
	["Toyota FJ Cruiser"] = P("v6"),
	["Toyota MR2 GT"] = P("i4t"),
	["Toyota Prius"] = P("i4h"),
	["Toyota Supra"] = P("i6t"),
	["Vauxhall Agila"] = P("i3"),
	["Vauxhall Astra"] = P("i4w"),
	["Vauxhall Corsa"] = P("i4q"),
	["Vauxhall Insignia"] = P("i4t"),
	["Volkswagen Beetle 1967"] = P("f4air"),
	["Volkswagen Camper 1965"] = P("f4air"),
	["Volkswagen Golf GTI 2014"] = P("i4st"),
	["Volkswagen Golf MKII"] = P("i4w"),
	["Volkswagen Golf MKIII"] = P("i4w"),
	["Volkswagen New Beetle"] = P("i4w"),
	["Volkswagen Scirocco GT"] = P("i4st"),
	["Volvo 242 Turbo"] = P("i4t", { redline = 6000 }),
	["Volvo 850R"] = P("i5t"),
	["Volvo S60"] = P("i5t"),

	-- work and emergency vehicles on their own models (not in the engine list). They reuse
	-- engines already baked (the same sound at a lower redline needs no new bank):
	-- the diesels as the Hummer H1's, the petrol V8s as the Ford F350's, the vans as the Transit's
	["Ambulance"] = P("v8x", { redline = 5000 }),   -- GTA IV ambulance (Ford E-Series type)
	["Courier Truck"] = P("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),
	["Fire Truck"] = P("v8xt", { redline = 3000, idle = 650, tone = 0.35 }),
	["Ford F350 Fire Rescue"] = P("v8x", { redline = 5000 }),
	["Ford F350 Tow Truck"] = P("v8x", { redline = 5000 }),
	["Ford F450 Ambulance"] = P("v8x", { redline = 5000 }),
	["Ford Transit 2016 (Police)"] = P("i4t", { redline = 4500, tone = 0.3 }),
	["Ford Transit 2016 (Prisoner Transport)"] = P("i4t", { redline = 4500, tone = 0.3 }),
	["Lenco BearCat"] = P("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),   -- 6.7 diesel V8
	["SWAT Stockade"] = P("v8xt", { redline = 3200, idle = 650, tone = 0.35 }),   -- GTA IV police stockade
}

--[[
	Stock pops & bangs: how often (0-1, the menu's "Pops & bangs" slider: under 0.25 Rare, under
	0.5 Occasional, under 0.8 Frequent). Only cars that crackle from the factory are listed: sports
	exhausts with an overrun map (AMG V8s, the F-Type, Italian V10s and V12s, GT3s, hot hatches),
	rotaries, carburettor-era racers and race cars. Every other car is off. The engine presets'
	own pop values are only the starting point when an engine is retuned in the menu.
	Frequency and volume are runtime settings: changing them needs no re-bake.
]]
E.STOCK_POP_VOLUME = 0.7   -- stock pops & bangs volume (the menu's 100% is 1)
E.CAR_POPS = {
	-- frequent: famous for it
	["Jaguar F-Type"] = 0.6,
	["Mazda Furai"] = 0.6,
	["Pagani Zonda C12"] = 0.5,
	["Bowler EXR-S"] = 0.5,
	-- occasional: sports exhaust, crackles on the overrun
	["Lamborghini Murcielago LP670-4 SV"] = 0.45,
	["Lamborghini Gallardo LP570-4 Spyder Performante"] = 0.4,
	["Noble M600"] = 0.4,
	["Shelby 1000"] = 0.4,
	["Audi R8 Plus"] = 0.35,
	["Lamborghini Reventon Roadster"] = 0.35,
	["McLaren P1"] = 0.35,
	["Porsche Carrera GT"] = 0.35,
	["Mercedes SLS AMG"] = 0.35,
	["Mazda RX7"] = 0.35,
	["Ford Focus RS"] = 0.35,
	["Audi R8 V10"] = 0.3,
	["Audi R8 Spyder"] = 0.3,
	["Lamborghini Gallardo"] = 0.3,
	["Lamborghini Murcielago"] = 0.3,
	["Ferrari F430"] = 0.3,
	["Ferrari F12 Berlinetta"] = 0.3,
	["Ferrari Enzo"] = 0.3,
	["Ferrari LaFerrari"] = 0.3,
	["Ferrari F50"] = 0.3,
	["Porsche 918 Spyder"] = 0.3,
	["Porsche 911 GT3"] = 0.3,
	["Mercedes E63 AMG"] = 0.3,
	["Mercedes McLaren SLR"] = 0.3,
	["Aston Martin V12 Vantage"] = 0.3,
	["Dodge Viper GTS"] = 0.3,
	["Chevrolet Corvette GSC"] = 0.3,
	["Holden HSV W427"] = 0.3,
	["Ferrari 458 Spider"] = 0.25,
	["McLaren F1"] = 0.25,
	["Porsche 997 GT3"] = 0.25,
	["Aston Martin DBS"] = 0.25,
	["Chevrolet Camaro ZL1"] = 0.25,
	["Chevrolet Corvette Stingray 427"] = 0.25,
	["Holden HSV GTS"] = 0.25,
	["Morgan Aero SS"] = 0.25,
	["Maserati Ghibli S"] = 0.25,
	["Alfa Romeo 33 Stradale (1967)"] = 0.25,
	-- rare: the odd crackle
	["Lamborghini Diablo"] = 0.2,
	["Lamborghini Miura"] = 0.2,
	["Ferrari 250 GTO"] = 0.2,
	["Mercedes ML63 AMG"] = 0.2,
	["Maserati Quattroporte Sport GT S"] = 0.2,
	["Ford Shelby GT500"] = 0.2,
	["Ford GT 05"] = 0.2,
	["Audi RS4 Avant"] = 0.2,
	["Subaru Impreza WRX STI"] = 0.2,
	["Mini Cooper S 2011"] = 0.2,
	["Ferrari 512 TR"] = 0.15,
	["Aston Martin Rapide"] = 0.15,
	["Mercedes SL65 AMG"] = 0.15,
	["BMW M6 2013"] = 0.15,
	["BMW 1M"] = 0.15,
	["Lexus IS F"] = 0.15,
	["Nissan GT-R SpecV"] = 0.15,
	["Nissan Skyline R34"] = 0.15,
	["Mazda RX-8"] = 0.15,
	["Mitsubishi Lancer Evo VIII"] = 0.15,
	["Mitsubishi Lancer Evo X"] = 0.15,
	["Mini Coupe"] = 0.15,
	["Ford Mustang GT"] = 0.15,
	["Dodge Challenger 2015"] = 0.15,
	["Ferrari 250GT"] = 0.1,
	["Mercedes C32 AMG"] = 0.1,
	["BMW M3 E92"] = 0.1,
	["BMW M5 E60"] = 0.1,
	["BMW 340i"] = 0.1,
	["Audi S5"] = 0.1,
	["Nissan 370Z"] = 0.1,
	["Toyota Supra"] = 0.1,
	["Volvo 850R"] = 0.1,
	["Volkswagen Golf GTI 2014"] = 0.1,
	["Alfa Romeo Giulietta"] = 0.1,
	["Honda Civic Type R"] = 0.1,
	["Dodge Charger SRT-8"] = 0.1,
	["Land Rover Range Rover 2012"] = 0.1,
	["Chevrolet Camaro SS 69"] = 0.1,
	["Chevrolet Chevelle SS"] = 0.1,
	["Dodge Challenger 1970"] = 0.1,
	["Pontiac Firebird Trans Am"] = 0.1,
}

--[[
	Stock blow-off valve: the "pssh" when the throttle shuts on boost. Most factory turbo cars
	recirculate that air back into the intake, which you barely hear, so only cars with an
	audible stock blow-off or wastegate sound get it. Every other turbo car keeps the turbo
	whistle without it. Runtime only: no re-bake.
]]
E.STOCK_BOV_VOLUME = 0.6   -- stock blow-off volume (the menu's 100% is 1)
E.CAR_BOV = {
	["Bugatti Veyron 16.4"] = true,
	["Bugatti Veyron SS"] = true,
	["Bugatti EB110"] = true,
	["McLaren P1"] = true,
	["Noble M600"] = true,
	["Nissan GT-R SpecV"] = true,
	["Subaru Impreza WRX STI"] = true,
	["Mitsubishi Lancer Evo VIII"] = true,
	["Mitsubishi Lancer Evo X"] = true,
}

--[[
	Stock supercharger: the belt-driven blower's whine, locked to the revs (cl_synth
	RenderSuperchargerLoop, env bank). sport / regular / heavy (heavy: trucks, no stock car has
	one). The 1970 Challenger and the Trans Am get it as a hot-rod blower. A supercharged car's
	preset turbo is switched off (Range Rover 2012: on the twin-turbo V8 preset). Runtime only:
	no re-bake.
]]
E.CAR_SUPERCHARGER = {
	["Ford GT 05"] = "sport",              -- 5.4 V8, Lysholm twin-screw
	["Mercedes McLaren SLR"] = "sport",    -- 5.4 V8, twin-screw
	["Mercedes C32 AMG"] = "sport",        -- 3.2 V6, twin-screw
	["Shelby 1000"] = "sport",
	["Ford Shelby GT500"] = "sport",       -- 2007-14 5.4 / 5.8 V8
	["Chevrolet Camaro ZL1"] = "sport",    -- 6.2 LSA
	["Dodge Challenger 2015"] = "sport",   -- SRT Hellcat 6.2
	["Holden HSV GTS"] = "sport",          -- Gen-F 6.2 LSA
	["Jaguar F-Type"] = "sport",
	["Bowler EXR-S"] = "sport",            -- Jaguar 5.0 V8
	["Dodge Challenger 1970"] = "sport",   -- hot-rod blower
	["Pontiac Firebird Trans Am"] = "sport",   -- hot-rod blower
	["Land Rover Range Rover 2012"] = "regular",   -- 5.0 V8 supercharged
}

--[[
	Whine pitch against the others (cfg.scPitch, cl_engine), for a blower geared unlike the
	~20 lobe passes per crank turn the whine is tuned to. SLR: its twin-screw tops out at 23,000
	rpm at the 6,500 redline, 4 male lobes = ~14 per turn (1.5 kHz, not 2.2). Runtime only.
]]
E.SC_PITCH = {
	["Mercedes McLaren SLR"] = 0.7,
}

-- gear count with fitted gearing (sh_presets.lua E.FitGearCount), where one per 40 km/h of
-- top speed gives another count than the car's PERP script. Runtime only: no re-bake
E.CAR_GEARS = {
	["Bugatti Veyron 16.4"] = 5,
	["Bugatti Veyron SS"] = 5,
	["Mazda Furai"] = 5,
}

--[[
	Rev flare on start-up (the "emotion start", audio_engine_emotionstart): only high-powered cars
	blip their engine on start-up (sports cars, supercars, muscle cars, AMG/M/RS saloons, rally
	homologation specials). Every other car starts with a short, gentle rise to just above idle.
	Runtime only: the server picks the start, both start-ups are in every bank, so no re-bake.
]]
E.CAR_EMOTION = {}
for _, name in ipairs({
	-- supercars and exotics
	"Alfa Romeo 33 Stradale (1967)", "Aston Martin DBS", "Aston Martin Rapide", "Aston Martin V12 Vantage",
	"Audi R8 Plus", "Audi R8 Spyder", "Audi R8 V10", "Bowler EXR-S", "Bugatti EB110",
	"Bugatti Veyron 16.4", "Bugatti Veyron SS", "Dodge Viper GTS", "Ferrari 250 GTO", "Ferrari 250GT",
	"Ferrari 458 Spider", "Ferrari 512 TR", "Ferrari Enzo", "Ferrari F12 Berlinetta", "Ferrari F430",
	"Ferrari F50", "Ferrari LaFerrari", "Ford GT 05", "Lamborghini Diablo", "Lamborghini Gallardo",
	"Lamborghini Gallardo LP570-4 Spyder Performante", "Lamborghini Miura", "Lamborghini Murcielago",
	"Lamborghini Murcielago LP670-4 SV", "Lamborghini Reventon Roadster", "Mazda Furai", "McLaren F1",
	"McLaren P1", "Mercedes McLaren SLR", "Mercedes SLS AMG", "Noble M600", "Pagani Zonda C12",
	"Porsche 911 GT3", "Porsche 918 Spyder", "Porsche 997 GT3", "Porsche Carrera GT",
	-- sports and GT cars
	"Aston Martin DB5", "BMW 1M", "BMW M1", "Chevrolet Corvette GSC", "Chevrolet Corvette Stingray 427",
	"Honda S2000", "Jaguar E-Type", "Jaguar F-Type", "Mazda RX7", "Mercedes 300SL Gullwing Coupe",
	"Mercedes SL65 AMG", "Morgan Aero SS", "Nissan 350z", "Nissan 370Z", "Nissan GT-R SpecV",
	"Nissan Skyline R34", "Toyota Supra",
	-- muscle cars
	"Chevrolet Camaro SS 69", "Chevrolet Camaro ZL1", "Chevrolet Chevelle SS", "Dodge Challenger 1970",
	"Dodge Challenger 2015", "Dodge Charger SRT-8", "Dodge RAM SRT10", "Ford Mustang GT",
	"Ford Shelby GT500", "Holden HSV GTS", "Holden HSV W427", "Pontiac Firebird Trans Am", "Shelby 1000",
	-- performance saloons and SUVs
	"Audi RS4 Avant", "Audi S5", "BMW 340i", "BMW M3 E92", "BMW M5 E34", "BMW M5 E60", "BMW M6 2013",
	"Lexus IS F", "Maserati Ghibli S", "Maserati Quattroporte Sport GT S", "Mercedes C32 AMG",
	"Mercedes E63 AMG", "Mercedes ML63 AMG", "Porsche Cayenne Turbo 2012", "Porsche Cayenne Turbo S",
	"GMC Syclone",
	-- hot hatches and rally specials
	"Ford Focus RS", "Honda Civic Type R", "Honda Civic Type R 1997", "Mitsubishi Lancer Evo VIII",
	"Mitsubishi Lancer Evo X", "Subaru Impreza WRX STI",
}) do E.CAR_EMOTION[name] = true end
-- and they carry further (Source sound level in dB; other cars 85, economy cars 80)
E.EMOTION_SOUNDLEVEL = 92

--[[
	Economy cars: stock silencers and small engines sound duller and quieter than the presets,
	which are tuned for character. On top of its preset, an economy car gets:
	  tone x ECONOMY.toneScale   (darker exhaust; part of the sound, so re-bake after changing)
	  muffle                     (a stock silencer: lower cutoffs, more treble cut; also re-bake)
	  gurgle = 0                 (no off-throttle burble; also part of the sound)
	  (a preset with economyTuned was tuned as an economy car: its tone and gurgle are kept)
	  volume, soundLevel         (quieter, and carries less far; runtime)
]]
E.ECONOMY_SOUND = { toneScale = 0.5, muffle = 0.7, gurgle = 0, volume = 0.8, soundLevel = 80 }
E.ECONOMY = {
	["Chevrolet Spark"] = true,
	["Chrysler PT Cruiser"] = true,
	["Citroen C1"] = true,
	["Citroen C4"] = true,
	["Kia Ceed"] = true,
	["Kia Forte Koup"] = true,
	["Mini Clubman"] = true,
	["Scion tC"] = true,
	["Scion xD"] = true,
	["Toyota Prius"] = true,
	["Vauxhall Agila"] = true,
	["Vauxhall Astra"] = true,
	["Vauxhall Corsa"] = true,
	["Vauxhall Insignia"] = true,
	["Volkswagen Golf MKII"] = true,
	["Volkswagen Golf MKIII"] = true,
	["Volkswagen New Beetle"] = true,
}

--[[
	Cars whose model also moves body parts on the "vehicle_guage" pose parameter (wings rising,
	vents opening), not just the dash needles. cl_engine points that pose at the revs for the tach,
	which made these parts flap with every shift, and Source's own speed value folds some of them
	back down at high speed (the R8 Plus and LaFerrari animations retract again near the top of
	the range). On these cars the server drives the pose from speed instead (sv_engine.lua): the parts rise once the
	car reaches E.WING_UP of its top speed and lower only under E.WING_DOWN_MPH (the gap stops them
	flapping), the needles still sweep with speed inside each range.
	{ rest from, rest to, up from, up to, pose = name if not vehicle_guage }: pose ranges where every part is fully down / fully up,
	read from the blend animations of each model's vehicle_guage sequence (the TDM .mdl files).
]]
E.WING_UP = 0.7
E.WING_DOWN_MPH = 30
E.WING_RATE = 0.25 -- pose range per second the parts travel
E.GAUGE_PARTS = {
	["Audi R8 Plus"] = { 0, 0.30, 0.45, 0.70 },                      -- Spoiler (down again past 0.8)
	["Audi R8 V10"] = { 0, 0.40, 0.75, 1 },                          -- Spoiler1, Spoiler2
	["Bugatti Veyron 16.4"] = { 0, 0.35, 0.65, 1 },                  -- Spoiler01-03
	["Bugatti Veyron SS"] = { 0, 0.30, 0.55, 1 },                    -- Spoiler1, Spoiler2
	["Ferrari Enzo"] = { 0, 0.40, 0.50, 1 },                         -- spoiler
	["Ferrari F12 Berlinetta"] = { 0.30, 0.30, 0.20, 0 },            -- spoiler1, spoiler2 (flaps open at the bottom of the range)
	["Ferrari LaFerrari"] = { 0, 0.35, 0.45, 0.70 },                 -- spoiler, lower_spoiler (down again past 0.75)
	["Jaguar F-Type"] = { 0, 0.35, 0.45, 1 },                        -- spoiler
	["Lamborghini Murcielago LP670-4 SV"] = { 0, 0.45, 0.55, 1 },    -- ventl, ventr
	["McLaren F1"] = { 0, 0.30, 0.35, 1 },                           -- spoiler
	["Mercedes SLS AMG"] = { 0, 0.30, 0.60, 1 },                     -- spoiler1, spoiler2
	["Mini Coupe"] = { 0, 0.35, 0.55, 1 },                           -- spoiler1, spoiler2
	["Porsche 918 Spyder"] = { 0, 0.30, 0.50, 1 },                   -- spoiler
	["Porsche Carrera GT"] = { 0, 0.30, 0.55, 1 },                   -- spoiler
}

--[[
	Brake wings, moved by the server through bone manipulation (networked): their models have
	no working animation for it. A brake flap tilts up once the driver has held S (no W) above
	WING_BRAKE_MPH for WING_BRAKE_HOLD s, and folds when the braking ends.
	  tuck: { bone, pos, ang } list: where the wing's bones sit tucked into the body (bone manipulation,
	        taken from the sandbox bone editor with audio_engine_bonedump); they go to 0 as it rises by
	        the same speed rules as the spoilers above (and while the brake flap is up)
	  flapPose/flapBone+flapAng: the brake flap, as a pose (0..1) or a bone rotation (pitch yaw roll)
	P1: the model stores its wing raised. Its flap is
	the spoilerbrake pose (named twice in the model, the wing uses the first). SLR: its airbrake pose
	compiled empty; the source data has the flap at 22.5 deg about its own z.
]]
E.WING_BRAKE_HOLD = 0.5
E.WING_BRAKE_MPH = 15
E.WING_MAIN_RATE = 0.8 -- share of the travel per second (~1.3 s)
E.WING_FLAP_RATE = 2   -- brake flap up per second (~0.5 s); folds at half this
E.BRAKE_WINGS = {
	["McLaren P1"] = { flapPose = "spoilerbrake", tuck = {   -- placed with the bone editor (audio_engine_bonedump)
		{ bone = "spoiler_main", pos = { 0, 9, -13 } },
		{ bone = "spoiler", pos = { -0.34, 1.88, 0.04 }, ang = { -0.16, -24.58, 0 } },
	} },
	["Mercedes McLaren SLR"] = { flapBone = "spoiler", flapAng = { 0, 22.5, 0 } },
}

-- speed rule shared by all wings: up from WING_UP of the top speed, down under WING_DOWN_MPH
function E.WingSpeedUp(veh, kmh, top)
	local f = kmh / math.max(top or 250, 40)
	if f >= E.WING_UP then veh.audioWingUp = true elseif kmh < E.WING_DOWN_MPH * 1.609344 then veh.audioWingUp = false end
	return veh.audioWingUp or false, f
end

-- the vehicle_guage pose for a car with parts on it (run by the server, sv_engine.lua): kmh and
-- top speed in km/h; cl_engine glides to it at E.WING_RATE of the pose range per second (the
-- parts take ~1-1.5 s)
function E.WingPose(veh, gp, kmh, top)
	local up, f = E.WingSpeedUp(veh, kmh, top)
	if up then
		return gp[3] + (gp[4] - gp[3]) * math.Clamp((f - E.WING_UP) / (1 - E.WING_UP), 0, 1)
	end
	return gp[1] + (gp[2] - gp[1]) * math.Clamp(f / E.WING_UP, 0, 1)
end

-- register a car's model with the engine from the list above
function E.RegisterCarNamed(model, carName, extra)
	local e = E.CAR_ENGINES[carName]
	if not e then
		ErrorNoHalt("[Audio Engine] no engine listed for '" .. tostring(carName) .. "'\n")
		return
	end
	local cfg = {
		carId = string.lower((carName:gsub("[^%w]+", "_"))),
		name = carName,
		preset = e.preset,
		stock = e.stock,
		character = e.character,
		stockPops = E.CAR_POPS[carName] or 0,
		stockPopVol = E.STOCK_POP_VOLUME,
		stockBov = E.CAR_BOV[carName] and true or false,
		stockBovVol = E.STOCK_BOV_VOLUME,
		supercharger = E.CAR_SUPERCHARGER[carName],
		scPitch = E.SC_PITCH[carName],
		emotionStart = E.CAR_EMOTION[carName] or false,
		gaugeParts = E.GAUGE_PARTS[carName],
		brakeWing = E.BRAKE_WINGS[carName],
		gearCount = E.CAR_GEARS[carName],
		topSpeed = "auto",
		wheelRadius = 0.33,
		soundLevel = E.CAR_EMOTION[carName] and E.EMOTION_SOUNDLEVEL or 85,
		volume = 1.0,
	}
	local preset = E.EnginePreset(e.preset)
	if E.ECONOMY[carName] then
		local eco = E.ECONOMY_SOUND
		local stock = {}
		for k, v in pairs(e.stock or {}) do stock[k] = v end
		if not (preset and preset.economyTuned) then
			stock.tone = (stock.tone or (preset and preset.tone) or 0.4) * eco.toneScale
			stock.gurgle = eco.gurgle
		end
		cfg.stock = stock
		cfg.volume, cfg.soundLevel, cfg.muffle, cfg.economy = eco.volume, eco.soundLevel, eco.muffle, true
	end
	-- a preset's own silencer (part of the sound: re-bake)
	if preset and preset.muffle then cfg.muffle = preset.muffle end
	for k, v in pairs(extra or {}) do cfg[k] = v end
	return E.RegisterCar(model, cfg)
end

--[[
	PERPHeads cars: the model each car uses (from the TDM / PERP content packs, referenced in place)
	and its PERP base vehicle script. PERP gives most cars tier scripts with the same file name
	in used/, upgrade_1/, upgrade_2/ and spiked/ next to the base script (worn, tuned, tyres shot),
	and some extra variants (_cop, _taxi, _unmarked, _medic). They all keep the model, so the
	engine follows the car whatever script PERP spawned it with; "auto" top speed and fitted
	gearing follow the tier's MaxSpeed. Work and emergency vehicles on models of their own (the
	BearCat, ambulances, fire trucks, the stockade...) are listed here too, by their base script.
	{ model, base vehicle script, wheel radius (m, from the script) }. Built by dev/perp_carmodels.py.
]]
E.CAR_MODELS = {
	["Alfa Romeo 33 Stradale (1967)"] = { "models/tdmcars/alfa_stradale.mdl", "scripts/vehicles/tdmcars/alfa_stradale.txt", 0.368 },
	["Alfa Romeo Giulietta"] = { "models/tdmcars/alfa_giulietta.mdl", "scripts/vehicles/tdmcars/alfa_giulietta.txt", 0.376 },
	["Ambulance"] = { "models/sickness/meatwagon.mdl", "scripts/vehicles/perp2/ambulance.txt", 0.368 },
	["Aston Martin DB5"] = { "models/tdmcars/ast_db5.mdl", "scripts/vehicles/tdmcars/ast_db5.txt", 0.427 },
	["Aston Martin DBS"] = { "models/tdmcars/dbs.mdl", "scripts/vehicles/tdmcars/dbs.txt", 0.406 },
	["Aston Martin Rapide"] = { "models/tdmcars/ast_rapide.mdl", "scripts/vehicles/tdmcars/ast_rapide.txt", 0.411 },
	["Aston Martin V12 Vantage"] = { "models/tdmcars/aston_v12vantage.mdl", "scripts/vehicles/tdmcars/v12vantage.txt", 0.401 },
	["Audi R8 Plus"] = { "models/tdmcars/audi_r8_plus.mdl", "scripts/vehicles/tdmcars/audir8plus.txt", 0.386 },
	["Audi R8 Spyder"] = { "models/tdmcars/audi_r8_spyder.mdl", "scripts/vehicles/tdmcars/audir8spyd.txt", 0.386 },
	["Audi R8 V10"] = { "models/tdmcars/audir8.mdl", "scripts/vehicles/tdmcars/audir8.txt", 0.368 },
	["Audi RS4 Avant"] = { "models/tdmcars/aud_rs4avant.mdl", "scripts/vehicles/tdmcars/rs4avant.txt", 0.401 },
	["Audi S5"] = { "models/tdmcars/s5.mdl", "scripts/vehicles/tdmcars/s5.txt", 0.381 },
	["Audi TT 2007"] = { "models/tdmcars/auditt.mdl", "scripts/vehicles/tdmcars/auditt.txt", 0.381 },
	["BMW 1M"] = { "models/tdmcars/bmw_1m.mdl", "scripts/vehicles/tdmcars/bmw_1m.txt", 0.394 },
	["BMW 340i"] = { "models/tdmcars/bmw_340i.mdl", "scripts/vehicles/tdmcars/bmw_340i.txt", 0.396 },
	["BMW 507"] = { "models/tdmcars/bmw507.mdl", "scripts/vehicles/tdmcars/507.txt", 0.432 },
	["BMW M1"] = { "models/tdmcars/bmwm1.mdl", "scripts/vehicles/tdmcars/m1.txt", 0.381 },
	["BMW M3 E92"] = { "models/tdmcars/bmwm3e92.mdl", "scripts/vehicles/tdmcars/bmwm3e92.txt", 0.381 },
	["BMW M5 E34"] = { "models/tdmcars/bmwm5e34.mdl", "scripts/vehicles/tdmcars/bmwm5e34.txt", 0.394 },
	["BMW M5 E60"] = { "models/tdmcars/bmwm5e60.mdl", "scripts/vehicles/tdmcars/bmwm5e60.txt", 0.406 },
	["BMW M6 2013"] = { "models/tdmcars/bmw_m6_13.mdl", "scripts/vehicles/tdmcars/bmwm613.txt", 0.406 },
	["Bowler EXR-S"] = { "models/tdmcars/bowler_exrs.mdl", "scripts/vehicles/tdmcars/bowlerexrs.txt", 0.452 },
	["Bugatti EB110"] = { "models/tdmcars/bug_eb110.mdl", "scripts/vehicles/tdmcars/eb110.txt", 0.406 },
	["Bugatti Veyron 16.4"] = { "models/tdmcars/bug_veyron.mdl", "scripts/vehicles/tdmcars/veyron.txt", 0.432 },
	["Bugatti Veyron SS"] = { "models/tdmcars/bug_veyronss.mdl", "scripts/vehicles/tdmcars/veyronss.txt", 0.419 },
	["Cadillac Escalade 2012"] = { "models/tdmcars/cad_escalade.mdl", "scripts/vehicles/tdmcars/escalade.txt", 0.457 },
	["Chevrolet Blazer"] = { "models/tdmcars/chev_blazer.mdl", "scripts/vehicles/tdmcars/blazer.txt", 0.419 },
	["Chevrolet C10"] = { "models/tdmcars/chev_c10.mdl", "scripts/vehicles/tdmcars/che_c10.txt", 0.386 },
	["Chevrolet Camaro SS 69"] = { "models/tdmcars/69camaro.mdl", "scripts/vehicles/tdmcars/69camaro.txt", 0.404 },
	["Chevrolet Camaro ZL1"] = { "models/tdmcars/chev_camzl1.mdl", "scripts/vehicles/tdmcars/camarozl1.txt", 0.432 },
	["Chevrolet Chevelle SS"] = { "models/tdmcars/chevelless.mdl", "scripts/vehicles/tdmcars/chevelless.txt", 0.406 },
	["Chevrolet Corvette GSC"] = { "models/tdmcars/chev_corv_gsc.mdl", "scripts/vehicles/tdmcars/chev_corv_gsc.txt", 0.406 },
	["Chevrolet Corvette Stingray 427"] = { "models/tdmcars/chev_stingray427.mdl", "scripts/vehicles/tdmcars/chevstingray427.txt", 0.438 },
	["Chevrolet Impala SS 96"] = { "models/tdmcars/chev_impala96.mdl", "scripts/vehicles/tdmcars/impala96.txt", 0.368 },
	["Chevrolet Spark"] = { "models/tdmcars/spark.mdl", "scripts/vehicles/tdmcars/spark.txt", 0.356 },
	["Chrysler 300C"] = { "models/tdmcars/chr_300c.mdl", "scripts/vehicles/tdmcars/300c.txt", 0.432 },
	["Chrysler PT Cruiser"] = { "models/tdmcars/chr_ptcruiser.mdl", "scripts/vehicles/tdmcars/ptcruiser.txt", 0.381 },
	["Citroen C1"] = { "models/tdmcars/citroen_c1.mdl", "scripts/vehicles/tdmcars/citroenc1.txt", 0.343 },
	["Citroen C4"] = { "models/tdmcars/cit_c4.mdl", "scripts/vehicles/tdmcars/c4.txt", 0.356 },
	["Courier Truck"] = { "models/tdmcars/courier_truck.mdl", "scripts/vehicles/tdmcars/courier_truck.txt", 0.495 },
	["DeLorean DMC-12"] = { "models/tdmcars/del_dmc.mdl", "scripts/vehicles/tdmcars/delorean.txt", 0.356 },
	["Dodge Challenger 1970"] = { "models/tdmcars/dod_challenger70.mdl", "scripts/vehicles/tdmcars/challenger70.txt", 0.399 },
	["Dodge Challenger 2015"] = { "models/tdmcars/dod_challenger15.mdl", "scripts/vehicles/tdmcars/dod_challenger15.txt", 0.457 },
	["Dodge Charger 2012"] = { "models/tdmcars/dod_charger12.mdl", "scripts/vehicles/tdmcars/charger2012.txt", 0.432 },
	["Dodge Charger SRT-8"] = { "models/tdmcars/chargersrt8.mdl", "scripts/vehicles/tdmcars/chargersrt8.txt", 0.406 },
	["Dodge RAM SRT10"] = { "models/tdmcars/dodgeram.mdl", "scripts/vehicles/tdmcars/dodgeram.txt", 0.432 },
	["Dodge Viper GTS"] = { "models/tdmcars/vip_viper.mdl", "scripts/vehicles/tdmcars/vipviper.txt", 0.406 },
	["Dundreary Limousine"] = { "models/sickness/stretchdr_tdmcars.mdl", "scripts/vehicles/perp2/stretch.txt", 0.419 },
	["Ferrari 250 GTO"] = { "models/tdmcars/fer_250gto.mdl", "scripts/vehicles/tdmcars/fer_250gto.txt", 0.381 },
	["Ferrari 250GT"] = { "models/tdmcars/ferrari250gt.mdl", "scripts/vehicles/tdmcars/ferrari250gt.txt", 0.406 },
	["Ferrari 458 Spider"] = { "models/tdmcars/fer_458spid.mdl", "scripts/vehicles/tdmcars/fer458spid.txt", 0.432 },
	["Ferrari 512 TR"] = { "models/tdmcars/ferrari512tr.mdl", "scripts/vehicles/tdmcars/ferrari512tr.txt", 0.387 },
	["Ferrari Enzo"] = { "models/tdmcars/fer_enzo.mdl", "scripts/vehicles/tdmcars/enzo.txt", 0.406 },
	["Ferrari F12 Berlinetta"] = { "models/tdmcars/fer_f12.mdl", "scripts/vehicles/tdmcars/fer_f12.txt", 0.424 },
	["Ferrari F430"] = { "models/tdmcars/fer_f430.mdl", "scripts/vehicles/tdmcars/fer_f430.txt", 0.401 },
	["Ferrari F50"] = { "models/tdmcars/fer_f50.mdl", "scripts/vehicles/tdmcars/f50.txt", 0.406 },
	["Ferrari LaFerrari"] = { "models/tdmcars/fer_lafer.mdl", "scripts/vehicles/tdmcars/laferrari.txt", 0.406 },
	["Fire Truck"] = { "models/sickness/truckfire.mdl", "scripts/vehicles/perp2/truckfire.txt", 0.686 },
	["Ford Crown Victoria"] = { "models/tdmcars/crownvic_taxi.mdl", "scripts/vehicles/tdmcars/crownvic.txt", 0.381 },
	["Ford Deluxe Coupe 1940"] = { "models/tdmcars/ford_coupe_40.mdl", "scripts/vehicles/tdmcars/coupe40.txt", 0.406 },
	["Ford F100"] = { "models/tdmcars/for_f100.mdl", "scripts/vehicles/tdmcars/f100.txt", 0.363 },
	["Ford F350"] = { "models/tdmcars/for_f350.mdl", "scripts/vehicles/tdmcars/f350.txt", 0.526 },
	["Ford F350 Fire Rescue"] = { "models/tdmcars/for_f350_fru.mdl", "scripts/vehicles/perp2/f350_firetruck.txt", 0.526 },
	["Ford F350 Tow Truck"] = { "models/tdmcars/for_f350_tow.mdl", "scripts/vehicles/perp2/f350_towtruck.txt", 0.485 },
	["Ford F450 Ambulance"] = { "models/forest/f450_ambo.mdl", "scripts/vehicles/perp2/f450_ambulance.txt", 0.480 },
	["Ford Focus RS"] = { "models/tdmcars/focusrs.mdl", "scripts/vehicles/tdmcars/focusrs.txt", 0.381 },
	["Ford Focus SVT"] = { "models/tdmcars/for_focussvt.mdl", "scripts/vehicles/tdmcars/focussvt.txt", 0.381 },
	["Ford GT 05"] = { "models/tdmcars/gt05.mdl", "scripts/vehicles/tdmcars/gt05.txt", 0.406 },
	["Ford Mustang GT"] = { "models/tdmcars/for_mustanggt.mdl", "scripts/vehicles/tdmcars/mustanggt.txt", 0.406 },
	["Ford Raptor SVT"] = { "models/tdmcars/for_raptor.mdl", "scripts/vehicles/tdmcars/raptorsvt.txt", 0.526 },
	["Ford Shelby GT500"] = { "models/tdmcars/gt500.mdl", "scripts/vehicles/tdmcars/gt500.txt", 0.439 },
	["Ford Transit"] = { "models/tdmcars/ford_transit.mdl", "scripts/vehicles/tdmcars/transit.txt", 0.432 },
	["Ford Transit 2016 (Police)"] = { "models/ezza/plpd_2016transit.mdl", "scripts/vehicles/jarheads/transit2016.txt", 0.483 },
	["Ford Transit 2016 (Prisoner Transport)"] = { "models/tdmcars/2016transit.mdl", "scripts/vehicles/tdmcars/2016transit.txt", 0.406 },
	["GMC Sierra"] = { "models/tdmcars/gmc_sierralow.mdl", "scripts/vehicles/tdmcars/sierralow.txt", 0.406 },
	["GMC Syclone"] = { "models/tdmcars/gmc_syclone.mdl", "scripts/vehicles/tdmcars/syclone.txt", 0.381 },
	["GMC Vandura"] = { "models/tdmcars/gmcvan.mdl", "scripts/vehicles/tdmcars/gmcvan.txt", 0.381 },
	["Holden HSV GTS"] = { "models/tdmcars/hsvgts.mdl", "scripts/vehicles/tdmcars/hsvgts.txt", 0.406 },
	["Holden HSV W427"] = { "models/tdmcars/hsvw427.mdl", "scripts/vehicles/tdmcars/hsvw427.txt", 0.406 },
	["Honda Civic Type R"] = { "models/tdmcars/civic_typer.mdl", "scripts/vehicles/tdmcars/civictyper.txt", 0.356 },
	["Honda Civic Type R 1997"] = { "models/tdmcars/hon_civic97.mdl", "scripts/vehicles/tdmcars/civic97.txt", 0.356 },
	["Honda CR-X SiR"] = { "models/tdmcars/hon_crxsir.mdl", "scripts/vehicles/tdmcars/hon_crxsir.txt", 0.335 },
	["Honda S2000"] = { "models/tdmcars/hon_s2000.mdl", "scripts/vehicles/tdmcars/s2000.txt", 0.373 },
	["Hudson Hornet"] = { "models/tdmcars/hud_hornet.mdl", "scripts/vehicles/tdmcars/hudhornet.txt", 0.432 },
	["Hummer H1"] = { "models/tdmcars/hummerh1.mdl", "scripts/vehicles/tdmcars/h1.txt", 0.533 },
	["Jaguar E-Type"] = { "models/tdmcars/jag_etype.mdl", "scripts/vehicles/tdmcars/jag_etype.txt", 0.343 },
	["Jaguar F-Type"] = { "models/tdmcars/jag_ftype.mdl", "scripts/vehicles/tdmcars/jag_ftype.txt", 0.411 },
	["Jeep Grand Cherokee"] = { "models/tdmcars/jeep_grandche.mdl", "scripts/vehicles/tdmcars/grandche.txt", 0.462 },
	["Jeep Wrangler"] = { "models/tdmcars/wrangler.mdl", "scripts/vehicles/tdmcars/wrangler.txt", 0.457 },
	["Kia Ceed"] = { "models/tdmcars/kia_ceed.mdl", "scripts/vehicles/tdmcars/ceed.txt", 0.381 },
	["Kia Forte Koup"] = { "models/tdmcars/kia_fortekoup.mdl", "scripts/vehicles/tdmcars/kiafortekoup.txt", 0.368 },
	["Lamborghini Diablo"] = { "models/tdmcars/lambo_diablo.mdl", "scripts/vehicles/tdmcars/diablo.txt", 0.406 },
	["Lamborghini Gallardo"] = { "models/tdmcars/gallardo.mdl", "scripts/vehicles/tdmcars/gallardo.txt", 0.381 },
	["Lamborghini Gallardo LP570-4 Spyder Performante"] = { "models/tdmcars/lam_gallardospyd.mdl", "scripts/vehicles/tdmcars/gallardospyd.txt", 0.406 },
	["Lamborghini Miura"] = { "models/tdmcars/lambo_miuracon.mdl", "scripts/vehicles/tdmcars/miuracon.txt", 0.406 },
	["Lamborghini Murcielago"] = { "models/tdmcars/murcielago.mdl", "scripts/vehicles/tdmcars/murcielago.txt", 0.368 },
	["Lamborghini Murcielago LP670-4 SV"] = { "models/tdmcars/lambo_murcielagosv.mdl", "scripts/vehicles/tdmcars/murcielagosv.txt", 0.394 },
	["Lamborghini Reventon Roadster"] = { "models/tdmcars/reventon_roadster.mdl", "scripts/vehicles/tdmcars/reventonr.txt", 0.394 },
	["Land Rover Defender"] = { "models/tdmcars/landrover_defender.mdl", "scripts/vehicles/tdmcars/lrdefender.txt", 0.711 },
	["Land Rover Range Rover 08"] = { "models/tdmcars/landrover.mdl", "scripts/vehicles/tdmcars/landrover.txt", 0.432 },
	["Land Rover Range Rover 2012"] = { "models/tdmcars/landrover12.mdl", "scripts/vehicles/tdmcars/landrover12.txt", 0.452 },
	["Lenco BearCat"] = { "models/tdmcars/plpd_bearcat.mdl", "scripts/vehicles/jarheads/bearcat.txt", 0.622 },
	["Lexus IS 300"] = { "models/tdmcars/lex_is300.mdl", "scripts/vehicles/tdmcars/lex_is300.txt", 0.389 },
	["Lexus IS F"] = { "models/tdmcars/lex_isf.mdl", "scripts/vehicles/tdmcars/lex_isf.txt", 0.381 },
	["Maserati Ghibli S"] = { "models/tdmcars/mas_ghibli.mdl", "scripts/vehicles/tdmcars/mas_ghibli.txt", 0.445 },
	["Maserati Quattroporte Sport GT S"] = { "models/tdmcars/mas_quattroporte.mdl", "scripts/vehicles/tdmcars/mas_quattroporte.txt", 0.445 },
	["Mazda Furai"] = { "models/tdmcars/maz_furai.mdl", "scripts/vehicles/tdmcars/furai.txt", 0.394 },
	["Mazda MX-5 2007"] = { "models/tdmcars/mx5.mdl", "scripts/vehicles/tdmcars/mx5.txt", 0.356 },
	["Mazda RX-8"] = { "models/tdmcars/rx8.mdl", "scripts/vehicles/tdmcars/rx8.txt", 0.394 },
	["Mazda RX7"] = { "models/tdmcars/maz_rx7.mdl", "scripts/vehicles/tdmcars/rx7.txt", 0.373 },
	["Mazda Speed 3 2009"] = { "models/tdmcars/maz_speed3.mdl", "scripts/vehicles/tdmcars/speed3.txt", 0.376 },
	["McLaren F1"] = { "models/tdmcars/mclaren_f1.mdl", "scripts/vehicles/tdmcars/mclarenf1.txt", 0.389 },
	["McLaren P1"] = { "models/tdmcars/mclaren_p1.mdl", "scripts/vehicles/tdmcars/mclarenp1.txt", 0.394 },
	["Mercedes 300 SEL"] = { "models/tdmcars/mer_300sel.mdl", "scripts/vehicles/tdmcars/mer300sel.txt", 0.394 },
	["Mercedes 300SL Gullwing Coupe"] = { "models/tdmcars/mer_300slgull.mdl", "scripts/vehicles/tdmcars/mer300slgull.txt", 0.394 },
	["Mercedes C32 AMG"] = { "models/tdmcars/mercedes_c32.mdl", "scripts/vehicles/tdmcars/c32.txt", 0.381 },
	["Mercedes E63 AMG"] = { "models/tdmcars/mer_e63.mdl", "scripts/vehicles/tdmcars/mere63.txt", 0.394 },
	["Mercedes G-Class"] = { "models/tdmcars/gwagon.mdl", "scripts/vehicles/jarheads/gwagon.txt", 0.483 },
	["Mercedes McLaren SLR"] = { "models/tdmcars/mer_slr.mdl", "scripts/vehicles/tdmcars/mer_slr.txt", 0.394 },
	["Mercedes ML63 AMG"] = { "models/tdmcars/mer_ml63.mdl", "scripts/vehicles/tdmcars/ml63.txt", 0.437 },
	["Mercedes SL65 AMG"] = { "models/tdmcars/sl65amg.mdl", "scripts/vehicles/tdmcars/sl65amg.txt", 0.381 },
	["Mercedes SLS AMG"] = { "models/tdmcars/mer_slsamg.mdl", "scripts/vehicles/tdmcars/slsamg.txt", 0.432 },
	["Mini Clubman"] = { "models/tdmcars/mini_clubman.mdl", "scripts/vehicles/tdmcars/miniclubman.txt", 0.348 },
	["Mini Cooper 1965"] = { "models/tdmcars/cooper65.mdl", "scripts/vehicles/tdmcars/cooper65.txt", 0.330 },
	["Mini Cooper S 2011"] = { "models/tdmcars/mini_coopers11.mdl", "scripts/vehicles/tdmcars/minicoopers11.txt", 0.356 },
	["Mini Coupe"] = { "models/tdmcars/mini_coupe.mdl", "scripts/vehicles/tdmcars/minicoupe.txt", 0.356 },
	["Mitsubishi Colt Ralliart"] = { "models/tdmcars/coltralliart.mdl", "scripts/vehicles/tdmcars/colt.txt", 0.381 },
	["Mitsubishi Eclipse GSX"] = { "models/tdmcars/mit_eclipsegsx.mdl", "scripts/vehicles/tdmcars/mit_eclipsegsx.txt", 0.406 },
	["Mitsubishi Eclipse GT"] = { "models/tdmcars/mitsu_eclipgt.mdl", "scripts/vehicles/tdmcars/mitsu_eclipgt.txt", 0.381 },
	["Mitsubishi Lancer Evo VIII"] = { "models/tdmcars/mitsu_evo8.mdl", "scripts/vehicles/tdmcars/mitsu_evo8.txt", 0.368 },
	["Mitsubishi Lancer Evo X"] = { "models/tdmcars/mitsu_evox.mdl", "scripts/vehicles/tdmcars/mitsu_evox.txt", 0.394 },
	["Morgan Aero SS"] = { "models/tdmcars/morg_aeross.mdl", "scripts/vehicles/tdmcars/morg_aeross.txt", 0.394 },
	["Nissan 350z"] = { "models/tdmcars/350z.mdl", "scripts/vehicles/tdmcars/350z.txt", 0.406 },
	["Nissan 370Z"] = { "models/tdmcars/nis_370z.mdl", "scripts/vehicles/tdmcars/370z.txt", 0.406 },
	["Nissan GT-R SpecV"] = { "models/tdmcars/nissan_gtr.mdl", "scripts/vehicles/tdmcars/gtr.txt", 0.419 },
	["Nissan Leaf"] = { "models/tdmcars/nis_leaf.mdl", "scripts/vehicles/tdmcars/nis_leaf.txt", 0.381 },
	["Nissan Silvia"] = { "models/tdmcars/nissan_silvias15.mdl", "scripts/vehicles/tdmcars/nissilvs15.txt", 0.368 },
	["Nissan Skyline R34"] = { "models/tdmcars/skyline_r34.mdl", "scripts/vehicles/tdmcars/skyline_r34.txt", 0.381 },
	["Noble M600"] = { "models/tdmcars/noblem600.mdl", "scripts/vehicles/tdmcars/noblem600.txt", 0.368 },
	["Pagani Zonda C12"] = { "models/tdmcars/zondac12.mdl", "scripts/vehicles/tdmcars/c12.txt", 0.381 },
	["Pontiac Fiero GT"] = { "models/tdmcars/pon_fierogt.mdl", "scripts/vehicles/tdmcars/pon_fierogt.txt", 0.368 },
	["Pontiac Firebird Trans Am"] = { "models/tdmcars/pon_firetransam.mdl", "scripts/vehicles/tdmcars/pon_firetransam.txt", 0.419 },
	["Porsche 911 GT3"] = { "models/tdmcars/gt3rs.mdl", "scripts/vehicles/jarheads/gt3rs.txt", 0.424 },
	["Porsche 918 Spyder"] = { "models/tdmcars/por_918.mdl", "scripts/vehicles/tdmcars/918spyd.txt", 0.437 },
	["Porsche 997 GT3"] = { "models/tdmcars/997gt3.mdl", "scripts/vehicles/tdmcars/997gt3.txt", 0.381 },
	["Porsche Carrera GT"] = { "models/tdmcars/por_carreragt.mdl", "scripts/vehicles/tdmcars/carreragt.txt", 0.386 },
	["Porsche Cayenne Turbo 2012"] = { "models/tdmcars/por_cayenne12.mdl", "scripts/vehicles/tdmcars/cayenne12.txt", 0.457 },
	["Porsche Cayenne Turbo S"] = { "models/tdmcars/cayenne.mdl", "scripts/vehicles/tdmcars/cayenne.txt", 0.457 },
	["Scion FR-S"] = { "models/tdmcars/scion_frs.mdl", "scripts/vehicles/tdmcars/scionfrs.txt", 0.381 },
	["Scion tC"] = { "models/tdmcars/scion_tc.mdl", "scripts/vehicles/tdmcars/sciontc.txt", 0.368 },
	["Scion xD"] = { "models/tdmcars/scion_xd.mdl", "scripts/vehicles/tdmcars/scionxd.txt", 0.361 },
	["Shelby 1000"] = { "models/tdmcars/she_1000.mdl", "scripts/vehicles/tdmcars/she1000.txt", 0.460 },
	["Subaru Impreza WRX STI"] = { "models/tdmcars/sub_wrxsti08.mdl", "scripts/vehicles/tdmcars/subimpreza08.txt", 0.381 },
	["Subaru Legacy GT 2010"] = { "models/tdmcars/sub_legacygt10.mdl", "scripts/vehicles/tdmcars/subleggt10.txt", 0.386 },
	["Subaru Legacy RS 1990"] = { "models/tdmcars/sub_legacyrs90.mdl", "scripts/vehicles/tdmcars/sublegrs90.txt", 0.381 },
	["SWAT Stockade"] = { "models/perp2.5/swat_van.mdl", "scripts/vehicles/perp2/swatvan.txt", 0.495 },
	["Tesla Model S"] = { "models/tdmcars/tesla_models.mdl", "scripts/vehicles/tdmcars/teslamodels.txt", 0.432 },
	["Toyota FJ Cruiser"] = { "models/tdmcars/toy_fj.mdl", "scripts/vehicles/tdmcars/toyfj.txt", 0.470 },
	["Toyota MR2 GT"] = { "models/tdmcars/toy_mr2gt.mdl", "scripts/vehicles/tdmcars/mr2gt.txt", 0.356 },
	["Toyota Prius"] = { "models/tdmcars/prius.mdl", "scripts/vehicles/tdmcars/prius.txt", 0.368 },
	["Toyota Supra"] = { "models/tdmcars/supra.mdl", "scripts/vehicles/tdmcars/supra.txt", 0.406 },
	["Vauxhall Agila"] = { "models/tdmcars/vaux_agila.mdl", "scripts/vehicles/tdmcars/vaux_agila.txt", 0.368 },
	["Vauxhall Astra"] = { "models/tdmcars/vaux_astra12.mdl", "scripts/vehicles/tdmcars/vauxastra12.txt", 0.406 },
	["Vauxhall Corsa"] = { "models/tdmcars/vaux_corsa.mdl", "scripts/vehicles/tdmcars/vaux_corsa.txt", 0.368 },
	["Vauxhall Insignia"] = { "models/tdmcars/vaux_insignia.mdl", "scripts/vehicles/tdmcars/vaux_insignia.txt", 0.399 },
	["Volkswagen Beetle 1967"] = { "models/tdmcars/beetle.mdl", "scripts/vehicles/tdmcars/beetle67.txt", 0.406 },
	["Volkswagen Camper 1965"] = { "models/tdmcars/vw_camper65.mdl", "scripts/vehicles/tdmcars/vwcamper.txt", 0.406 },
	["Volkswagen Golf GTI 2014"] = { "models/tdmcars/vw_golfgti_14.mdl", "scripts/vehicles/tdmcars/vw_golfgti_14.txt", 0.396 },
	["Volkswagen Golf MKII"] = { "models/tdmcars/golf_mk2.mdl", "scripts/vehicles/tdmcars/golfmk2.txt", 0.381 },
	["Volkswagen Golf MKIII"] = { "models/tdmcars/golf3.mdl", "scripts/vehicles/tdmcars/golf3.txt", 0.318 },
	["Volkswagen New Beetle"] = { "models/tdmcars/vw_beetleconv.mdl", "scripts/vehicles/tdmcars/vwbeetleconv.txt", 0.381 },
	["Volkswagen Scirocco GT"] = { "models/tdmcars/scirocco.mdl", "scripts/vehicles/tdmcars/scirocco.txt", 0.356 },
	["Volvo 242 Turbo"] = { "models/tdmcars/242turbo.mdl", "scripts/vehicles/tdmcars/242turbo.txt", 0.356 },
	["Volvo 850R"] = { "models/tdmcars/vol_850r.mdl", "scripts/vehicles/tdmcars/850r.txt", 0.373 },
	["Volvo S60"] = { "models/tdmcars/vol_s60.mdl", "scripts/vehicles/tdmcars/vols60.txt", 0.368 },
}

--[[
	Job vehicles (police, fire, EMS, taxi, tow, SWAT), listed in their own spawn-menu tab. Most are
	a car above on its own PERP script (_cop, _medic, _fire, _taxi...) in the job livery: skin 11
	on the TDM models (skins 0-10 are the paint colours, 12 is often a supervisor/chief livery;
	the Crown Vic has the taxi on 11 and the police on 12). The engine follows the model, so they
	sound like their car; the script only changes the handling. A car whose base script is
	listed here (the ambulances, fire trucks, BearCat...) spawns from this tab only.
	{ spawn name, car (E.CAR_MODELS), vehicle script, skin }. Built by dev/perp_carmodels.py.
]]
E.JOB_VEHICLES = {
	{ "Ambulance", "Ambulance", "scripts/vehicles/perp2/ambulance.txt", 0 },
	{ "Audi RS4 Avant First Responder", "Audi RS4 Avant", "scripts/vehicles/tdmcars/rs4avant_medic.txt", 11 },
	{ "BMW 340i Police", "BMW 340i", "scripts/vehicles/tdmcars/bmw_340i_police.txt", 11 },
	{ "BMW M5 E60 Police", "BMW M5 E60", "scripts/vehicles/tdmcars/bmwm5e60_cop.txt", 11 },
	{ "Dodge Charger 2012 Police", "Dodge Charger 2012", "scripts/vehicles/tdmcars/charger2012_cop.txt", 11 },
	{ "Dodge Charger SRT-8 Police", "Dodge Charger SRT-8", "scripts/vehicles/tdmcars/charger_cop.txt", 11 },
	{ "Dodge RAM SRT10 Fire Rescue", "Dodge RAM SRT10", "scripts/vehicles/tdmcars/dodgeramff.txt", 11 },
	{ "Fire Truck", "Fire Truck", "scripts/vehicles/perp2/truckfire.txt", 0 },
	{ "Ford Crown Victoria Police", "Ford Crown Victoria", "scripts/vehicles/tdmcars/crownvic_cop.txt", 12 },
	{ "Ford Crown Victoria Taxi", "Ford Crown Victoria", "scripts/vehicles/tdmcars/crownvic_taxi.txt", 11 },
	{ "Ford Crown Victoria Unmarked", "Ford Crown Victoria", "scripts/vehicles/tdmcars/crownvic_unmarked.txt", 0 },
	{ "Ford F350 Fire Rescue", "Ford F350 Fire Rescue", "scripts/vehicles/perp2/f350_firetruck.txt", 0 },
	{ "Ford F350 Tow Truck", "Ford F350 Tow Truck", "scripts/vehicles/perp2/f350_towtruck.txt", 0 },
	{ "Ford F450 Ambulance", "Ford F450 Ambulance", "scripts/vehicles/perp2/f450_ambulance.txt", 0 },
	{ "Ford Transit 2016 (Police)", "Ford Transit 2016 (Police)", "scripts/vehicles/jarheads/transit2016.txt", 0 },
	{ "Ford Transit 2016 (Prisoner Transport)", "Ford Transit 2016 (Prisoner Transport)", "scripts/vehicles/tdmcars/2016transit.txt", 11 },
	{ "Land Rover Defender Fire", "Land Rover Defender", "scripts/vehicles/tdmcars/lrdefender_fire.txt", 11 },
	{ "Land Rover Range Rover 2012 Police", "Land Rover Range Rover 2012", "scripts/vehicles/tdmcars/landrover12_cop.txt", 11 },
	{ "Lenco BearCat", "Lenco BearCat", "scripts/vehicles/jarheads/bearcat.txt", 0 },
	{ "Mercedes SL65 AMG Police", "Mercedes SL65 AMG", "scripts/vehicles/tdmcars/sl65amg_cop.txt", 11 },
	{ "Porsche Cayenne Turbo S Police", "Porsche Cayenne Turbo S", "scripts/vehicles/tdmcars/cayenne_cop.txt", 11 },
	{ "SWAT Stockade", "SWAT Stockade", "scripts/vehicles/perp2/swatvan.txt", 0 },
	{ "Toyota Prius Medic", "Toyota Prius", "scripts/vehicles/tdmcars/prius_medic.txt", 11 },
}

-- the stability assist on the PERP cars, with each car's own steering angles (sv_handling.lua).
-- Never on spiked tyres: a stinger is meant to make the car hard to drive. false = off for all
E.PERP_STABILITY = true

for name, m in pairs(E.CAR_MODELS) do
	local extra = { script = m[2], wheelRadius = m[3] or 0.36, perp = true }
	if not E.PERP_STABILITY then extra.stability = false end
	E.RegisterCarNamed(m[1], name, extra)
end
