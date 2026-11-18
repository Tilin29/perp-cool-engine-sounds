--[[
	Car horn settings. Edit them in dev/honk_studio.html and paste its export over this file.

	volume       playback volume of every horn, 0..1 (x the horn's own level)
	soundLevel   Source sound level in dB: how far it carries (the cars' engines play at 85)
	sampleRate   44100 or 22050
	doppler      Doppler pitch shift of passing cars: 0 = off, 1 = real. Each player scales it with car_horn_doppler
	distance     the horn's own fall-off with distance, on top of the game's, in shares of the engine's audible
	             range (audio_engine_range, for a car at this soundLevel): full volume up to `full`, falling
	             evenly to `volume` at `at` and on, silent at `silent`
	limit        overuse (server convar car_horn_limit 1 = on): each player has `charge` s of horn, used up while
	             it sounds and `pressCost` s per press (tapping costs more than one blast), back at `refill` s per
	             second. Under `weakBelow` of a full charge it weakens, down to `weakVolume` x the volume and
	             `weakPitch` x the pitch at empty (a horn on a dying battery); empty, it croaks `croak` s at its
	             weakest and is silent until the charge is back to `resume` s. Held over `relaxAfter` s, it eases
	             down to `relaxVolume` x over `relaxTime` s (a stuck horn doesn't stay at full blast)
	cabin        inside the car (driver and passengers): volume x this, muffled above `muffle` Hz
	keys         default keys (honk: held down to sound the horn)
	default      the horn of a car not listed in `models`
	models       the horn per car model (lower-case model path)

	horns[id]
	  name       shown in the studio
	  level      the horn's own volume, 0..1
	  units      the horn units sounding together: f (Hz), level. A car's pair is usually a major
	             third apart (a high and a low horn), a truck's air horn two or three trumpets
	  harmonics  level of harmonic 1, 2, 3...: the diaphragm's buzz (all of them, slowly falling = brassy).
	             With resonances, keep them nearly flat and let the resonances colour it
	  strike     0..1: how sharply the diaphragm hits its stop each cycle (1 = every harmonic peaking at
	             once, a kick that sets the resonances ringing; 0 = a smooth wave)
	  rasp       noise each cycle where the diaphragm strikes its stop, 0 = clean: the grit of a cheap horn
	  air        a steady rush of air under the tone, 0 = none: an air horn's, there from the moment it's pressed
	  jitter     rate (Hz) and depth (cents) of each unit's own random pitch drift: a steady pitch sounds synthetic
	  shimmer    how much each cycle's level differs from the last, 0..1 (0 = every cycle the same)
	  roughness  how much each cycle's length differs from the last, in cents: a hard-driven diaphragm's blat
	             (what keeps an air horn from sounding like a musical chord); stronger at first while pressing
	  growl      every other cycle stronger, 0..1: a rumble an octave under the note
	  grille     the bumper and grille in front of the horn, 0..1: their short reflections colour it (0 = in free air)
	  flutter    rate (Hz) and depth (cents) of a pitch wobble (an air horn's reed)
	  resonances the horn's body: its tone disc (or a trumpet's air column) rung by every strike, at its own
	             fixed pitches whatever note the units buzz at: f (Hz), q (higher = narrower, rings longer),
	             level. This, not the harmonics, is what makes it sound like a horn rather than a note
	  direct     how much of the diaphragm's own buzz passes by the resonances (only with resonances)
	  attack     on pressing: time (s) to reach full pitch and level, starting at `pitch` x the
	             horn's, shaped by `curve` (1 = even, below 1 = fast at first, above 1 = slow at first).
	             A real electric horn is at full within ~10-15 ms with hardly any pitch rise: a long
	             scoop up to pitch is a cartoon "bwah"
	  release    on letting go: time (s) to fade out, falling to `pitch` x the horn's. An electric horn
	             stops within a few cycles at its own pitch (1): a pitch fall is a cartoon "boop"
	             (an air horn sags a little as its air runs out)
	  speaker    highpass / lowpass (Hz), drive (0 = clean, more = a harsher driver), asymmetry 0..0.9
	             (the drive clipping one way sooner: the pair's units mix, a low snarl under the note),
	             resonance (Hz), resonanceQ, resonanceGain (dB): the horn trumpet's peak
]]
CAR_HORN = CAR_HORN or {}

CAR_HORN.CONFIG = {
	volume = 0.8,
	soundLevel = 85,
	sampleRate = 44100,
	doppler = 1,
	distance = { full = 0.1, at = 0.6, volume = 0.3, silent = 1 },
	limit = { charge = 8, pressCost = 0.15, refill = 0.75, weakBelow = 0.3, weakVolume = 0.35, weakPitch = 0.94, croak = 0.15, resume = 0.5, relaxAfter = 4, relaxVolume = 0.6, relaxTime = 2 },
	cabin = { volume = 0.45, muffle = 1800 },
	keys = { honk = "lalt" },
	default = "dual",
	models = {
		["models/forest/f450_ambo.mdl"] = "american",
		["models/perp2.5/swat_van.mdl"] = "airhorn",
		["models/sickness/meatwagon.mdl"] = "american",
		["models/sickness/stretchdr_tdmcars.mdl"] = "american",
		["models/sickness/truckfire.mdl"] = "airhorn",
		["models/tdmcars/69camaro.mdl"] = "american",
		["models/tdmcars/997gt3.mdl"] = "sport",
		["models/tdmcars/alfa_stradale.mdl"] = "sport",
		["models/tdmcars/ast_db5.mdl"] = "trumpet",
		["models/tdmcars/ast_rapide.mdl"] = "trumpet",
		["models/tdmcars/aston_v12vantage.mdl"] = "trumpet",
		["models/tdmcars/audi_r8_plus.mdl"] = "sport",
		["models/tdmcars/audi_r8_spyder.mdl"] = "sport",
		["models/tdmcars/audir8.mdl"] = "sport",
		["models/tdmcars/bmw507.mdl"] = "trumpet",
		["models/tdmcars/bmw_1m.mdl"] = "trumpet",
		["models/tdmcars/bmw_340i.mdl"] = "trumpet",
		["models/tdmcars/bmw_m6_13.mdl"] = "trumpet",
		["models/tdmcars/bmwm1.mdl"] = "sport",
		["models/tdmcars/bmwm3e92.mdl"] = "trumpet",
		["models/tdmcars/bmwm5e34.mdl"] = "trumpet",
		["models/tdmcars/bmwm5e60.mdl"] = "trumpet",
		["models/tdmcars/bowler_exrs.mdl"] = "sport",
		["models/tdmcars/bug_eb110.mdl"] = "sport",
		["models/tdmcars/bug_veyron.mdl"] = "trumpet",
		["models/tdmcars/bug_veyronss.mdl"] = "trumpet",
		["models/tdmcars/cad_escalade.mdl"] = "american",
		["models/tdmcars/cayenne.mdl"] = "trumpet",
		["models/tdmcars/chargersrt8.mdl"] = "american",
		["models/tdmcars/chev_blazer.mdl"] = "american",
		["models/tdmcars/chev_c10.mdl"] = "american",
		["models/tdmcars/chev_camzl1.mdl"] = "american",
		["models/tdmcars/chev_corv_gsc.mdl"] = "american",
		["models/tdmcars/chev_impala96.mdl"] = "american",
		["models/tdmcars/chev_stingray427.mdl"] = "american",
		["models/tdmcars/chevelless.mdl"] = "american",
		["models/tdmcars/chr_300c.mdl"] = "american",
		["models/tdmcars/chr_ptcruiser.mdl"] = "american",
		["models/tdmcars/courier_truck.mdl"] = "airhorn",
		["models/tdmcars/crownvic_taxi.mdl"] = "american",
		["models/tdmcars/dbs.mdl"] = "trumpet",
		["models/tdmcars/del_dmc.mdl"] = "american",
		["models/tdmcars/dod_challenger15.mdl"] = "american",
		["models/tdmcars/dod_challenger70.mdl"] = "american",
		["models/tdmcars/dod_charger12.mdl"] = "american",
		["models/tdmcars/dodgeram.mdl"] = "american",
		["models/tdmcars/fer_250gto.mdl"] = "trumpet",
		["models/tdmcars/fer_458spid.mdl"] = "sport",
		["models/tdmcars/fer_enzo.mdl"] = "sport",
		["models/tdmcars/fer_f12.mdl"] = "sport",
		["models/tdmcars/fer_f430.mdl"] = "sport",
		["models/tdmcars/fer_f50.mdl"] = "sport",
		["models/tdmcars/fer_lafer.mdl"] = "sport",
		["models/tdmcars/ferrari250gt.mdl"] = "trumpet",
		["models/tdmcars/ferrari512tr.mdl"] = "sport",
		["models/tdmcars/for_f100.mdl"] = "american",
		["models/tdmcars/for_f350.mdl"] = "american",
		["models/tdmcars/for_f350_fru.mdl"] = "american",
		["models/tdmcars/for_f350_tow.mdl"] = "american",
		["models/tdmcars/for_mustanggt.mdl"] = "american",
		["models/tdmcars/for_raptor.mdl"] = "american",
		["models/tdmcars/ford_coupe_40.mdl"] = "american",
		["models/tdmcars/gallardo.mdl"] = "sport",
		["models/tdmcars/gmc_sierralow.mdl"] = "american",
		["models/tdmcars/gmc_syclone.mdl"] = "american",
		["models/tdmcars/gmcvan.mdl"] = "american",
		["models/tdmcars/gt05.mdl"] = "american",
		["models/tdmcars/gt3rs.mdl"] = "sport",
		["models/tdmcars/gt500.mdl"] = "american",
		["models/tdmcars/gwagon.mdl"] = "trumpet",
		["models/tdmcars/hsvgts.mdl"] = "american",
		["models/tdmcars/hsvw427.mdl"] = "american",
		["models/tdmcars/hud_hornet.mdl"] = "american",
		["models/tdmcars/hummerh1.mdl"] = "american",
		["models/tdmcars/jag_etype.mdl"] = "trumpet",
		["models/tdmcars/jag_ftype.mdl"] = "trumpet",
		["models/tdmcars/jeep_grandche.mdl"] = "american",
		["models/tdmcars/lam_gallardospyd.mdl"] = "sport",
		["models/tdmcars/lambo_diablo.mdl"] = "sport",
		["models/tdmcars/lambo_miuracon.mdl"] = "trumpet",
		["models/tdmcars/lambo_murcielagosv.mdl"] = "sport",
		["models/tdmcars/landrover.mdl"] = "trumpet",
		["models/tdmcars/landrover12.mdl"] = "trumpet",
		["models/tdmcars/lex_is300.mdl"] = "trumpet",
		["models/tdmcars/lex_isf.mdl"] = "trumpet",
		["models/tdmcars/mas_ghibli.mdl"] = "trumpet",
		["models/tdmcars/mas_quattroporte.mdl"] = "trumpet",
		["models/tdmcars/maz_furai.mdl"] = "sport",
		["models/tdmcars/mclaren_f1.mdl"] = "sport",
		["models/tdmcars/mclaren_p1.mdl"] = "sport",
		["models/tdmcars/mer_300sel.mdl"] = "trumpet",
		["models/tdmcars/mer_300slgull.mdl"] = "trumpet",
		["models/tdmcars/mer_e63.mdl"] = "trumpet",
		["models/tdmcars/mer_ml63.mdl"] = "trumpet",
		["models/tdmcars/mer_slr.mdl"] = "trumpet",
		["models/tdmcars/mer_slsamg.mdl"] = "trumpet",
		["models/tdmcars/mercedes_c32.mdl"] = "trumpet",
		["models/tdmcars/morg_aeross.mdl"] = "trumpet",
		["models/tdmcars/murcielago.mdl"] = "sport",
		["models/tdmcars/noblem600.mdl"] = "sport",
		["models/tdmcars/plpd_bearcat.mdl"] = "airhorn",
		["models/tdmcars/pon_fierogt.mdl"] = "american",
		["models/tdmcars/pon_firetransam.mdl"] = "american",
		["models/tdmcars/por_918.mdl"] = "sport",
		["models/tdmcars/por_carreragt.mdl"] = "sport",
		["models/tdmcars/por_cayenne12.mdl"] = "trumpet",
		["models/tdmcars/reventon_roadster.mdl"] = "sport",
		["models/tdmcars/she_1000.mdl"] = "american",
		["models/tdmcars/sl65amg.mdl"] = "trumpet",
		["models/tdmcars/tesla_models.mdl"] = "american",
		["models/tdmcars/vip_viper.mdl"] = "american",
		["models/tdmcars/wrangler.mdl"] = "american",
		["models/tdmcars/zondac12.mdl"] = "sport",
	},
	horns = {
		dual = {
			name = "Dual disc",
			level = 1,
			units = {
				{ f = 415, level = 1 },
				{ f = 520, level = 0.85 },
			},
			harmonics = { 1, 0.78, 0.68, 0.62, 0.57, 0.53, 0.51, 0.48, 0.46, 0.45, 0.43, 0.42, 0.41, 0.4, 0.39, 0.38, 0.37, 0.36, 0.36, 0.35, 0.34, 0.34, 0.33, 0.33 },
			strike = 1,
			rasp = 0.35,
			air = 0,
			jitter = { rate = 3, depth = 3 },
			shimmer = 0.15,
			grille = 0.6,
			roughness = 6,
			growl = 0,
			flutter = { rate = 0, depth = 0 },
			direct = 0.25,
			resonances = {
				{ f = 2350, q = 6, level = 1 },
				{ f = 3500, q = 8, level = 0.55 },
				{ f = 1100, q = 2, level = 0.35 },
			},
			attack = { time = 0.012, pitch = 0.97, curve = 0.5 },
			release = { time = 0.03, pitch = 1 },
			speaker = { highpass = 300, lowpass = 7000, drive = 3.5, asymmetry = 0.2, resonance = 2500, resonanceQ = 1.2, resonanceGain = 0 },
		},
		trumpet = {
			name = "Trumpet pair",
			level = 1,
			units = {
				{ f = 360, level = 1 },
				{ f = 452, level = 0.9 },
			},
			harmonics = { 1, 0.71, 0.58, 0.5, 0.45, 0.41, 0.38, 0.35, 0.33, 0.32, 0.3, 0.29, 0.28, 0.27, 0.26, 0.25, 0.24, 0.24, 0.23, 0.22 },
			strike = 0.8,
			rasp = 0.18,
			air = 0,
			jitter = { rate = 3, depth = 3 },
			shimmer = 0.1,
			grille = 0.5,
			roughness = 4,
			growl = 0,
			flutter = { rate = 0, depth = 0 },
			direct = 0.5,
			resonances = {
				{ f = 1250, q = 2.5, level = 1 },
				{ f = 2500, q = 4, level = 0.5 },
				{ f = 620, q = 1.5, level = 0.3 },
			},
			attack = { time = 0.015, pitch = 0.98, curve = 0.5 },
			release = { time = 0.035, pitch = 1 },
			speaker = { highpass = 200, lowpass = 6000, drive = 1.8, asymmetry = 0.2, resonance = 1300, resonanceQ = 0.9, resonanceGain = 0 },
		},
		sport = {
			name = "Sport pair",
			level = 1,
			units = {
				{ f = 500, level = 1 },
				{ f = 630, level = 0.85 },
			},
			harmonics = { 1, 0.78, 0.68, 0.62, 0.57, 0.53, 0.51, 0.48, 0.46, 0.45, 0.43, 0.42, 0.41, 0.4, 0.39, 0.38, 0.37, 0.36, 0.36, 0.35 },
			strike = 1,
			rasp = 0.3,
			air = 0,
			jitter = { rate = 3, depth = 3 },
			shimmer = 0.13,
			grille = 0.6,
			roughness = 6,
			growl = 0,
			flutter = { rate = 0, depth = 0 },
			direct = 0.25,
			resonances = {
				{ f = 3000, q = 6, level = 1 },
				{ f = 4400, q = 8, level = 0.5 },
				{ f = 1400, q = 2, level = 0.3 },
			},
			attack = { time = 0.01, pitch = 0.97, curve = 0.5 },
			release = { time = 0.025, pitch = 1 },
			speaker = { highpass = 350, lowpass = 8500, drive = 3.2, asymmetry = 0.2, resonance = 3000, resonanceQ = 1.2, resonanceGain = 0 },
		},
		american = {
			name = "American pair",
			level = 1,
			units = {
				{ f = 330, level = 1 },
				{ f = 415, level = 0.9 },
			},
			harmonics = { 1, 0.76, 0.64, 0.57, 0.53, 0.49, 0.46, 0.44, 0.42, 0.4, 0.38, 0.37, 0.36, 0.35, 0.34, 0.33, 0.32, 0.31, 0.31, 0.3, 0.3, 0.29, 0.29, 0.28 },
			strike = 0.9,
			rasp = 0.28,
			air = 0,
			jitter = { rate = 3, depth = 3 },
			shimmer = 0.13,
			grille = 0.6,
			roughness = 5,
			growl = 0,
			flutter = { rate = 0, depth = 0 },
			direct = 0.35,
			resonances = {
				{ f = 1700, q = 3.5, level = 1 },
				{ f = 2900, q = 5, level = 0.5 },
				{ f = 800, q = 2, level = 0.3 },
			},
			attack = { time = 0.014, pitch = 0.97, curve = 0.5 },
			release = { time = 0.035, pitch = 1 },
			speaker = { highpass = 220, lowpass = 6500, drive = 3.2, asymmetry = 0.2, resonance = 1900, resonanceQ = 1.1, resonanceGain = 0 },
		},
		airhorn = {
			name = "Air horn",
			level = 1,
			units = {
				{ f = 190, level = 1 },
				{ f = 246.4, level = 0.9 },
			},
			harmonics = { 0.8, 1, 0.95, 0.9, 0.82, 0.75, 0.68, 0.6, 0.53, 0.47, 0.42, 0.37, 0.33, 0.29, 0.26, 0.23, 0.2, 0.18, 0.16, 0.14, 0.12, 0.1, 0.09, 0.08 },
			strike = 0,
			rasp = 0.5,
			air = 0.04,
			jitter = { rate = 4, depth = 6 },
			shimmer = 0.2,
			grille = 0,
			roughness = 35,
			growl = 0.2,
			flutter = { rate = 0, depth = 0 },
			direct = 1,
			resonances = {},
			attack = { time = 0.12, pitch = 0.95, curve = 0.5 },
			release = { time = 0.18, pitch = 0.93 },
			speaker = { highpass = 120, lowpass = 6000, drive = 3, asymmetry = 0, resonance = 700, resonanceQ = 0.7, resonanceGain = 5 },
		},
	},
}
