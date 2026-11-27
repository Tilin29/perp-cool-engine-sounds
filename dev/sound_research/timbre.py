import sys, os, re, json, glob, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); from audio import load
from scipy import signal
OCT = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
def octs(p, f): return np.array([10*np.log10(p[(f >= c/1.414) & (f < c*1.414)].sum()+1e-20) for c in OCT])
def flat(p, f, a, b):
    m = (f >= a) & (f < b); q = p[m] + 1e-20; return float(np.exp(np.mean(np.log(q)))/np.mean(q))
def describe(x, sr, frames=None):
    x = x/(np.abs(x).max()+1e-9)
    w = int(0.2*sr); n = len(x)//w
    if n < 3: return None
    seg = x[:n*w].reshape(n, w)
    lev = 10*np.log10((seg**2).mean(1)+1e-14)
    # treble transients (pops / clicks) out
    b, a = signal.butter(4, [1000, 10000], 'band', fs=sr); y = signal.filtfilt(b, a, x)[:n*w].reshape(n, w)
    crest = np.array([np.abs(r).max()/(np.sqrt((r**2).mean())+1e-12) for r in y])
    keep = (lev > np.percentile(lev, 60)) & (crest < 6)
    if frames is None and keep.sum() < 3: keep = lev > np.percentile(lev, 60)
    if frames is not None: keep = np.ones(n, bool)
    O, F1, F2, P = [], [], [], []
    for i in np.where(keep)[0]:
        f, p = signal.welch(seg[i], sr, nperseg=4096)
        o = octs(p, f); O.append(o - o[1:4].mean())
        F1.append(flat(p, f, 1000, 4000)); F2.append(flat(p, f, 4000, 8000))
        # pulsiness: 300-3000 Hz envelope (1 ms) coefficient of variation inside the frame
        bb, aa = signal.butter(2, [300, 3000], 'band', fs=sr); z = signal.lfilter(bb, aa, seg[i])
        h = int(sr*0.001); e = np.sqrt((z[:len(z)//h*h].reshape(-1, h)**2).mean(1)); P.append(np.std(e)/(np.mean(e)+1e-12))
    return dict(oct=np.median(O, 0).tolist(), flat_1_4k=float(np.median(F1)), flat_4_8k=float(np.median(F2)), pulse=float(np.median(P)), n=int(keep.sum()))
if __name__ == "__main__":
    out = {}
    mode = sys.argv[1]
    if mode == 'ref':
        for p in sys.argv[3:]:
            x, sr = load(p); d = describe(x, sr)
            if d: out[os.path.basename(p)] = d
    else:   # ours: on loops of the bands at 35-95% of redline, all banks
        root = sys.argv[3]; txt = open(os.path.join(root, 'lua/audio_engine/cl_baked.lua'), encoding='utf-8').read()
        for m in re.finditer(r'dir = "([^"]+)",\s*engine = "[^"]+",\s*layers = \{ ([^}]*) \}', txt):
            d, layers = m.group(1), [int(v) for v in m.group(2).split(',')]
            if d.startswith('ev'): continue
            for kind in ('on', 'off'):
                xs = []
                for i, r in enumerate(layers):
                    if 0.35*layers[-1] <= r <= 0.95*layers[-1]:
                        x, sr = load(os.path.join(root, 'sound/audio_engine', d, f'b{i+1}{kind}.wav')); xs.append(x/np.abs(x).max())
                dd = describe(np.concatenate(xs), 44100, frames=True)
                out[f"{d}_{kind}"] = dd
    json.dump(out, open(sys.argv[2], 'w'), indent=0)
    for k, d in out.items():
        print(f"{k[:24]:24s} oct(rel 125-500) " + ' '.join(f'{v:6.1f}' for v in d['oct']) + f" | flat1-4k {d['flat_1_4k']:.3f} 4-8k {d['flat_4_8k']:.3f} pulse {d['pulse']:.2f} n={d['n']}")
