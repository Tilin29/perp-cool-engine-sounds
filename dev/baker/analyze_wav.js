/*
  Loudness and pitch of baked WAVs, to check a re-bake by ear-free numbers.
    node analyze_wav.js <file.wav | folder>...
  Per file: length, rms (dBFS), peak, the strongest frequency (50 Hz-8 kHz) and the spectral
  centroid, and how much of the energy sits above 1 kHz (how bright it is). Folders list their b<N>on loops in band order.
*/
const fs = require('fs')
const path = require('path')

function readWav(file) {
  const b = fs.readFileSync(file)
  let p = 12, rate = 44100, data = null
  while (p + 8 <= b.length) {
    const id = b.toString('ascii', p, p + 4), size = b.readUInt32LE(p + 4)
    if (id === 'fmt ') rate = b.readUInt32LE(p + 12)
    if (id === 'data') {
      data = new Float32Array(size / 2)
      for (let i = 0; i < data.length; i++) data[i] = b.readInt16LE(p + 8 + i * 2) / 32768
    }
    p += 8 + size + (size & 1)
  }
  return { rate, data }
}

// Goertzel power at frequency f over a window
function power(x, rate, f) {
  const k = 2 * Math.cos(2 * Math.PI * f / rate)
  let s1 = 0, s2 = 0
  for (let i = 0; i < x.length; i++) { const s = x[i] + k * s1 - s2; s2 = s1; s1 = s }
  return s1 * s1 + s2 * s2 - k * s1 * s2
}

function analyze(file) {
  const { rate, data } = readWav(file)
  let sq = 0, pk = 0
  for (const v of data) { sq += v * v; pk = Math.max(pk, Math.abs(v)) }
  const rms = Math.sqrt(sq / data.length)
  // a Hann-windowed 8192-sample slice from the middle
  const n = Math.min(8192, data.length), o = Math.floor((data.length - n) / 2)
  const w = new Float32Array(n)
  for (let i = 0; i < n; i++) w[i] = data[o + i] * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (n - 1)))
  let best = 0, bestF = 0, num = 0, den = 0, hi = 0
  for (let f = 50; f <= 8000; f += f < 1000 ? 5 : 20) {
    const pw = power(w, rate, f)
    if (pw > best) { best = pw; bestF = f }
    num += f * pw; den += pw
    if (f >= 1000) hi += pw
  }
  return { len: data.length / rate, db: 20 * Math.log10(rms + 1e-9), pk, peakF: bestF, centroid: den > 0 ? num / den : 0, hiDb: 10 * Math.log10((hi + 1e-12) / (den + 1e-12)) }
}

function row(name, a) {
  console.log(`${name.padEnd(14)} ${a.len.toFixed(2).padStart(5)} s  rms ${a.db.toFixed(1).padStart(6)} dBFS  peak ${a.pk.toFixed(2)}  ` +
    `strongest ${String(a.peakF).padStart(5)} Hz  centroid ${Math.round(a.centroid).toString().padStart(5)} Hz  above 1 kHz ${a.hiDb.toFixed(1).padStart(6)} dB`)
}

for (const arg of process.argv.slice(2)) {
  if (fs.statSync(arg).isDirectory()) {
    console.log(arg)
    const files = fs.readdirSync(arg).filter((f) => /^b\d+on\.wav$/.test(f))
      .sort((a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1)))
    for (const f of files) row(f, analyze(path.join(arg, f)))
  } else {
    row(path.basename(arg), analyze(arg))
  }
}
