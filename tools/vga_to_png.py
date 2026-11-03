import struct, sys

# vga_to_png.py -- converts VGA mode 12h framebuffer to BMP
# 640x480x16 planar: 4 planes at A0000, each 38400 bytes (640*480/8 bits)
# Reads the dumped framebuffer and produces a viewable BMP image.

fb = open(r'media/win31/vga_framebuffer.bin', 'rb').read()
W, H = 640, 480

# standard VGA 16-color palette
pal = [
    (0,0,0), (0,0,168), (0,168,0), (0,168,168),
    (168,0,0), (168,0,168), (168,84,0), (168,168,168),
    (84,84,84), (84,84,255), (84,168,84), (84,168,255),
    (168,84,84), (168,84,255), (168,168,84), (255,255,255)
]

# decode planar: 4 planes, each byte = 8 pixels (MSB = leftmost)
plane_size = (W // 8) * H
planes = []
for p in range(4):
    off = p * plane_size
    planes.append(fb[off:off+plane_size])

# BMP file header (54 bytes) + pixel data
row_size = ((W * 3 + 3) // 4) * 4
img_size = row_size * H
file_size = 54 + img_size

bmp = bytearray()
# BITMAPFILEHEADER
bmp += b'BM'
bmp += struct.pack('<I', file_size)
bmp += struct.pack('<HH', 0, 0)
bmp += struct.pack('<I', 54)
# BITMAPINFOHEADER
bmp += struct.pack('<IiiHHIIiiII', 40, W, -H, 1, 24, 0, img_size, 0, 0, 0, 0)
# palette (not needed for 24-bit, but add 16 entries)
for r, g, b in pal:
    bmp += bytes([b, g, r, 0])

# pixel data (bottom-up)
for y in range(H - 1, -1, -1):
    row_off = y * (W // 8)
    row_data = bytearray()
    for x in range(W):
        byte_off = x // 8
        bit = 7 - (x % 8)
        # read from 4 planes
        pixel = 0
        for p in range(4):
            bit_val = (planes[p][byte_off] >> bit) & 1
            pixel |= bit_val << p
        r, g, b = pal[pixel & 0xF]
        row_data += bytes([b, g, r])
    bmp += bytes(row_data)

open(r'media/win31/vga_output.bmp', 'wb').write(bytes(bmp))
print(f'wrote vga_output.bmp ({len(bmp)} bytes)')
