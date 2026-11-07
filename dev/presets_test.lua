PerpAudioEngine = {}
local A = "/home/claude/addon/sl65amg_rtu/lua/audio_engine/"
dofile(A.."sh_config.lua"); dofile(A.."sh_presets.lua")
local E = PerpAudioEngine
local car = E.Cars["models/plpd/sl65amg_rtu.mdl"]
for _, p in ipairs(E.ENGINE_PRESETS) do
  local prof = E.ProfileFromPreset(p.id)
  local s = E.EncodeProfile(prof)
  local back = E.DecodeProfile(s)
  assert(E.EncodeProfile(back) == s, "roundtrip "..p.id)
  local cfg = E.ResolveProfile(car, back)
  print(string.format("%-7s %-58s %2d bands final %.2f  len %d", p.id, s, #cfg.bands, cfg.final, #s))
end
-- hostile input is clamped
local bad = E.DecodeProfile("x;rm|v99|9|9|9|1|99999|5|1|99,0.01,abc|0|-5|99|9999|7|1")
print("sanitised:", E.EncodeProfile(bad))
print("empty ->", E.DecodeProfile(""), "garbage ->", E.DecodeProfile("a|b"))
