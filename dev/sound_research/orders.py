"""Order analysis of a steady segment: rpm (given or found), firing vs other engine orders, line sharpness."""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); from audio import load
from scipy import signal
def spectrum(x, sr):
    n = 1 << int(np.log2(min(len(x), sr*4)))
    f, p = signal.welch(x, sr, nperseg=n, noverlap=n//2, window='blackmanharris')
    return f, p
def amp_at(f, p, freqs, bw):
    # max power within +-bw Hz of each frequency
    out = []
    for c in freqs:
        m = (f >= c-bw) & (f <= c+bw); out.append(p[m].max() if m.any() else 0)
    return np.array(out)
def find_rpm(f, p, lo=550, hi=9000, fmax=2500):
    best, br = -1e9, 0
    lp = np.log(p + 1e-20)
    for rpm in np.geomspace(lo, hi, 1500):
        h = rpm/120; k = np.arange(1, int(fmax/h)+1)
        if len(k) < 6: continue
        on = np.interp(k*h, f, lp).mean(); off = np.interp((k-0.5)*h, f, lp).mean()
        if on - off > best: best, br = on - off, rpm
    return br, best
def analyse(x, sr, cyl, rpm=None):
    f, p = spectrum(x, sr)
    conf = None
    if rpm is None: rpm, conf = find_rpm(f, p)
    h = rpm/120                                   # half-order spacing, Hz
    res = {"rpm": rpm, "conf": conf}
    for name, a, b in (("300-3k", 300, 3000), ("1k-4k", 1000, 4000)):
        k = np.arange(max(1, int(a/h)), int(b/h)+1); orders = k/2
        amps = amp_at(f, p, k*h, max(1.0, 0.12*h))
        firing = np.isclose(orders % (cyl/2), 0) | np.isclose(orders % (cyl/2), cyl/2)
        res[f"nonfiring_vs_firing_{name}"] = 10*np.log10(amps[~firing].mean()/(amps[firing].mean()+1e-20)+1e-12)
        # line sharpness: order peaks over the floor midway between half orders
        floor = np.interp((k+0.5)*h, f, p)
        res[f"line_over_floor_{name}"] = float(np.median(10*np.log10(amps/(floor+1e-20)+1e-12)))
    return res
if __name__ == "__main__":
    path, cyl, t0, t1 = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    rpm = float(sys.argv[5]) if len(sys.argv) > 5 else None
    x, sr = load(path); x = x[int(t0*sr): int(t1*sr) if t1 > 0 else None]
    r = analyse(x, sr, cyl, rpm)
    print(f"{os.path.basename(path)[:26]:26s} {t0:5.1f}-{t1:5.1f}s rpm {r['rpm']:6.0f}{'' if r['conf'] is None else f' (found, conf {r[chr(99)+chr(111)+chr(110)+chr(102)]:.2f})':22s} non-firing vs firing orders 300-3k {r['nonfiring_vs_firing_300-3k']:6.1f} dB, 1-4k {r['nonfiring_vs_firing_1k-4k']:6.1f} dB | order lines over floor 300-3k {r['line_over_floor_300-3k']:5.1f} dB, 1-4k {r['line_over_floor_1k-4k']:5.1f} dB")
