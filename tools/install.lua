-- install.lua -- stages C:\WINDOWS inside the machine VFS from the real
-- SETUP.INF copy lists + INI templates, then hands back a bootable machine.
-- Used by boot.lua (and later, the Studio boot path).
--
-- The profile is Windows 3.0a real mode on VGA: the shell, the built-in
-- applications, the help/bitmap files, the VGA-resolution proportional fonts,
-- and the standard-mode (286) kernel are staged. 386-only files, network
-- stacks and printer drivers are intentionally left out; Install.audit()
-- reports exactly which SETUP.INF files that leaves behind.
local fs = require("@lune/fs")
local Group = require("./win_group")

local Install = {}

local STAGED = "media/win30/staged"
local VGA_RESOLUTION = "100,96,96"

-- parse SETUP.INF: returns { [section] = { lines... } }
local function parseInf(text)
	local sections = {}
	local current = nil
	for line in string.gmatch(text, "([^\r\n]*)\r?\n?") do
		local trimmed = string.gsub(line, "^%s+", "")
		local name = string.match(trimmed, "^%[(.-)%]")
		if name then
			current = string.lower(name)
			sections[current] = sections[current] or {}
		elseif current and trimmed ~= "" and string.sub(trimmed, 1, 1) ~= ";" then
			local t = sections[current]
			t[#t + 1] = trimmed
		end
	end
	return sections
end

-- every "N:file.ext" token on a SETUP.INF line, uppercased. Lines that copy
-- directories ("0:system") and bare destination names are ignored.
local function entryFiles(entry)
	local files = {}
	for file in string.gmatch(entry, "%d+:([%w%._%-]+)") do
		local upper = string.upper(file)
		if string.find(upper, "%.") then
			files[#files + 1] = upper
		end
	end
	return files
end

-- first copy source on a SETUP.INF line ("1:win.cnf" -> "win.cnf")
local function entryFile(entry)
	local file = string.match(entry, "^[^:]+:([^%s,]+)")
	return file and string.lower(file) or nil
end

-- quoted fields, in order ("desc", "res", ...)
local function quotedFields(entry)
	local fields = {}
	for value in string.gmatch(entry, '"([^"]*)"') do
		fields[#fields + 1] = value
	end
	return fields
end

-- resolution selector for font sections: the second quoted field, if any.
-- Fonts without a selector are continuously scaled and always apply.
local function fontResolution(entry)
	local fields = quotedFields(entry)
	return fields[2]
end

local function wantsVgaFont(entry)
	local resolution = fontResolution(entry)
	return resolution == nil or resolution == VGA_RESOLUTION or resolution == "CONTINUOUSSCALING"
end

local function trim(text)
	return (string.gsub(text, "^%s+", "")):gsub("%s+$", "")
end

-- Split a SETUP.INF program-item line on top-level commas.  Quoted fields may
-- contain spaces ("NOTEPAD.EXE README.TXT") and are kept whole.
local function splitGroupFields(line)
	local fields = {}
	local index = 1
	local length = #line
	while index <= length do
		while index <= length and string.match(string.sub(line, index, index), "[%s,]") do
			index += 1
		end
		if index > length then
			break
		end
		if string.sub(line, index, index) == '"' then
			index += 1
			local start = index
			while index <= length and string.sub(line, index, index) ~= '"' do
				index += 1
			end
			fields[#fields + 1] = string.sub(line, start, index - 1)
			index += 1
		else
			local start = index
			while index <= length and string.sub(line, index, index) ~= "," do
				index += 1
			end
			fields[#fields + 1] = trim(string.sub(line, start, index - 1))
		end
		while index <= length and string.sub(line, index, index) ~= "," do
			index += 1
		end
		if string.sub(line, index, index) == "," then
			index += 1
		end
	end
	return fields
end

-- first token of a command ("NOTEPAD.EXE README.TXT" -> "NOTEPAD.EXE")
local function commandProgram(command)
	local quoted = string.match(command, '^%s*"([^"]+)"')
	if quoted then
		return quoted
	end
	return string.match(command, "^%s*([^%s]+)")
end

local function baseName(path)
	return string.match(path, "([^\\/]+)$") or path
end

-- Setup's standard names are the 8.3 names every Windows 3.0 install has.
local GROUP_FILE_NAMES = {
	main = "MAIN.GRP",
	accessories = "ACCESSOR.GRP",
	games = "GAMES.GRP",
}

local function groupFileName(name)
	local known = GROUP_FILE_NAMES[string.lower(name)]
	if known then
		return known
	end
	local stem = string.upper((string.gsub(name, "[^%w]", "")))
	return string.sub(stem, 1, 8) .. ".GRP"
end

-- First-run window placement: Main open, Accessories and Games minimized as
-- group icons at the bottom of the desktop.
local GROUP_LAYOUTS = {
	main = {
		x = 20,
		y = 20,
		width = 420,
		height = 190,
		iconX = 20,
		iconY = 430,
		cmdShow = 1, -- SW_SHOWNORMAL
		columns = 4,
	},
	accessories = {
		x = 70,
		y = 70,
		width = 460,
		height = 190,
		iconX = 280,
		iconY = 430,
		cmdShow = 2, -- SW_SHOWMINIMIZED
		columns = 5,
	},
	games = {
		x = 110,
		y = 110,
		width = 220,
		height = 120,
		iconX = 390,
		iconY = 430,
		cmdShow = 2, -- SW_SHOWMINIMIZED
		columns = 2,
	},
}

-- which SETUP.INF sections Install.seed materialises, and where. Used by
-- Install.audit() and the app harness.
Install.STAGED_SECTIONS = {
	["windows.system"] = "WINDOWS + SYSTEM",
	["windows"] = "WINDOWS",
	shell = "WINDOWS",
	system = "SYSTEM + WINDOWS (selected)",
	["keyboard.drivers"] = "SYSTEM + WINDOWS (selected)",
	["pointing.device"] = "SYSTEM + WINDOWS (selected)",
	["win.other"] = "SYSTEM",
	["win.apps"] = "WINDOWS (+ SYSTEM for DLL/FON)",
	["win.help"] = "WINDOWS",
	["win.bmps"] = "WINDOWS",
	["win.readme"] = "WINDOWS",
	pwin286 = "SYSTEM",
	pwin386 = "SYSTEM",
	fonts = "SYSTEM + WINDOWS (VGA resolution)",
	sysfonts = "SYSTEM + WINDOWS (VGA resolution)",
	fixedfonts = "SYSTEM + WINDOWS (VGA resolution)",
	oemfonts = "SYSTEM + WINDOWS (VGA resolution)",
	net = "WINDOWS (CONTROL.INI, WINVER only)",
	["progman.groups"] = "WINDOWS (generated MAIN/ACCESSOR/GAMES.GRP)",
}

local AUDIT_SECTIONS = {
	"windows.system",
	"windows",
	"shell",
	"system",
	"keyboard.drivers",
	"pointing.device",
	"win.other",
	"win.apps",
	"win.help",
	"win.bmps",
	"win.readme",
	"pwin286",
	"pwin386",
	"fonts",
	"sysfonts",
	"fixedfonts",
	"oemfonts",
	"display",
	"net",
	"network",
	"dos.mouse.drivers",
	"pif",
	"progman.groups",
	"win.copy",
	"win.copy.win386",
	"diskcache",
	"ramdrive",
}

-- build the C: tree; returns count of files staged
function Install.seed(machine)
	local infText = fs.readFile(STAGED .. "/SETUP.INF")
	local sections = parseInf(infText)
	local count = 0
	local missing = {}

	local function put(path, data)
		local cut = nil
		for k = #path, 1, -1 do
			if string.sub(path, k, k) == "\\" then
				cut = k
				break
			end
		end
		local dir = cut and string.sub(path, 1, cut - 1) or "C:"
		assert(machine.vfs:ensureDir(dir), "ensureDir failed: " .. path)
		assert(machine.vfs:writeFile(path, data), "vfs write failed: " .. path)
		count += 1
	end

	local function stageFile(dir, file)
		local path = STAGED .. "/" .. file
		if not fs.isFile(path) then
			missing[#missing + 1] = file
			return false
		end
		put(dir .. "\\" .. file, fs.readFile(path))
		return true
	end

	local function stageSection(name, dir, filter)
		for _, entry in ipairs(sections[name] or {}) do
			for _, file in ipairs(entryFiles(entry)) do
				if not filter or filter(entry) then
					stageFile(dir, file)
				end
			end
		end
	end

	put("C:\\WINDOWS\\WIN.COM", fs.readFile(STAGED .. "/WIN.CNF"))
	-- WIN.COM 3.0 probes bare "kernel.exe" from its cwd and also joins its
	-- windir variable without a separator; serve the kernel at both paths
	put("C:\\WINDOWS\\KERNEL.EXE", fs.readFile(STAGED .. "/KERNEL.EXE"))
	put("C:\\WINDOWS\\WIN.INI", fs.readFile(STAGED .. "/WIN.SRC"))
	put("C:\\WINDOWS\\SYSTEM.INI", fs.readFile(STAGED .. "/SYSTEM.SRC"))

	-- [windows.system]: KERNEL/GDI/USER/WIN.CNF. KERNEL opens GDI/USER from
	-- the Windows directory, so stage both search paths.
	for _, entry in ipairs(sections["windows.system"] or {}) do
		local file = entryFile(entry)
		if file then
			local path = STAGED .. "/" .. string.upper(file)
			if fs.isFile(path) then
				local data = fs.readFile(path)
				put("C:\\WINDOWS\\SYSTEM\\" .. string.upper(file), data)
				put("C:\\WINDOWS\\" .. string.upper(file), data)
			end
		end
	end

	-- [windows]: WINHELP plus the INI templates (renamed WIN.SRC/SYSTEM.SRC)
	for _, entry in ipairs(sections["windows"] or {}) do
		local file = entryFile(entry)
		if file then
			local src = string.upper(file)
			if src == "WIN.SRC" or src == "SYSTEM.SRC" then
				-- already staged above
			else
				stageFile("C:\\WINDOWS", src)
			end
		end
	end

	-- [shell] + [win.apps]: the built-in applications live in WINDOWS, their
	-- DLLs and the clock font also go to SYSTEM (Windows' DLL search path).
	stageSection("shell", "C:\\WINDOWS")
	stageSection("win.apps", "C:\\WINDOWS")
	for _, entry in ipairs(sections["win.apps"] or {}) do
		for _, file in ipairs(entryFiles(entry)) do
			if string.match(file, "%.DLL$") or string.match(file, "%.FON$") then
				stageFile("C:\\WINDOWS\\SYSTEM", file)
			end
		end
	end

	-- help, wallpapers and readme files
	stageSection("win.help", "C:\\WINDOWS")
	stageSection("win.bmps", "C:\\WINDOWS")
	stageSection("win.readme", "C:\\WINDOWS")

	-- [win.other]: WINOLDAP + LZEXPAND/WIN87EM/SYSEDIT go to SYSTEM per
	-- [win.copy] ("#win.other, 0:system").
	stageSection("win.other", "C:\\WINDOWS\\SYSTEM")

	-- standard-mode kernel (real-mode boots KERNEL.EXE instead) and the 386
	-- stack, both to SYSTEM per [win.copy.win386].
	stageSection("pwin286", "C:\\WINDOWS\\SYSTEM")
	stageSection("pwin386", "C:\\WINDOWS\\SYSTEM")

	-- [net] is mostly network/DOS drivers; CONTROL.INI and WINVER are the two
	-- files a VGA real-mode install actually needs.
	for _, entry in ipairs(sections["net"] or {}) do
		for _, file in ipairs(entryFiles(entry)) do
			if file == "CONTROL.INI" then
				stageFile("C:\\WINDOWS", file)
			end
		end
	end
	-- SETUP.INF spells this copy source without an extension ("2:WINVER");
	-- the media file is also extensionless, but Setup installs WINVER.EXE.
	if fs.isFile(STAGED .. "/WINVER") then
		put("C:\\WINDOWS\\WINVER.EXE", fs.readFile(STAGED .. "/WINVER"))
	else
		missing[#missing + 1] = "WINVER"
	end
	-- Setup's own executable and the SZDD expander remain in a real install.
	stageFile("C:\\WINDOWS", "SETUP.EXE")
	stageFile("C:\\WINDOWS", "EXPAND.EXE")

	-- selected machine/input drivers ("system = 1:system.drv", etc.)
	local function driverFile(entry)
		local file = string.match(entry, "=%s*%d+:([%w%._%-]+)")
			or string.match(entry, "^%d+:([%w%._%-]+)")
		return file and string.lower(file) or nil
	end
	for _, section in { "system", "keyboard.drivers", "pointing.device" } do
		for _, entry in ipairs(sections[section] or {}) do
			local file = driverFile(entry)
			if file then
				local path = STAGED .. "/" .. string.upper(file)
				if fs.isFile(path) then
					local data = fs.readFile(path)
					put("C:\\WINDOWS\\SYSTEM\\" .. string.upper(file), data)
					put("C:\\WINDOWS\\" .. string.upper(file), data)
				end
			end
		end
	end

	-- VGA display driver + VGA-resolution system/fixed/OEM fonts. The grabber
	-- and logo files are only used by standard/enhanced mode but are cheap and
	-- make a later mode switch possible without restaging.
	local vgaFiles = {
		"VGA.DRV",
		"VGASYS.FON",
		"VGAFIX.FON",
		"VGAOEM.FON",
		"VGA.GR3",
		"VGACOLOR.GR2",
		"VGALOGO.LGO",
		"VGALOGO.RLE",
	}
	for _, dir in { "C:\\WINDOWS", "C:\\WINDOWS\\SYSTEM" } do
		for _, name in vgaFiles do
			stageFile(dir, name)
		end
	end
	-- DOS/WIN.INI aliases used by the display/font loader
	local aliases = {
		{ "DISPLAY.DRV", "VGA.DRV" },
		{ "FONTS.FON", "VGASYS.FON" },
		{ "FIXEDFON.FON", "VGAFIX.FON" },
		{ "OEMFONTS.FON", "VGAOEM.FON" },
	}
	for _, dir in { "C:\\WINDOWS", "C:\\WINDOWS\\SYSTEM" } do
		for _, alias in aliases do
			local data = machine.vfs:readFile(dir .. "\\" .. alias[2])
			if data then
				put(dir .. "\\" .. alias[1], data)
			end
		end
	end

	-- VGA-resolution proportional fonts. GDI enumerates the WIN.INI
	-- fonts.fon/... entries plus these files; without them dialog text has no
	-- face and USER/GDI initialization exercises a different (empty) font
	-- path.
	for _, section in { "fonts", "sysfonts", "fixedfonts", "oemfonts" } do
		for _, entry in ipairs(sections[section] or {}) do
			for _, file in ipairs(entryFiles(entry)) do
				if wantsVgaFont(entry) then
					stageFile("C:\\WINDOWS\\SYSTEM", file)
					stageFile("C:\\WINDOWS", file)
				end
			end
		end
	end

	-- Program Manager groups. Setup generates MAIN.GRP/ACCESSOR.GRP/GAMES.GRP
	-- from [progman.groups] and the per-group item lists; the media ships no
	-- .GRP files. Generate the same binary groups here, embedding the real
	-- icon from each item executable's NE icon resources.
	local groupNames, groupFiles, groupFallbacks = {}, {}, {}
	local progmanData = nil
	if fs.isFile(STAGED .. "/PROGMAN.EXE") then
		progmanData = fs.readFile(STAGED .. "/PROGMAN.EXE")
	end
	for _, entry in ipairs(sections["progman.groups"] or {}) do
		local name = trim(string.match(entry, "^([^,]+)") or "")
		if name ~= "" then
			local layout = GROUP_LAYOUTS[string.lower(name)]
				or {
					x = 20,
					y = 20,
					width = 400,
					height = 190,
					iconX = 20,
					iconY = 430,
					cmdShow = 2,
					columns = 5,
				}
			local items = {}
			for _, line in ipairs(sections[string.lower(name)] or {}) do
				local fields = splitGroupFields(line)
				local description, command = fields[1], fields[2]
				if description and command and command ~= "" then
					local iconFile = fields[3]
					if not iconFile or iconFile == "" then
						iconFile = commandProgram(command)
					end
					iconFile = iconFile and baseName(iconFile) or "PROGMAN.EXE"
					local iconIndex = tonumber(fields[4]) or 0
					local icon, iconErr = nil, nil
					local iconPath = STAGED .. "/" .. string.upper(iconFile)
					if fs.isFile(iconPath) then
						icon, iconErr = Group.extractIcon(fs.readFile(iconPath), iconIndex, 4)
					else
						iconErr = "missing " .. string.upper(iconFile)
					end
					if not icon and progmanData then
						local originalErr = iconErr
						local fallback
						fallback, iconErr = Group.extractIcon(progmanData, 0, 4)
						if fallback then
							icon = fallback
							groupFallbacks[#groupFallbacks + 1] = ("%s: %s (%s)"):format(
								name,
								description,
								originalErr or "no icon in source"
							)
						end
					end
					if icon then
						local column = #items % layout.columns
						local row = math.floor(#items / layout.columns)
						items[#items + 1] = {
							name = description,
							command = command,
							iconPath = "C:\\WINDOWS\\" .. string.upper(iconFile),
							iconIndex = iconIndex,
							icon = icon,
							x = 20 + column * 80,
							y = 16 + row * 58,
						}
					else
						groupFallbacks[#groupFallbacks + 1] = ("%s: %s (no icon: %s)"):format(
							name,
							description,
							iconErr or "?"
						)
					end
				end
			end
			local data, buildErr = Group.build({
				name = name,
				x = layout.x,
				y = layout.y,
				width = layout.width,
				height = layout.height,
				iconX = layout.iconX,
				iconY = layout.iconY,
				cmdShow = layout.cmdShow,
				logPixelsX = 96,
				logPixelsY = 96,
				-- VGA mode 12h is a 4-plane, 1-bit-per-plane display
				bitsPerPixel = 1,
				planes = 4,
				items = items,
			})
			if data then
				local file = groupFileName(name)
				put("C:\\WINDOWS\\" .. file, data)
				groupNames[#groupNames + 1] = name
				groupFiles[#groupFiles + 1] = file
			else
				groupFallbacks[#groupFallbacks + 1] = ("%s: build failed (%s)"):format(
					name,
					tostring(buildErr)
				)
			end
		end
	end

	-- Windows 3.0 INI paths use literal backslashes; Setup writes full 8.3
	-- group paths.  PROGMAN re-reads these keys whenever it opens the shell.
	local iniLines = { "[Settings]", "Window=", "display.drv=VGA.DRV", "", "[Groups]" }
	for index, file in ipairs(groupFiles) do
		iniLines[#iniLines + 1] = ("Group%d=C:\\WINDOWS\\%s"):format(index, file)
	end
	put("C:\\WINDOWS\\PROGMAN.INI", table.concat(iniLines, "\r\n") .. "\r\n")

	Install.stageStats = {
		files = count,
		missing = missing,
		groups = groupNames,
		groupFiles = groupFiles,
		groupFallbacks = groupFallbacks,
	}
	Install.writeWinIni(machine)
	return count
end

-- Apply the [wininiupdate] keys that matter for a VGA real-mode install.
-- WIN.SRC already carries [Extensions] and [ports]; only the document
-- association list is empty in the template.
function Install.writeWinIni(machine)
	local text = machine.vfs:readFile("C:\\WINDOWS\\WIN.INI") or ""
	local out = {}
	local section = ""
	local sawKey = false
	for line in string.gmatch(text, "([^\r\n]*)\r?\n?") do
		local trimmed = string.gsub(line, "^%s+", "")
		local name = string.match(trimmed, "^%[(.-)%]")
		if name then
			section = string.lower(name)
		end
		if section == "windows" and string.match(string.lower(trimmed), "^documents%s*=") then
			out[#out + 1] = "Documents=txt"
			sawKey = true
		else
			out[#out + 1] = line
		end
	end
	if not sawKey then
		out[#out + 1] = "[windows]"
		out[#out + 1] = "Documents=txt"
	end
	machine.vfs:writeFile("C:\\WINDOWS\\WIN.INI", table.concat(out, "\r\n") .. "\r\n")
end

-- set [windows] run= in WIN.INI: the other documented Windows 3.0 auto-start
function Install.setWinIniRunText(text: string, program: string): string
	local out = {}
	local section = ""
	local found = false
	for line in string.gmatch(text, "([^\r\n]*)\r?\n?") do
		local trimmed = string.gsub(line, "^%s+", "")
		local name = string.match(trimmed, "^%[(.-)%]")
		if name then
			section = string.lower(name)
		end
		if section == "windows" and string.match(string.lower(trimmed), "^run%s*=") then
			out[#out + 1] = "run=" .. program
			found = true
		else
			out[#out + 1] = line
		end
	end
	if not found then
		out[#out + 1] = "[windows]"
		out[#out + 1] = "run=" .. program
	end
	return table.concat(out, "\r\n") .. "\r\n"
end

function Install.setWinIniRun(machine, program)
	local text = machine.vfs:readFile("C:\\WINDOWS\\WIN.INI") or ""
	machine.vfs:writeFile("C:\\WINDOWS\\WIN.INI", Install.setWinIniRunText(text, program))
end

-- SYSTEM.INI template -> configured for VGA real mode. Section-aware so
-- [boot] shell/display.drv and [keyboard] type/subtype are set together.
function Install.writeSystemIni(machine)
	local text = machine.vfs:readFile("C:\\WINDOWS\\SYSTEM.INI") or ""
	local out = {}
	local section = ""
	for line in string.gmatch(text, "([^\r\n]*)\r?\n?") do
		local t = string.gsub(line, "^%s+", "")
		local name = string.match(t, "^%[(.-)%]")
		if name then
			section = string.lower(name)
		end
		local key = string.match(t, "^([%w%._%-]+)%s*=")
		local low = key and string.lower(key) or nil
		local replacement = nil
		local drop = false
		if section == "boot" then
			if low == "shell" then
				replacement = "shell=progman.exe"
			elseif low == "display.drv" then
				replacement = "display.drv=vga.drv"
			elseif low == "keyboard.drv" then
				replacement = "keyboard.drv=keyboard.drv"
			elseif low == "mouse.drv" then
				replacement = "mouse.drv=mouse.drv"
			elseif low == "system.drv" then
				replacement = "system.drv=system.drv"
			elseif low == "sound.drv" then
				replacement = "sound.drv=sound.drv"
			elseif low == "comm.drv" then
				replacement = "comm.drv=comm.drv"
			elseif low == "network.drv" then
				-- default is "none": an explicit blank value is what Setup writes
				replacement = "network.drv="
			elseif low == "fonts.fon" then
				replacement = "fonts.fon=vgasys.fon"
			elseif low == "oemfonts.fon" then
				replacement = "oemfonts.fon=vgaoem.fon"
			elseif low == "fixedfon.fon" then
				replacement = "fixedfon.fon=vgafix.fon"
			elseif low == "286grabber" then
				replacement = "286grabber=vgacolor.gr2"
			elseif low == "386grabber" then
				replacement = "386grabber=vga.gr3"
			end
		elseif section == "boot.description" then
			if low == "network.drv" then
				replacement = "network.drv=No Network Installed"
			end
		elseif section == "386enh" then
			if low == "network" then
				-- real mode does not load the 386 network VxD chain
				drop = true
			end
		elseif section == "keyboard" then
			if low == "type" then
				replacement = "type=4" -- enhanced 101/102-key
			elseif low == "subtype" then
				replacement = "subtype=0"
			end
		end
		if replacement then
			out[#out + 1] = replacement
		elseif not drop and t ~= "" then
			out[#out + 1] = line
		end
	end
	machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM.INI", table.concat(out, "\r\n") .. "\r\n")
end

-- SETUP.INF coverage audit: every file a section references, whether it is
-- present in the decompressed media, and whether Install.seed stages it.
function Install.audit()
	local sections = parseInf(fs.readFile(STAGED .. "/SETUP.INF"))
	local report = {}
	for _, name in ipairs(AUDIT_SECTIONS) do
		local seen = {}
		local files = {}
		local present, compressed, missing = 0, 0, 0
		for _, entry in ipairs(sections[name] or {}) do
			local entries = entryFiles(entry)
			-- [shell] lists "progman.exe" without a disk prefix
			if name == "shell" and #entries == 0 then
				local bare = string.match(entry, "^([%w%._%-]+%.[%w]+)")
				if bare then
					entries[1] = string.upper(bare)
				end
			end
			for _, file in ipairs(entries) do
				if not seen[file] then
					seen[file] = true
					local exists = fs.isFile(STAGED .. "/" .. file)
					-- Microsoft ships DOS drivers compressed as .SY$; they
					-- need EXPAND.EXE before they can be used.
					local packed = false
					if not exists then
						local candidate = string.gsub(file, "%.SYS$", ".SY$")
						packed = candidate ~= file and fs.isFile(STAGED .. "/" .. candidate)
					end
					if exists then
						present += 1
					elseif packed then
						compressed += 1
					else
						missing += 1
					end
					files[#files + 1] = { name = file, present = exists, compressed = packed }
				end
			end
		end
		report[#report + 1] = {
			section = name,
			stagedTo = Install.STAGED_SECTIONS[name],
			files = files,
			present = present,
			compressed = compressed,
			missing = missing,
		}
	end
	return report
end

return Install
