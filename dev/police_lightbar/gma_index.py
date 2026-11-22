import struct, sys, json
path = sys.argv[1]
f = open(path, 'rb')
def cstr():
    b = bytearray()
    while True:
        c = f.read(1)
        if c in (b'\0', b''): return b.decode('utf-8', 'replace')
        b += c
assert f.read(4) == b'GMAD'
version = f.read(1)[0]
f.read(8); f.read(8)
if version > 1:
    while cstr(): pass
cstr(); cstr(); cstr(); f.read(4)
entries = []
while True:
    number = struct.unpack('<I', f.read(4))[0]
    if number == 0: break
    name = cstr(); size = struct.unpack('<q', f.read(8))[0]; f.read(4)
    entries.append((name, size))
dataStart = f.tell()
offset = 0
out = []
for name, size in entries:
    out.append((name, dataStart + offset, size)); offset += size
json.dump(out, open('index.json', 'w'))
print(len(out), 'files')
