# Runs the LED bar's skins' lens materials the way Source's proxies do (CurrentTime, Add, WrapMinMax,
# LessOrEqual) and compares every lens's frame with cl_police's pattern (isLit + the car's phase):
# the glow and the HUD follow that pattern, so they must agree. Usage: python -I check_vmts.py <materials dir> <mdl>
import sys, re, struct, math
MATERIALS, MDL = sys.argv[1], sys.argv[2]
FRAMES = {'red': 1, 'white': 2, 'blue': 3, 'yellow': 4}
SCHEMES = [('police', {-1: 'red', 0: 'white', 1: 'blue'}), ('fire', {-1: 'red', 0: 'yellow', 1: 'yellow'}), ('medical', {-1: 'red', 0: 'white', 1: 'white'})]
CODE2, CODE3, PERIODS = dict(period=1.2, onTime=0.4), dict(period=0.5, flashPeriod=0.0625, flashOnTime=0.04, centre=0.035), [1.2, 0.5]
def lens_info(name):
    if name == 'front_centre': return 0, 0
    side = -1 if '_driver_' in name else 1
    return side, (-side if name.endswith('_inner') else side)
def is_lit(side, half, mode, t):   # cl_police isLit
    if mode == 1:
        phase = t % CODE2['period']; lit_half = -1 if phase < CODE2['period'] / 2 else 1
        return side != 0 and half == lit_half and phase % (CODE2['period'] / 2) < CODE2['onTime']
    phase = t % CODE3['period']; in_half = phase % (CODE3['period'] / 2); c = CODE3['centre']
    if side == 0: return in_half < c or (2 * c < in_half < 3 * c)
    lit_half = -1 if phase < CODE3['period'] / 2 else 1
    return half == lit_half and in_half % CODE3['flashPeriod'] < CODE3['flashOnTime']
def run_vmt(path, t):
    text = open(path).read()
    vars_ = {k.lower(): v for k, v in re.findall(r'^\t"(\$\w+)" "([^"]*)"', text, re.M)}
    num = lambda x: float(vars_[x.lower()]) if x.startswith('$') else float(x)
    for kind, body in re.findall(r'^\t\t"(\w+)" \{ (.*?) \}$', text, re.M):
        a = dict(re.findall(r'"(\w+)" "([^"]*)"', body)); out = a.get('resultVar', '').lower()
        if kind == 'CurrentTime': vars_[out] = t
        elif kind == 'Add': vars_[out] = num(a['srcVar1']) + num(a['srcVar2'])
        elif kind == 'WrapMinMax':
            lo, hi = num(a['minVal']), num(a['maxVal']); vars_[out] = lo + (num(a['srcVar1']) - lo) % (hi - lo)
        elif kind == 'LessOrEqual':
            vars_[out] = num(a['lessEqualVar']) if num(a['srcVar1']) <= num(a['srcVar2']) else num(a['greaterVar'])
        else: raise SystemExit('unknown proxy ' + kind)
    return int(float(vars_['$frame']))
d = open(MDL, 'rb').read(); I = lambda o: struct.unpack_from('<i', d, o)[0]
mats = []
for i in range(I(204)):
    b = I(208) + i * 64; o = struct.unpack_from('<i', d, b)[0]; mats.append(d[b + o:d.index(b'\0', b + o)].decode())
nref, sk = I(220), I(228)
skin = lambda f: {mats[r]: mats[struct.unpack_from('<h', d, sk + (f * nref + r) * 2)[0]] for r in range(nref)}
checked = mismatches = 0
for scheme_index, (scheme, colours) in enumerate(SCHEMES):
    for mode in (1, 2):
        for phase in (0, 1):
            row = skin(1 + (scheme_index * 2 + mode - 1) * 2 + phase)
            for base, material in row.items():
                if not base.startswith('lens_'): continue
                side, half = lens_info(base[5:])
                for step in range(480):
                    t = 1000 + step * 0.005
                    tp = t + (PERIODS[mode - 1] / 2 if phase else 0)
                    want = FRAMES[colours[side]] if is_lit(side, half, mode, tp) else 0
                    # (an exact boundary instant can differ: < in Lua, <= in LessOrEqual)
                    near_edge = any(abs(is_lit(side, half, mode, tp + e) - is_lit(side, half, mode, tp)) for e in (-1e-6, 1e-6))
                    got = run_vmt(f'{MATERIALS}/{material}.vmt', t) if material.startswith('flash_') else 0
                    checked += 1
                    if got != want and not near_edge:
                        mismatches += 1
                        if mismatches < 5: print('mismatch', scheme, mode, phase, base, material, round(t, 3), got, want)
print(f'{checked} lens frames checked, {mismatches} differ from cl_police')
