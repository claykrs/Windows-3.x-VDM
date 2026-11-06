--!nonstrict
-- app_harness.lua -- boots the genuine Windows 3.0a WIN.COM/KERNEL from the
-- SETUP.INF install, optionally launches a built-in application through the
-- WIN.COM command line, and reports exactly where the boot stopped.
--
-- It deliberately never fakes a launch: if the guest does not reach an
-- AH=4Bh EXEC of the application, the report says so and names the final
-- CS:IP, the spinning address, and the last DOS calls.
--
-- Usage:
--   lune run tools/app_harness.lua                      plain WIN.COM boot
--   lune run tools/app_harness.lua boot CALC            boot + CALC on the WIN cmdline
--   lune run tools/app_harness.lua boot CALC --via ini  queue CALC in WIN.INI run=
--   lune run tools/app_harness.lua boot all --steps 3000000
--   lune run tools/app_harness.lua static all           NE-load every app against
--                                                       the real KERNEL/GDI/USER
--   lune run tools/app_harness.lua list                 NE header facts
--   lune run tools/app_harness.lua audit                SETUP.INF staging coverage
-- Options: --steps N --slice N --hot N --shot DIR --shots --no-shot
--          --via cmdline|ini --cmdline TEXT
--
-- Screenshots are written as dependency-free PNGs under tools/out/ by default;
-- that directory is git-ignored.

const fs = require("@lune/fs")
const process = require("@lune/process")

const Harness = require("./harness")
const Install = require("./install")
const Dos = require("../core/Dos")
const Executables = require("../core/Executables")

const band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift

const STAGED = "media/win30/staged"
const SHOT_DIR = "tools/out"

-- the applications listed in SETUP.INF [win.apps], plus WINVER (which lives
-- outside that section but is part of every Windows 3.0 install)
const BUILTIN_APPS = {
	"PROGMAN",
	"WINFILE",
	"WRITE",
	"PBRUSH",
	"NOTEPAD",
	"CARDFILE",
	"CALENDAR",
	"CALC",
	"CLOCK",
	"REVERSI",
	"CONTROL",
	"TASKMAN",
	"WINVER",
	"CLIPBRD",
	"PIFEDIT",
	"RECORDER",
	"PRINTMAN",
	"SOL",
	"TERMINAL",
	"MSDOS",
}

local function appFileName(name)
	local upper = string.upper(name)
	if string.find(upper, "%.") then
		return upper
	end
	return upper .. ".EXE"
end

local function stagedFile(name)
	local upper = string.upper(name)
	if fs.isFile(STAGED .. "/" .. upper) then
		return STAGED .. "/" .. upper
	end
	-- DLL/DRV before EXE: an import named "PBRUSH" means PBRUSH.DLL, not
	-- PBRUSH.EXE, and "SYSTEM" means SYSTEM.DRV.
	for _, extension in { ".DLL", ".DRV", ".EXE" } do
		local path = STAGED .. "/" .. upper .. extension
		if fs.isFile(path) then
			return path
		end
	end
	-- some media files are shipped without an extension (WINVER)
	local stem = string.match(upper, "^(.*)%.[^%.]+$")
	if stem and fs.isFile(STAGED .. "/" .. stem) then
		return STAGED .. "/" .. stem
	end
	return nil
end

local function fileBytes(path)
	return fs.readFile(path)
end

-- ---------------------------------------------------------------- NE header
-- The fields that decide whether a module can run in Windows 3.0 real mode:
--   0Ch program flags: bit 3 = protected-mode only, bits 4/5/6 = 8086/286/386
--   0Dh application flags: bit 7 = DLL, bits 0..2 = application type
--   36h target OS (02h = Windows), 3Eh expected Windows version (major, minor)
local function parseNE(data)
	local function u8(off)
		return string.byte(data, off + 1)
	end
	local function u16(off)
		return u8(off) + u8(off + 1) * 256
	end
	local function u32(off)
		return u16(off) + u16(off + 2) * 65536
	end
	if #data < 0x40 or u8(0) ~= 0x4D or u8(1) ~= 0x5A then
		return nil
	end
	local ne = u32(0x3C)
	if ne + 0x40 > #data or string.sub(data, ne + 1, ne + 2) ~= "NE" then
		return nil
	end
	local function n8(off)
		return u8(ne + off)
	end
	local function n16(off)
		return u16(ne + off)
	end
	local programFlags = n8(0x0C)
	local appFlags = n8(0x0D)
	local cseg = n16(0x1C)
	local cmod = n16(0x1E)
	local segtab = n16(0x22)
	local restab = n16(0x26)
	local modtab = n16(0x28)
	local imptab = n16(0x2A)
	local unit = lshift(1, n16(0x32))

	local moduleName = ""
	if restab > 0 and n8(restab) > 0 then
		local length = n8(restab)
		for i = 1, math.min(length, 20) do
			moduleName ..= string.char(n8(restab + i))
		end
	end

	local imports, seen = {}, {}
	local importedNames = {}
	if modtab > 0 and imptab > 0 then
		for index = 0, cmod - 1 do
			local entry = imptab + n16(modtab + index * 2)
			local length = n8(entry)
			local name = ""
			for i = 1, math.min(length, 20) do
				name ..= string.char(n8(entry + i))
			end
			local upper = string.upper(name)
			importedNames[index + 1] = upper
			if upper ~= "" and not seen[upper] then
				seen[upper] = true
				imports[#imports + 1] = upper
			end
		end
	end
	table.sort(imports)

	-- Enumerate every imported ordinal/name from the relocation records. This
	-- is the check that answers "needs a missing DLL/export" without having to
	-- fit the app's segments in the 640K DOS arena.
	local refs, refSeen = {}, {}
	for index = 1, cseg do
		local entry = segtab + (index - 1) * 8
		local sector = n16(entry)
		local length = n16(entry + 2)
		local flags = n16(entry + 4)
		if length > 0 and band(flags, 0x0100) ~= 0 then
			local relocOff = sector * unit + length
			local count = u16(relocOff)
			for r = 0, count - 1 do
				local record = relocOff + 2 + r * 8
				local rtype = band(u8(record + 1), 3)
				local target1 = u16(record + 4)
				local target2 = u16(record + 6)
				local ref = nil
				if rtype == 1 then
					ref = { module = importedNames[target1] or ("#" .. target1), ordinal = target2 }
				elseif rtype == 2 then
					local nameOff = imptab + target2
					local nameLen = n8(nameOff)
					local name = ""
					for i = 1, math.min(nameLen, 40) do
						name ..= string.char(n8(nameOff + i))
					end
					ref = {
						module = importedNames[target1] or ("#" .. target1),
						name = string.upper(name),
					}
				end
				if ref then
					local key = ref.module .. "#" .. tostring(ref.ordinal or ref.name)
					if not refSeen[key] then
						refSeen[key] = true
						refs[#refs + 1] = ref
					end
				end
			end
		end
	end

	local major, minor = n8(0x3F), n8(0x3E)
	local protectedOnly = band(programFlags, 0x08) ~= 0
	local realMode
	if major < 3 then
		realMode = true
	elseif major == 3 then
		realMode = not protectedOnly
	else
		realMode = false
	end
	-- No CPU bits is the 8086-compatible baseline Windows 3.0 apps use when
	-- the linker does not mark a higher instruction set.
	local cpu = "8086"
	if band(programFlags, 0x40) ~= 0 then
		cpu = "386"
	elseif band(programFlags, 0x20) ~= 0 then
		cpu = "286"
	elseif band(programFlags, 0x10) ~= 0 then
		cpu = "8086"
	elseif band(programFlags, 0x80) ~= 0 then
		cpu = "8086+x87"
	end

	return {
		moduleName = moduleName,
		linker = ("%d.%d"):format(n8(0x02), n8(0x03)),
		expected = ("%d.%d"):format(major, minor),
		expectedMajor = major,
		targetOS = n8(0x36),
		programFlags = programFlags,
		appFlags = appFlags,
		dll = band(appFlags, 0x80) ~= 0,
		protectedOnly = protectedOnly,
		realMode = realMode,
		cpu = cpu,
		segments = cseg,
		imports = imports,
		importRefs = refs,
		entrySeg = n16(0x16),
		entryOff = n16(0x14),
	}
end

-- --------------------------------------------------------------- PNG output
local CRC_TABLE = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if band(c, 1) ~= 0 then
			c = bxor(0xEDB88320, rshift(c, 1))
		else
			c = rshift(c, 1)
		end
	end
	CRC_TABLE[n] = c
end

local function crc32(text)
	local c = 0xFFFFFFFF
	for i = 1, #text do
		local index = band(bxor(c, string.byte(text, i)), 0xFF)
		c = bxor(CRC_TABLE[index], rshift(c, 8))
	end
	return bxor(c, 0xFFFFFFFF)
end

local function be32(value)
	return string.char(
		band(rshift(value, 24), 0xFF),
		band(rshift(value, 16), 0xFF),
		band(rshift(value, 8), 0xFF),
		band(value, 0xFF)
	)
end

local function chunk(kind, data)
	return be32(#data) .. kind .. data .. be32(crc32(kind .. data))
end

local function adler32(text)
	local a, b = 1, 0
	for i = 1, #text do
		a = (a + string.byte(text, i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

-- zlib stream using stored (uncompressed) deflate blocks: keeps the encoder
-- dependency-free while producing a standard PNG any viewer can open.
local function zlibStored(raw)
	local parts = { "\120\1" }
	local position = 1
	while position <= #raw do
		local block = string.sub(raw, position, position + 65534)
		local final = position + 65535 > #raw
		local length = #block
		local inverse = bxor(length, 0xFFFF)
		parts[#parts + 1] = string.char(final and 1 or 0)
		parts[#parts + 1] = string.char(
			band(length, 0xFF),
			band(rshift(length, 8), 0xFF),
			band(inverse, 0xFF),
			band(rshift(inverse, 8), 0xFF)
		)
		parts[#parts + 1] = block
		position += length
	end
	parts[#parts + 1] = be32(adler32(raw))
	return table.concat(parts)
end

local function encodePng(rgba, width, height)
	local raw = buffer.create(height * (1 + width * 3))
	for y = 0, height - 1 do
		local row = y * (1 + width * 3)
		buffer.writeu8(raw, row, 0) -- filter: none
		for x = 0, width - 1 do
			local source = (y * width + x) * 4
			local target = row + 1 + x * 3
			buffer.writeu8(raw, target, buffer.readu8(rgba, source))
			buffer.writeu8(raw, target + 1, buffer.readu8(rgba, source + 1))
			buffer.writeu8(raw, target + 2, buffer.readu8(rgba, source + 2))
		end
	end
	local ihdr = be32(width) .. be32(height) .. "\8\2\0\0\0"
	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", ihdr)
		.. chunk("IDAT", zlibStored(buffer.tostring(raw)))
		.. chunk("IEND", "")
end

local function ensureParent(path)
	local dir = string.match(path, "^(.*)[/\\][^/\\]*$")
	if dir and not fs.isDir(dir) then
		fs.writeDir(dir)
	end
end

local function frameStats(rgba, width, height)
	local nonBlack, colors, distinct = 0, {}, 0
	local limit = width * height - 1
	for index = 0, limit do
		local offset = index * 4
		local red = buffer.readu8(rgba, offset)
		local green = buffer.readu8(rgba, offset + 1)
		local blue = buffer.readu8(rgba, offset + 2)
		if red ~= 0 or green ~= 0 or blue ~= 0 then
			nonBlack += 1
		end
		local key = red * 65536 + green * 256 + blue
		if not colors[key] then
			colors[key] = true
			distinct += 1
		end
	end
	return nonBlack, distinct
end

local function saveFrame(machine, basePath)
	if not machine.vga then
		return nil, "no VGA device"
	end
	local info = machine.vga:modeInfo()
	local rgba = machine.vga:snapshotRGBA()
	ensureParent(basePath)
	local png = basePath .. ".png"
	fs.writeFile(png, encodePng(rgba, info.width, info.height))
	local nonBlack, colors = frameStats(rgba, info.width, info.height)
	return {
		path = png,
		mode = info.mode,
		kind = info.kind,
		width = info.width,
		height = info.height,
		nonBlack = nonBlack,
		colors = colors,
	}
end

-- ------------------------------------------------------------------ tracing
-- One wrapper shared by every machine: the active trace table is swapped
-- before each run, so nested boots never stack DOS wrappers.
local activeTrace = nil
const realInt21 = Dos.int21
Dos.int21 = function(self)
	local trace = activeTrace
	if not trace then
		return realInt21(self)
	end
	const cpu = self.machine.cpu
	const site = ("%04X:%04X"):format(cpu.cs, band(cpu.ip - 2, 0xFFFF))
	const ah = band(rshift(cpu.r[1], 8), 0xFF)
	local path = nil
	if ah == 0x3C or ah == 0x3D or ah == 0x41 or ah == 0x43 or ah == 0x4B then
		-- raw (unresolved) path: device opens must show "CON", not C:\WINDOWS\CON
		local ok, value = pcall(function()
			return self:readRawAsciz(cpu)
		end)
		if ok then
			path = value
		end
	end
	local execTail = nil
	if ah == 0x4B then
		const block = lshift(cpu.es, 4) + cpu.r[4]
		const cmdOff = self.machine.mem:read16(block + 2)
		const cmdSeg = self.machine.mem:read16(block + 4)
		if cmdSeg ~= 0 then
			const base = lshift(cmdSeg, 4) + cmdOff
			const length = self.machine.mem:read8(base)
			local chars = {}
			for i = 1, math.min(length, 127) do
				chars[#chars + 1] = string.char(self.machine.mem:read8(base + i))
			end
			execTail = table.concat(chars)
		end
	end
	realInt21(self)
	const cf = cpu:getF(1)
	trace.count += 1
	trace.byAh[ah] = (trace.byAh[ah] or 0) + 1
	const entry = {
		site = site,
		ah = ah,
		path = path,
		ax = cpu.r[1],
		cf = cf,
	}
	trace.recent[#trace.recent + 1] = entry
	if #trace.recent > 40 then
		table.remove(trace.recent, 1)
	end
	if path then
		if ah == 0x3D then
			trace.opens[#trace.opens + 1] = path
			if #trace.opens > 24 then
				table.remove(trace.opens, 1)
			end
		elseif ah == 0x4B then
			trace.execs[#trace.execs + 1] = { path = path, tail = execTail }
		end
	end
end

local function newTrace()
	return {
		count = 0,
		byAh = {},
		recent = {},
		opens = {},
		execs = {},
		win16 = 0,
		int2f = 0,
	}
end

local function attachTrace(machine, trace)
	local original = machine.cpu.defaultInts[0x2F]
	machine.cpu.defaultInts[0x2F] = function(cpu)
		trace.int2f += 1
		if original then
			original(cpu)
		end
	end
	const realWinInt80 = machine.winInt80
	machine.winInt80 = function(self)
		trace.win16 += 1
		return realWinInt80(self)
	end
end

-- -------------------------------------------------------------- hot sampling
local function topHot(samples, count)
	local list = {}
	for pc, steps in samples do
		list[#list + 1] = { pc = pc, steps = steps }
	end
	table.sort(list, function(a, b)
		return a.steps > b.steps
	end)
	local out = {}
	for index = 1, math.min(count, #list) do
		out[#out + 1] = list[index]
	end
	return out
end

-- --------------------------------------------------------------- NE loading
const CORE_MODULES = {
	"KERNEL",
	"KEYBOARD.DRV",
	"MOUSE.DRV",
	"SOUND.DRV",
	"SYSTEM.DRV",
	"COMM.DRV",
	"VGA.DRV",
	"GDI",
	"USER",
}

const MODULE_ALIASES = {
	DISPLAY = "VGA.DRV",
}

local function modulePath(name)
	local key = string.upper(MODULE_ALIASES[string.upper(name)] or name)
	return stagedFile(key)
end

-- load the real Windows core (and recursive dependencies) into a fresh
-- machine. Returns machine, loaded list, missing dependency list.
local function loadCore()
	const machine = Harness.newMachine({ timerInterval = 25_000 })
	const loaded, missing = {}, {}
	local loading = {}

	local function loadModule(name)
		const key = string.upper(MODULE_ALIASES[string.upper(name)] or name)
		if machine.winImages[key] then
			return machine.winImages[key]
		end
		if loading[key] then
			return nil -- dependency cycle; the already-registered image wins
		end
		const path = modulePath(key)
		if not path then
			missing[#missing + 1] = key
			return nil
		end
		const data = fileBytes(path)
		const info = parseNE(data)
		loading[key] = true
		for _, imported in ipairs(info and info.imports or {}) do
			if not machine.winImages[imported] then
				loadModule(imported)
			end
		end
		local module = nil
		local ok, value = pcall(function()
			return Executables.loadNEImage(machine, buffer.fromstring(data), key)
		end)
		loading[key] = nil
		if not ok then
			error(value)
		end
		module = value
		-- also register the file/key name: an import names the module
		-- ("WIN87EM"), which is not always the DLL's resident name
		machine.winImages[key] = module
		loaded[#loaded + 1] = { name = key, module = module }
		return module
	end

	local ok, err = pcall(function()
		for _, name in CORE_MODULES do
			loadModule(name)
		end
	end)
	return machine, loaded, missing, loadModule, ok, err
end

-- verify that every imported ordinal/name exists in the loaded real images
local function unresolvedImports(machine, refs)
	local missing = {}
	for _, ref in refs do
		local image = machine.winImages[ref.module]
		if not image then
			missing[#missing + 1] = ref.module .. " (no image)"
		elseif ref.ordinal then
			if not image.entries[ref.ordinal] then
				missing[#missing + 1] = ("%s#%d (no export)"):format(ref.module, ref.ordinal)
			end
		elseif not image.resident[ref.name] then
			missing[#missing + 1] = ("%s!%s (no export)"):format(ref.module, ref.name)
		end
	end
	return missing
end

-- ------------------------------------------------------------------- modes
local function listApps(apps)
	print(
		("%-12s %8s %7s %6s %6s %5s %5s %5s  %s"):format(
			"app",
			"bytes",
			"linker",
			"reqWin",
			"minOS",
			"cpu",
			"real",
			"segs",
			"imports"
		)
	)
	for _, name in apps do
		const file = appFileName(name)
		const path = stagedFile(file)
		if not path then
			print(("%-12s %8s  MISSING from %s"):format(file, "-", STAGED))
			continue
		end
		const data = fileBytes(path)
		const info = parseNE(data)
		if not info then
			print(("%-12s %8d  not an NE image"):format(file, #data))
			continue
		end
		print(
			("%-12s %8d %7s %6s %6s %5s %5s %5d  %s"):format(
				file,
				#data,
				info.linker,
				info.expected,
				info.targetOS == 2 and "Win16" or ("OS" .. info.targetOS),
				info.cpu,
				info.realMode and "yes" or "NO",
				info.segments,
				table.concat(info.imports, " ")
			)
		)
	end
end

local function audit()
	const report = Install.audit()
	print("SETUP.INF coverage (VGA real-mode profile)")
	print(
		("%-20s %5s %5s %6s %7s  %s"):format(
			"section",
			"files",
			"ok",
			"packed",
			"missing",
			"Install.seed stages"
		)
	)
	for _, row in report do
		print(
			("%-20s %5d %5d %6d %7d  %s"):format(
				row.section,
				#row.files,
				row.present,
				row.compressed,
				row.missing,
				row.stagedTo or "- (not staged)"
			)
		)
	end
	print("")
	print("files only present compressed (.SY$, need EXPAND.EXE):")
	local packed = false
	for _, row in report do
		for _, file in row.files do
			if file.compressed then
				packed = true
				print(("  %-20s %s"):format(row.section, file.name))
			end
		end
	end
	if not packed then
		print("  (none)")
	end
	print("")
	print("files referenced by SETUP.INF but absent from the media:")
	local any = false
	for _, row in report do
		for _, file in row.files do
			if not file.present and not file.compressed then
				any = true
				print(("  %-20s %s"):format(row.section, file.name))
			end
		end
	end
	if not any then
		print("  (none)")
	end
end

local function loadAppsStatic(apps)
	print("=== static NE load: real KERNEL/GDI/USER + app image ===")
	for _, name in apps do
		const file = appFileName(name)
		const path = stagedFile(file)
		if not path then
			print(("%-12s MISSING from %s"):format(file, STAGED))
			continue
		end
		const machine, _, _, loadModule, coreOk, coreErr = loadCore()
		if not coreOk then
			print(("%-12s CORE LOAD FAILED: %s"):format(file, tostring(coreErr)))
			continue
		end
		const data = fileBytes(path)
		const info = parseNE(data)
		if not info then
			print(("%-12s not an NE image"):format(file))
			continue
		end
		local missingDeps = {}
		for _, dependency in info.imports do
			if not machine.winImages[dependency] then
				if modulePath(dependency) then
					local okDep, errDep = pcall(loadModule, dependency)
					if not okDep then
						missingDeps[#missingDeps + 1] = dependency
							.. " ("
							.. tostring(errDep)
							.. ")"
					end
				else
					missingDeps[#missingDeps + 1] = dependency .. " (missing file)"
				end
			end
		end
		local ok, module = pcall(function()
			return Executables.loadNEImage(machine, buffer.fromstring(data), string.upper(name))
		end)
		if ok then
			print(
				("%-12s LOADED  segs=%d entry=%d:%04X dgroup=%s imports=%s"):format(
					file,
					#module.segBases,
					module.entrySeg,
					module.entryOff,
					module.dgroup and ("%04X"):format(module.dgroup) or "none",
					table.concat(info.imports, " ")
				)
			)
		else
			local message = tostring(module)
			local unresolved = unresolvedImports(machine, info.importRefs)
			if string.find(message, "out of conventional memory", 1, true) then
				print(
					("%-12s IMAGE OK (segs=%d, %d imports) but the loader ran out of the 640K DOS arena"):format(
						file,
						info.segments,
						#info.importRefs
					)
				)
				if #unresolved == 0 then
					print(
						("%-12s   all %d imports resolve against real KERNEL/GDI/USER/DLL images"):format(
							file,
							#info.importRefs
						)
					)
				else
					print(
						("%-12s   unresolved imports: %s"):format(
							file,
							table.concat(unresolved, ", ")
						)
					)
				end
			else
				print(("%-12s FAILED  %s"):format(file, message))
				if #unresolved > 0 then
					print(
						("%-12s   unresolved imports: %s"):format(
							file,
							table.concat(unresolved, ", ")
						)
					)
				end
			end
		end
		if #missingDeps > 0 then
			print(
				("%-12s   missing dependency files: %s"):format(
					file,
					table.concat(missingDeps, " ")
				)
			)
		end
	end
	print("(static load proves the NE loader + imports; it does not execute app code)")
end

-- Boot WIN.COM with an optional application on its command line.
local function bootOnce(app, options)
	-- Diagnostic PIT: 25k keeps the default step budget reaching USER, but it
	-- also fires faster than a real 18.2 Hz PIT at ~1M instr/sec and can trip
	-- KERNEL's reentrancy guards. Boots that need to run guest code should use
	-- --timer 55000; the production default is 55000.
	const machine = Harness.newMachine({ timerInterval = options.timer })
	const staged = Install.seed(machine)
	const stageStats = Install.stageStats
	if options.appDir then
		for _, entry in fs.readDir(options.appDir) do
			const path = options.appDir .. "/" .. entry
			if not fs.isDir(path) then
				const name = string.upper(entry)
				const data = fs.readFile(path)
				machine.vfs:writeFile("C:\\WINDOWS\\" .. name, data)
				if string.match(name, "%.DLL$") then
					machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM\\" .. name, data)
				end
			end
		end
	end
	Install.writeSystemIni(machine)
	local via = options.via or "cmdline"
	if app and via == "ini" then
		Install.setWinIniRun(machine, "C:\\WINDOWS\\" .. appFileName(app))
	end
	machine.dos.cwd = "C:\\WINDOWS"
	machine.vfs.cwd = "C:\\WINDOWS"
	const winCom = machine.vfs:readFile("C:\\WINDOWS\\WIN.COM")
	machine:loadCOM(buffer.fromstring(winCom), nil, "C:\\WINDOWS\\WIN.COM")

	local commandLine = ""
	if options.cmdline then
		commandLine = options.cmdline
	elseif app and via == "cmdline" then
		commandLine = " C:\\WINDOWS\\" .. appFileName(app)
	end
	if commandLine ~= "" then
		const psp = machine.pspSeg or machine.cpu.cs
		const base = lshift(psp, 4)
		machine.mem:write8(base + 0x80, #commandLine)
		machine.mem:writeString(base + 0x81, commandLine)
		machine.mem:write8(base + 0x81 + #commandLine, 0x0D)
	end

	const trace = newTrace()
	attachTrace(machine, trace)
	activeTrace = trace

	local steps, samples = 0, {}
	local tailSamples = {}
	local firstZero = nil
	local fault = nil
	local idleRuns = 0
	local keyIndex, keyAt = 1, options.keyAt or 0
	const ok, err = pcall(function()
		while steps < options.steps and not machine.exitCode do
			-- a guest inside HLT is idle, not finished: the next run() wakes it
			-- on the PIT. Only a keyboard wait or a DOS exit ends the boot.
			if machine.waiting == "keyboard" then
				break
			end
			const ran = machine:run(options.slice)
			if ran == 0 then
				if machine.waiting or machine.exitCode then
					break
				end
				idleRuns += 1
				if idleRuns > 3 then
					break
				end
			else
				idleRuns = 0
			end
			if ran == 0 then
				continue
			end
			steps += ran
			if options.keys and keyIndex <= #options.keys and steps >= keyAt then
				const scan = options.keys[keyIndex]
				machine:keyDown(scan)
				steps += machine:run(20_000)
				machine:keyUp(scan)
				steps += machine:run(20_000)
				keyIndex += 1
				keyAt += options.keyGap
			end
			const pc = ("%04X:%04X"):format(machine.cpu.cs, machine.cpu.ip)
			samples[pc] = (samples[pc] or 0) + ran
			tailSamples[#tailSamples + 1] = { pc = pc, steps = ran }
			if #tailSamples > 12 then
				table.remove(tailSamples, 1)
			end
			-- a PC in zeroed memory is executing ADD [BX+SI],AL forever: a
			-- wild jump, not a scheduler loop. Record where it first happened.
			if not firstZero then
				const address = lshift(machine.cpu.cs, 4) + machine.cpu.ip
				local zero = true
				for i = 0, 7 do
					if machine.mem:read8(address + i) ~= 0 then
						zero = false
						break
					end
				end
				if zero then
					firstZero = { pc = pc, steps = steps }
				end
			end
		end
	end)
	if not ok then
		fault = tostring(err)
	end
	activeTrace = nil

	const hot = topHot(samples, options.hot)
	-- a spin loop is the consecutive run of identical sampled PCs at the end
	local spinPc, spinSteps = nil, 0
	for index = #tailSamples, 1, -1 do
		if not spinPc then
			spinPc = tailSamples[index].pc
		end
		if tailSamples[index].pc ~= spinPc then
			break
		end
		spinSteps += tailSamples[index].steps
	end
	if spinSteps < 2 * options.slice then
		spinPc = nil
	end
	local launched = false
	local opened = false
	if app then
		const wanted = appFileName(app)
		for _, exec in trace.execs do
			-- only the EXEC target counts; the KERNEL command tail also names
			-- the app, but that is not a launch
			if exec.path and string.find(string.upper(exec.path), wanted, 1, true) then
				launched = true
				break
			end
		end
		-- KERNEL's WinExec/LoadModule path does not go through DOS AH=4Bh;
		-- an open of the app image means the guest loaded it.
		for _, path in trace.opens do
			if string.find(string.upper(path), wanted, 1, true) then
				opened = true
				break
			end
		end
	end
	local shot = nil
	if options.shot and machine.vga then
		local base = options.shot
		if app then
			base ..= "-" .. string.lower(string.gsub(appFileName(app), "%..*$", ""))
		else
			base ..= "-win"
		end
		local okShot, value = pcall(function()
			return saveFrame(machine, base)
		end)
		if okShot then
			shot = value
		end
	end
	return {
		app = app and appFileName(app) or nil,
		commandLine = commandLine,
		via = via,
		staged = staged,
		missing = stageStats and stageStats.missing or {},
		launched = launched,
		opened = opened,
		steps = steps,
		budget = options.steps,
		halted = machine.cpu.halted,
		waiting = machine.waiting,
		exitCode = machine.exitCode,
		cs = machine.cpu.cs,
		ip = machine.cpu.ip,
		fault = fault,
		hot = hot,
		spinPc = spinPc,
		spinSteps = spinSteps,
		firstZero = firstZero,
		trace = trace,
		shot = shot,
		output = machine:outputText(),
		diagnostics = machine.diagnostics,
		machine = machine,
	}
end

local function verdictFor(result)
	local text
	if result.fault then
		return "FAULT: " .. result.fault
	end
	if result.launched then
		text = "APP EXEC REACHED"
	else
		const top = result.hot[1]
		const share = top and top.steps / math.max(result.steps, 1) or 0
		if result.halted and result.waiting == "keyboard" then
			text = "BLOCKED ON KEYBOARD before app EXEC"
		elseif result.halted then
			text = ("EXITED exit=%s before app EXEC"):format(tostring(result.exitCode))
		elseif result.spinPc then
			text = ("BLOCKED before app EXEC -- spin at %s (last %d steps)"):format(
				result.spinPc,
				result.spinSteps
			)
		elseif top and share >= 0.75 and result.steps >= 500_000 then
			text = ("BLOCKED before app EXEC -- hot loop at %s (%.0f%% of steps)"):format(
				top.pc,
				100 * share
			)
		elseif result.firstZero then
			text = ("WILD JUMP into zero-filled memory at %s after %d steps before app EXEC"):format(
				result.firstZero.pc,
				result.firstZero.steps
			)
		else
			text = ("BUDGET EXHAUSTED at %04X:%04X before app EXEC"):format(result.cs, result.ip)
		end
	end
	if result.app and result.via == "ini" then
		text ..= (" (queued via WIN.INI [windows] run=%s)"):format(result.app)
	end
	return text
end

local function printBoot(result, verbose)
	const title = result.app and ("boot with " .. result.app) or "plain WIN.COM boot"
	print(("=== %s ==="):format(title))
	print(
		("steps=%d/%d  halted=%s  waiting=%s  exit=%s  stop=%04X:%04X  cmdline=%s"):format(
			result.steps,
			result.budget,
			tostring(result.halted),
			tostring(result.waiting),
			tostring(result.exitCode),
			result.cs,
			result.ip,
			result.commandLine == "" and "(none)" or ("[" .. result.commandLine .. "]")
		)
	)
	if verbose then
		print(
			("install: %d VFS files staged, %d media files missing"):format(
				result.staged,
				#result.missing
			)
		)
		if #result.missing > 0 then
			print("  missing: " .. table.concat(result.missing, ", "))
		end
		local hs = {}
		for _, entry in result.hot do
			hs[#hs + 1] = ("%s=%d"):format(entry.pc, entry.steps)
		end
		print("hot spots: " .. (#hs > 0 and table.concat(hs, " ") or "(none)"))
		if result.spinPc then
			print(("final spin: %s for %d steps"):format(result.spinPc, result.spinSteps))
		end
		if result.firstZero then
			print(
				("first zero-fill execution: %s after %d steps"):format(
					result.firstZero.pc,
					result.firstZero.steps
				)
			)
		end
		local mem = result.machine.mem
		local address = lshift(result.cs, 4) + result.ip
		local bytes = {}
		for i = 0, 15 do
			bytes[#bytes + 1] = ("%02X"):format(mem:read8(address + i))
		end
		print("code at stop: " .. table.concat(bytes, " "))
	end
	const ahs = {}
	for ah, count in result.trace.byAh do
		ahs[#ahs + 1] = { ah = ah, count = count }
	end
	table.sort(ahs, function(a, b)
		return a.count > b.count
	end)
	local parts = {}
	for _, entry in ahs do
		parts[#parts + 1] = ("AH=%02X x%d"):format(entry.ah, entry.count)
	end
	print(
		("DOS INT 21h calls: %d%s"):format(
			result.trace.count,
			#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
		)
	)
	print(
		("INT 80h thunk calls: %d; INT 2Fh multiplex calls: %d"):format(
			result.trace.win16,
			result.trace.int2f
		)
	)
	if #result.trace.execs > 0 then
		local execs = {}
		for _, exec in result.trace.execs do
			execs[#execs + 1] = (exec.path or "?") .. " [" .. (exec.tail or "") .. "]"
		end
		print("EXEC targets: " .. table.concat(execs, " | "))
	else
		print("EXEC targets: (none)")
	end
	if verbose then
		print("last DOS calls:")
		for _, entry in result.trace.recent do
			print(
				("  %s AH=%02X %s-> AX=%04X CF=%d"):format(
					entry.site,
					entry.ah,
					entry.path and ('"' .. entry.path .. '" ') or "",
					entry.ax,
					entry.cf and 1 or 0
				)
			)
		end
	end
	if #result.trace.opens > 0 then
		print("recent opens: " .. table.concat(result.trace.opens, " | "))
	end
	if result.shot then
		print(
			("VGA: mode=%02X %s %dx%d, %d non-black px, %d colours -> %s"):format(
				result.shot.mode,
				result.shot.kind,
				result.shot.width,
				result.shot.height,
				result.shot.nonBlack,
				result.shot.colors,
				result.shot.path
			)
		)
	end
	if #result.output > 0 then
		print("guest output: " .. result.output)
	end
	if #result.diagnostics > 0 then
		local last = result.diagnostics[#result.diagnostics]
		print("last diagnostic: " .. last)
	end
	print("verdict: " .. verdictFor(result))
end

-- -------------------------------------------------------------------- main
local function parseArgs(args)
	local options = {
		command = "boot",
		app = nil,
		all = false,
		steps = 4_000_000,
		slice = 50_000,
		hot = 8,
		shot = SHOT_DIR .. "/boot",
		shots = false,
		cmdline = nil,
		via = "cmdline",
		timer = 25_000,
		appDir = nil,
		keys = nil,
		keyAt = 12_000_000,
		keyGap = 2_000_000,
	}
	local index = 1
	while index <= #args do
		const value = args[index]
		if value == "boot" or value == "static" or value == "list" or value == "audit" then
			options.command = value
		elseif value == "--app" then
			index += 1
			options.app = args[index]
		elseif value == "--steps" then
			index += 1
			options.steps = tonumber(args[index]) or options.steps
		elseif value == "--slice" then
			index += 1
			options.slice = tonumber(args[index]) or options.slice
		elseif value == "--hot" then
			index += 1
			options.hot = tonumber(args[index]) or options.hot
		elseif value == "--cmdline" then
			index += 1
			options.cmdline = args[index] or ""
		elseif value == "--via" then
			index += 1
			options.via = args[index] or "cmdline"
		elseif value == "--app-dir" then
			index += 1
			options.appDir = args[index]
		elseif value == "--keys" then
			index += 1
			options.keys = {}
			for part in string.gmatch(args[index] or "", "[^,]+") do
				options.keys[#options.keys + 1] = tonumber(part, 16)
			end
		elseif value == "--key-at" then
			index += 1
			options.keyAt = tonumber(args[index]) or options.keyAt
		elseif value == "--key-gap" then
			index += 1
			options.keyGap = tonumber(args[index]) or options.keyGap
		elseif value == "--timer" then
			index += 1
			options.timer = tonumber(args[index]) or options.timer
		elseif value == "--shot" then
			index += 1
			options.shot = args[index] or options.shot
		elseif value == "--shots" then
			options.shots = true
		elseif value == "--no-shot" then
			options.shot = nil
		elseif value == "--all" then
			options.all = true
		elseif string.sub(value, 1, 2) ~= "--" and not options.app then
			options.app = value
		end
		index += 1
	end
	return options
end

local function selectedApps(options)
	if options.app == "all" or options.all then
		return BUILTIN_APPS
	end
	if options.app then
		return { options.app }
	end
	return BUILTIN_APPS
end

const options = parseArgs(process.args)

if options.command == "list" then
	listApps(selectedApps(options))
elseif options.command == "audit" then
	audit()
elseif options.command == "static" then
	loadAppsStatic(selectedApps(options))
else
	const apps = selectedApps(options)
	if options.app == "all" or options.all then
		print(("booting %d applications with %d-step budget each"):format(#apps, options.steps))
		const rows = {}
		for _, app in apps do
			const shot = options.shots and options.shot or nil
			const result = bootOnce(app, {
				steps = options.steps,
				slice = options.slice,
				hot = options.hot,
				shot = shot,
				cmdline = options.cmdline,
				via = options.via,
				appDir = options.appDir,
			})
			rows[#rows + 1] = { app = result.app, result = result }
		end
		print("")
		print(("%-12s %9s %-12s %-8s %s"):format("app", "steps", "stop", "halted", "verdict"))
		for _, row in rows do
			const result = row.result
			print(
				("%-12s %9d %04X:%04X    %-8s %s"):format(
					row.app,
					result.steps,
					result.cs,
					result.ip,
					tostring(result.halted),
					verdictFor(result)
				)
			)
		end
	else
		const result = bootOnce(options.app, options)
		printBoot(result, true)
	end
end
