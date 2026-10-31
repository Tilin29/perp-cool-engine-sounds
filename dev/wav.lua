local W = {}
function W.write(path, data, sr, gain)
  gain = gain or 1
  local n = #data
  local f = assert(io.open(path, "wb"))
  local function u32(x) return string.char(x % 256, math.floor(x/256)%256, math.floor(x/65536)%256, math.floor(x/16777216)%256) end
  local function u16(x) return string.char(x % 256, math.floor(x/256)%256) end
  f:write("RIFF", u32(36 + n*2), "WAVE", "fmt ", u32(16), u16(1), u16(1), u32(sr), u32(sr*2), u16(2), u16(16), "data", u32(n*2))
  local parts = {}
  for i = 1, n do
    local v = math.floor(math.max(-1, math.min(1, data[i]*gain)) * 32767 + 0.5)
    if v < 0 then v = v + 65536 end
    parts[#parts+1] = string.char(v % 256, math.floor(v/256))
    if #parts >= 4096 then f:write(table.concat(parts)); parts = {} end
  end
  f:write(table.concat(parts)); f:close()
end
return W
