--[[
	Police siren settings. Edit them in dev/siren_studio.html and paste its export over this file.

	volume       playback volume of every tone, 0..1 (x the tone's own level)
	soundLevel   Source sound level in dB: how far it carries. The cars' engines play at 85, high-powered
	             ones at 92: a little over that keeps the siren to just past the car's own sound
	doppler      Doppler pitch shift of passing cars: 0 = off, 1 = real (capped at about 5 semitones)
	attack       seconds a tone takes to fade in when it starts
	release      seconds it takes to fade out when it stops or changes
	stopPitch    pitch it falls to while fading out (1 = none, 0.6 = winds down like a motor siren)
	pitch        overall pitch of every tone
	sampleRate   44100 or 22050
	lightTones   the tone each light mode starts: [1] = CODE 2, [2] = CODE 3 ("" = none)
	cycle        the tones the tone key steps through, in order (then off, then the first again)
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
	soundLevel = 94,
	doppler = 1,
	attack = 0.05,
	release = 0.5,
	stopPitch = 0.7,
	pitch = 1,
	sampleRate = 44100,
	lightTones = { "", "wail" },
	cycle = { "wail", "yelp", "phaser", "hilo" },
	cabin = { volume = 0.35, muffle = 1400 },
	keys = { tone = "q" },
	tones = {
		wail = {
			name = "Wail",
			level = 1,
			pattern = {
				{ f = 1247.19, glide = 2, hold = 0.09, curve = 0.6 },
				{ f = 552.36, glide = 2.08, hold = 0.041, curve = 1.6 },
			},
			logGlide = true,
			harmonics = { 1, 0.03, 0.2, 0.02, 0.09, 0.01, 0.04, 0, 0.02 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 3200, drive = 0.8, resonance = 950, resonanceQ = 1, resonanceGain = 3 },
		},
		yelp = {
			name = "Yelp",
			level = 1,
			pattern = {
				{ f = 1400, glide = 0.17, hold = 0, curve = 0.7 },
				{ f = 620, glide = 0.16, hold = 0, curve = 1.2 },
			},
			logGlide = true,
			harmonics = { 1, 0.03, 0.2, 0.02, 0.09, 0.01, 0.04, 0, 0.02 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 3200, drive = 0.8, resonance = 950, resonanceQ = 1, resonanceGain = 3 },
		},
		phaser = {
			name = "Phaser",
			level = 0.9,
			pattern = {
				{ f = 1300, glide = 0.05, hold = 0, curve = 0.8 },
				{ f = 700, glide = 0.05, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.03, 0.2, 0.02, 0.09, 0.01, 0.04, 0, 0.02 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 3200, drive = 0.8, resonance = 950, resonanceQ = 1, resonanceGain = 3 },
		},
		hilo = {
			name = "Hi-lo",
			level = 0.9,
			pattern = {
				{ f = 960, glide = 0.01, hold = 0.45, curve = 1 },
				{ f = 770, glide = 0.01, hold = 0.45, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.03, 0.2, 0.02, 0.09, 0.01, 0.04, 0, 0.02 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 350, lowpass = 3200, drive = 0.8, resonance = 950, resonanceQ = 1, resonanceGain = 3 },
		},
	},
}
