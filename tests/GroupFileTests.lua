--!nonstrict
-- GroupFileTests.lua -- Windows 3.0 Program Manager group-file format.
--
-- The guest is the authority: PROGMAN.EXE validates "PMCC", requires the sum
-- of every 16-bit word to be zero, reads a 34-byte header followed by item
-- offsets, and passes each item's iconinfo/AND/XOR pointers to USER.408
-- CreateCursorIconIndirect.  These tests pin the byte layout that the real
-- shell accepted in tools/out/groups-*.png.
const Group = require("../tools/win_group")

local GroupFileTests = {}

local function word(data, offset)
	return string.byte(data, offset + 1) + string.byte(data, offset + 2) * 256
end

local function byte(data, offset)
	return string.byte(data, offset + 1)
end

local function cstring(data, offset)
	local stop = string.find(data, "\0", offset + 1, true)
	return string.sub(data, offset + 1, (stop or (#data + 1)) - 1)
end

local function iconFixture()
	return {
		width = 32,
		height = 32,
		hotspotX = 16,
		hotspotY = 16,
		planes = 4,
		bitsPerPixel = 1,
		widthBytes = 4,
		andBits = string.rep("\255", 128),
		xorBits = string.rep("\0", 512),
	}
end

function GroupFileTests.run(expect)
	do
		local data, err = Group.build({
			name = "Main",
			x = 20,
			y = 20,
			width = 560,
			height = 190,
			iconX = 20,
			iconY = 430,
			cmdShow = 1,
			logPixelsX = 96,
			logPixelsY = 96,
			bitsPerPixel = 1,
			planes = 4,
			items = {
				{
					name = "File Manager",
					command = "WINFILE.EXE",
					iconPath = "C:\\WINDOWS\\WINFILE.EXE",
					iconIndex = 0,
					icon = iconFixture(),
					x = 20,
					y = 16,
				},
			},
		})
		local e = expect("group_file_build")
		e(data ~= nil, tostring(err))
		if not data then
			return
		end
		e(string.sub(data, 1, 4) == "PMCC", "magic=" .. string.sub(data, 1, 4))
		e(Group.checksum(data) == 0, ("checksum sum=%04X"):format(Group.checksum(data)))
		e(word(data, 6) == #data, ("cbGroup=%d size=%d"):format(word(data, 6), #data))
		e(word(data, 8) == 1, "cmdShow")
		e(word(data, 10) == 20 and word(data, 12) == 20, "rcNormal origin")
		e(word(data, 14) == 560 and word(data, 16) == 190, "rcNormal extent")
		e(word(data, 18) == 20 and word(data, 20) == 430, "ptMin")
		e(word(data, 24) == 96 and word(data, 26) == 96, "log pixels")
		e(word(data, 28) == 1 and word(data, 30) == 4, "display bpp/planes")
		e(word(data, 32) == 1, "item count")

		local nameOffset = word(data, 22)
		e(cstring(data, nameOffset) == "Main", "group name")

		local itemOffset = word(data, 34)
		e(itemOffset == 34 + 2 + 5, ("first item offset=%d"):format(itemOffset))
		e(word(data, itemOffset + 0) == 20 and word(data, itemOffset + 2) == 16, "item xy")
		e(word(data, itemOffset + 4) == 0, "icon index")
		e(word(data, itemOffset + 6) == 12, "iconinfo size")
		e(word(data, itemOffset + 8) == 128, "AND size")
		e(word(data, itemOffset + 10) == 512, "XOR size")

		local infoOffset = word(data, itemOffset + 12)
		local andOffset = word(data, itemOffset + 14)
		local xorOffset = word(data, itemOffset + 16)
		e(infoOffset + 12 <= #data, "iconinfo in range")
		e(andOffset + 128 <= #data, "AND in range")
		e(xorOffset + 512 <= #data, "XOR in range")
		e(word(data, infoOffset) == 16 and word(data, infoOffset + 2) == 16, "hotspot")
		e(word(data, infoOffset + 4) == 32 and word(data, infoOffset + 6) == 32, "icon size")
		e(word(data, infoOffset + 8) == 4, "widthBytes")
		e(byte(data, infoOffset + 10) == 4 and byte(data, infoOffset + 11) == 1, "planes/bpp")

		e(cstring(data, word(data, itemOffset + 18)) == "File Manager", "item name")
		e(cstring(data, word(data, itemOffset + 20)) == "WINFILE.EXE", "command")
		e(cstring(data, word(data, itemOffset + 22)) == "C:\\WINDOWS\\WINFILE.EXE", "icon path")
	end

	do
		local data = Group.build({
			name = "Empty",
			bitsPerPixel = 1,
			planes = 4,
			items = {},
		})
		local e = expect("group_file_empty")
		e(data ~= nil, "empty group should build")
		if data then
			e(Group.checksum(data) == 0, "empty group checksum")
			e(word(data, 32) == 0, "empty item count")
			e(word(data, 6) == #data, "empty cbGroup")
		end
	end
end

return GroupFileTests
