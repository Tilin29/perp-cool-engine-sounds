--[[
	Police siren settings. Edit them in dev/siren_studio.html and paste its export over this file.

	volume       playback volume of every tone, 0..1 (x the tone's own level)
	soundLevel   Source sound level in dB: how far it carries. The cars' engines play at 85, high-powered
	             ones at 92: a few dB over the car's own keeps the siren heard first, but not much further
	soundLevels  the same per car model, for cars whose engine is louder (lower-case model path)
	doppler      Doppler pitch shift of passing cars: 0 = off, 1 = real, 0.5 = half (capped at +4 / -5 semitones).
	             Each player scales it with audio_engine_police_doppler (1 = this)
	attack       seconds a tone takes to fade in when it starts
	release      seconds it takes to fade out when it stops or changes
	stopPitch    pitch it falls to while fading out (1 = none, 0.6 = winds down like a motor siren)
	pitch        overall pitch of every tone
	sampleRate   44100 or 22050
	lightTones   the tone each light mode starts: [1] = CODE 2, [2] = CODE 3 ("" = none)
	cycle        the tones the tone key steps through, in order (then off, then the first again)
	schemes      lightTones and cycle for the other light schemes (the lights' NW2 audio_lightscheme:
	             fire, medical); a police car, or any scheme not listed, uses the two above
	cabin        inside the car (driver and passengers): volume x this, muffled above `muffle` Hz
	keys         default keys (players can rebind: police_siren_tonekey)

	tones[id]
	  name       shown in the studio
	  level      the tone's own volume, 0..1
	  pattern    the pitch over one loop, a list of points. Each glides from the previous point
	             (the last one before the first) to f (Hz) in `glide` s, shaped by `curve`
	             (1 = even, below 1 = fast at first, above 1 = slow at first), then holds `hold` s
	  logGlide   glide in musical steps (true) or in Hz (false)
	  harmonics  level of harmonic 1, 2, 3...: the tone colour (1, 0, 0.33, 0, 0.2... = square)
	  voice2     a second tone: on, semitones above the first, cents of detune, level,
	             offset = how far along the pattern it runs (0..1 of the loop)
	  vibrato    rate (Hz) and depth (cents) of a pitch wobble
	  tremolo    rate (Hz) and depth (0..1) of a volume wobble
	  speaker    highpass / lowpass (Hz), drive (0 = clean, more = a harsher driver),
	             resonance (Hz), resonanceQ, resonanceGain (dB): the horn speaker's peak
]]
POLICE_SIREN = POLICE_SIREN or {}

POLICE_SIREN.CONFIG = {
	volume = 0.75,
	soundLevel = 88,
	soundLevels = {
		["models/tdmcars/bmw_340i.mdl"] = 94,
		["models/tdmcars/bmwm5e60.mdl"] = 94,
		["models/tdmcars/cayenne.mdl"] = 94,
		["models/tdmcars/chargersrt8.mdl"] = 94,
		["models/tdmcars/sl65amg.mdl"] = 94,
	},
	doppler = 0.5,
	attack = 0.05,
	release = 0.08,
	stopPitch = 1,
	pitch = 1,
	sampleRate = 44100,
	lightTones = { "", "wail" },
	cycle = { "wail", "yelp", "phaser", "hilo" },
	schemes = {
		fire = { lightTones = { "", "firewail" }, cycle = { "firewail", "fireyelp", "firephaser" } },
		medical = { lightTones = { "", "emswail" }, cycle = { "emswail", "emsyelp", "hilo" } },
	},
	cabin = { volume = 0.35, muffle = 1400 },
	keys = { tone = "q" },
	tones = {
		wail = {
			name = "Wail",
			level = 1,
			pattern = {
				{ f = 1190, glide = 1.5, hold = 0.05, curve = 0.25 },
				{ f = 613, glide = 3.15, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.055, 0.082, 0.021, 0.024, 0.008, 0.008, 0.002, 0.002 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 300, lowpass = 8000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
		yelp = {
			name = "Yelp",
			level = 1,
			pattern = {
				{ f = 1190, glide = 0.15, hold = 0, curve = 0.5 },
				{ f = 613, glide = 0.18, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.055, 0.082, 0.021, 0.024, 0.008, 0.008, 0.002, 0.002 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 300, lowpass = 8000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
		phaser = {
			name = "Phaser",
			level = 0.9,
			pattern = {
				{ f = 1190, glide = 0.045, hold = 0, curve = 0.6 },
				{ f = 613, glide = 0.055, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.055, 0.082, 0.021, 0.024, 0.008, 0.008, 0.002, 0.002 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 300, lowpass = 8000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
		hilo = {
			name = "Hi-lo",
			level = 0.9,
			pattern = {
				{ f = 960, glide = 0.01, hold = 0.45, curve = 1 },
				{ f = 770, glide = 0.01, hold = 0.45, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.055, 0.082, 0.021, 0.024, 0.008, 0.008, 0.002, 0.002 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 300, lowpass = 8000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
		firewail = {
			name = "Fire wail",
			level = 0.9,
			pattern = {
				{ f = 1200, glide = 1.8, hold = 0.1, curve = 0.4 },
				{ f = 560, glide = 2.6, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.2, 0.03, 0.1, 0.02, 0.06, 0.01, 0.04 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 250, lowpass = 6500, drive = 0.6, resonance = 1200, resonanceQ = 1.2, resonanceGain = 3 },
		},
		fireyelp = {
			name = "Fire yelp",
			level = 0.9,
			pattern = {
				{ f = 1200, glide = 0.16, hold = 0, curve = 0.5 },
				{ f = 560, glide = 0.18, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.2, 0.03, 0.1, 0.02, 0.06, 0.01, 0.04 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 250, lowpass = 6500, drive = 0.6, resonance = 1200, resonanceQ = 1.2, resonanceGain = 3 },
		},
		firephaser = {
			name = "Fire phaser",
			level = 0.85,
			pattern = {
				{ f = 1200, glide = 0.05, hold = 0, curve = 0.6 },
				{ f = 560, glide = 0.06, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.2, 0.03, 0.1, 0.02, 0.06, 0.01, 0.04 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 250, lowpass = 6500, drive = 0.6, resonance = 1200, resonanceQ = 1.2, resonanceGain = 3 },
		},
		emswail = {
			name = "EMS wail",
			level = 1,
			pattern = {
				{ f = 1480, glide = 1.1, hold = 0.05, curve = 0.35 },
				{ f = 720, glide = 2.2, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.08, 0.12, 0.04, 0.05, 0.015, 0.015 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 9000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
		emsyelp = {
			name = "EMS yelp",
			level = 1,
			pattern = {
				{ f = 1480, glide = 0.12, hold = 0, curve = 0.5 },
				{ f = 720, glide = 0.14, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.08, 0.12, 0.04, 0.05, 0.015, 0.015 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 9000, drive = 0, resonance = 1000, resonanceQ = 1, resonanceGain = 0 },
		},
	},
}
