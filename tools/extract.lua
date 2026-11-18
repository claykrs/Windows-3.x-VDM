-- extract.lua -- FAT12 floppy unpacker for the Windows 3.0a disks.
-- Reads each .IMG, walks the root directory, follows FAT12 chains, writes
-- every file into media/win30/files/ (flat; disk number prefixed on collision).
-- Run from robloxDos/: ./tools/bin/lune.exe run tools/extract.lua

local fs = require("@lune/fs")

local band, rshift, lshift, bor = bit32.band, bit32.rshift, bit32.lshift, bit32.bor

local MEDIA_DIR = "media/win30/Microsoft Windows 3.0a (5.25 1.2MB)"
local OUT_DIR = "media/win30/files"

local function fat12Entry(data, i)
	-- packed 12-bit entries: two per three bytes
	local off = math.floor(i * 3 / 2)
	local b0, b1 = string.byte(data, off + 1, off + 2)
	local v
	if i % 2 == 0 then
		v = bor(b0, lshift(band(b1, 0x0F), 8))
	else
		v = bor(rshift(b0, 4), lshift(b1, 4))
	end
	return v
end

local function extractDisk(path, _diskNo)
	local img = fs.readFile(path)
	local bs = 512
	local spc = string.byte(img, 14) -- sect/cluster (BPB offsets 0x0D)
	local res = string.unpack("<I2", img, 15)
	local nfats = string.byte(img, 17)
	local rootent = string.unpack("<I2", img, 18)
	local spf = string.unpack("<I2", img, 23)

	local fatStart = res * bs
	local rootStart = fatStart + nfats * spf * bs
	local dataStart = rootStart + math.ceil(rootent * 32 / bs) * bs

	-- FAT chain walk; FAT entries index from the FAT's own start, not byte 0
	local fat = string.sub(img, fatStart + 1, fatStart + nfats * spf * bs)
	local function readChain2(firstCluster, size)
		local out = {}
		local c = firstCluster
		local guard = 0
		while guard < 5000 do
			guard += 1
			out[#out + 1] =
				string.sub(img, dataStart + (c - 2) * spc * bs + 1, dataStart + (c - 1) * spc * bs)
			if #table.concat(out) >= size then
				break
			end
			c = fat12Entry(fat, c)
			if c >= 0xFF8 then
				break
			end
			if c < 2 then
				break
			end
		end
		return string.sub(table.concat(out), 1, size)
	end

	local files = {}
	for i = 0, rootent - 1 do
		local e = rootStart + i * 32
		local b0 = string.byte(img, e + 1)
		if b0 == 0x00 then
			break
		end -- end of directory
		if b0 ~= 0xE5 then -- not deleted
			local attr = string.byte(img, e + 12)
			if band(attr, 0x08) == 0 then -- skip volume labels
				local raw = string.sub(img, e + 1, e + 11)
				local name = string.gsub(raw:sub(1, 8), " +$", "")
				local ext = string.gsub(raw:sub(9, 11), " +$", "")
				local fname = ext ~= "" and (name .. "." .. ext) or name
				local cluster = string.unpack("<I2", img, e + 27)
				local size = string.unpack("<I4", img, e + 29)
				if cluster >= 2 and size > 0 then
					files[#files + 1] = { name = fname, data = readChain2(cluster, size) }
				end
			end
		end
	end
	return files
end

-- dead helper cleanup (readChain kept out of the final flow)
if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end

local disks = { "DISK01.IMG", "DISK02.IMG", "DISK03.IMG", "DISK04.IMG", "DISK05.IMG" }
-- setup floppies span big files across disks: a repeated name is the NEXT PIECE
-- of the same stream, so append in disk order
local total, merged = 0, 0
for dno, name in ipairs(disks) do
	local files = extractDisk(MEDIA_DIR .. "/" .. name, dno)
	print(("== %s: %d files"):format(name, #files))
	for _, f in ipairs(files) do
		local path = OUT_DIR .. "/" .. f.name
		if fs.isFile(path) then
			local prev = fs.readFile(path)
			fs.writeFile(path, prev .. f.data)
			merged += 1
			print(("   %-12s + %6d (spanned piece)"):format(f.name, #f.data))
		else
			fs.writeFile(path, f.data)
			print(("   %-12s %6d bytes"):format(f.name, #f.data))
			total += 1
		end
	end
end
print(("total: %d files (%d spanned pieces merged) -> %s"):format(total, merged, OUT_DIR))
