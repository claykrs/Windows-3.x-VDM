--!nonstrict
-- vga_test.lua -- standalone diagnostics for core/Vga.lua.
-- Sets mode 12h, draws the planar test pattern, exercises the register paths,
-- and writes PPM files so the result can be inspected without Roblox.

const fs = require("@lune/fs")
const Memory = require("../core/Memory")
const Vga = require("../core/Vga")

const MODE12_PPM = "tools/vga_test.ppm"
const MODE13_PPM = "tools/vga_test_mode13.ppm"
const TEXT_PPM = "tools/vga_test_text.ppm"

local function pixelAt(
	rgba: buffer,
	width: number,
	x: number,
	y: number
): (number, number, number, number)
	const offset = (y * width + x) * 4
	return buffer.readu8(rgba, offset),
		buffer.readu8(rgba, offset + 1),
		buffer.readu8(rgba, offset + 2),
		buffer.readu8(rgba, offset + 3)
end

local function stats(rgba: buffer, width: number, height: number): (number, number)
	local nonBlack = 0
	local colors = {}
	local count = 0
	for index = 0, width * height - 1 do
		const offset = index * 4
		const red = buffer.readu8(rgba, offset)
		const green = buffer.readu8(rgba, offset + 1)
		const blue = buffer.readu8(rgba, offset + 2)
		if red ~= 0 or green ~= 0 or blue ~= 0 then
			nonBlack += 1
		end
		const key = red * 65536 + green * 256 + blue
		if not colors[key] then
			colors[key] = true
			count += 1
		end
	end
	return nonBlack, count
end

local function writePpm(path: string, rgba: buffer, width: number, height: number)
	const rgb = buffer.create(width * height * 3)
	for index = 0, width * height - 1 do
		buffer.copy(rgb, index * 3, rgba, index * 4, 3)
	end
	const header = string.format("P6\n%d %d\n255\n", width, height)
	fs.writeFile(path, header .. buffer.tostring(rgb))
end

local function outRegister(vga: any, port: number, index: number, value: number)
	vga:out8(port, index)
	vga:out8(port + 1, value)
end

local function inRegister(vga: any, port: number, index: number): number
	vga:out8(port, index)
	return vga:in8(port + 1)
end

local function assertPixel(
	rgba: buffer,
	width: number,
	x: number,
	y: number,
	expectedR: number,
	expectedG: number,
	expectedB: number,
	label: string
)
	const red, green, blue = pixelAt(rgba, width, x, y)
	assert(
		red == expectedR and green == expectedG and blue == expectedB,
		string.format(
			"%s: got (%d,%d,%d), expected (%d,%d,%d)",
			label,
			red,
			green,
			blue,
			expectedR,
			expectedG,
			expectedB
		)
	)
end

const mem = Memory.new()
const vga = Vga.new(mem)

-- ---------------------------------------------------------------- mode 12h
assert(vga:mode() == 0x03, "VGA should power up in text mode 3")
assert(vga:setMode(0x12), "mode 12h should be supported")
assert(vga:mode() == 0x12, "mode register should be 12h")
assert(vga:width() == 640 and vga:height() == 480, "mode 12h geometry")
vga:fillTestPattern()

assert(Vga.containsAddress(0xA0000), "aperture start should be routed")
assert(Vga.containsAddress(0xAFFFF), "aperture end should be routed")
assert(not Vga.containsAddress(0xB0000), "B0000 is outside the VGA aperture")

const rgba = vga:snapshotRGBA()
assert(buffer.len(rgba) == 640 * 480 * 4, "RGBA buffer length")
const snapshot = vga:snapshot()
assert(snapshot.width == 640 and snapshot.height == 480, "snapshot geometry")
assert(snapshot.stride == 640 * 4, "snapshot stride")
const nonBlack, colorCount = stats(rgba, 640, 480)
assert(nonBlack > 0, "framebuffer must not be blank")
assert(nonBlack > 200000, "test pattern should cover most of the screen")
assert(colorCount >= 16, "test pattern should use all 16 colours")

-- Colour bars: bar 0 black, bar 1 EGA blue, bar 15 white; border white.
assertPixel(rgba, 640, 20, 100, 0, 0, 0, "bar 0")
assertPixel(rgba, 640, 60, 100, 0, 0, 170, "bar 1")
assertPixel(rgba, 640, 620, 100, 255, 255, 255, "bar 15")
assertPixel(rgba, 640, 2, 2, 255, 255, 255, "border")

writePpm(MODE12_PPM, rgba, 640, 480)

-- ------------------------------------------------------- planar register paths
-- Prepare a known planar write state.
outRegister(vga, 0x3C4, 0x02, 0x0F) -- map mask: all four planes
outRegister(vga, 0x3CE, 0x00, 0x00) -- set/reset
outRegister(vga, 0x3CE, 0x01, 0x00) -- disable set/reset
outRegister(vga, 0x3CE, 0x03, 0x00) -- no rotate/function
outRegister(vga, 0x3CE, 0x05, 0x00) -- write mode 0
outRegister(vga, 0x3CE, 0x08, 0xFF) -- bit mask

-- Write mode 1: latches loaded from row 0 must copy to row 1.
vga:fillRect(0, 0, 8, 1, 5)
vga:read8(0xA0000) -- load latches from the row-0 bytes
outRegister(vga, 0x3CE, 0x05, 0x01)
vga:write8(0xA0000 + 80, 0)
outRegister(vga, 0x3CE, 0x05, 0x00)
local frame = vga:snapshotRGBA()
assertPixel(frame, 640, 0, 1, 170, 0, 170, "write mode 1 latch copy")

-- Write mode 2: data bits 0-3 expand to the four planes.
outRegister(vga, 0x3CE, 0x05, 0x02)
vga:write8(0xA0000, 0x0A)
outRegister(vga, 0x3CE, 0x05, 0x00)
frame = vga:snapshotRGBA()
assertPixel(frame, 640, 0, 0, 85, 255, 85, "write mode 2 plane expansion")
assertPixel(frame, 640, 7, 0, 85, 255, 85, "write mode 2 fills the byte")

-- Read map select: plane 0 is zero, plane 1 is all ones after the 0x0A write.
outRegister(vga, 0x3CE, 0x04, 0x00)
assert(vga:read8(0xA0000) == 0x00, "read map 0")
outRegister(vga, 0x3CE, 0x04, 0x01)
assert(vga:read8(0xA0000) == 0xFF, "read map 1")

-- CRTC protection: registers 0..7 are ignored until 3D5:11h bit 7 is clear.
assert(inRegister(vga, 0x3D4, 0x00) == 0x5F, "mode 12h horizontal total")
outRegister(vga, 0x3D4, 0x00, 0xAA)
assert(inRegister(vga, 0x3D4, 0x00) == 0x5F, "CRTC write must be protected")
outRegister(vga, 0x3D4, 0x11, 0x0E)
outRegister(vga, 0x3D4, 0x00, 0xAA)
assert(inRegister(vga, 0x3D4, 0x00) == 0xAA, "CRTC unlock")
outRegister(vga, 0x3D4, 0x00, 0x5F)
outRegister(vga, 0x3D4, 0x11, 0x8C)

-- DAC writes: recolour attribute 1 from EGA blue to red.
vga:out8(0x3C8, 0x01)
vga:out8(0x3C9, 63)
vga:out8(0x3C9, 0)
vga:out8(0x3C9, 0)
frame = vga:snapshotRGBA()
assertPixel(frame, 640, 60, 100, 255, 0, 0, "DAC write")
vga:out8(0x3C8, 0x01)
vga:out8(0x3C9, 0)
vga:out8(0x3C9, 0)
vga:out8(0x3C9, 42)

-- Attribute palette: map attribute 1 to DAC 4 (EGA red).
vga:out8(0x3C0, 0x01)
vga:out8(0x3C0, 0x04)
vga:out8(0x3C0, 0x20)
frame = vga:snapshotRGBA()
assertPixel(frame, 640, 60, 100, 170, 0, 0, "attribute palette")
vga:out8(0x3C0, 0x01)
vga:out8(0x3C0, 0x01)
vga:out8(0x3C0, 0x20)

-- Dirty rectangle: one planar byte maps to an 8x1 pixel rectangle.
vga:clearDirty()
vga:write8(0xA0000, 0)
const dirty = vga:consumeDirty()
assert(dirty ~= nil, "write should mark a dirty rectangle")
assert(
	dirty.x == 0 and dirty.y == 0 and dirty.width == 8 and dirty.height == 1,
	"dirty rectangle should be the written byte"
)
assert(vga:consumeDirty() == nil, "consumeDirty should reset the rectangle")

-- A two-row aperture notification conservatively marks both full rows.
vga:noteWrite(0xA0000, 81)
const rowDirty = vga:consumeDirty()
assert(rowDirty ~= nil, "noteWrite should mark a rectangle")
assert(
	rowDirty.x == 0 and rowDirty.y == 0 and rowDirty.width == 640 and rowDirty.height == 2,
	"noteWrite should cover both planar rows"
)

-- ---------------------------------------------------------------- mode 13h
assert(vga:setMode(0x13), "mode 13h should be supported")
vga:fillTestPattern()
const rgba13 = vga:snapshotRGBA()
assert(buffer.len(rgba13) == 320 * 200 * 4, "mode 13h RGBA length")
const nonBlack13, colors13 = stats(rgba13, 320, 200)
assert(nonBlack13 > 0, "mode 13h must not be blank")
assert(colors13 > 16, "mode 13h gradient should use many colours")
writePpm(MODE13_PPM, rgba13, 320, 200)

-- ----------------------------------------------------------------- text mode
assert(vga:setMode(0x03), "text mode 3 should be supported")
assert(vga:isTextMode(), "mode 03h should report text")
vga:fillTestPattern()
const rgbaText = vga:snapshotRGBA()
assert(buffer.len(rgbaText) == 640 * 400 * 4, "text RGBA length")
const nonBlackText, colorsText = stats(rgbaText, 640, 400)
assert(nonBlackText > 0, "text fallback must not be blank")
assert(colorsText >= 2, "text fallback should have foreground and background")
writePpm(TEXT_PPM, rgbaText, 640, 400)

assert(not vga:setMode(0x99), "unknown modes should be rejected")

print("VGA test: OK")
print(
	string.format(
		"  mode 12h 640x480x16: %d non-black pixels, %d colours, %d-byte RGBA",
		nonBlack,
		colorCount,
		buffer.len(rgba)
	)
)
print(
	string.format("  mode 13h 320x200x256: %d non-black pixels, %d colours", nonBlack13, colors13)
)
print(
	string.format(
		"  text mode 03h 640x400: %d non-black pixels, %d colours",
		nonBlackText,
		colorsText
	)
)
print("  planar write modes 0/1/2, read map 0/1, CRTC lock, DAC, attribute palette: OK")
print("  wrote " .. MODE12_PPM .. ", " .. MODE13_PPM .. ", " .. TEXT_PPM)
