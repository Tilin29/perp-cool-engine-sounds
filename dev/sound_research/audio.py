import numpy as np, subprocess, imageio_ffmpeg, soundfile as sf
from scipy import signal
FF = imageio_ffmpeg.get_ffmpeg_exe()
def load(path, sr=44100):
    if path.lower().endswith('.wav'):
        x, r = sf.read(path, always_2d=True); x = x.mean(1)
        if r != sr: x = signal.resample_poly(x, sr, r)
        return x.astype(np.float64), sr
    raw = subprocess.run([FF, '-v', 'quiet', '-i', path, '-ac', '1', '-ar', str(sr), '-f', 'f32le', '-'], capture_output=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64), sr
def db(x): return 20*np.log10(np.maximum(x, 1e-12))
def bands(x, sr, edges=(0,100,300,1000,4000,20000)):
    f, p = signal.welch(x, sr, nperseg=4096)
    tot = p.sum()
    return [10*np.log10(max(p[(f>=a)&(f<b)].sum()/tot,1e-12)) for a,b in zip(edges[:-1], edges[1:])]
def centroid(x, sr):
    f, p = signal.welch(x, sr, nperseg=4096); return (f*p).sum()/p.sum()
def envelope(x, sr, ms=1.0):
    n = max(1,int(sr*ms/1000)); e = np.sqrt(np.convolve(x*x, np.ones(n)/n, 'same')); return e
