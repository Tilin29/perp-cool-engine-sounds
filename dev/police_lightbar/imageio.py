# Plain-Python PNG / BMP reading, PNG writing (no PIL here). Images are (width, height, rows of RGBA bytes).
import struct, zlib
def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, width = 8, b'', None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8]); chunk = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            width, height, depth, colorType, _, _, interlace = struct.unpack('>IIBBBBB', chunk)
            assert depth == 8 and interlace == 0 and colorType in (2, 6)
        elif kind == b'IDAT': idat += chunk
        pos += 12 + length
    channels = 3 if colorType == 2 else 4
    raw = zlib.decompress(idat); stride = width * channels
    rows, previous, offset = [], bytearray(stride), 0
    for y in range(height):
        kind = raw[offset]; line = bytearray(raw[offset + 1:offset + 1 + stride]); offset += 1 + stride
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]; upLeft = previous[i - channels] if i >= channels else 0
            if kind == 1: line[i] = (line[i] + left) & 255
            elif kind == 2: line[i] = (line[i] + up) & 255
            elif kind == 3: line[i] = (line[i] + ((left + up) >> 1)) & 255
            elif kind == 4:
                p = left + up - upLeft; pa, pb, pc = abs(p - left), abs(p - up), abs(p - upLeft)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else (up if pb <= pc else upLeft))) & 255
        previous = line
        if channels == 3:
            rgba = bytearray(width * 4)
            rgba[0::4], rgba[1::4], rgba[2::4] = line[0::3], line[1::3], line[2::3]
            rgba[3::4] = b'\xff' * width
            line = rgba
        rows.append(bytes(line))
    return width, height, rows
def read_bmp(path):
    data = open(path, 'rb').read()
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18); bpp = struct.unpack_from('<H', data, 28)[0]
    assert bpp == 32
    rows = []
    for y in range(abs(height)):
        row = data[offset + y * width * 4: offset + (y + 1) * width * 4]
        rgba = bytearray(width * 4)
        rgba[0::4], rgba[1::4], rgba[2::4], rgba[3::4] = row[2::4], row[1::4], row[0::4], row[3::4]
        rows.append(bytes(rgba))
    if height > 0: rows.reverse()
    return width, abs(height), rows
def write_png(path, width, height, rows):
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(kind, body): return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
