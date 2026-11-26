--[[
	Audio Engine - which engine preset each car on the server uses (shared)

	From the engine list (Engine Types.xlsx): every car, its engine preset (sh_presets.lua), and where the
	real car differs a lot from the preset, a few per-car changes ("stock"). Turbo cars use a
	turbo preset; the turbo itself is a shared sound, so it never costs a new engine.

	Cars only get the procedural engine once they are registered with their model. All of them
	are, from AudioEngine.CAR_MODELS at the bottom of this file. To add another car, register it by name:

	    AUDIO_ENGINE.RegisterCarNamed("models/tdmcars/458spider.mdl", "Ferrari 458 Spider")

	and optionally pass anything sh_config.lua takes (wheelRadius, soundLevel, stability...):

	    AUDIO_ENGINE.RegisterCarNamed("models/tdmcars/c10.mdl", "Chevrolet C10", { wheelRadius = 0.37 })

	Each different preset + "stock" combination is its own set of sounds, so cars that share
	one share their sounds. Diesels (Transit, Defender, Range Rover 08, Hummer H1) use the
	closest petrol engine, slowed and softened.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local AudioEngine = AUDIO_ENGINE

-- character: the car's own exhaust voice over its engine type's (the old Lua synth's CHARACTER; still part of the baked sound key: f1, f2,
-- f3, w, o1, o05; any left out keep the type's). A new sound: re-bake. dev/tone_studio.html edits it
local function engineEntry(preset, stock, character) return { preset = preset, stock = stock, character = character } end

AudioEngine.CAR_ENGINES = {
	["Alfa Romeo 33 Stradale (1967)"] = engineEntry("v8flat", { redline = 8800 }),
	["Alfa Romeo Giulietta"] = engineEntry("i4t"),
	["Aston Martin DB5"] = engineEntry("i6", { redline = 5500 }),
	["Aston Martin DBS"] = engineEntry("v12r"),
	["Aston Martin Rapide"] = engineEntry("v12r"),
	["Aston Martin V12 Vantage"] = engineEntry("v12r"),
	["Audi R8 Plus"] = engineEntry("v10"),
	["Audi R8 Spyder"] = engineEntry("v10"),
	["Audi R8 V10"] = engineEntry("v10"),
	["Audi RS4 Avant"] = engineEntry("v8s"),
	["Audi S5"] = engineEntry("v8s", { redline = 7000 }),
	["Audi TT 2007"] = engineEntry("i4t"),
	["BMW 1M"] = engineEntry("i6t"),
	["BMW 340i"] = engineEntry("i6t"),
	["BMW 507"] = engineEntry("v8r", { redline = 5000 }),
	["BMW M1"] = engineEntry("i6"),
	["BMW M3 E92"] = engineEntry("v8s", { redline = 8400 }),
	["BMW M5 E34"] = engineEntry("i6"),
	["BMW M5 E60"] = engineEntry("v10"),
	["BMW M6 2013"] = engineEntry("v8xt"),
	["Bowler EXR-S"] = engineEntry("v8p"),
	["Bugatti EB110"] = engineEntry("v12t"),
	-- tuned in dev/tone_studio.html
	["Bugatti Veyron 16.4"] = engineEntry("w16"),
	["Bugatti Veyron SS"] = engineEntry("w16"),
	["Cadillac Escalade 2012"] = engineEntry("v8x"),
	["Chevrolet Blazer"] = engineEntry("v6", { redline = 5000 }),
	["Chevrolet C10"] = engineEntry("v8x", { redline = 5000 }),
	["Chevrolet Camaro SS 69"] = engineEntry("v8m"),
	["Chevrolet Camaro ZL1"] = engineEntry("v8p"),
	["Chevrolet Chevelle SS"] = engineEntry("v8m"),
	["Chevrolet Corvette GSC"] = engineEntry("v8p"),
	["Chevrolet Corvette Stingray 427"] = engineEntry("v8m"),
	["Chevrolet Impala SS 96"] = engineEntry("v8r", { redline = 5000 }),
	["Chevrolet Spark"] = engineEntry("i4q"),
	["Chrysler 300C"] = engineEntry("v8r"),
	["Chrysler PT Cruiser"] = engineEntry("i4w"),
	["Citroen C1"] = engineEntry("i3"),
	["Citroen C4"] = engineEntry("i4w"),
	["DeLorean DMC-12"] = engineEntry("v6odd"),
	["Dodge Challenger 1970"] = engineEntry("v8m"),
	["Dodge Challenger 2015"] = engineEntry("v8p"),
	["Dodge Charger 2012"] = engineEntry("v8p"),
	["Dodge Charger SRT-8"] = engineEntry("v8p"),
	["Dodge RAM SRT10"] = engineEntry("v10l"),
	["Dodge Viper GTS"] = engineEntry("v10l"),
	["Dundreary Limousine"] = engineEntry("v8r"),
	["Ferrari 250 GTO"] = engineEntry("v12r"),
	["Ferrari 250GT"] = engineEntry("v12r"),
	["Ferrari 458 Spider"] = engineEntry("v8flat", { redline = 9000 }),
	["Ferrari 512 TR"] = engineEntry("f12"),
	["Ferrari Enzo"] = engineEntry("v12na"),
	["Ferrari F12 Berlinetta"] = engineEntry("v12na", { redline = 8700 }),
	["Ferrari F430"] = engineEntry("v8flat"),
	["Ferrari F50"] = engineEntry("v12na", { redline = 8500 }),
	["Ferrari LaFerrari"] = engineEntry("v12na", { redline = 9200 }),
	["Ford Crown Victoria"] = engineEntry("v8r", { redline = 5000 }),
	["Ford Deluxe Coupe 1940"] = engineEntry("v8m", { redline = 4000 }),
	["Ford F100"] = engineEntry("v8x", { redline = 5000 }),
	["Ford F350"] = engineEntry("v8x", { redline = 5000 }),
	["Ford Focus RS"] = engineEntry("i5t"),
	["Ford Focus SVT"] = engineEntry("i4s", { redline = 7200 }),
	["Ford GT 05"] = engineEntry("v8p", { redline = 6500 }),
	["Ford Mustang GT"] = engineEntry("v8p", { redline = 7000 }),
	["Ford Raptor SVT"] = engineEntry("v8x"),
	["Ford Shelby GT500"] = engineEntry("v8m"),
	["Ford Transit"] = engineEntry("i4t", { redline = 4500, tone = 0.3 }),
	["GMC Sierra"] = engineEntry("v8x"),
	["GMC Syclone"] = engineEntry("v6t", { redline = 5000 }),
	["GMC Vandura"] = engineEntry("v8x", { redline = 5000 }),
	["Holden HSV GTS"] = engineEntry("v8p"),
	["Holden HSV W427"] = engineEntry("v8p", { redline = 6500 }),
	["Honda CR-X SiR"] = engineEntry("i4s", { redline = 8000 }),
	["Honda Civic Type R"] = engineEntry("i4s"),
	["Honda Civic Type R 1997"] = engineEntry("i4s"),
	["Honda S2000"] = engineEntry("i4s", { redline = 9000 }),
	["Hudson Hornet"] = engineEntry("i6", { redline = 4500, tone = 0.4 }),
	["Hummer H1"] = engineEntry("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),
	["Jaguar E-Type"] = engineEntry("i6", { redline = 6000 }),
	["Jaguar F-Type"] = engineEntry("v8p", { redline = 6500 }),
	["Jeep Grand Cherokee"] = engineEntry("v8x"),
	["Jeep Wrangler"] = engineEntry("i6", { redline = 5000 }),
	["Kia Ceed"] = engineEntry("i4q"),
	["Kia Forte Koup"] = engineEntry("i4q"),
	["Lamborghini Diablo"] = engineEntry("v12na", { redline = 7000 }),
	["Lamborghini Gallardo"] = engineEntry("v10"),
	["Lamborghini Gallardo LP570-4 Spyder Performante"] = engineEntry("v10"),
	["Lamborghini Miura"] = engineEntry("v12r"),
	["Lamborghini Murcielago"] = engineEntry("v12na"),
	["Lamborghini Murcielago LP670-4 SV"] = engineEntry("v12na"),
	["Lamborghini Reventon Roadster"] = engineEntry("v12na"),
	["Land Rover Defender"] = engineEntry("i4t", { redline = 4500, tone = 0.3 }),
	["Land Rover Range Rover 08"] = engineEntry("v8xt", { redline = 4500, tone = 0.4 }),
	["Land Rover Range Rover 2012"] = engineEntry("v8xt", { redline = 6000 }),
	["Lexus IS 300"] = engineEntry("i6"),
	["Lexus IS F"] = engineEntry("v8s", { redline = 7000 }),
	["Maserati Ghibli S"] = engineEntry("v6t", { redline = 6500 }),
	["Maserati Quattroporte Sport GT S"] = engineEntry("v8s", { redline = 7200 }),
	["Mazda Furai"] = engineEntry("r3"),
	["Mazda MX-5 2007"] = engineEntry("i4", { redline = 7000 }),
	["Mazda RX-8"] = engineEntry("r2"),
	["Mazda RX7"] = engineEntry("r2t"),
	["Mazda Speed 3 2009"] = engineEntry("i4t"),
	["McLaren F1"] = engineEntry("v12na", { redline = 7500 }),
	["McLaren P1"] = engineEntry("v8h", { turbo = true, bov = true, redline = 8500 }),
	["Mercedes 300 SEL"] = engineEntry("v8r", { redline = 5000 }),
	["Mercedes 300SL Gullwing Coupe"] = engineEntry("i6", { redline = 6000 }),
	["Mercedes C32 AMG"] = engineEntry("v6", { redline = 6200 }),
	["Mercedes E63 AMG"] = engineEntry("v8s", { redline = 7200 }),
	["Mercedes G-Class"] = engineEntry("v8x"),
	["Mercedes ML63 AMG"] = engineEntry("v8s", { redline = 7200 }),
	["Mercedes McLaren SLR"] = engineEntry("v8r", { redline = 6500 }),
	["Mercedes SL65 AMG"] = engineEntry("sl65"),
	["Mercedes SLS AMG"] = engineEntry("v8s", { redline = 7200 }),
	["Mini Clubman"] = engineEntry("i4w"),
	["Mini Cooper 1965"] = engineEntry("i4", { redline = 6000 }),
	["Mini Cooper S 2011"] = engineEntry("i4st"),
	["Mini Coupe"] = engineEntry("i4st"),
	["Mitsubishi Colt Ralliart"] = engineEntry("i4st"),
	["Mitsubishi Eclipse GSX"] = engineEntry("i4t"),
	["Mitsubishi Eclipse GT"] = engineEntry("v6"),
	["Mitsubishi Lancer Evo VIII"] = engineEntry("i4t"),
	["Mitsubishi Lancer Evo X"] = engineEntry("i4t"),
	["Morgan Aero SS"] = engineEntry("v8p", { redline = 6500 }),
	["Nissan 350z"] = engineEntry("v6", { redline = 7000 }),
	["Nissan 370Z"] = engineEntry("v6", { redline = 7500 }),
	["Nissan GT-R SpecV"] = engineEntry("v6t"),
	["Nissan Leaf"] = engineEntry("ev", { redline = 10400 }),
	["Nissan Silvia"] = engineEntry("i4t"),
	["Nissan Skyline R34"] = engineEntry("i6t", { redline = 8000 }),
	["Noble M600"] = engineEntry("v8xt"),
	["Pagani Zonda C12"] = engineEntry("v12r"),
	["Pontiac Fiero GT"] = engineEntry("v6", { redline = 5500 }),
	["Pontiac Firebird Trans Am"] = engineEntry("v8m"),
	["Porsche 911 GT3"] = engineEntry("f6"),
	["Porsche 918 Spyder"] = engineEntry("v8h"),
	["Porsche 997 GT3"] = engineEntry("f6", { redline = 8400 }),
	["Porsche Carrera GT"] = engineEntry("v10"),
	["Porsche Cayenne Turbo 2012"] = engineEntry("v8xt"),
	["Porsche Cayenne Turbo S"] = engineEntry("v8xt"),
	["Scion FR-S"] = engineEntry("f4"),
	["Scion tC"] = engineEntry("i4w"),
	["Scion xD"] = engineEntry("i4q"),
	["Shelby 1000"] = engineEntry("v8m", { redline = 6500 }),
	["Subaru Impreza WRX STI"] = engineEntry("boxer"),
	["Subaru Legacy GT 2010"] = engineEntry("boxer"),
	["Subaru Legacy RS 1990"] = engineEntry("boxer"),
	["Tesla Model S"] = engineEntry("ev"),
	["Toyota FJ Cruiser"] = engineEntry("v6"),
	["Toyota MR2 GT"] = engineEntry("i4t"),
	["Toyota Prius"] = engineEntry("i4h"),
	["Toyota Supra"] = engineEntry("i6t"),
	["Vauxhall Agila"] = engineEntry("i3"),
	["Vauxhall Astra"] = engineEntry("i4w"),
	["Vauxhall Corsa"] = engineEntry("i4q"),
	["Vauxhall Insignia"] = engineEntry("i4t"),
	["Volkswagen Beetle 1967"] = engineEntry("f4air"),
	["Volkswagen Camper 1965"] = engineEntry("f4air"),
	["Volkswagen Golf GTI 2014"] = engineEntry("i4st"),
	["Volkswagen Golf MKII"] = engineEntry("i4w"),
	["Volkswagen Golf MKIII"] = engineEntry("i4w"),
	["Volkswagen New Beetle"] = engineEntry("i4w"),
	["Volkswagen Scirocco GT"] = engineEntry("i4st"),
	["Volvo 242 Turbo"] = engineEntry("i4t", { redline = 6000 }),
	["Volvo 850R"] = engineEntry("i5t"),
	["Volvo S60"] = engineEntry("i5t"),

	-- work and emergency vehicles on their own models (not in the engine list). They reuse
	-- engines already baked (the same sound at a lower redline needs no new bank):
	-- the diesels as the Hummer H1's, the petrol V8s as the Ford F350's, the vans as the Transit's
	["Ambulance"] = engineEntry("v8x", { redline = 5000 }),   -- GTA IV ambulance (Ford E-Series type)
	["Courier Truck"] = engineEntry("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),
	["Fire Truck"] = engineEntry("v8xt", { redline = 3000, idle = 650, tone = 0.35 }),
	["Ford F350 Fire Rescue"] = engineEntry("v8x", { redline = 5000 }),
	["Ford F350 Tow Truck"] = engineEntry("v8x", { redline = 5000 }),
	["Ford F450 Ambulance"] = engineEntry("v8x", { redline = 5000 }),
	["Ford Transit 2016 (Police)"] = engineEntry("i4t", { redline = 4500, tone = 0.3 }),
	["Ford Transit 2016 (Prisoner Transport)"] = engineEntry("i4t", { redline = 4500, tone = 0.3 }),
	["Lenco BearCat"] = engineEntry("v8xt", { redline = 3500, idle = 650, tone = 0.35 }),   -- 6.7 diesel V8
	["SWAT Stockade"] = engineEntry("v8xt", { redline = 3200, idle = 650, tone = 0.35 }),   -- GTA IV police stockade
}

--[[
	Stock pops & bangs: how often (0-1, the menu's "Pops & bangs" slider: under 0.25 Rare, under
	0.5 Occasional, under 0.8 Frequent). Only cars that crackle from the factory are listed: sports
	exhausts with an overrun map (AMG V8s, the F-Type, Italian V10s and V12s, GT3s, hot hatches),
	rotaries, carburettor-era racers and race cars. Every other car is off. The engine presets'
	own pop values are only the starting point when an engine is retuned in the menu.
	Frequency and volume are runtime settings: changing them needs no re-bake.
]]
AudioEngine.STOCK_POP_VOLUME = 0.7   -- stock pops & bangs volume (the menu's 100% is 1)
AudioEngine.CAR_POPS = {
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
AudioEngine.STOCK_BOV_VOLUME = 0.6   -- stock blow-off volume (the menu's 100% is 1)
AudioEngine.CAR_BOV = {
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
AudioEngine.CAR_SUPERCHARGER = {
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
	Whine pitch against the others (config.scPitch, cl_engine), for a blower geared unlike the
	~20 lobe passes per crank turn the whine is tuned to. A Roots / TVS blower (two rotors, each
	pushing its own pockets) passes 2 x lobes x drive ratio a turn, a twin-screw male lobes x ratio.
	  Eaton TVS (LSA: ZL1, HSV GTS; AJ133: F-Type, Bowler, Range Rover; GT500): 4 lobes, ~2.6:1 =
	  ~21 per turn: as tuned, not listed
	  Mercedes twin-screw (IHI, 3-lobe male rotor): C32 155/74 mm pulleys = 21,600 rpm at 6,200,
	  3 lobes = 10.5 per turn; SLR 23,000 rpm at 6,500 = 10.6
	  Ford GT (Lysholm 2300), Hellcat (2.4 l twin-screw): ratios not published; their boost needs
	  ~2.5x crank speed, ~10 per turn with 4 male lobes (estimates)
	  hot-rod blower (1970 Challenger, Trans Am): a 6-71 style 3-lobe Roots on a ~15% overdrive =
	  ~7 per turn: the low classic whine
	Shelby 1000 (twin-screw, drive unknown) is left as tuned. Runtime only.
]]
AudioEngine.SC_PITCH = {
	["Mercedes McLaren SLR"] = 0.52,
	["Mercedes C32 AMG"] = 0.52,
	["Ford GT 05"] = 0.52,
	["Dodge Challenger 2015"] = 0.52,
	["Dodge Challenger 1970"] = 0.35,
	["Pontiac Firebird Trans Am"] = 0.35,
}

-- gear count with fitted gearing (sh_presets.lua AudioEngine.FitGearEnds), instead of the one the top speed
-- gives (at most AudioEngine.GEAR_FIT.maxCount 5; set here 2..8). Runtime only: no re-bake
AudioEngine.CAR_GEARS = {
	["Mazda Furai"] = 6,
	["Mini Cooper 1965"] = 3,
	["Mini Cooper S 2011"] = 3,
}

--[[
	A car's own gearing, set by shift speed per gear (sh_presets.lua AudioEngine.ApplyGearing): replaces the
	fitted gearing. Made with the debug module's gearing editor (audio_engine_debug_menu), which
	copies an entry for this table. Runtime only: no re-bake.
	  ["BMW 1M"] = { topRpm = 6000, { mph = 30, rpm = 6500 }, { mph = 52, rpm = 6600, down = 18 }, ..., { down = 70 } },
]]
AudioEngine.CAR_GEARING = {
}

--[[
	How quickly a car's engine revs up and drops back to idle when revved standing still, as
	sh_drivetrain.lua Drivetrain.REV (rise / fall, torque units; default 500 / 500). Made with the debug
	module's rev response page. Runtime only.
	  ["BMW 1M"] = { rise = 600, fall = 800 },
]]
AudioEngine.CAR_REV = {
}

--[[
	Passenger seats (sv_seats.lua): PERP's own, AudioEngine.PERP_SEATS[name] = { seats, exits },
	copied from the PERP gamemode's vehicle definitions (VEHICLE.PassengerSeats / ExitPoints) by
	dev/perp_seats.py from a client's Lua cache. A seat is { x, y, z, pitch, yaw, roll }: the seat pod's
	origin and angles in the car's space (PERP's airboat-seat pods, as sv_seats makes them); an exit
	is { x, y, z } in the car's space, where a passenger gets out (the nearest free one).
	The cars PERP has no seats for keep an estimate, AudioEngine.CAR_SEATS: laid out from the driver's
	attachment (vehicle_feet_passenger0), unlisted = 4: the front passenger mirrors the driver, the back
	row sits AudioEngine.SEAT_REAR_PITCH x wheelbase behind them, AudioEngine.SEAT_REAR_RISE higher.
	1 = driver only, 2 = driver and front passenger. A list names every passenger seat: { side, back,
	up[, width] }: side 1 = the driver's side, -1 the other; back / up = units behind / above the
	driver's hips (back nil = the usual back row); width = units from the centre line (default: the
	driver's).
]]
local FRONT_PASSENGER = { -1, 0, 0 }
AudioEngine.CAR_SEATS = {
	["Ford Transit 2016 (Prisoner Transport)"] = { FRONT_PASSENGER, { 1, 84, 9 }, { -1, 84, 9 } },
	["SWAT Stockade"] = { FRONT_PASSENGER, { 1, 90, 0 }, { -1, 90, 0 }, { 1, 130, 0 }, { -1, 130, 0 } },
}

-- BEGIN PERP_SEATS (generated by dev/perp_seats.py: edit there, not here)
AudioEngine.PERP_SEATS = {
	["Alfa Romeo 33 Stradale (1967)"] = {   -- PERP: Alfa Romeo 33 Stradale
		seats = { { 15.8, -6.4, 5.1, 0, 0, 0 } },
		exits = { { -68, -25, 0 }, { 68, -25, 0 } },
	},
	["Alfa Romeo Giulietta"] = {
		seats = { { 18.8, -4.4, 15.1, 0, 0, 0 }, { 17.8, -48.4, 20.1, 0, 0, 0 }, { -17.8, -48.4, 20.1, 0, 0, 0 } },
		exits = { { -76, -16, 0 }, { 76, -16, 0 }, { 76, -55, 0 }, { -76, -55, 0 } },
	},
	["Ambulance"] = {
		seats = { { 23, 45, 29, 0, 0, 0 }, { 38, -101, 32, 0, 90, 0 }, { -38, -101, 32, 0, -90, 0 }, { 38, -119, 32, 0, 90, 0 }, { -38, -119, 32, 0, -90, 0 } },
		exits = { { -67, 46, 0 }, { 67, 46, 0 }, { 29, -180, 0 }, { -29, -180, 0 } },
	},
	["Aston Martin DB5"] = {
		seats = { { -16.2, -6.4, 18.1, 0, 0, 0 } },
		exits = { { 69, -35, 0 }, { -69, -35, 0 } },
	},
	["Aston Martin DBS"] = {
		seats = { { 18.3, -11.2, 9.3, 0, 0, 0 } },
		exits = { { -65, -14, 0 }, { 65, -14, 0 } },
	},
	["Aston Martin Rapide"] = {
		seats = { { 19.8, -6.4, 15.1, 0, 0, 0 }, { 19.8, -46.4, 15.1, 0, 0, 0 }, { -19.8, -46.4, 15.1, 0, 0, 0 } },
		exits = { { -76, -17, 0 }, { 76, -17, 0 }, { 76, -63, 0 }, { -76, -63, 0 } },
	},
	["Aston Martin V12 Vantage"] = {
		seats = { { -17.7, -30.2, 13.3, 0, 0, 0 } },
		exits = { { 68, -14, 0 }, { -68, -14, 0 } },
	},
	["Audi R8 Plus"] = {
		seats = { { 17.8, -0.4, 14.1, 0, 0, 0 } },
		exits = { { -76, -25, 0 }, { 76, -25, 0 } },
	},
	["Audi R8 Spyder"] = {
		seats = { { 18.8, -2.4, 14.1, 0, 0, 0 } },
		exits = { { -77, -28, 0 }, { 77, -28, 0 } },
	},
	["Audi R8 V10"] = {
		seats = { { 19.4, -3.4, 9.5, 0, 0, 0 } },
		exits = { { -67, -5, 0 }, { 67, -5, 0 } },
	},
	["Audi RS4 Avant"] = {
		seats = { { 20, 4.9, 11.9, 0, 0, 0 }, { 20.5, -35.1, 11.8, 0, 0, 0 }, { -19.4, -34.6, 11.8, 0, 0, 0 }, { 0, -34.8, 11.8, 0, 0, 0 } },
		exits = { { -67, 8, 0 }, { 67, 8, 0 }, { 67, -36, 0 }, { -67, -36, 0 } },
	},
	["Audi S5"] = {
		seats = { { 18.9, -8.1, 9.3, 0, 0, 0 }, { -17.2, -49.5, 13, 0, 0, 0 }, { 17.2, -49.5, 13, 0, 0, 0 } },
		exits = { { -69, -17, 0 }, { 69, -17, 0 } },
	},
	["Audi TT 2007"] = {
		seats = { { 20.3, -1.5, 10.6, 0, 0, 0 } },
		exits = { { -69, -5, 0 }, { 69, -5, 0 } },
	},
	["BMW 1M"] = {
		seats = { { 17.8, -6.4, 14.1, 0, 0, 0 } },
		exits = { { -72, -30, 0 }, { 72, -30, 0 } },
	},
	["BMW 340i"] = {
		seats = { { 18.1, -1.8, 13.3, 0, 0, 0 }, { 18.1, -42.8, 16.3, 0, 0, 0 }, { -15.9, -42.8, 16.3, 0, 0, 0 } },
		exits = { { -70, 11, 0 }, { 64, 11, 0 }, { 70, -39, 0 }, { -64, -39, 0 } },
	},
	["BMW 507"] = {
		seats = { { 18.1, -19.8, 11.3, 0, 0, 0 } },
		exits = { { -64, -23, 0 }, { 64, -23, 0 } },
	},
	["BMW M1"] = {
		seats = { { 19.9, 5.1, 6.9, 0, 0, 0 } },
		exits = { { -65, -13, 0 }, { 65, -13, 0 } },
	},
	["BMW M3 E92"] = {
		seats = { { 22.7, -3, 17.3, 0, 0, 0 }, { 21.3, -45.1, 16.8, 0, 0, 0 }, { -19.4, -45.2, 17.9, 0, 0, 0 } },
		exits = { { -65, -14, 0 }, { 65, -14, 0 } },
	},
	["BMW M5 E34"] = {
		seats = { { 18.7, -2, 17.3, 0, 0, 0 }, { 18.7, -39, 19.3, 0, 0, 0 }, { -18.7, -39, 19.3, 0, 0, 0 } },
		exits = { { -66, -2, 0 }, { 66, -2, 0 }, { 66, -40, 0 }, { -66, -40, 0 } },
	},
	["BMW M5 E60"] = {
		seats = { { 22.7, -3, 17.3, 0, 0, 0 }, { 21.3, -45.1, 16.8, 0, 0, 0 }, { -19.4, -45.2, 17.9, 0, 0, 0 } },
		exits = { { -69, 1, 0 }, { 69, 1, 0 }, { 69, -40, 0 }, { -69, -40, 0 } },
	},
	["BMW M6 2013"] = {
		seats = { { 19.8, -5.4, 24.1, 0, 0, 0 }, { 17.8, -46.4, 24.1, 0, 0, 0 }, { -17.8, -46.4, 24.1, 0, 0, 0 } },
		exits = { { -76, -28, 0 }, { 76, -28, 0 }, { 76, -28, 0 }, { -76, -28, 0 } },
	},
	["Bowler EXR-S"] = {
		seats = { { 17.8, -6.4, 14.1, 0, 0, 0 } },
		exits = { { -72, -30, 0 }, { 72, -30, 0 } },
	},
	["Bugatti EB110"] = {
		seats = { { 19.9, 5.1, 6.9, 0, 0, 0 } },
		exits = { { -70, -1, 0 }, { 70, -1, 0 } },
	},
	["Bugatti Veyron 16.4"] = {
		seats = { { 19.9, 5.1, 7.9, 0, 0, 0 } },
		exits = { { -72, -7, 0 }, { 72, -7, 0 } },
	},
	["Bugatti Veyron SS"] = {
		seats = { { 19.9, 5.1, 6.9, 0, 0, 0 } },
		exits = { { -72, -8, 0 }, { 72, -8, 0 } },
	},
	["Cadillac Escalade 2012"] = {
		seats = { { 18.1, 15, 26.7, 0, 0, 0 }, { 22.5, -31.7, 25.9, 0, 0, 0 }, { -15.2, -30.9, 25.9, 0, 0, 0 }, { 15.5, -75.2, 28.6, 0, 0, 0 }, { -12.7, -75.5, 28.5, 0, 0, 0 } },
		exits = { { -68, 10, 0 }, { 68, 10, 0 }, { 68, -31, 0 }, { -68, -31, 0 }, { 68, -31, 0 }, { -68, -31, 0 } },
	},
	["Chevrolet Blazer"] = {
		seats = { { 16.9, -5, 22.2, 0, 0, 0 }, { 16.9, -39.9, 27.8, 0, 0, 0 }, { -16.9, -39.9, 27.8, 0, 0, 0 } },
		exits = { { -67, -2, 0 }, { 67, -2, 0 }, { -67, -2, 0 }, { 67, -2, 0 } },
	},
	["Chevrolet C10"] = {
		seats = { { 25.1, 3.4, 27.2, 0, 0, 0 }, { 0.1, 3.4, 27.2, 0, 0, 0 } },
		exits = { { -68, 17, 0 }, { 68, 19, 0 } },
	},
	["Chevrolet Camaro SS 69"] = {
		seats = { { 18.1, 2.8, 12.9, 0, 0, 0 }, { 15.8, -33.6, 18.5, 0, 0, 0 }, { -18.2, -33.2, 14.9, 0, 0, 0 } },
		exits = { { -64, -13, 0 }, { 64, -13, 0 } },
	},
	["Chevrolet Camaro ZL1"] = {
		seats = { { 20.1, 2.4, 15.2, 0, 0, 0 } },
		exits = { { -70, -17, 0 }, { 70, -17, 0 } },
	},
	["Chevrolet Chevelle SS"] = {
		seats = { { 20.1, 5.9, 16.3, 0, 0, 0 }, { 14.9, -38.2, 16.1, 0, 0, 0 }, { -12, -38.1, 16.3, 0, 0, 0 } },
		exits = { { -67, -2, 0 }, { 67, -2, 0 } },
	},
	["Chevrolet Corvette GSC"] = {
		seats = { { 18.8, -19.4, 9.1, 0, 0, 0 } },
		exits = { { -77, -43, 0 }, { 77, -43, 0 } },
	},
	["Chevrolet Corvette Stingray 427"] = {
		seats = { { 15.8, -23.4, 13.1, 0, 0, 0 } },
		exits = { { -72, -41, 0 }, { 72, -41, 0 } },
	},
	["Chevrolet Impala SS 96"] = {
		seats = { { 21, -8, 19, 0, 0, 0 }, { 25, -58, 19, 0, 0, 0 }, { -24, -54, 19, 0, 0, 0 } },
		exits = { { -67, -5, 0 }, { 67, -5, 0 }, { -67, -51, 0 }, { 67, -51, 0 } },
	},
	["Chevrolet Spark"] = {
		seats = { { -15, -9.9, 19.4, 0, 0, 0 }, { -17.1, -48.2, 21.2, 0, 0, 0 }, { 17.1, -48.2, 21.2, 0, 0, 0 } },
		exits = { { 60, -7, 0 }, { -60, -7, 0 }, { -60, -17, 0 }, { 60, -17, 0 } },
	},
	["Chrysler 300C"] = {
		seats = { { 21.3, 1.6, 21.3, 0, 0, 0 }, { 22, -41.3, 20.1, 0, 0, 0 }, { -11.9, -41.9, 21.3, 0, 0, 0 } },
		exits = { { -64, 2, 0 }, { 64, 2, 0 }, { -64, -48, 0 }, { 64, -48, 0 } },
	},
	["Chrysler PT Cruiser"] = {
		seats = { { 20, -0.1, 16.9, 0, 0, 0 }, { 16.6, -41.3, 16.8, 0, 0, 0 }, { -16.6, -41.3, 16.8, 0, 0, 0 } },
		exits = { { -59, 3, 0 }, { 59, 3, 0 }, { -59, -43, 0 }, { 59, -43, 0 } },
	},
	["Citroen C1"] = {
		seats = { { 15.6, -7.6, 16.9, 0, 0, 0 }, { 15.7, -45.6, 16.8, 0, 0, 0 }, { -14.3, -45.9, 16.9, 0, 0, 0 } },
		exits = { { -61, -10, 0 }, { 61, -10, 0 } },
	},
	["Citroen C4"] = {
		seats = { { 18.3, -5, 14.7, 0, 0, 0 }, { 19, -49.3, 13.7, 0, 0, 0 }, { -17.6, -47, 13.6, 0, 0, 0 }, { 1.6, -47.8, 13.6, 0, 0, 0 } },
		exits = { { -61, -15, 0 }, { 61, -15, 0 } },
	},
	["Courier Truck"] = {   -- PERP: Van Doorn Delivery
		seats = { { 21.8, 36.6, 51.1, 0, 0, 0 } },
		exits = { { -85, 35, 0 }, { 85, 35, 0 } },
	},
	["DeLorean DMC-12"] = {
		seats = { { 19.9, -14.9, 11.9, 0, 0, 0 } },
		exits = { { -65, -13, 0 }, { 65, -13, 0 } },
	},
	["Dodge Challenger 1970"] = {
		seats = { { 19.5, -15.1, 16.4, 0, 0, 0 }, { 19.5, -50.1, 16.6, 0, 0, 0 }, { -19.5, -50.1, 16.6, 0, 0, 0 } },
		exits = { { -66, -2, 0 }, { 66, -2, 0 } },
	},
	["Dodge Challenger 2015"] = {
		seats = { { 18.8, -5.4, 19.1, 0, 0, 0 } },
		exits = { { -81, -24, 0 }, { 81, -24, 0 } },
	},
	["Dodge Charger 2012"] = {
		seats = { { 20, -0.1, 16.9, 0, 0, 0 }, { 19.4, -50.1, 16.8, 0, 0, 0 }, { -19.4, -49.9, 16.8, 0, 0, 0 } },
		exits = { { -72, 2, 0 }, { 72, 2, 0 }, { 72, -48, 0 }, { -72, -48, 0 } },
	},
	["Dodge Charger SRT-8"] = {
		seats = { { 18.9, -0.2, 16.1, 0, 0, 0 }, { 19.6, -48.8, 16.3, 0, 0, 0 }, { -15.9, -49, 16.6, 0, 0, 0 } },
		exits = { { -67, 1, 0 }, { 67, 1, 0 }, { 67, -47, 0 }, { -67, -47, 0 } },
	},
	["Dodge RAM SRT10"] = {   -- PERP: Dodge Ram SRT-10
		seats = { { 22, 8, 33, 0, 0, 0 } },
		exits = { { -76, 2, 0 }, { 76, 2, 0 } },
	},
	["Dodge Viper GTS"] = {
		seats = { { 20.1, -18.9, 11.7, 0, 0, 0 } },
		exits = { { -68, -24, 0 }, { 68, -24, 0 } },
	},
	["Dundreary Limousine"] = {   -- PERP: Government Dundreary Limousine
		seats = { { 21, -118, 16, 0, 0, 0 }, { -22, -111, 15, 0, 0, 0 }, { -18, -55, 17, 0, 270, 0 }, { -16, -32, 16, 0, 270, 0 }, { -17, -10, 16, 0, 270, 0 }, { -14, 13, 15, 0, 270, 0 }, { 22, 49, 15, 0, 0, 0 } },
		exits = { { -75, 51, 0 }, { 73, -120, 0 }, { -73, -120, 0 }, { 75, 51, 0 } },
	},
	["Ferrari 250 GTO"] = {
		seats = { { 16.8, -11.4, 3.1, 0, 0, 0 } },
		exits = { { -70, -40, 0 }, { 70, -40, 0 } },
	},
	["Ferrari 250GT"] = {
		seats = { { 17.3, -17, 13.8, 0, 0, 0 } },
		exits = { { -59, -16, 0 }, { 59, -16, 0 } },
	},
	["Ferrari 458 Spider"] = {
		seats = { { 14.8, 2.5, 10.3, 0, 0, 0 } },
		exits = { { -74, -16, 0 }, { 74, -16, 0 } },
	},
	["Ferrari 512 TR"] = {
		seats = { { 15.8, -5.4, 8.1, 0, 0, 0 } },
		exits = { { -68, -6, 0 }, { 68, -6, 0 } },
	},
	["Ferrari Enzo"] = {
		seats = { { 19.9, -5.1, 6.9, 0, 0, 0 } },
		exits = { { -67, -9, 0 }, { 67, -9, 0 } },
	},
	["Ferrari F12 Berlinetta"] = {
		seats = { { 19.8, -21.4, 10.1, 0, 0, 0 } },
		exits = { { -75, -46, 0 }, { 75, -46, 0 } },
	},
	["Ferrari F430"] = {
		seats = { { 17.8, 6.6, 11.1, 0, 0, 0 } },
		exits = { { -73, -25, 0 }, { 73, -25, 0 } },
	},
	["Ferrari F50"] = {
		seats = { { 15, -0.1, 6.8, 0, 0, 0 } },
		exits = { { -67, -2, 0 }, { 67, -2, 0 } },
	},
	["Ferrari LaFerrari"] = {
		seats = { { 15.8, 4.6, 6.1, 0, 0, 0 } },
		exits = { { -73, -6, 0 }, { 73, -6, 0 } },
	},
	["Fire Truck"] = {   -- PERP: Fire Department Fire Truck
		seats = { { 31, 147, 53, 0, 0, 0 }, { -32, 49, 61, 0, 0, 0 }, { 32, 49, 61, 0, 0, 0 }, { 0, 49, 61, 0, 0, 0 }, { 32, 103.9, 59, 0, 180, 0 }, { -32, 103.9, 59, 0, 180, 0 } },
		exits = { { -80, 153, 0 }, { 80, 153, 0 }, { -80, 50, 0 }, { 80, 50, 0 } },
	},
	["Ford Crown Victoria"] = {
		seats = { { 19.3, 7.7, 14.6, 0, 0, 0 }, { 19.7, -36.3, 17.6, 0, 0, 0 }, { -19.7, -36.3, 17.6, 0, 0, 0 }, { 0, -36.3, 17.6, 0, 0, 0 } },
		exits = { { -69, 17, 0 }, { 69, 17, 0 }, { 69, -36, 0 }, { -69, -36, 0 } },
	},
	["Ford Deluxe Coupe 1940"] = {
		seats = { { 12.1, 7.2, 19.6, 0, 0, 0 } },
		exits = { { -59, 5, 0 }, { 59, 5, 0 } },
	},
	["Ford F100"] = {
		seats = { { 20.1, 9.9, 31.9, 0, 0, 0 } },
		exits = { { -63, 8, 0 }, { 63, 8, 0 } },
	},
	["Ford F350"] = {
		seats = { { 21.1, 25.9, 42.9, 0, 0, 0 }, { 21.1, -14.1, 38.9, 0, 0, 0 }, { -20.9, -14.1, 38.9, 0, 0, 0 }, { 0.1, -13.1, 39.9, 0, 0, 0 } },
		exits = { { -82, 34, 0 }, { 82, 34, 0 }, { 82, -7, 0 }, { -82, -7, 0 }, { -82, -7, 0 } },
	},
	["Ford F350 Fire Rescue"] = {
		seats = { { 20, 23, 24.6, 0, 0, 0 }, { 21, -12, 26.9, 0, 0, 0 }, { -21, -12, 38.9, 0, 0, 0 } },
		exits = { { -70, 25, 0 }, { 70, 25, 0 }, { 82, -15, 0 }, { -82, -15, 0 } },
	},
	["Ford F350 Tow Truck"] = {
		seats = { { 20, 23, 24.6, 0, 0, 0 } },
		exits = { { -76, 1, 0 }, { 76, 1, 0 } },
	},
	["Ford F450 Ambulance"] = {
		seats = { { 21.5, 38, 37, 0, 0, 0 }, { -23, -98, 49, 0, 270, 0 }, { -23, -122, 49, 0, 270, 0 }, { 16, -122, 67, 0, 180, 85 } },
		exits = { { -80, 45, 0 }, { 80, 45, 0 }, { -25, -180, 10 }, { 25, -180, 10 } },
	},
	["Ford Focus RS"] = {
		seats = { { -17.9, -6.8, 11.4, 0, 0, 0 } },
		exits = { { 72, -9, 0 }, { -72, -9, 0 } },
	},
	["Ford Focus SVT"] = {
		seats = { { 19.8, 5, 13.8, 0, 0, 0 }, { 20.5, -45, 13.8, 0, 0, 0 }, { -20.5, -45, 13.8, 0, 0, 0 }, { 0.5, -44.8, 13.8, 0, 0, 0 } },
		exits = { { -66, -11, 0 }, { 66, -11, 0 } },
	},
	["Ford GT 05"] = {   -- PERP: Ford GT 2005
		seats = { { 20.6, -1.5, 6.9, 0, 0, 0 } },
		exits = { { -70, -10, 0 }, { 70, -10, 0 } },
	},
	["Ford Mustang GT"] = {
		seats = { { 20.1, -5, 16.9, 0, 0, 0 } },
		exits = { { -67, -18, 0 }, { 67, -18, 0 } },
	},
	["Ford Raptor SVT"] = {
		seats = { { 24.7, 21.5, 34.4, 0, 0, 0 }, { 24.1, -17.5, 34.7, 0, 0, 0 }, { -24.7, -17.5, 34.4, 0, 0, 0 }, { 0, -17.5, 33.5, 0, 0, 0 } },
		exits = { { -75, 4, 0 }, { 75, 4, 0 } },
	},
	["Ford Shelby GT500"] = {
		seats = { { 19.8, -0.2, 13.5, 0, 0, 0 }, { 17.5, -38.7, 13.2, 0, 0, 0 }, { -17.5, -38.7, 13.2, 0, 0, 0 } },
		exits = { { -69, -12, 0 }, { 69, -12, 0 } },
	},
	["Ford Transit"] = {
		seats = { { -17.3, 25.7, 38.1, 0, 0, 0 }, { -23.3, -86, 39.1, 0, 0, 0 }, { 23.3, -86, 39.1, 0, 0, 0 }, { -23.3, -46, 39.1, 0, 0, 0 }, { 23.3, -46, 39.1, 0, 0, 0 } },
		exits = { { 70, 27, 0 }, { -70, 27, 0 }, { -70, -17, 0 }, { 70, -17, 0 } },
	},
	["Ford Transit 2016 (Police)"] = {   -- PERP: Police Ford Transit 2016
		seats = { { 19.7, 26.7, 43.1, 0, 0, 0 }, { -31.3, -86, 39.1, 0, -90, 0 }, { 31.3, -86, 39.1, 0, 90, 0 }, { -19.3, -9, 41.1, 0, 180, 0 }, { 20.7, -9, 41.1, 0, 180, 0 } },
		exits = { { 70, 27, 0 }, { -70, 27, 0 }, { -70, -17, 0 }, { 70, -17, 0 } },
	},
	["GMC Sierra"] = {
		seats = { { 19.4, 17.4, 30, 0, 0, 0 } },
		exits = { { -70, 9, 0 }, { 70, 9, 0 } },
	},
	["GMC Syclone"] = {
		seats = { { 19.4, 6.4, 24, 0, 0, 0 } },
		exits = { { -64, 9, 0 }, { 64, 9, 0 } },
	},
	["GMC Vandura"] = {
		seats = { { 24.8, 38.9, 31.9, 0, 0, 0 }, { 33.8, -64.1, 31.9, 0, 90, 0 }, { -33.8, -64.1, 31.9, 0, -90, 0 } },
		exits = { { -68, 49, 0 }, { 68, 49, 0 }, { 19, -143, 0 }, { -19, -143, 0 } },
	},
	["Holden HSV GTS"] = {
		seats = { { -20, -7, 18, 0, 0, 0 }, { -20, -46, 19, 0, 0, 0 }, { 20, -46, 19, 0, 0, 0 } },
		exits = { { 68, -8, 0 }, { -68, -8, 0 }, { -68, -47, 0 }, { 68, -47, 0 } },
	},
	["Holden HSV W427"] = {
		seats = { { -20, 4, 19, 0, 0, 0 }, { -23, -45, 19, 0, 0, 0 }, { 23, -45, 19, 0, 0, 0 } },
		exits = { { 69, 3, 0 }, { -69, 3, 0 }, { -69, -46, 0 }, { 69, -46, 0 } },
	},
	["Honda CR-X SiR"] = {
		seats = { { -16.2, -6.4, 8.1, 0, 0, 0 } },
		exits = { { 68, -30, 0 }, { -68, -30, 0 } },
	},
	["Honda Civic Type R"] = {
		seats = { { -14.4, 0.5, 9.6, 0, 0, 0 } },
		exits = { { 61, -2, 0 }, { -61, -2, 0 } },
	},
	["Honda Civic Type R 1997"] = {
		seats = { { -17.4, -6.5, 14.6, 0, 0, 0 }, { -17.4, -53.5, 16.6, 0, 0, 0 }, { 17.4, -53.5, 16.6, 0, 0, 0 } },
		exits = { { 68, -8, 0 }, { -68, -8, 0 } },
	},
	["Honda S2000"] = {
		seats = { { -18.4, -21.5, 13.6, 0, 0, 0 } },
		exits = { { 68, -22, 0 }, { -68, -22, 0 } },
	},
	["Hudson Hornet"] = {
		seats = { { 16, 10.7, 17.3, 0, 0, 0 }, { 21.7, -34.4, 17.5, 0, 0, 0 }, { -21.7, -34.4, 17.5, 0, 0, 0 }, { 0, 34.1, 17.5, 0, 0, 0 } },
		exits = { { -72, -3, 0 }, { 72, -3, 0 } },
	},
	["Hummer H1"] = {
		seats = { { 32.7, 6, 35.1, 0, 0, 0 }, { 32.7, -32, 35.1, 0, 0, 0 }, { -32.7, -32, 35.1, 0, 0, 0 } },
		exits = { { -76, 4, 0 }, { 76, 4, 0 }, { 76, -34, 0 }, { -76, -34, 0 } },
	},
	["Jaguar E-Type"] = {
		seats = { { -15.2, -25.4, 12.1, 0, 0, 0 } },
		exits = { { 67, -38, 0 }, { -67, -38, 0 } },
	},
	["Jaguar F-Type"] = {
		seats = { { 19.8, -11.4, 14.1, 0, 0, 0 } },
		exits = { { -80, -38, 0 }, { 80, -38, 0 } },
	},
	["Jeep Grand Cherokee"] = {
		seats = { { 20.4, 0.4, 34.7, 0, 0, 0 }, { 20.8, -45.3, 31.3, 0, 0, 0 }, { -20.8, -45.3, 31.3, 0, 0, 0 } },
		exits = { { -70, -1, 0 }, { 70, -1, 0 }, { 70, -47, 0 }, { -70, -47, 0 } },
	},
	["Jeep Wrangler"] = {
		seats = { { 21.1, -11.3, 29.2, 0, 0, 0 }, { 20.4, -55.4, 29.5, 0, 0, 0 }, { -20.4, -55.4, 29.5, 0, 0, 0 } },
		exits = { { -65, -9, 0 }, { 65, -9, 0 } },
	},
	["Kia Ceed"] = {
		seats = { { -14.6, -2.6, 12.4, 0, 0, 0 }, { -18, -46.8, 11.8, 0, 0, 0 }, { 17.9, -46.6, 11.5, 0, 0, 0 } },
		exits = { { 63, 1, 0 }, { -63, 1, 0 }, { -63, -43, 0 }, { 63, -43, 0 } },
	},
	["Kia Forte Koup"] = {
		seats = { { 18.4, -2.6, 17.4, 0, 0, 0 }, { 18.4, -42.6, 18.4, 0, 0, 0 }, { -18.4, -42.6, 18.4, 0, 0, 0 } },
		exits = { { -68, -4, 0 }, { 68, -4, 0 } },
	},
	["Lamborghini Diablo"] = {   -- PERP: Lamborghini Diablo VT
		seats = { { 16.6, 7.5, 9.2, 0, 0, 0 } },
		exits = { { -68, -9, 0 }, { 68, -9, 0 } },
	},
	["Lamborghini Gallardo"] = {
		seats = { { 19.6, 2.5, 9.2, 0, 0, 0 } },
		exits = { { -70, 0, 0 }, { 70, 0, 0 } },
	},
	["Lamborghini Gallardo LP570-4 Spyder Performante"] = {
		seats = { { 19.6, -0.5, 10.2, 0, 0, 0 } },
		exits = { { -68, -9, 0 }, { 68, -9, 0 } },
	},
	["Lamborghini Miura"] = {
		seats = { { 17.6, -3.5, 8.2, 0, 0, 0 } },
		exits = { { -68, -9, 0 }, { 68, -9, 0 } },
	},
	["Lamborghini Murcielago"] = {
		seats = { { 18.8, 4.7, 4.7, 0, 0, 0 } },
		exits = { { -66, -5, 0 }, { 66, -5, 0 } },
	},
	["Lamborghini Murcielago LP670-4 SV"] = {
		seats = { { 19.8, 5.7, 6.7, 0, 0, 0 } },
		exits = { { -68, -5, 0 }, { 68, -5, 0 } },
	},
	["Lamborghini Reventon Roadster"] = {
		seats = { { 23.5, 4.4, 7.4, 0, 0, 0 } },
		exits = { { -71, 0, 0 }, { 71, 0, 0 } },
	},
	["Land Rover Defender"] = {
		seats = { { -27.6, -78.8, 55.4, 0, -90, 0 }, { -17.8, -17.6, 51.7, 0, 0, 0 }, { 29.4, -66.5, 49.5, 0, 90, 0 } },
		exits = { { 65, 0, 0 }, { -65, 0, 0 }, { 65, -49, 0 }, { -65, -49, 0 } },
	},
	["Land Rover Range Rover 08"] = {
		seats = { { 20.4, -4.6, 32.7, 0, 0, 0 }, { 20.8, -48.3, 27.3, 0, 0, 0 }, { -20.8, -48.3, 27.3, 0, 0, 0 } },
		exits = { { -65, 0, 0 }, { 65, 0, 0 }, { 65, -49, 0 }, { -65, -49, 0 } },
	},
	["Land Rover Range Rover 2012"] = {
		seats = { { -20.6, -2.6, 33.7, 0, 0, 0 }, { -20.6, -51.6, 33.7, 0, 0, 0 }, { 20.6, -51.6, 33.7, 0, 0, 0 }, { 0, -51.6, 33.7, 0, 0, 0 } },
		exits = { { 70, 0, 0 }, { -70, 0, 0 }, { -70, -53, 0 }, { 70, -53, 0 } },
	},
	["Lenco BearCat"] = {   -- PERP: SWAT Van
		seats = { { 27.7, 1.3, 30.1, 0, 0, 0 }, { -34.7, -77.7, 34.1, 0, -90, 0 }, { 34.7, -77.7, 34.1, 0, 90, 0 }, { -34.7, -114.7, 34.1, 0, -90, 0 }, { 34.7, -114.7, 34.1, 0, 90, 0 } },
		exits = { { -86, -6, -10 }, { 86, -6, -10 }, { 0, -186, -10 } },
	},
	["Lexus IS 300"] = {
		seats = { { 16.8, 0.6, 17.1, 0, 0, 0 }, { 15.8, -46.4, 20.1, 0, 0, 0 }, { -15.8, -46.4, 20.1, 0, 0, 0 } },
		exits = { { -69, -14, 0 }, { 69, -14, 0 }, { 69, -48, 0 }, { -69, -48, 0 } },
	},
	["Lexus IS F"] = {
		seats = { { 17.8, -3.4, 15.1, 0, 0, 0 }, { 18.8, -43.4, 14.1, 0, 0, 0 }, { -18.8, -43.4, 14.1, 0, 0, 0 } },
		exits = { { -73, -11, 0 }, { 73, -11, 0 }, { 73, -53, 0 }, { -73, -53, 0 } },
	},
	["Maserati Ghibli S"] = {
		seats = { { 17.8, -6.4, 18.1, 0, 0, 0 }, { 17.8, -46.4, 20.1, 0, 0, 0 }, { -17.8, -46.4, 20.1, 0, 0, 0 } },
		exits = { { -76, -17, 0 }, { 76, -17, 0 }, { 76, -66, 0 }, { -76, -66, 0 } },
	},
	["Maserati Quattroporte Sport GT S"] = {   -- PERP: Maserati Quattroporte GTS
		seats = { { 18.8, -1.4, 17.1, 0, 0, 0 }, { 18.8, -50.4, 17.1, 0, 0, 0 }, { -18.8, -50.4, 17.1, 0, 0, 0 } },
		exits = { { -76, -14, 0 }, { 76, -14, 0 }, { 76, -62, 0 }, { -76, -62, 0 } },
	},
	["Mazda Furai"] = {
		seats = { { -11.2, 12.6, 2.1, 0, 0, 0 } },
		exits = { { 70, -6, 0 }, { -70, -6, 0 } },
	},
	["Mazda MX-5 2007"] = {
		seats = { { -15.2, -12.3, 10.7, 0, 0, 0 } },
		exits = { { 65, -19, 0 }, { -65, -19, 0 } },
	},
	["Mazda RX-8"] = {
		seats = { { -17.7, -3.4, 16.9, 0, 0, 0 }, { -17.7, -42.4, 17.2, 0, 0, 0 }, { 17.7, -42.4, 17.2, 0, 0, 0 } },
		exits = { { 66, -11, 0 }, { -66, -11, 0 }, { -66, -11, 0 }, { 66, -11, 0 } },
	},
	["Mazda RX7"] = {   -- PERP: Mazda RX-7
		seats = { { -20.1, -13.5, 10.3, 0, 0, 0 } },
		exits = { { 66, -23, 0 }, { -66, -23, 0 } },
	},
	["Mazda Speed 3 2009"] = {
		seats = { { 17.8, -3.3, 17.7, 0, 0, 0 }, { 17.8, -40.3, 16.7, 0, 0, 0 }, { -17.8, -40.3, 16.7, 0, 0, 0 } },
		exits = { { -68, -4, 0 }, { 68, -4, 0 }, { 68, -41, 0 }, { -68, -41, 0 } },
	},
	["McLaren F1"] = {
		seats = { { -21.2, -9.5, 9.1, 0, 0, 0 }, { 21.2, -9.5, 9.1, 0, 0, 0 } },
		exits = { { 71, -8, 0 }, { -71, -8, 0 } },
	},
	["McLaren P1"] = {
		seats = { { 15.8, 2.5, 8.1, 0, 0, 0 } },
		exits = { { -70, 0, 0 }, { 70, 0, 0 } },
	},
	["Mercedes 300 SEL"] = {
		seats = { { 18.9, 7.1, 16.9, 0, 0, 0 }, { 18.9, -36.9, 16.9, 0, 0, 0 }, { -18.9, -36.9, 16.9, 0, 0, 0 } },
		exits = { { -68, 6, 0 }, { 68, 6, 0 }, { 68, -38, 0 }, { -68, -38, 0 } },
	},
	["Mercedes 300SL Gullwing Coupe"] = {
		seats = { { 15.9, -11.9, 13.9, 0, 0, 0 } },
		exits = { { -65, -13, 0 }, { 65, -13, 0 } },
	},
	["Mercedes C32 AMG"] = {   -- PERP: Mercedes C 32 AMG
		seats = { { 19.7, 4.1, 15.6, 0, 0, 0 }, { 12.8, -37.8, 18.5, 0, 0, 0 }, { -16.6, -41.7, 18.3, 0, 0, 0 } },
		exits = { { -67, 2, 0 }, { 67, 2, 0 }, { 67, -44, 0 }, { -67, -44, 0 } },
	},
	["Mercedes E63 AMG"] = {   -- PERP: Mercedes E 63 AMG
		seats = { { 18.7, 5, 17.3, 0, 0, 0 }, { 18.7, -43.1, 17.8, 0, 0, 0 }, { -18.7, -43.1, 17.8, 0, 0, 0 } },
		exits = { { -67, 5, 0 }, { 67, 5, 0 }, { 67, -44, 0 }, { -67, -44, 0 } },
	},
	["Mercedes G-Class"] = {
		seats = { { 18.9, -1.9, 31.9, 0, 0, 0 }, { 18.9, -41.9, 32.9, 0, 0, 0 }, { -18.9, -41.9, 32.9, 0, 0, 0 } },
		exits = { { -68, 6, 0 }, { 68, 6, 0 }, { 68, -38, 0 }, { -68, -38, 0 } },
	},
	["Mercedes ML63 AMG"] = {   -- PERP: Mercedes ML 63 AMG
		seats = { { 18.7, 1, 26.3, 0, 0, 0 }, { 18.7, -48, 26.3, 0, 0, 0 }, { -18.7, -48, 26.3, 0, 0, 0 } },
		exits = { { -70, 0, 0 }, { 70, 0, 0 }, { 70, -49, 0 }, { -70, -49, 0 } },
	},
	["Mercedes McLaren SLR"] = {
		seats = { { 16.8, -28.4, 15.1, 0, 0, 0 } },
		exits = { { -76, -55, 0 }, { 76, -55, 0 } },
	},
	["Mercedes SL65 AMG"] = {
		seats = { { 19.1, -15.9, 10.7, 0, 0, 0 } },
		exits = { { -66, -24, 0 }, { 66, -24, 0 } },
	},
	["Mercedes SLS AMG"] = {
		seats = { { 20.1, -27.8, 14.1, 0, 0, 0 } },
		exits = { { -71, -34, 0 }, { 71, -34, 0 } },
	},
	["Mini Clubman"] = {
		seats = { { 15.9, -8.5, 14.2, 0, 0, 0 }, { 12.9, -43.5, 14.2, 0, 0, 0 }, { -12.9, -43.5, 14.2, 0, 0, 0 } },
		exits = { { -67, -11, 0 }, { 67, -11, 0 }, { 67, -20, 0 }, { -67, -20, 0 } },
	},
	["Mini Cooper 1965"] = {
		seats = { { -15.1, -2.5, 13.2, 0, 0, 0 }, { 16.2, -42.5, 14.1, 0, 0, 0 }, { -16.2, -42.5, 14.1, 0, 0, 0 } },
		exits = { { 60, -4, 0 }, { -60, -4, 0 }, { 60, -4, 0 }, { -60, -4, 0 } },
	},
	["Mini Cooper S 2011"] = {
		seats = { { -15.1, -15.5, 16.2, 0, 0, 0 }, { -15.1, -50.5, 16.2, 0, 0, 0 }, { 15.1, -50.5, 16.2, 0, 0, 0 } },
		exits = { { 66, -16, 0 }, { -66, -16, 0 }, { -66, -16, 0 }, { 66, -16, 0 } },
	},
	["Mini Coupe"] = {
		seats = { { 15.9, -10.5, 12.2, 0, 0, 0 } },
		exits = { { -67, -12, 0 }, { 67, -12, 0 } },
	},
	["Mitsubishi Colt Ralliart"] = {
		seats = { { -18, -5.2, 17.5, 0, 0, 0 } },
		exits = { { 64, -10, 0 }, { -64, -10, 0 } },
	},
	["Mitsubishi Eclipse GSX"] = {
		seats = { { 17.8, -7.4, 13.1, 0, 0, 0 } },
		exits = { { -70, -28, 0 }, { 70, -28, 0 } },
	},
	["Mitsubishi Eclipse GT"] = {
		seats = { { 19, -4, 12, 0, 0, 0 } },
		exits = { { -64, -6, 0 }, { 68, -6, 0 } },
	},
	["Mitsubishi Lancer Evo VIII"] = {
		seats = { { -17, -1, 11, 0, 0, 0 }, { -17, -42, 13, 0, 0, 0 }, { 17, -42, 13, 0, 0, 0 } },
		exits = { { 68, -2, 0 }, { -68, -2, 0 }, { -68, -44, 0 }, { 68, -44, 0 } },
	},
	["Mitsubishi Lancer Evo X"] = {
		seats = { { -20, -11, 15, 0, 0, 0 }, { 16, -55, 15, 0, 0, 0 }, { -20, -55, 15, 0, 0, 0 } },
		exits = { { 64, -14, 0 }, { -68, -13, 0 }, { 64, -60, 0 }, { -66, -60, 0 } },
	},
	["Morgan Aero SS"] = {
		seats = { { 14.9, -28.9, 8.9, 0, 0, 0 } },
		exits = { { -65, -29, 0 }, { 65, -29, 0 } },
	},
	["Nissan 350z"] = {   -- PERP: Nissan 350Z
		seats = { { -18.1, -12.5, 12.3, 0, 0, 0 } },
		exits = { { 63, -23, 0 }, { -63, -23, 0 } },
	},
	["Nissan 370Z"] = {
		seats = { { 19.9, -14.5, 15.3, 0, 0, 0 } },
		exits = { { -66, -23, 0 }, { 66, -23, 0 } },
	},
	["Nissan GT-R SpecV"] = {   -- PERP: Nissan GT-R Spec-V
		seats = { { -17.1, -10.9, 18.9, 0, 0, 0 } },
		exits = { { 68, -7, 0 }, { -68, -7, 0 } },
	},
	["Nissan Leaf"] = {
		seats = { { 19.6, 2.8, 18.1, 0, 0, 0 }, { 17.6, -43.2, 18.1, 0, 0, 0 }, { -17.6, -43.2, 18.1, 0, 0, 0 } },
		exits = { { -64, 10, 0 }, { 64, 11, 0 }, { 63, -41, 0 }, { -59, -41, 0 } },
	},
	["Nissan Silvia"] = {   -- PERP: Nissan Silvia Spec-R
		seats = { { -17.4, -10.2, 12.1, 0, 0, 0 } },
		exits = { { 68, -12, 0 }, { -68, -12, 0 } },
	},
	["Nissan Skyline R34"] = {
		seats = { { -16.4, -11.2, 11.1, 0, 0, 0 } },
		exits = { { 65, -16, 0 }, { -65, -16, 0 } },
	},
	["Noble M600"] = {
		seats = { { -15.2, 4.7, 2.7, 0, 0, 0 } },
		exits = { { 68, -5, 0 }, { -68, -5, 0 } },
	},
	["Pagani Zonda C12"] = {
		seats = { { 14.2, 1.5, 6.9, 0, 0, 0 } },
		exits = { { -67, -5, 0 }, { 67, -5, 0 } },
	},
	["Pontiac Fiero GT"] = {
		seats = { { 17.8, -11.4, 7.1, 0, 0, 0 } },
		exits = { { -73, -32, 0 }, { 73, -32, 0 } },
	},
	["Pontiac Firebird Trans Am"] = {
		seats = { { 18.8, -9.4, 16.1, 0, 0, 0 } },
		exits = { { -83, -35, 0 }, { 83, -35, 0 } },
	},
	["Porsche 911 GT3"] = {
		seats = { { 16.8, -4.8, 10.1, 0, 0, 0 } },
		exits = { { -64, -18, 0 }, { 64, -18, 0 } },
	},
	["Porsche 918 Spyder"] = {
		seats = { { 16.8, -1.5, 11.1, 0, 0, 0 } },
		exits = { { -70, -2, 0 }, { 70, -2, 0 } },
	},
	["Porsche 997 GT3"] = {
		seats = { { 18.8, -4.8, 15.1, 0, 0, 0 } },
		exits = { { -64, -18, 0 }, { 64, -18, 0 } },
	},
	["Porsche Carrera GT"] = {
		seats = { { 15.8, 2.5, 8.1, 0, 0, 0 } },
		exits = { { -70, 0, 0 }, { 70, 0, 0 } },
	},
	["Porsche Cayenne Turbo 2012"] = {
		seats = { { 20.4, -1.1, 26.9, 0, 0, 0 }, { 20.4, -48.5, 27.2, 0, 0, 0 }, { -20.4, -48.5, 27.2, 0, 0, 0 } },
		exits = { { -75, -1, 0 }, { 75, -1, 0 }, { 75, -51, 0 }, { -75, -51, 0 } },
	},
	["Porsche Cayenne Turbo S"] = {
		seats = { { 23.4, -2.1, 25.9, 0, 0, 0 }, { 23.2, -44.5, 24.2, 0, 0, 0 }, { -27.4, -44.1, 24.8, 0, 0, 0 } },
		exits = { { -75, -1, 0 }, { 75, -1, 0 }, { 75, -51, 0 }, { -75, -51, 0 } },
	},
	["Scion FR-S"] = {
		seats = { { 17.9, -12.5, 14.3, 0, 0, 0 } },
		exits = { { -69, -23, 0 }, { 69, -23, 0 } },
	},
	["Scion tC"] = {
		seats = { { 17.9, 0.5, 12.3, 0, 0, 0 }, { 17.9, -47.5, 12.3, 0, 0, 0 }, { -17.9, -47.5, 12.3, 0, 0, 0 } },
		exits = { { -70, -13, 0 }, { 70, -13, 0 } },
	},
	["Scion xD"] = {
		seats = { { 13.9, -9.5, 13.3, 0, 0, 0 }, { 13.9, -46.5, 14.3, 0, 0, 0 }, { -13.9, -46.5, 14.3, 0, 0, 0 } },
		exits = { { -63, -10, 0 }, { 63, -10, 0 }, { 63, -47, 0 }, { -63, -47, 0 } },
	},
	["Shelby 1000"] = {
		seats = { { 17.8, -5.4, 23.1, 0, 0, 0 } },
		exits = { { -78, -37, 0 }, { 78, -37, 0 } },
	},
	["Subaru Impreza WRX STI"] = {   -- PERP: Subaru Impreza
		seats = { { 17.7, -4.1, 16.9, 0, 0, 0 }, { 15.3, -48.5, 18, 0, 0, 0 }, { -15.3, -48.5, 18, 0, 0, 0 } },
		exits = { { -67, -3, 0 }, { 67, -3, 0 }, { 67, -44, 0 }, { -67, -44, 0 } },
	},
	["Subaru Legacy GT 2010"] = {
		seats = { { -18.2, -0.4, 14.1, 0, 0, 0 }, { -19.2, -43.4, 15.1, 0, 0, 0 }, { 19.2, -43.4, 15.1, 0, 0, 0 } },
		exits = { { 75, -4, 0 }, { -75, -4, 0 }, { -75, -64, 0 }, { 75, -64, 0 } },
	},
	["Subaru Legacy RS 1990"] = {
		seats = { { -17.2, 0.6, 16.1, 0, 0, 0 }, { -17.2, -43.4, 16.1, 0, 0, 0 }, { 17.2, -43.4, 16.1, 0, 0, 0 } },
		exits = { { 71, -8, 0 }, { -71, -8, 0 }, { -71, -60, 0 }, { 71, -60, 0 } },
	},
	["Tesla Model S"] = {
		seats = { { 19.9, -6.9, 19.2, 0, 0, 0 }, { 19.9, -55.9, 19.2, 0, 0, 0 }, { -19.9, -55.9, 19.2, 0, 0, 0 } },
		exits = { { -69, 7, 0 }, { 69, 7, 0 }, { 69, -57, 0 }, { -69, -57, 0 } },
	},
	["Toyota FJ Cruiser"] = {
		seats = { { 21.8, 5.6, 30.1, 0, 0, 0 }, { 20.8, -33.4, 32.1, 0, 0, 0 }, { -20.8, -33.4, 32.1, 0, 0, 0 } },
		exits = { { -82, -11, 0 }, { 82, -11, 0 }, { 82, -51, 0 }, { -82, -51, 0 } },
	},
	["Toyota MR2 GT"] = {
		seats = { { -17.2, -7.4, 8.1, 0, 0, 0 } },
		exits = { { 67, -19, 0 }, { -67, -19, 0 } },
	},
	["Toyota Prius"] = {
		seats = { { 18.9, 0.1, 15.2, 0, 0, 0 }, { 18.8, -39, 16.6, 0, 0, 0 }, { -18.8, -39, 16.6, 0, 0, 0 } },
		exits = { { -66, 7, 0 }, { 66, 7, 0 }, { 66, -38, 0 }, { -66, -38, 0 } },
	},
	["Toyota Supra"] = {
		seats = { { -18, -17.6, 7.6, 0, 0, 0 } },
		exits = { { 66, -18, 0 }, { -66, -18, 0 } },
	},
	["Vauxhall Agila"] = {
		seats = { { -16.4, -6.6, 21.9, 0, 0, 0 }, { 15.7, -49.6, 24.8, 0, 0, 0 }, { -15.7, -49.6, 24.8, 0, 0, 0 } },
		exits = { { 61, 4, 0 }, { 62, -38, 0 }, { -61, 4, 0 }, { -62, -38, 0 } },
	},
	["Vauxhall Astra"] = {
		seats = { { -19.4, 1.4, 11.9, 0, 0, 0 }, { 19.7, -45.6, 12.8, 0, 0, 0 }, { -19.7, -45.6, 12.8, 0, 0, 0 } },
		exits = { { 64, 5, 0 }, { 64, -47, 0 }, { -68, 0, 0 }, { -68, -50, 0 } },
	},
	["Vauxhall Corsa"] = {
		seats = { { -15.4, -8.6, 20.9, 0, 0, 0 }, { 15.2, -49.6, 19.8, 0, 0, 0 }, { -15.2, -49.6, 19.8, 0, 0, 0 } },
		exits = { { 58, 2, 0 }, { -59, 0, 0 }, { 60, -48, 0 }, { -59, -47, 0 } },
	},
	["Vauxhall Insignia"] = {
		seats = { { -20.4, 3.4, 17.9, 0, 0, 0 }, { 19.7, -41.6, 18.8, 0, 0, 0 }, { -19.7, -41.6, 18.8, 0, 0, 0 } },
		exits = { { 68, 10, 0 }, { -68, 7, 0 }, { 64, -39, 0 }, { -64, -40, 0 } },
	},
	["Volkswagen Beetle 1967"] = {
		seats = { { 13.1, 4, 19.1, 0, 0, 0 }, { -16, -26.6, 18.7, 0, 0, 0 }, { 18.6, -33.4, 18.6, 0, 0, 0 } },
		exits = { { -60, -1, 0 }, { 60, -1, 0 } },
	},
	["Volkswagen Camper 1965"] = {
		seats = { { 24.8, 55.6, 35.1, 0, 0, 0 }, { -25.2, 2.6, 33.1, 0, 0, 0 }, { 5.8, 2.6, 33.1, 0, 0, 0 }, { -25.2, -46.4, 34.1, 0, 0, 0 }, { -0.2, -46.4, 34.1, 0, 0, 0 }, { 25.2, -46.4, 34.1, 0, 0, 0 } },
		exits = { { -77, 40, 0 }, { 77, 40, 0 }, { 79, 7, 0 } },
	},
	["Volkswagen Golf GTI 2014"] = {
		seats = { { 18.4, -2.6, 17.4, 0, 0, 0 }, { 18.4, -42.6, 18.4, 0, 0, 0 }, { -18.4, -42.6, 18.4, 0, 0, 0 } },
		exits = { { -68, -4, 0 }, { 68, -4, 0 }, { 59, -45, 0 }, { -59, -41, 0 } },
	},
	["Volkswagen Golf MKII"] = {
		seats = { { 19, -2, 17.3, 0, 0, 0 }, { 19.6, -52.1, 17.3, 0, 0, 0 }, { -19.6, -52.1, 17.3, 0, 0, 0 } },
		exits = { { -70, -7, 0 }, { 70, -7, 0 } },
	},
	["Volkswagen Golf MKIII"] = {   -- PERP: Volkswagen Golf MK3
		seats = { { 14.9, 0.4, 13, 0, 0, 0 }, { 20, -43, 14.4, 0, 0, 0 }, { -18, -43, 14.4, 0, 0, 0 } },
		exits = { { -64, -8, 0 }, { 64, -8, 0 } },
	},
	["Volkswagen New Beetle"] = {
		seats = { { 16.8, -5.4, 16.1, 0, 0, 0 }, { 16.8, -43.4, 21.1, 0, 0, 0 }, { -16.8, -43.4, 21.1, 0, 0, 0 } },
		exits = { { -71, -18, 0 }, { 71, -18, 0 }, { 71, -56, 0 }, { -71, -56, 0 } },
	},
	["Volkswagen Scirocco GT"] = {
		seats = { { -17.2, 0.6, 13.5, 0, 0, 0 }, { 7.5, -39, 12.4, 0, 0, 0 }, { -7.5, -39, 12.4, 0, 0, 0 } },
		exits = { { 65, -3, 0 }, { -65, -3, 0 } },
	},
	["Volvo 242 Turbo"] = {
		seats = { { 19.1, 4.6, 11.3, 0, 0, 0 }, { 18.6, -34.3, 11.1, 0, 0, 0 }, { -13.4, -30.8, 10, 0, 0, 0 } },
		exits = { { -69, -4, 0 }, { 69, -4, 0 } },
	},
	["Volvo 850R"] = {   -- PERP: Volvo 850 R
		seats = { { 19.1, 2.6, 16.3, 0, 0, 0 }, { 24, -44, 13, 0, 0, 0 }, { -24, -44, 13, 0, 0, 0 }, { 0, -44, 13, 0, 0, 0 } },
		exits = { { -64, 9, 0 }, { 64, 9, 0 }, { 67, -38, 0 }, { -67, -38, 0 }, { -67, -38, 0 } },
	},
	["Volvo S60"] = {
		seats = { { 19.1, -2.4, 11.3, 0, 0, 0 }, { 17.6, -46.3, 12.1, 0, 0, 0 }, { -18.4, -45.8, 11, 0, 0, 0 } },
		exits = { { -62, 8, 0 }, { 62, 10, 0 }, { 68, -40, 0 }, { -68, -40, 0 } },
	},
}
-- END PERP_SEATS

--[[
	Rev flare on start-up (the "emotion start", audio_engine_emotionstart): only high-powered cars
	blip their engine on start-up (sports cars, supercars, muscle cars, AMG/M/RS saloons, rally
	homologation specials). Every other car starts with a short, gentle rise to just above idle.
	Runtime only: the server picks the start, both start-ups are in every bank, so no re-bake.
]]
AudioEngine.CAR_EMOTION = {}
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
}) do AudioEngine.CAR_EMOTION[name] = true end
-- and they carry further (Source sound level in dB; other cars 85, economy cars 80)
AudioEngine.EMOTION_SOUNDLEVEL = 92

--[[
	Economy cars: stock silencers and small engines sound duller and quieter than the presets,
	which are tuned for character. On top of its preset, an economy car gets:
	  tone x ECONOMY.toneScale   (darker exhaust; part of the sound, so re-bake after changing)
	  muffle                     (a stock silencer: lower cutoffs, more treble cut; also re-bake)
	  gurgle = 0                 (no off-throttle burble; also part of the sound)
	  (a preset with economyTuned was tuned as an economy car: its tone and gurgle are kept)
	  volume, soundLevel         (quieter, and carries less far; runtime)
]]
AudioEngine.ECONOMY_SOUND = { toneScale = 0.5, muffle = 0.7, gurgle = 0, volume = 0.8, soundLevel = 80 }
AudioEngine.ECONOMY = {
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
	car reaches AudioEngine.WING_UP of its top speed and lower only under AudioEngine.WING_DOWN_MPH (the gap stops them
	flapping), the needles still sweep with speed inside each range.
	{ rest from, rest to, up from, up to, pose = name if not vehicle_guage }: pose ranges where every part is fully down / fully up,
	read from the blend animations of each model's vehicle_guage sequence (the TDM .mdl files).
]]
AudioEngine.WING_UP = 0.7
AudioEngine.WING_DOWN_MPH = 30
AudioEngine.WING_RATE = 0.25 -- pose range per second the parts travel
AudioEngine.GAUGE_PARTS = {
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
	        the same speed rules as the spoilers above only (braking doesn't raise it); the flap tilts
	        only once the wing is all the way out, and the wing stays out until the flap has folded
	  flapPose/flapBone+flapAng: the brake flap, as a pose (0..1) or a bone rotation (pitch yaw roll)
	P1: the model stores its wing raised. Its flap is
	the spoilerbrake pose (named twice in the model, the wing uses the first). SLR: its airbrake pose
	compiled empty; the source data has the flap at 22.5 deg about its own z.
]]
AudioEngine.WING_BRAKE_HOLD = 0.15 -- (was 0.5: the flap came up late in a stop)
AudioEngine.WING_BRAKE_MPH = 15    -- forward speed: S held reversing never raises it
AudioEngine.WING_MAIN_RATE = 0.8 -- share of the travel per second (~1.3 s)
AudioEngine.WING_FLAP_RATE = 5   -- brake flap up per second (~0.2 s; was 2); folds at half this (~0.4 s)
AudioEngine.BRAKE_WINGS = {
	["McLaren P1"] = { flapPose = "spoilerbrake", tuck = {   -- placed with the bone editor (audio_engine_bonedump)
		{ bone = "spoiler_main", pos = { 0, 9, -13 } },
		{ bone = "spoiler", pos = { -0.34, 1.88, 0.04 }, ang = { -0.16, -24.58, 0 } },
	} },
	["Mercedes McLaren SLR"] = { flapBone = "spoiler", flapAng = { 0, 22.5, 0 } },
}

-- speed rule shared by all wings: up from WING_UP of the top speed, down under WING_DOWN_MPH
function AudioEngine.WingSpeedUp(vehicle, speedKmh, topSpeed)
	local topSpeedShare = speedKmh / math.max(topSpeed or 250, 40)
	if topSpeedShare >= AudioEngine.WING_UP then
		vehicle.audioWingUpLatched = true
	elseif speedKmh < AudioEngine.WING_DOWN_MPH * 1.609344 then
		vehicle.audioWingUpLatched = false
	end
	return vehicle.audioWingUpLatched or false, topSpeedShare
end

-- the vehicle_guage pose for a car with parts on it (run by the server, sv_engine.lua): kmh and
-- top speed in km/h; cl_engine glides to it at AudioEngine.WING_RATE of the pose range per second (the
-- parts take ~1-1.5 s)
function AudioEngine.WingPose(vehicle, gaugeParts, speedKmh, topSpeed)
	local wingUp, topSpeedShare = AudioEngine.WingSpeedUp(vehicle, speedKmh, topSpeed)
	if wingUp then
		return gaugeParts[3] + (gaugeParts[4] - gaugeParts[3]) * math.Clamp((topSpeedShare - AudioEngine.WING_UP) / (1 - AudioEngine.WING_UP), 0, 1)
	end
	return gaugeParts[1] + (gaugeParts[2] - gaugeParts[1]) * math.Clamp(topSpeedShare / AudioEngine.WING_UP, 0, 1)
end

-- register a car's model with the engine from the list above
function AudioEngine.RegisterCarNamed(model, carName, extra)
	local listed = AudioEngine.CAR_ENGINES[carName]
	if not listed then
		ErrorNoHalt("[Audio Engine] no engine listed for '" .. tostring(carName) .. "'\n")
		return
	end
	local carConfig = {
		carId = string.lower((carName:gsub("[^%w]+", "_"))),
		name = carName,
		preset = listed.preset,
		stock = listed.stock,
		character = listed.character,
		stockPops = AudioEngine.CAR_POPS[carName] or 0,
		stockPopVol = AudioEngine.STOCK_POP_VOLUME,
		stockBov = AudioEngine.CAR_BOV[carName] and true or false,
		stockBovVol = AudioEngine.STOCK_BOV_VOLUME,
		supercharger = AudioEngine.CAR_SUPERCHARGER[carName],
		scPitch = AudioEngine.SC_PITCH[carName],
		emotionStart = AudioEngine.CAR_EMOTION[carName] or false,
		gaugeParts = AudioEngine.GAUGE_PARTS[carName],
		brakeWing = AudioEngine.BRAKE_WINGS[carName],
		gearCount = AudioEngine.CAR_GEARS[carName],
		gearing = AudioEngine.CAR_GEARING[carName],
		rev = AudioEngine.CAR_REV[carName],
		seats = AudioEngine.CAR_SEATS[carName],
		perpSeats = AudioEngine.PERP_SEATS[carName],
		topSpeed = "auto",
		wheelRadius = 0.33,
		soundLevel = AudioEngine.CAR_EMOTION[carName] and AudioEngine.EMOTION_SOUNDLEVEL or 85,
		volume = 1.0,
	}
	local preset = AudioEngine.EnginePreset(listed.preset)
	if AudioEngine.ECONOMY[carName] then
		local economySound = AudioEngine.ECONOMY_SOUND
		local stock = {}
		for key, value in pairs(listed.stock or {}) do stock[key] = value end
		if not (preset and preset.economyTuned) then
			stock.tone = (stock.tone or (preset and preset.tone) or 0.4) * economySound.toneScale
			stock.gurgle = economySound.gurgle
		end
		carConfig.stock = stock
		carConfig.volume = economySound.volume
		carConfig.soundLevel = economySound.soundLevel
		carConfig.muffle = economySound.muffle
		carConfig.economy = true
	end
	-- a preset's own silencer (part of the sound: re-bake)
	if preset and preset.muffle then carConfig.muffle = preset.muffle end
	for key, value in pairs(extra or {}) do carConfig[key] = value end
	return AudioEngine.RegisterCar(model, carConfig)
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
AudioEngine.CAR_MODELS = {
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
	{ spawn name, car (AudioEngine.CAR_MODELS), vehicle script, skin }. Built by dev/perp_carmodels.py.
]]
AudioEngine.JOB_VEHICLES = {
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
AudioEngine.PERP_STABILITY = true

for name, modelEntry in pairs(AudioEngine.CAR_MODELS) do
	local extra = { script = modelEntry[2], wheelRadius = modelEntry[3] or 0.36, perp = true }
	if not AudioEngine.PERP_STABILITY then extra.stability = false end
	AudioEngine.RegisterCarNamed(modelEntry[1], name, extra)
end

-- the handling model's tyre grip by kind of car (sh_handling.lua AudioEngine.CAR_HANDLING): the
-- high-powered cars (CAR_EMOTION) hold more, and with downforce more again at speed (1.5x at
-- 112 mph), economy cars a little less. The turn itself is every car's alike (the turn floor,
-- sh_handling.lua). Built anew on every load: kept over a Lua refresh, old values (a per-car turn
-- floor) stayed on a running server
AudioEngine.CAR_HANDLING = {}
for carName in pairs(AudioEngine.CAR_EMOTION) do AudioEngine.CAR_HANDLING[carName] = { grip = 1.3, downforce = 0.5 } end
for carName in pairs(AudioEngine.ECONOMY) do AudioEngine.CAR_HANDLING[carName] = { grip = 1.05 } end
