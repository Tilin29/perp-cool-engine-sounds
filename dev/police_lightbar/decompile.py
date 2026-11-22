# Writes the light bar's body (bodygroup "Body", Lightbar.smd) as a reference SMD in model space,
# every LED lens on its own material, and the QC to compile it.
import json, struct, collections, os
gma = open("X:/SteamLibrary/steamapps/workshop/content/4000/2897742669/content.gma", 'rb')
index = {n: (o, s) for n, o, s in json.load(open('index.json'))}
def read(name):
    o, s = index[name]; gma.seek(o); return gma.read(s)
base = 'models/perpheads/props/police_lightbar'
mdl, vvd, vtx = read(base + '.mdl'), read(base + '.vvd'), read(base + '.dx90.vtx')
I = lambda b, o: struct.unpack_from('<i', b, o)[0]
materials = []
for i in range(I(mdl, 204)):
    b = I(mdl, 208) + i * 64; off = I(mdl, b); materials.append(mdl[b + off:mdl.index(b'\0', b + off)].decode())
vertStart = I(vvd, 56)
def vertex(i):
    o = vertStart + i * 48
    return dict(bones=vvd[o + 15], bone0=vvd[o + 12], pos=struct.unpack_from('<3f', vvd, o + 16),
                normal=struct.unpack_from('<3f', vvd, o + 28), uv=struct.unpack_from('<2f', vvd, o + 40))
# the Body bodypart's one model: its meshes
bpo = I(mdl, 236); mo = bpo + I(mdl, bpo + 12)
assert mdl[mo:mo + 64].split(b'\0')[0] == b'Lightbar.smd'
meshMaterial, meshStart = [], []
for k in range(I(mdl, mo + 72)):
    me = mo + I(mdl, mo + 76) + k * 116
    meshMaterial.append(I(mdl, me)); meshStart.append(I(mdl, mo + 84) // 48 + I(mdl, me + 12))
# VTX: body part 0, model 0, LOD 0
bp = I(vtx, 32); m = bp + I(vtx, bp + 4); lod = m + I(vtx, m + 4)
triangles = []   # (material name, [3 vertex ids])
for k in range(I(vtx, lod)):
    me = lod + I(vtx, lod + 4) + k * 9
    for g in range(I(vtx, me)):
        sg = me + I(vtx, me + 4) + g * 25
        nv, vOff, ni, iOff = I(vtx, sg), I(vtx, sg + 4), I(vtx, sg + 8), I(vtx, sg + 12)
        ids = [struct.unpack_from('<H', vtx, sg + vOff + j * 9 + 4)[0] for j in range(nv)]
        idx = [struct.unpack_from('<H', vtx, sg + iOff + j * 2)[0] for j in range(ni)]
        for t in range(0, ni, 3):
            triangles.append((materials[meshMaterial[k]], [meshStart[k] + ids[idx[t + q]] for q in range(3)]))

# the game draws the original's mesh turned +90 deg about Z: (x, y) -> (-y, x) (its idle pose and poseToBone
# together; -90 was the first guess and came out back to front in game, the user). studiomdl turns a
# $staticprop's SMD +90 deg itself, so the SMD is the mesh as it is
def toModel(x, y, z): return (x, y, z)

def lensName(material, centre):
    x, y, _ = centre            # mesh frame, drawn as model (-y, x): x > 0 front (+Y), y > 0 driver's side (-X)
    side = 'driver' if y > 0 else 'passenger'
    if material == 'LEDs2':
        if abs(y) < 5: return 'lens_front_centre'
        face = 'front' if x > 0 else 'rear'
        return f'lens_{face}_{side}_' + ('inner' if abs(y) < 14.8 else 'outer')
    if x > 3: return f'lens_corner_{side}_front'
    if x < -4: return f'lens_corner_{side}_rear'
    return f'lens_corner_{side}_side'

# lens quads: the two triangles sharing an edge, named by their centre
pos = lambda v: tuple(round(c, 3) for c in vertex(v)['pos'])
lensOf = {}
lensTris = [i for i, (mat, _) in enumerate(triangles) if mat in ('LEDs', 'LEDs2')]
for i in lensTris:
    if i in lensOf: continue
    mate = next(j for j in lensTris if j != i and j not in lensOf
                and len({pos(v) for v in triangles[i][1]} & {pos(v) for v in triangles[j][1]}) >= 2)
    points = {pos(v) for t in (i, mate) for v in triangles[t][1]}
    centre = [sum(p[c] for p in points) / len(points) for c in range(3)]
    name = lensName(triangles[i][0], centre)
    assert name not in lensOf.values(), name
    lensOf[i] = lensOf[mate] = name
print(len(set(lensOf.values())), 'lenses:', sorted(set(lensOf.values())))
lensTexture = {}

lines = ['version 1', 'nodes', '  0 "root" -1', 'end', 'skeleton', 'time 0', '  0  0 0 0  0 0 0', 'end', 'triangles']
for i, (mat, ids) in enumerate(triangles):
    name = lensOf.get(i, mat)
    if i in lensOf: lensTexture[name] = 'LED_large' if mat == 'LEDs2' else 'LED_small'
    lines.append(name)
    # (an SMD triangle winds the other way round from the compiled index order)
    for v in reversed(ids):
        d = vertex(v)
        assert d['bones'] == 1 and d['bone0'] == 0, 'body vertex weighted to another bone'
        p, n = toModel(*d['pos']), toModel(*d['normal'])
        lines.append('0 %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f 0' % (*p, *n, d['uv'][0], 1 - d['uv'][1]))
lines.append('end')
os.makedirs('src', exist_ok=True)
open('src/lightbar_leds.smd', 'w').write('\n'.join(lines) + '\n')
json.dump(lensTexture, open('src/lens_textures.json', 'w'), indent=1)
print(len(triangles), 'triangles;', collections.Counter(lensOf.get(i, m) if i not in lensOf else 'lens' for i, (m, _) in enumerate(triangles)))
