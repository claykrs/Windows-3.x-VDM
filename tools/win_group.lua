-- win_group.lua -- build real Windows 3.0 Program Manager .GRP files.
--
-- Setup generates the standard groups from SETUP.INF [progman.groups] and the
-- per-group item sections; no .GRP files ship on the media.  The on-disk format
-- is the Program Manager group file ("PMCC"):
--
--   group header   34 bytes + citems WORD offsets (0-based)
--   group name     NUL-terminated
--   item records   24 bytes each + name/command/icon-path strings
--   icon blobs     12-byte iconinfo + AND mask + XOR mask
--
-- Windows 3.0a PROGMAN.EXE validates the first two words ("PM","CC") and then
-- checks that the sum of every 16-bit word in the file is zero (PROGMAN.EXE
-- segment 4, file offset 2C08 / 2C0F).  The item layout is the one read by
-- PROGMAN's group loader: x/y, icon index, iconinfo bytes, AND bytes, XOR
-- bytes, iconinfo offset, AND offset, XOR offset, name, command, icon path.
-- The pointers are consumed by USER.408 CreateCursorIconIndirect, whose
-- argument order is (hInstance, iconinfo, AND bits, XOR bits).
--
-- Icons are copied from the executable's own NE RT_GROUP_ICON/RT_ICON
-- resources.  Setup does the same: the group file embeds the icon bitmap so
-- Program Manager does not have to reload it from the executable until the
-- group is edited.  Windows 3.0's VGA path stores the 16-colour icon as four
-- interleaved 1bpp planes, so the DIB is converted before it is embedded.
const lshift = bit32.lshift

local Group = {}

-- ------------------------------------------------------------------ bytes
local function u8(data, offset)
	return string.byte(data, offset + 1)
end

local function u16(data, offset)
	return u8(data, offset) + u8(data, offset + 1) * 256
end

local function u32(data, offset)
	return u16(data, offset) + u16(data, offset + 2) * 65536
end

local function le16(value)
	value = value % 65536
	return string.char(value % 256, math.floor(value / 256) % 256)
end

-- --------------------------------------------------------------- NE res
-- Resource table types are stored with the high bit set for numeric IDs.
local RT_ICON = 3
local RT_GROUP_ICON = 14

-- Return every resource as { type = number, id = number, offset = number,
-- size = number }.  Offsets are absolute byte offsets into the file.
local function readResources(data)
	local ne = u32(data, 0x3C)
	if u8(data, ne) ~= 0x4E or u8(data, ne + 1) ~= 0x45 then
		return nil, "not an NE image"
	end
	local tableOffset = u16(data, ne + 0x24)
	if tableOffset == 0 then
		return {}
	end
	local base = ne + tableOffset
	local shift = u16(data, base)
	local position = base + 2
	local resources = {}
	while true do
		local resourceType = u16(data, position)
		if resourceType == 0 then
			break
		end
		local count = u16(data, position + 2)
		position += 8
		for _ = 1, count do
			local offset = lshift(u16(data, position), shift)
			local size = lshift(u16(data, position + 2), shift)
			local id = u16(data, position + 6)
			resources[#resources + 1] = {
				type = resourceType % 32768,
				id = id,
				offset = offset,
				size = size,
			}
			position += 12
		end
	end
	return resources
end

-- Windows 3.0's VGA driver stores a 16-colour icon as four interleaved
-- 1bpp planes, one plane per palette bit, row-major top-down.  Program
-- Manager writes that device format into .GRP files (its own saved groups use
-- CURSORICONINFO planes=4/bpp=1, widthBytes=4 for 32x32 icons).
local function planarize4bpp(xorBits, width, height, xorStride)
	local planeStride = math.floor((width + 31) / 32) * 4
	local rowBytes = planeStride * 4
	local out = {}
	for y = 0, height - 1 do
		local sourceRow = (height - 1 - y) * xorStride
		local row = {}
		for i = 1, rowBytes do
			row[i] = 0
		end
		for x = 0, width - 1 do
			local byte = string.byte(xorBits, sourceRow + math.floor(x / 2) + 1)
			local index = (x % 2 == 0) and math.floor(byte / 16) or (byte % 16)
			local bit = 2 ^ (7 - (x % 8))
			local column = math.floor(x / 8) + 1
			for plane = 0, 3 do
				if math.floor(index / 2 ^ plane) % 2 == 1 then
					row[plane * planeStride + column] += bit
				end
			end
		end
		local chars = {}
		for i = 1, rowBytes do
			chars[i] = string.char(row[i])
		end
		out[#out + 1] = table.concat(chars)
	end
	return table.concat(out)
end

-- Convert one RT_ICON DIB (BITMAPINFOHEADER + palette + bottom-up XOR + AND)
-- into the iconinfo/AND/XOR blob a group item points at.
local function dibToIcon(data, offset, size)
	if offset + 40 > #data or size < 40 then
		return nil, "icon resource is truncated"
	end
	local headerSize = u32(data, offset)
	if headerSize < 40 then
		return nil, "icon is not a BITMAPINFOHEADER"
	end
	local width = u32(data, offset + 4)
	local doubleHeight = u32(data, offset + 8)
	local planes = u16(data, offset + 12)
	local bitsPerPixel = u16(data, offset + 14)
	if width == 0 or width > 256 or doubleHeight == 0 or doubleHeight > 512 then
		return nil, "icon has an invalid size"
	end
	if doubleHeight % 2 ~= 0 then
		return nil, "icon height is not doubled"
	end
	local height = math.floor(doubleHeight / 2)
	local colorCount = u32(data, offset + 32)
	if colorCount == 0 then
		colorCount = lshift(1, bitsPerPixel)
	end
	local paletteBytes = colorCount * 4
	local xorStride = math.floor((width * bitsPerPixel + 31) / 32) * 4
	local andStride = math.floor((width + 31) / 32) * 4
	local xorBytes = xorStride * height
	local andBytes = andStride * height
	local expected = headerSize + paletteBytes + xorBytes + andBytes
	if offset + expected > #data or expected > size then
		return nil, "icon bitmap is truncated"
	end
	local xorOffset = offset + headerSize + paletteBytes
	local andOffset = xorOffset + xorBytes
	local xorBits = string.sub(data, xorOffset + 1, xorOffset + xorBytes)
	local iconPlanes = planes
	local iconBpp = bitsPerPixel
	local iconWidthBytes = xorStride
	if bitsPerPixel == 4 and planes == 1 then
		xorBits = planarize4bpp(xorBits, width, height, xorStride)
		iconPlanes = 4
		iconBpp = 1
		iconWidthBytes = math.floor((width + 31) / 32) * 4
	end
	return {
		width = width,
		height = height,
		hotspotX = math.floor(width / 2),
		hotspotY = math.floor(height / 2),
		planes = iconPlanes,
		bitsPerPixel = iconBpp,
		widthBytes = iconWidthBytes,
		andBits = string.sub(data, andOffset + 1, andOffset + andBytes),
		xorBits = xorBits,
	}
end

-- Pick the best image from a GRPICONDIR for the current display.  Windows 3.0
-- resources carry a 16-colour image, a monochrome image and sometimes a
-- greyed/selected 16-colour image; the first 4bpp image is the real one.
local function chooseIconImage(entries, preferredBpp)
	if preferredBpp then
		for _, entry in ipairs(entries) do
			if
				entry.bitsPerPixel == preferredBpp
				and entry.planes == 1
				and entry.width <= 32
				and entry.height <= 32
			then
				return entry
			end
		end
	end
	for _, entry in ipairs(entries) do
		if
			entry.bitsPerPixel == 4
			and entry.planes == 1
			and entry.width <= 32
			and entry.height <= 32
		then
			return entry
		end
	end
	for _, entry in ipairs(entries) do
		if
			entry.bitsPerPixel == 1
			and entry.planes == 1
			and entry.width <= 32
			and entry.height <= 32
		then
			return entry
		end
	end
	return entries[1]
end

-- Extract icon number `index` (0-based, resource-ID order) from an NE image.
-- Program Manager's DOS Prompt item names PROGMAN.EXE icon 1, which resolves
-- to PROGMAN's second RT_GROUP_ICON (the single DOS-window icon).
function Group.extractIcon(data, index, preferredBpp)
	local resources, err = readResources(data)
	if not resources then
		return nil, err
	end
	local groups, icons = {}, {}
	for _, resource in ipairs(resources) do
		if resource.type == RT_GROUP_ICON then
			groups[#groups + 1] = resource
		elseif resource.type == RT_ICON then
			icons[resource.id] = resource
		end
	end
	table.sort(groups, function(a, b)
		return a.id < b.id
	end)
	local group = groups[index + 1]
	if not group then
		return nil, "no icon group " .. tostring(index)
	end
	local offset = group.offset
	if offset + 6 > #data then
		return nil, "icon group is truncated"
	end
	local count = u16(data, offset + 4)
	local entries = {}
	for i = 0, count - 1 do
		local entryOffset = offset + 6 + i * 14
		if entryOffset + 14 > #data then
			return nil, "icon directory is truncated"
		end
		entries[#entries + 1] = {
			width = u8(data, entryOffset),
			height = u8(data, entryOffset + 1),
			planes = u16(data, entryOffset + 4),
			bitsPerPixel = u16(data, entryOffset + 6),
			size = u32(data, entryOffset + 8),
			id = u16(data, entryOffset + 12),
		}
	end
	local image = chooseIconImage(entries, preferredBpp)
	if not image then
		return nil, "icon group has no images"
	end
	-- Windows 3.0 icon resources use 32768 + n for the RT_ICON id, while the
	-- GRPICONDIR entry stores the small n.  Fall back to the literal id.
	local icon = icons[32768 + image.id] or icons[image.id]
	if not icon then
		return nil, "icon image " .. tostring(image.id) .. " is missing"
	end
	return dibToIcon(data, icon.offset, icon.size)
end

-- -------------------------------------------------------------- builder
local function addWord(parts, value)
	parts[#parts + 1] = le16(value)
end

-- spec:
--   name, x, y, width, height, iconX, iconY, cmdShow,
--   logPixelsX, logPixelsY, bitsPerPixel, planes,
--   items = { { name, command, iconPath, iconIndex, icon = blob }, ... }
-- icon blobs come from Group.extractIcon.
function Group.build(spec)
	local items = spec.items or {}
	local count = #items
	local headerSize = 34 + count * 2
	local groupName = spec.name or "Program Group"
	local groupNameOffset = headerSize
	local position = groupNameOffset + #groupName + 1

	local layouts = {}
	for index, item in ipairs(items) do
		if not item.icon then
			return nil, ("item %d (%s) has no icon"):format(index, item.name or "?")
		end
		local name = item.name or ""
		local command = item.command or ""
		local iconPath = item.iconPath or ""
		local layout = {
			offset = position,
			nameOffset = position + 24,
			commandOffset = position + 24 + #name + 1,
			iconPathOffset = position + 24 + #name + 1 + #command + 1,
			name = name,
			command = command,
			iconPath = iconPath,
			icon = item.icon,
			iconIndex = item.iconIndex or 0,
			x = item.x or 0,
			y = item.y or 0,
		}
		position = layout.iconPathOffset + #iconPath + 1
		layouts[index] = layout
	end

	for _, layout in ipairs(layouts) do
		layout.iconOffset = position
		position += 12 + #layout.icon.andBits + #layout.icon.xorBits
	end
	local totalSize = position

	local parts = { "PMCC" }
	addWord(parts, 0) -- checksum, patched below
	addWord(parts, totalSize) -- cbGroup
	addWord(parts, spec.cmdShow or 1)
	addWord(parts, spec.x or 0)
	addWord(parts, spec.y or 0)
	addWord(parts, spec.width or 0)
	addWord(parts, spec.height or 0)
	addWord(parts, spec.iconX or 0)
	addWord(parts, spec.iconY or 0)
	addWord(parts, groupNameOffset)
	addWord(parts, spec.logPixelsX or 96)
	addWord(parts, spec.logPixelsY or 96)
	-- 3.0 PROGMAN compares these words with GetDeviceCaps(LOGPIXELSX/Y,
	-- BITSPIXEL, PLANES) and rebuilds every icon when they differ.
	addWord(parts, spec.bitsPerPixel or 1)
	addWord(parts, spec.planes or 4)
	addWord(parts, count)
	for _, layout in ipairs(layouts) do
		addWord(parts, layout.offset)
	end
	parts[#parts + 1] = groupName .. "\0"

	for _, layout in ipairs(layouts) do
		local icon = layout.icon
		addWord(parts, layout.x or 0)
		addWord(parts, layout.y or 0)
		addWord(parts, layout.iconIndex)
		-- The three block sizes drive PROGMAN's pointer-relocation pass:
		-- iconinfo header (CURSORICONINFO), AND mask bytes, XOR bytes.
		addWord(parts, 12)
		addWord(parts, #icon.andBits)
		addWord(parts, #icon.xorBits)
		addWord(parts, layout.iconOffset)
		addWord(parts, layout.iconOffset + 12)
		addWord(parts, layout.iconOffset + 12 + #icon.andBits)
		addWord(parts, layout.nameOffset)
		addWord(parts, layout.commandOffset)
		addWord(parts, layout.iconPathOffset)
		parts[#parts + 1] = layout.name .. "\0"
		parts[#parts + 1] = layout.command .. "\0"
		parts[#parts + 1] = layout.iconPath .. "\0"
	end

	for _, layout in ipairs(layouts) do
		local icon = layout.icon
		addWord(parts, icon.hotspotX or math.floor(icon.width / 2))
		addWord(parts, icon.hotspotY or math.floor(icon.height / 2))
		addWord(parts, icon.width)
		addWord(parts, icon.height)
		addWord(parts, icon.widthBytes)
		parts[#parts + 1] = string.char(icon.planes % 256, icon.bitsPerPixel % 256)
		parts[#parts + 1] = icon.andBits
		parts[#parts + 1] = icon.xorBits
	end

	local data = table.concat(parts)
	if #data % 2 == 1 then
		-- keep the checksum word-aligned; the extra NUL is inside cbGroup and
		-- never referenced by a string or icon pointer
		data ..= "\0"
		data = string.sub(data, 1, 6) .. le16(#data) .. string.sub(data, 9)
	end

	local sum = 0
	for offset = 0, #data - 2, 2 do
		sum = (sum + u16(data, offset)) % 65536
	end
	local checksum = (65536 - sum) % 65536
	return string.sub(data, 1, 4) .. le16(checksum) .. string.sub(data, 7)
end

-- Exposed for the focused format test.
Group.readResources = readResources
Group.dibToIcon = dibToIcon
Group.checksum = function(data)
	local sum = 0
	for offset = 0, #data - 2, 2 do
		sum = (sum + u16(data, offset)) % 65536
	end
	return sum
end

return Group
