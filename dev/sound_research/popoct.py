import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); from audio import load
from popmeasure import measure
from scipy import signal
OCT = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
def octs(seg, sr):
    f, p = signal.welch(seg, sr, nperseg=min(len(seg), 1024))
    return np.array([10*np.log10(p[(f >= c/1.414) & (f < c*1.414)].sum()+1e-20) for c in OCT])
mode = sys.argv[1]
for path in sys.argv[2:]:
    x, sr = load(path); x = x/(np.abs(x).max()+1e-9)
    if mode == 'ref':
        ps = [q for q in measure(path) if q['rise'] > 16]
        ex, ab = [], []
        for q in ps:
            i = int(q['t']*sr)
            a = octs(x[i-int(0.002*sr): i+int(0.025*sr)], sr); b = octs(x[i-int(0.15*sr): i-int(0.03*sr)], sr)
            ex.append(a-b); ab.append(a - a.max())
        if not ex: print(os.path.basename(path), 'none'); continue
        ex = np.median(ex, 0); ab = np.median(ab, 0)
        print(f"{os.path.basename(path):14s} n={len(ps):3d} over-engine dB " + ' '.join(f'{v:5.1f}' for v in ex) + ' | shape ' + ' '.join(f'{v:5.1f}' for v in ab))
    else:
        e = np.abs(x); i = int(np.argmax(e))
        a = octs(x[max(0, i-int(0.002*sr)): i+int(0.025*sr)], sr); w = octs(x, sr)
        print(f"{os.path.basename(os.path.dirname(path))[:8]+'/'+os.path.basename(path):18s} first 25ms shape " + ' '.join(f'{v-a.max():5.1f}' for v in a) + ' | whole file ' + ' '.join(f'{v-w.max():5.1f}' for v in w))
print('octaves:', OCT)
