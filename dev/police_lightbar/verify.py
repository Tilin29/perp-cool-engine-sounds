import json, struct, collections
I = lambda b, o: struct.unpack_from('<i', b, o)[0]
def load(mdl, vvd, vtx):
    materials = []
    for i in range(I(mdl, 204)):
        b = I(mdl, 208) + i * 64; off = I(mdl, b); materials.append(mdl[b + off:mdl.index(b'\0', b + off)].decode())
    # bone 0 rotation (radians), to draw vertices as the game does
    rotation = struct.unpack_from('<3f', mdl, I(mdl, 160) + 60)
    vs = I(vvd, 56)
    vert = lambda i: struct.unpack_from('<3f', vvd, vs + i * 48 + 16)
    bpo = I(mdl, 236); mo = bpo + I(mdl, bpo + 12)
    meshMat, meshStart = [], []
    for k in range(I(mdl, mo + 72)):
        me = mo + I(mdl, mo + 76) + k * 116
        meshMat.append(I(mdl, me)); meshStart.append(I(mdl, mo + 84) // 48 + I(mdl, me + 12))
    bp = I(vtx, 32); m = bp + I(vtx, bp + 4); lod = m + I(vtx, m + 4)
    out = []
    for k in range(I(vtx, lod)):
        me = lod + I(vtx, lod + 4) + k * 9
        for g in range(I(vtx, me)):
            sg = me + I(vtx, me + 4) + g * 25
            nv, vOff, ni, iOff = I(vtx, sg), I(vtx, sg + 4), I(vtx, sg + 8), I(vtx, sg + 12)
            ids = [struct.unpack_from('<H', vtx, sg + vOff + j * 9 + 4)[0] for j in range(nv)]
            idx = [struct.unpack_from('<H', vtx, sg + iOff + j * 2)[0] for j in range(ni)]
            for t in range(0, ni, 3):
                out.append((materials[meshMat[k]], [vert(meshStart[k] + ids[idx[t + q]]) for q in range(3)]))
    return materials, rotation, out
gma = open("X:/SteamLibrary/steamapps/workshop/content/4000/2897742669/content.gma", 'rb')
index = {n: (o, s) for n, o, s in json.load(open('index.json'))}
def read(name):
    o, s = index[name]; gma.seek(o); return gma.read(s)
b = 'models/perpheads/props/police_lightbar'
oMats, _, orig = load(read(b + '.mdl'), read(b + '.vvd'), read(b + '.dx90.vtx'))
n = 'X:/SteamLibrary/steamapps/common/GarrysMod/garrysmod/addons/cool_engine_sounds_perpcars/addons/police_lightbar/models/perpheads/props/police_lightbar_leds'
nMats, nRot, new = load(open(n + '.mdl', 'rb').read(), open(n + '.vvd', 'rb').read(), open(n + '.dx90.vtx', 'rb').read())
import math
oRot = (0, 0, math.pi / 2)   # the original is drawn turned +90 (mesh (x, y) -> (-y, x))
print('new root rotation', [round(r, 4) for r in nRot])
print('new materials', nMats)
import math
def draw(p, rot):   # yaw only
    c, s = math.cos(rot[2]), math.sin(rot[2])
    return (round(p[0] * c - p[1] * s, 2), round(p[0] * s + p[1] * c, 2), round(p[2], 2))
def canon(tri):     # rotation-invariant but winding-sensitive
    k = min(range(3), key=lambda i: tri[i]); return tuple(tri[k:] + tri[:k])
o = collections.Counter(canon([draw(p, oRot) for p in t]) for _, t in orig)
nw = collections.Counter(canon([draw(p, nRot) for p in t]) for _, t in new)
flipped = collections.Counter(canon([draw(p, nRot) for p in reversed(t)]) for _, t in new)
print('triangles', sum(o.values()), sum(nw.values()), ' same winding', sum((o & nw).values()), ' reversed', sum((o & flipped).values()))
lens = collections.Counter(m for m, _ in new if m.startswith('lens'))
print('lens materials with 2 triangles each:', len(lens), set(lens.values()))

# every lens where sh_police's module table says (model space: front +Y, driver's side -X)
table = {}
for face_side in (1, -1):
    face = 'front' if face_side > 0 else 'rear'
    if face_side > 0: table['lens_front_centre'] = (0, 7.6)
    for side, name in ((-1, 'driver'), (1, 'passenger')):
        table[f'lens_{face}_{name}_inner'] = (10 * side, 7.6 * face_side)
        table[f'lens_{face}_{name}_outer'] = (19.35 * side, 7.6 * face_side)
for side, name in ((-1, 'driver'), (1, 'passenger')):
    table[f'lens_corner_{name}_front'] = (26.7 * side, 5.2)
    table[f'lens_corner_{name}_side'] = (29.6 * side, -1)
    table[f'lens_corner_{name}_rear'] = (26.6 * side, -6.2)
worst = 0
for material in sorted(table):
    pts = [p for m, t in new if m == material for p in t]
    cx, cy = sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
    dist = math.hypot(cx - table[material][0], cy - table[material][1]); worst = max(worst, dist)
    if dist > 1.5: print('  far from the table:', material, (round(cx, 1), round(cy, 1)), table[material])
print('lens centres vs the module table: worst', round(worst, 2), 'units')
