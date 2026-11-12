--[[
	Police siren settings. Edit them in dev/siren_studio.html and paste its export over this file.

	volume       playback volume of every tone, 0..1 (x the tone's own level)
	soundLevel   Source sound level in dB: how far it carries (75 = normal speech, 90 = loud, 100+ = far)
	attack       seconds a tone takes to fade in when it starts
	release      seconds it takes to fade out when it stops or changes
	stopPitch    pitch it falls to while fading out (1 = none, 0.6 = winds down like a motor siren)
	pitch        overall pitch of every tone
	sampleRate   44100 or 22050
	lightTones   the tone each light mode starts: [1] = CODE 2, [2] = CODE 3 ("" = none)
	cycle        the tones the tone key steps through, in order (then off, then the first again)
	horn         the tone played while the horn key is held
	keys         default keys (players can rebind: police_siren_tonekey, police_siren_hornkey)

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
	volume = 0.9,
	soundLevel = 100,
	attack = 0.05,
	release = 0.5,
	stopPitch = 0.7,
	pitch = 1,
	sampleRate = 44100,
	lightTones = { "", "wail" },
	cycle = { "wail", "yelp", "phaser", "hilo" },
	horn = "horn",
	keys = { tone = "j", horn = "h" },
	tones = {
		wail = {
			name = "Wail",
			level = 1,
			pattern = {
				{ f = 1400, glide = 2, hold = 0.1, curve = 0.6 },
				{ f = 620, glide = 2.6, hold = 0.05, curve = 1.5 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.33, 0.04, 0.2, 0.03, 0.14, 0.02, 0.11, 0, 0.09, 0, 0.07 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 400, lowpass = 5500, drive = 1.5, resonance = 1100, resonanceQ = 1.4, resonanceGain = 5 },
		},
		yelp = {
			name = "Yelp",
			level = 1,
			pattern = {
				{ f = 1400, glide = 0.17, hold = 0, curve = 0.7 },
				{ f = 620, glide = 0.16, hold = 0, curve = 1.2 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.33, 0.04, 0.2, 0.03, 0.14, 0.02, 0.11, 0, 0.09, 0, 0.07 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 400, lowpass = 5500, drive = 1.5, resonance = 1100, resonanceQ = 1.4, resonanceGain = 5 },
		},
		phaser = {
			name = "Phaser",
			level = 0.9,
			pattern = {
				{ f = 1300, glide = 0.05, hold = 0, curve = 0.8 },
				{ f = 700, glide = 0.05, hold = 0, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.33, 0.04, 0.2, 0.03, 0.14, 0.02, 0.11, 0, 0.09, 0, 0.07 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 400, lowpass = 5500, drive = 1.5, resonance = 1100, resonanceQ = 1.4, resonanceGain = 5 },
		},
		hilo = {
			name = "Hi-lo",
			level = 0.9,
			pattern = {
				{ f = 960, glide = 0.01, hold = 0.45, curve = 1 },
				{ f = 770, glide = 0.01, hold = 0.45, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.05, 0.33, 0.04, 0.2, 0.03, 0.14, 0.02, 0.11, 0, 0.09, 0, 0.07 },
			voice2 = { on = false, semitones = 0, cents = 6, level = 0.6, offset = 0 },
			vibrato = { rate = 0, depth = 0 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 400, lowpass = 5500, drive = 1.5, resonance = 1100, resonanceQ = 1.4, resonanceGain = 5 },
		},
		horn = {
			name = "Air horn",
			level = 1,
			pattern = {
				{ f = 370, glide = 0, hold = 0.5, curve = 1 },
			},
			logGlide = true,
			harmonics = { 1, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.12, 0.11, 0.1, 0.09, 0.08, 0.07, 0.06, 0.05, 0.05 },
			voice2 = { on = true, semitones = 4, cents = 0, level = 0.8, offset = 0 },
			vibrato = { rate = 7, depth = 6 },
			tremolo = { rate = 0, depth = 0 },
			speaker = { highpass = 250, lowpass = 4500, drive = 3, resonance = 800, resonanceQ = 1.2, resonanceGain = 6 },
		},
	},
}
