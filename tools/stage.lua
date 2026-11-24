-- stage.lua -- decompresses SZDD (Microsoft Compress) files into a staged
-- Windows 3.0a install tree. Format (empirically verified against these disks):
-- 14-byte header: "SZDD", 88 F0, 27 33, 41 00, size(u32 LE) — then LZSS stream:
-- control byte MSB-first, bit=1 literal, bit=0 match (2 bytes: 12-bit offset,
-- len = low nibble + 3, source = winPos - (4096 - off)), 4096-byte ring window
-- pre-filled with 0x20, write position starts at 4080.
-- Run from robloxDos/: ./tools/bin/lune.exe run tools/stage.lua

local fs = require("@lune/fs")

local IN_DIR = "media/win30/files"
local OUT_DIR = "media/win30/staged"

local band, lshift, bor, rshift = bit32.band, bit32.lshift, bit32.bor, bit32.rshift

local function szddDecompress(data)
	if string.sub(data, 1, 4) ~= "SZDD" then
		return nil
	end
	local outSize = string.unpack("<I4", data, 11)
	local out = buffer.create(outSize)
	local win = buffer.create(4096)
	for i = 0, 4095 do
		buffer.writeu8(win, i, 0x20)
	end
	local pos = 4080
	local inLen = #data
	local inPos = 15 -- first stream byte (after 14-byte header)
	local outPos = 0
	local control, bits = 0, 0
	while outPos < outSize do
		if bits == 0 then
			if inPos > inLen then
				break
			end
			control = string.byte(data, inPos)
			inPos += 1
			bits = 8
		end
		bits -= 1
		if band(control, 1) ~= 0 then
			control = rshift(control, 1)
			if inPos > inLen then
				break
			end
			local b = string.byte(data, inPos)
			inPos += 1
			buffer.writeu8(out, outPos, b)
			buffer.writeu8(win, pos, b)
			outPos += 1
			pos = (pos + 1) % 4096
		else
			control = rshift(control, 1)
			if inPos + 1 > inLen then
				break
			end
			local b1, b2 = string.byte(data, inPos, inPos + 1)
			inPos += 2
			local mpos = bor(b1, lshift(band(b2, 0xF0), 4)) -- ABSOLUTE ring index
			local len = band(b2, 0x0F) + 3
			for _ = 1, len do
				if outPos >= outSize then
					break
				end
				local b = buffer.readu8(win, mpos)
				buffer.writeu8(out, outPos, b)
				buffer.writeu8(win, pos, b)
				outPos += 1
				pos = (pos + 1) % 4096
				mpos = (mpos + 1) % 4096
			end
		end
	end
	if outPos ~= outSize then
		return nil,
			("stream ended early: out %d/%d, in %d/%d"):format(outPos, outSize, inPos - 1, inLen)
	end
	return out
end

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end

local okCount, rawCount, errCount = 0, 0, 0
for _, name in ipairs(fs.readDir(IN_DIR)) do
	local data = fs.readFile(IN_DIR .. "/" .. name)
	if string.sub(data, 1, 4) == "SZDD" then
		local out, err = szddDecompress(data)
		if out then
			fs.writeFile(OUT_DIR .. "/" .. name, out)
			okCount += 1
		else
			errCount += 1
			print(("FAIL %s: %s"):format(name, tostring(err)))
		end
	else
		fs.writeFile(OUT_DIR .. "/" .. name, data)
		rawCount += 1
	end
end
print(
	("staged: %d decompressed, %d verbatim, %d failed -> %s"):format(
		okCount,
		rawCount,
		errCount,
		OUT_DIR
	)
)

-- verify: every .EXE/.DLL/.DRV/.FON/.MOD in staged must start with MZ
local bad = {}
local mzCount = 0
for _, name in ipairs(fs.readDir(OUT_DIR)) do
	local ext = string.match(string.upper(name), "%.(%w+)$")
	if ext == "EXE" or ext == "DLL" or ext == "DRV" or ext == "MOD" then
		local d = fs.readFile(OUT_DIR .. "/" .. name)
		if string.sub(d, 1, 2) == "MZ" then
			mzCount += 1
		else
			bad[#bad + 1] = name
		end
	end
end
print(("executable check: %d valid MZ, %d bad"):format(mzCount, #bad))
for _, b in ipairs(bad) do
	print("  BAD: " .. b)
end
