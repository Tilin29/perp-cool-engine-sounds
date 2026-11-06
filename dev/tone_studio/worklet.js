/*
  Tone Studio audio output: a ring buffer the worker fills straight through a MessagePort, so a busy
  page can't starve it. Reports how far it has played; the worker keeps its lead from that.
*/
class LiveOut extends AudioWorkletProcessor {
  constructor() {
    super()
    this.ring = new Float32Array(1 << 16)
    this.read = 0; this.write = 0
    this.played = 0; this.under = 0; this.since = 0
    this.primed = false; this.fade = 0; this.last = 0
    this.port.onmessage = (e) => {
      if (e.data.flush) {
        this.read = this.write; this.played = 0; this.under = 0; this.primed = false
        return
      }
      this.out = e.data.port
      this.out.onmessage = (m) => this.push(m.data)
    }
  }
  push(d) {
    const mask = this.ring.length - 1
    for (let i = 0; i < d.length; i++) this.ring[this.write++ & mask] = d[i]
  }
  process(_, outputs) {
    const o = outputs[0][0], n = o.length, mask = this.ring.length - 1
    const have = this.write - this.read
    // wait for a little queue after running dry, so it doesn't stutter sample by sample
    if (!this.primed && have >= 2048) { this.primed = true; this.fade = 0 }
    if (this.primed && have >= n) {
      for (let i = 0; i < n; i++) {
        if (this.fade < 1) this.fade = Math.min(1, this.fade + 1 / 256)
        this.last = o[i] = this.ring[this.read++ & mask] * this.fade
      }
      this.played += n
    } else {
      if (this.primed) { this.primed = false; this.under++ }
      // ease out of the last sample instead of dropping to zero
      for (let i = 0; i < n; i++) { this.last *= 0.97; o[i] = this.last }
    }
    if (this.out && ++this.since >= 8) {
      this.since = 0
      this.out.postMessage({ played: this.played, under: this.under })
    }
    return true
  }
}
registerProcessor('live-out', LiveOut)
