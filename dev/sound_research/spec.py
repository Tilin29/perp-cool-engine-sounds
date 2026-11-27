import sys, os, numpy as np, matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
sys.path.insert(0, os.path.dirname(__file__)); from audio import load
from scipy import signal
def plot(path, out, t0=0, t1=None, fmax=8000, nfft=2048, title=None, grid=False):
    x, sr = load(path); t1 = t1 or len(x)/sr
    x = x[int(t0*sr):int(t1*sr)]
    fig, ax = plt.subplots(2, 1, figsize=(14, 6.5), sharex=True, gridspec_kw={'height_ratios': [3, 1]})
    f, t, Z = signal.stft(x, sr, nperseg=nfft, noverlap=nfft*7//8)
    S = 20*np.log10(np.abs(Z)+1e-9); S -= S.max()
    m = f <= fmax
    ax[0].pcolormesh(t+t0, f[m], S[m], vmin=-80, vmax=0, cmap='magma', shading='auto')
    ax[0].set_ylabel('Hz')
    if grid: ax[0].grid(alpha=0.35, color='w', lw=0.4); ax[0].minorticks_on(); ax[0].grid(which='minor', alpha=0.15, color='w', lw=0.3); ax[0].set_title(title or os.path.basename(path))
    hop = int(sr*0.002); n = len(x)//hop
    e = 10*np.log10((x[:n*hop].reshape(n, hop)**2).mean(1)+1e-12)
    b, a = signal.butter(4, [1000, 8000], 'band', fs=sr); y = signal.filtfilt(b, a, x)
    eh = 10*np.log10((y[:n*hop].reshape(n, hop)**2).mean(1)+1e-12)
    tt = np.arange(n)*0.002 + t0
    ax[1].plot(tt, e - e.max(), lw=0.6, label='broadband'); ax[1].plot(tt, eh - e.max(), lw=0.6, label='1-8 kHz')
    ax[1].set_ylim(-70, 2); ax[1].legend(loc='lower right', fontsize=7); ax[1].set_xlabel('s'); ax[1].grid(alpha=0.3)
    plt.tight_layout(); plt.savefig(out, dpi=80); plt.close()
if __name__ == "__main__":
    a = sys.argv
    plot(a[1], a[2], float(a[3]) if len(a) > 3 else 0, float(a[4]) if len(a) > 4 and a[4] != '-' else None, float(a[5]) if len(a) > 5 else 8000, title=a[6] if len(a) > 6 else None, nfft=int(a[7]) if len(a) > 7 else 2048, grid=True)
