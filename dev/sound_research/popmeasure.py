import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); from audio import load
from scipy import signal
def measure(path, min_rise=12):
    x, sr = load(path); x = x/(np.abs(x).max()+1e-9)
    b, a = signal.butter(4, [1000, 10000], 'band', fs=sr); y = signal.filtfilt(b, a, x)
    hop = int(sr*0.001); n = len(y)//hop
    e = 10*np.log10((y[:n*hop].reshape(n, hop)**2).mean(1)+1e-14)
    bg = signal.medfilt(e, 201)                      # 0.2 s running median: the engine's own treble
    rise = e - bg
    pk, _ = signal.find_peaks(rise, height=min_rise, distance=20)
    out = []
    for p in pk:
        r = rise[p]; on = p
        while on > 0 and rise[on-1] > r - 20 and p-on < 15: on -= 1
        tail = rise[p:p+400]
        d10 = np.argmax(tail < r-10) if (tail < r-10).any() else 400
        d20 = np.argmax(tail < r-20) if (tail < r-20).any() else 400
        s = x[p*hop - int(0.002*sr): p*hop + int(0.020*sr)]
        pre = x[p*hop - int(0.12*sr): p*hop - int(0.02*sr)]
        if len(s) < 256 or len(pre) < 256: continue
        f, ps = signal.welch(s, sr, nperseg=256); _, pb = signal.welch(pre, sr, nperseg=256)
        ex = np.maximum(ps - pb, 0)
        cen = (f*ex).sum()/(ex.sum()+1e-20)
        lo = ex[f < 300].sum()/(ex.sum()+1e-20)
        hi = ex[f > 4000].sum()/(ex.sum()+1e-20)
        out.append(dict(t=p/1000, rise=r, attack=p-on, d10=d10, d20=d20, cen=cen, lo=lo, hi=hi))
    return out
if __name__ == '__main__':
  for path in sys.argv[1:]:
      ps = measure(path)
      if not ps: print(os.path.basename(path), 'none'); continue
      t = np.array([q['t'] for q in ps]); iv = np.diff(t); iv = iv[iv < 1.0]
      A = lambda k: np.median([q[k] for q in ps])
      print(f"{os.path.basename(path):16s} n={len(ps):3d} rise {A('rise'):4.1f}dB attack {A('attack'):3.0f}ms decay-10dB {A('d10'):4.0f}ms -20dB {A('d20'):4.0f}ms centroid {A('cen'):5.0f}Hz <300Hz {A('lo')*100:3.0f}% >4k {A('hi')*100:3.0f}% | gaps<1s med {np.median(iv)*1000 if len(iv) else 0:4.0f}ms p10 {np.percentile(iv,10)*1000 if len(iv) else 0:4.0f} p90 {np.percentile(iv,90)*1000 if len(iv) else 0:4.0f}")
