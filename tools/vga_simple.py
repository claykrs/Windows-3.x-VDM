import struct

fb = open(r'media/win31/vga_framebuffer.bin', 'rb').read()
# VGA DAC 256-color palette (standard VGA default)
pal = []
for i in range(256):
    # simplified default VGA palette
    if i < 16:
        vga16 = [
            (0,0,0),(0,0,168),(0,168,0),(0,168,168),
            (168,0,0),(168,0,168),(168,84,0),(168,168,168),
            (84,84,84),(84,84,255),(84,168,84),(84,168,255),
            (168,84,84),(168,84,255),(168,168,84),(255,255,255)
        ]
        pal.append(vga16[i])
    else:
        r = ((i >> 5) & 7) * 36
        g = ((i >> 2) & 7) * 36
        b = (i & 3) * 85
        pal.append((r, g, b))

# try mode 13h: 320x200, linear, one byte per pixel
W, H = 320, 200
row_size = ((W * 3 + 3) // 4) * 4
img_size = row_size * H
file_size = 54 + 1024 + img_size  # header + 256-color palette + pixels

bmp = bytearray()
bmp += b'BM'
bmp += struct.pack('<I', file_size)
bmp += struct.pack('<HH', 0, 0)
bmp += struct.pack('<I', 54 + 1024)  # pixel data starts after header + palette
bmp += struct.pack('<I', 40)
bmp += struct.pack('<IiiHHIIiiII', 40, W, -H, 1, 8, 0, img_size, 0, 0, 0, 256)
for r, g, b in pal:
    bmp += bytes([b, g, r, 0])  # BMP palette is B,G,R,reserved

pixels = bytearray()
for y in range(H - 1, -1, -1):
    row_start = y * W
    pixels += fb[row_start:row_start + W]
    while len(pixels) % 4 != 0:
        pixels.append(0)

bmp += bytes(pixels)
open(r'media/win31/vga_mode13h.bmp', 'wb').write(bytes(bmp))
print(f'wrote vga_mode13h.bmp ({len(bmp)} bytes, {W}x{H})')
