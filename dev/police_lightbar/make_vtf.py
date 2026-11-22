# Builds the light bar's multi-frame lens textures: frame 0 unlit (alpha 0), 1 red, 2 white, 3 blue,
# 4 yellow (alpha 255: the self-illumination mask). VTF 7.2, BGRA8888, full mip chain.
import sys, struct
sys.path.insert(0, '.')
import imageio
FRAME_COLOURS = ['red', 'white', 'blue', 'yellow']
def half(width, height, pixels):
    # box-filter one mip level down (pixels: bytearray RGBA)
    newWidth, newHeight = max(1, width // 2), max(1, height // 2)
    out = bytearray(newWidth * newHeight * 4)
    for y in range(newHeight):
        for x in range(newWidth):
            for c in range(4):
                total = count = 0
                for dy in range(2 if height > 1 else 1):
                    for dx in range(2 if width > 1 else 1):
                        total += pixels[((y * 2 + dy) * width + x * 2 + dx) * 4 + c]; count += 1
                out[(y * newWidth + x) * 4 + c] = (total + count // 2) // count
    return newWidth, newHeight, out
def build(name, size, downloads, outPath):
    frames = []
    width, height, rows = imageio.read_bmp(f'{downloads}/{size}.bmp')
    frames.append((rows, 0))
    for colour in FRAME_COLOURS:
        w, h, r = imageio.read_png(f'{downloads}/{size}_{colour}.png')
        assert (w, h) == (width, height), (size, colour, w, h)
        frames.append((r, 255))
    # each frame's mip chain, largest first
    chains = []
    for rows, alpha in frames:
        pixels = bytearray(b''.join(rows))
        pixels[3::4] = bytes([alpha]) * (width * height)
        chain, w, h = [(width, height, pixels)], width, height
        while w > 1 or h > 1:
            w, h, pixels = half(w, h, pixels); chain.append((w, h, pixels))
        chains.append(chain)
    mipCount = len(chains[0])
    lit = chains[1][-1][2]
    reflectivity = [(lit[0] / 255) ** 2.2, (lit[1] / 255) ** 2.2, (lit[2] / 255) ** 2.2]
    header = bytearray(80)
    struct.pack_into('<4sIII', header, 0, b'VTF\0', 7, 2, 80)
    struct.pack_into('<HHI', header, 16, width, height, 0x2000 | 0x0100)    # eight-bit alpha, no LOD
    struct.pack_into('<HH', header, 24, len(frames), 0)
    struct.pack_into('<3f', header, 32, *reflectivity)
    struct.pack_into('<f', header, 48, 1.0)
    struct.pack_into('<IB', header, 52, 12, mipCount)                       # 12 = BGRA8888
    struct.pack_into('<iBBH', header, 57, -1, 0, 0, 1)                      # no low-res image, depth 1
    body = bytearray()
    for mip in reversed(range(mipCount)):                                    # smallest mip first
        for chain in chains:
            w, h, pixels = chain[mip]
            bgra = bytearray(len(pixels))
            bgra[0::4], bgra[1::4], bgra[2::4], bgra[3::4] = pixels[2::4], pixels[1::4], pixels[0::4], pixels[3::4]
            body += bgra
    open(outPath, 'wb').write(bytes(header) + bytes(body))
    print(outPath, f'{width}x{height}', len(frames), 'frames', mipCount, 'mips', len(header) + len(body), 'bytes')
    # previews of each frame to check the order
    for index, chain in enumerate(chains):
        w, h, pixels = chain[0]
        imageio.write_png(f'preview_{name}_{index}.png', w, h, [bytes(pixels[y * w * 4:(y + 1) * w * 4]) for y in range(h)])
out = sys.argv[1]
source = sys.argv[2] if len(sys.argv) > 2 else '.'
build('large', 'led_large', source, out + '/leds_large.vtf')
build('small', 'led_small', source, out + '/leds_small.vtf')
