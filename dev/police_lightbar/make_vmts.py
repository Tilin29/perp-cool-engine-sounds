# Writes the light bar's lens materials and the QC's skin table. The flashing lives in the VMTs: Source's
# own proxies (CurrentTime, Add, WrapMinMax, LessOrEqual) work out each lens's CODE 2 / CODE 3 pattern
# and set its texture frame (leds_<size>.vtf: 0 unlit, 1 red, 2 white, 3 blue, 4 yellow). The server
# picks the bar's skin for the car's scheme, light mode and phase (AudioEngine.LightbarSkin): phase 1 runs
# the pattern half a period later, so cars side by side alternate rather than flash together. That is
# the other wig-wag half's material, so it costs almost no materials: studiomdl allows 64 per model.
# Keep SCHEMES and the timings in step with sh_police.lua / cl_police.lua.
# Usage: python -I make_vmts.py <materials/police_lightbar> <qc to update>
import sys, re
OUT, QC = sys.argv[1], sys.argv[2]
FRAMES = {'red': 1, 'white': 2, 'blue': 3, 'yellow': 4}
SCHEMES = [('police', {-1: 'red', 0: 'white', 1: 'blue'}),
           ('fire', {-1: 'red', 0: 'yellow', 1: 'yellow'}),
           ('medical', {-1: 'red', 0: 'white', 1: 'white'})]
CODE2 = dict(period=1.2, onTime=0.4)
CODE3 = dict(period=0.5, flashPeriod=0.0625, flashOnTime=0.04, centreFlashTime=0.035)
PHASES = 2
SIDE = {'driver': -1, 'passenger': 1}
lenses = []   # (name, size, side, half)
for face in ('front', 'rear'):
    for side in ('driver', 'passenger'):
        for ring in ('inner', 'outer'):
            s = SIDE[side]
            lenses.append((f'{face}_{side}_{ring}', 'large', s, -s if ring == 'inner' else s))
lenses.append(('front_centre', 'large', 0, 0))
for side in ('driver', 'passenger'):
    for spot in ('front', 'side', 'rear'):
        lenses.append((f'corner_{side}_{spot}', 'small', SIDE[side], SIDE[side]))

def write(name, body):
    open(f'{OUT}/{name}.vmt', 'w', newline='\n').write(body)

def header(size, comment):
    return (f'// {comment}\n"VertexlitGeneric"\n{{\n\t"$basetexture" "police_lightbar/leds_{size}"\n'
            f'\t"$selfillum" "1"\n')

for name, size, _, _ in lenses:
    write(f'lens_{name}', header(size, 'a bar lens, unlit (skin 0); the lit skins swap in flash_* materials') + '\t"$frame" "0"\n}\n')

def flash(size, colour, pattern):
    # pattern: code2_a / code2_b (wig-wag halves), code3_a / code3_b (quad flashes), code3_c (centre double flash)
    lit = FRAMES[colour]
    code, part = pattern.split('_')
    timing = CODE2 if code == 'code2' else CODE3
    offset = timing['period'] / 2 if part == 'b' else 0
    v = [f'\t"$frame" "0"', f'\t"$lit" "{lit}"', '\t"$off" "0"', '\t"$time" "0"', f'\t"$offset" "{offset:.4f}"', '\t"$phase" "0"']
    p = ['\t\t"CurrentTime" { "resultVar" "$time" }',
         '\t\t"Add" { "srcVar1" "$time" "srcVar2" "$offset" "resultVar" "$time" }',
         f'\t\t"WrapMinMax" {{ "srcVar1" "$time" "minVal" "0" "maxVal" "{timing["period"]}" "resultVar" "$phase" }}']
    if code == 'code2':
        # lit for onTime at the start of its half
        v.append(f'\t"$ontime" "{timing["onTime"]}"')
        p.append('\t\t"LessOrEqual" { "srcVar1" "$phase" "srcVar2" "$ontime" "lessEqualVar" "$lit" "greaterVar" "$off" "resultVar" "$frame" }')
    elif part in ('a', 'b'):
        # quick flashes through the first half of the period (0.1 ms short of it: LessOrEqual is <=, cl_police <)
        v += ['\t"$flash" "0"', '\t"$flashstate" "0"', f'\t"$flashperiod" "{timing["flashPeriod"]}"', f'\t"$flashon" "{timing["flashOnTime"]}"',
              f'\t"$half" "{timing["period"] / 2 - 0.0001:.4f}"']
        p += ['\t\t"WrapMinMax" { "srcVar1" "$phase" "minVal" "0" "maxVal" "$flashperiod" "resultVar" "$flash" }',
              '\t\t"LessOrEqual" { "srcVar1" "$flash" "srcVar2" "$flashon" "lessEqualVar" "$lit" "greaterVar" "$off" "resultVar" "$flashstate" }',
              '\t\t"LessOrEqual" { "srcVar1" "$phase" "srcVar2" "$half" "lessEqualVar" "$flashstate" "greaterVar" "$off" "resultVar" "$frame" }']
    else:
        # centre: a double flash at the start of each half: on to t, off to 2t, on to 3t
        t = timing['centreFlashTime']
        v += ['\t"$inhalf" "0"', '\t"$second" "0"', '\t"$gap" "0"', f'\t"$t1" "{t}"', f'\t"$t2" "{2 * t}"', f'\t"$t3" "{3 * t}"']
        p += [f'\t\t"WrapMinMax" {{ "srcVar1" "$phase" "minVal" "0" "maxVal" "{timing["period"] / 2}" "resultVar" "$inhalf" }}',
              '\t\t"LessOrEqual" { "srcVar1" "$inhalf" "srcVar2" "$t3" "lessEqualVar" "$lit" "greaterVar" "$off" "resultVar" "$second" }',
              '\t\t"LessOrEqual" { "srcVar1" "$inhalf" "srcVar2" "$t2" "lessEqualVar" "$off" "greaterVar" "$second" "resultVar" "$gap" }',
              '\t\t"LessOrEqual" { "srcVar1" "$inhalf" "srcVar2" "$t1" "lessEqualVar" "$lit" "greaterVar" "$gap" "resultVar" "$frame" }']
    name = f'flash_{size}_{colour}_{pattern}'
    write(name, header(size, f'a lit lens: {colour}, {pattern.replace("_", " ")} (made by dev/police_lightbar/make_vmts.py)')
          + '\n'.join(v) + '\n\t"Proxies"\n\t{\n' + '\n'.join(p) + '\n\t}\n}\n')
    return name

made = set()
rows = [[f'lens_{name}' for name, _, _, _ in lenses]]
for scheme, colours in SCHEMES:
    for code in ('code2', 'code3'):
        for phase in range(PHASES):
            row = []
            for name, size, side, half in lenses:
                if side == 0:
                    # (the centre's double flash repeats every half period: the same in both phases)
                    pattern = 'code3_c' if code == 'code3' else None
                else:
                    # phase 1: half a period later = the other half's timing
                    first = (half == -1) != (phase == 1)
                    pattern = code + ('_a' if first else '_b')
                if pattern is None:
                    row.append(f'lens_{name}')
                else:
                    material = f'flash_{size}_{colours[side]}_{pattern}'
                    if material not in made:
                        flash(size, colours[side], pattern); made.add(material)
                    row.append(material)
            rows.append(row)
group = ('$texturegroup "skinfamilies"\n{\n' + '\n'.join('\t{ ' + ' '.join(f'"{m}"' for m in row) + ' }' for row in rows) + '\n}\n')
qc = open(QC).read()
qc = re.sub(r'\$texturegroup "skinfamilies"\n\{\n.*?\n\}\n', '', qc, flags=re.S)
qc = qc.replace('$sequence', group + '$sequence', 1)
open(QC, 'w', newline='\n').write(qc)
print(len(lenses), 'lenses,', len(made), 'flash materials,', len(rows), 'skins,', len(lenses) + 2 + len(made), 'materials in the model (max 64)')
