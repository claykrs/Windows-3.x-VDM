--!strict
-- Executables.lua -- DOS .COM / .MZ loaders with PSP construction and relocations.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Executables = {}

export type Entry = {
	seg: number,
	off: number,
	movable: boolean?,
}

export type Module = {
	name: string?,
	segBases: { [number]: number },
	entries: { [number]: Entry },
	resident: { [string]: number },
	importedNames: { [number]: string },
	dgroup: number?,
	entrySeg: number,
	entryOff: number,
	ssIdx: number,
	sp: number,
}

type SegmentInfo = {
	sector: number,
	length: number,
	flags: number,
	minAlloc: number,
}

local function writeEnv(mem: any, envSeg: number, programPath: string?, parentEnvSeg: number?)
	const envBase = lshift(envSeg, 4)
	local position = 0
	if parentEnvSeg and parentEnvSeg ~= 0 then
		const src = lshift(parentEnvSeg, 4)
		local read = 0
		local write = 0
		while read < 0x3F0 do
			local chars: { string } = {}
			while read < 0x3F0 do
				const byte = mem:read8(src + read)
				read += 1
				if byte == 0 then
					break
				end
				chars[#chars + 1] = string.char(byte)
			end
			if #chars == 0 then
				break -- environment terminator
			end
			local entry = table.concat(chars)
			-- WIN.COM needs windir with a trailing separator to find KERNEL,
			-- but KERNEL's profile code appends its own separator. Children
			-- (KERNEL, USER, apps) must see the Windows directory without it,
			-- or every SYSTEM.INI path becomes C:\WINDOWS\\SYSTEM.INI and the
			-- profile lookup silently falls back to defaults (NETWORK.DRV).
			if
				string.sub(string.lower(entry), 1, 7) == "windir="
				and string.sub(entry, -1) == "\\"
			then
				entry = string.sub(entry, 1, -2)
			end
			mem:writeString(envBase + write, entry)
			write += #entry + 1
		end
		position = write
		if position == 0 then
			mem:write8(envBase, 0) -- empty environment still needs its terminator
			position = 1
		end
	else
		const envVars = {
			-- WIN.COM scans for lowercase "windir=" and appends "kernel.exe"
			-- / "system\kernel.exe" directly to the value, so it needs the slash
			"windir=C:\\WINDOWS\\",
			"WINDIR=C:\\WINDOWS\\",
			"PATH=C:\\WINDOWS;C:\\WINDOWS\\SYSTEM",
			"COMSPEC=C:\\WINDOWS\\COMMAND.COM",
		}
		for _, entry in envVars do
			mem:writeString(envBase + position, entry)
			position += #entry + 1
		end
		mem:write8(envBase + position, 0) -- extra NUL
	end
	-- DOS trailer: extra NUL, word count (1), then the program's full path.
	-- KERNEL reads the word after the double NUL and opens the path that follows.
	mem:write8(envBase + position, 0)
	mem:write16(envBase + position + 1, 1)
	mem:writeString(envBase + position + 3, programPath or "C:\\")
end

local function buildPSP(
	mem: any,
	pspSeg: number,
	programPath: string?,
	envSeg: number?,
	parentEnvSeg: number?
)
	const base = lshift(pspSeg, 4)
	mem:write16(base + 0, 0x20CD) -- INT 20h at PSP:0000 (so a bare RET terminates)
	mem:write8(base + 0x80, 0) -- empty command tail
	mem:write8(base + 0x81, 0x0D)

	-- environment block below the PSP (or a separately allocated block)
	const resolvedEnv = envSeg or (pspSeg - 0x40)
	writeEnv(mem, resolvedEnv, programPath, parentEnvSeg)
	mem:write16(base + 0x2C, resolvedEnv) -- PSP:2Ch -> environment segment

	-- terminate / ctrl-break / critical-error vectors (DOS fills these in):
	-- terminate points at the INT 20h at PSP:0000; the other two at IRET stubs
	mem:write16(base + 0x0A, 0x0000)
	mem:write16(base + 0x0C, pspSeg)
	mem:write16(base + 0x0E, 68) -- ctrl-break stub (F100:0044)
	mem:write16(base + 0x10, 0xF100)
	mem:write16(base + 0x12, 72) -- critical-error stub (F100:0048)
	mem:write16(base + 0x14, 0xF100)
end

function Executables.loadCOM(
	machine: any,
	bytes: buffer,
	pspSeg: number?,
	programPath: string?,
	envSeg: number?,
	parentEnvSeg: number?,
	stackParas: number?
): number
	const segment = pspSeg or 0x1000
	const mem = machine.mem
	buildPSP(mem, segment, programPath, envSeg, parentEnvSeg)
	mem:copyFrom(lshift(segment, 4) + 0x100, bytes)
	const cpu = machine.cpu
	cpu.cs, cpu.ds, cpu.es, cpu.ss = segment, segment, segment, segment
	cpu.ip = 0x100
	-- The stack must live inside the program's MCB block. Direct loads get the
	-- initial 0xFF-paragraph PSP block; EXEC COMs get their allocated block.
	const stackTop = math.min((stackParas or 0xFF) * 16 - 2, 0xFFFE)
	cpu.r[5] = stackTop
	machine.pspSeg = segment
	machine.exitCode = nil
	return segment
end

function Executables.loadMZ(
	machine: any,
	bytes: buffer,
	programPath: string?,
	pspSeg: number?,
	envSeg: number?,
	parentEnvSeg: number?,
	programParas: number?
): number
	const mem = machine.mem
	local function u8(off: number): number
		return buffer.readu8(bytes, off)
	end
	local function u16(off: number): number
		return bor(u8(off), lshift(u8(off + 1), 8))
	end

	if u8(0) ~= 0x4D or u8(1) ~= 0x5A then
		error("not an MZ executable (bad magic)")
	end
	const cblp = u16(2) -- bytes on last page
	const cp = u16(4) -- pages in file
	const crlc = u16(6) -- relocation count
	const cparhdr = u16(8) -- header size in paragraphs
	const ss = u16(0x0E)
	const sp = u16(0x10)
	const ip = u16(0x14)
	const cs = u16(0x16)
	const lfarlc = u16(0x18) -- relocation table offset

	-- cp/cblp describe the WHOLE FILE size; the load image excludes the header
	local fileLen = cp * 512
	if cblp > 0 then
		fileLen -= 512 - cblp
	end
	const headerLen = cparhdr * 16
	const imageLen = math.max(fileLen - headerLen, 0)

	const segment = pspSeg or 0x1000
	const imageParas = math.ceil(imageLen / 16)
	-- Load-high: when EXEC supplies a block with slack, put the MZ image at the
	-- top so KERNEL's first fixed allocation (loadSeg+1) is below it.
	const imageBase = if programParas and programParas >= 0x10 + imageParas
		then segment + programParas - imageParas
		else segment + 0x10
	const loadSeg = imageBase

	buildPSP(mem, segment, programPath, envSeg, parentEnvSeg)
	const image = buffer.create(imageLen)
	buffer.copy(image, 0, bytes, headerLen, imageLen)
	mem:copyFrom(lshift(loadSeg, 4), image)

	-- apply relocations: word at (loadSeg + seg):off += loadSeg
	for index = 0, crlc - 1 do
		const off = u16(lfarlc + index * 4)
		const seg = u16(lfarlc + index * 4 + 2)
		const addr = lshift(loadSeg + seg, 4) + off
		mem:write16(addr, band(mem:read16(addr) + loadSeg, 0xFFFF))
	end

	const cpu = machine.cpu
	cpu.ds = segment
	cpu.es = segment
	cpu.ss = loadSeg + ss
	cpu.r[5] = sp
	cpu.cs = loadSeg + cs
	cpu.ip = ip
	machine.pspSeg = segment
	machine.exitCode = nil
	return segment
end

-- NE (Windows 1.x/2.x/3.x real-mode) loader -- REAL format, verified against
-- Windows 3.0a KERNEL/USER/GDI:
--   MZ at 0, e_lfanew (u32 @0x3C) -> NE header:
--   +04 enttab +06 cbenttab +0C flags +0E autodata +14 csip(dword: ip,cs)
--   +18 sssp(dword: sp,ss) +1C cseg +1E cmod +22 segtab +24 rsrctab
--   +26 restab +28 modtab +2A imptab +2C nrestab(dword) +30 cmovent
--   +32 align (sector = 1<<align)
--   Segment entries: [sector:2][len:2][flags:2][minAlloc:2]; flags 0x0100 =
--   relocation data follows the segment image (count word + 8-byte records:
--   [addrType:1][relocType:1][offset:2][target1:2][target2:2]).
--   Entry table bundles: [count:1][segIdx:1] then count entries:
--   fixed = [flags:1][off:2]; segIdx 0xFF = movable = [flags:1][skip:2][seg:1][off:2].

-- parse the entry table into ordinal -> { seg = 1-based seg index, off = offset }
local function parseEntryTable(
	u8: (off: number) -> number,
	neOff: number,
	enttab: number,
	cbenttab: number
): { [number]: Entry }
	const entries: { [number]: Entry } = {}
	local ordinal = 0
	local position = 0
	while position < cbenttab do
		const count = u8(neOff + enttab + position)
		if count == 0 then
			break
		end
		const segIndex = u8(neOff + enttab + position + 1)
		position += 2
		if segIndex == 0 then
			-- ordinal-space bundle: ordinals exist but have no entry data
			ordinal += count
		else
			for _ = 1, count do
				ordinal += 1
				if segIndex == 0xFF then
					-- movable: flags(1) + INT-3F hint(2) + seg(1) + off(2)
					const seg = u8(neOff + enttab + position + 3)
					const off = bor(
						u8(neOff + enttab + position + 4),
						lshift(u8(neOff + enttab + position + 5), 8)
					)
					entries[ordinal] = { seg = seg, off = off, movable = true }
					position += 6
				else
					const off = bor(
						u8(neOff + enttab + position + 1),
						lshift(u8(neOff + enttab + position + 2), 8)
					)
					entries[ordinal] = { seg = segIndex, off = off }
					position += 3
				end
			end
		end
	end
	return entries
end

-- A DOS EXEC of a Windows "bound" executable (MZ stub + NE image) maps the
-- whole file at loadSeg; the tiny MZ stub then jumps straight to the NE entry
-- with segments at their file offsets. Relocations are the loader's job
-- (WIN.COM does this in real Windows), so apply them in place here. All
-- fixups in KERNEL.EXE are internal; imports would need the thunk machinery.
function Executables.relocateBoundNE(
	machine: any,
	bytes: buffer,
	loadSeg: number,
	headerParas: number
): boolean
	const mem = machine.mem
	local function u8(off: number): number
		return buffer.readu8(bytes, off)
	end
	local function u16(off: number): number
		return bor(u8(off), lshift(u8(off + 1), 8))
	end
	local function u32(off: number): number
		return bor(u16(off), lshift(u16(off + 2), 16))
	end

	const neOff = u32(0x3C)
	if u8(neOff) ~= 0x4E or u8(neOff + 1) ~= 0x45 then
		return false
	end
	local function n16(off: number): number
		return u16(neOff + off)
	end

	const enttab, cbenttab = n16(4), n16(6)
	const cseg = n16(0x1C)
	const segtab = n16(0x22)
	const align = n16(0x32)
	const unit = lshift(1, align)
	const imageSeg = loadSeg - headerParas

	const segBases: { [number]: number } = {}
	for index = 1, cseg do
		const entry = segtab + (index - 1) * 8
		segBases[index] = imageSeg + math.floor(n16(entry) * unit / 16)
	end
	const entries = parseEntryTable(u8, neOff, enttab, cbenttab)

	for index = 1, cseg do
		const entry = segtab + (index - 1) * 8
		const sector, length, segFlags = n16(entry), n16(entry + 2), n16(entry + 4)
		if length > 0 and band(segFlags, 0x0100) ~= 0 then
			const relocOff = sector * unit + length
			const count = u16(relocOff)
			for r = 0, count - 1 do
				const record = relocOff + 2 + r * 8
				const addrType = band(u8(record), 0x7F)
				const relocType = u8(record + 1)
				const fixOff = u16(record + 2)
				const target1 = u16(record + 4)
				const target2 = u16(record + 6)
				const rtype = band(relocType, 3)
				local tgtSeg: number, tgtOff: number
				if rtype == 0 then
					if band(target1, 0xFF) == 0xFF then
						const target = entries[target2]
						if not target then
							error(("bound NE fixup: entry %d unresolvable"):format(target2))
						end
						tgtSeg, tgtOff = segBases[target.seg], target.off
					else
						tgtSeg, tgtOff = segBases[target1], target2
					end
				elseif rtype == 1 or rtype == 2 then
					error("bound NE fixup: imports unsupported in a bound image")
				end -- rtype 3: OSFIXUP, skip
				if rtype ~= 3 then
					const addr = lshift(segBases[index], 4) + fixOff
					local chain = mem:read16(addr)
					if addrType == 2 then
						mem:write16(addr, tgtSeg)
					elseif addrType == 3 or addrType == 11 then
						mem:write16(addr, tgtOff)
						mem:write16(addr + 2, tgtSeg)
					else
						error(("bound NE fixup: unsupported address type %d"):format(addrType))
					end
					local guard = 0
					while chain ~= 0xFFFF and chain ~= fixOff and guard < 1000 do
						guard += 1
						const caddr = lshift(segBases[index], 4) + chain
						const follow = mem:read16(caddr)
						if addrType == 2 then
							mem:write16(caddr, tgtSeg)
						else
							mem:write16(caddr, tgtOff)
							mem:write16(caddr + 2, tgtSeg)
						end
						chain = follow
					end
				end
			end
		end
	end
	return true
end

-- load one NE image (executable or DLL): segments + fixups + module registry.
-- Registers itself on machine.winImages when named.
function Executables.loadNEImage(machine: any, bytes: buffer, moduleName: string?): Module
	const mem = machine.mem
	local function u8(off: number): number
		return buffer.readu8(bytes, off)
	end
	local function u16(off: number): number
		return bor(u8(off), lshift(u8(off + 1), 8))
	end
	local function u32(off: number): number
		return bor(u16(off), lshift(u16(off + 2), 16))
	end

	if u8(0) ~= 0x4D or u8(1) ~= 0x5A then
		error("not an MZ executable (bad magic)")
	end
	const neOff = u32(0x3C)
	if u8(neOff) ~= 0x4E or u8(neOff + 1) ~= 0x45 then
		error("NE magic not found at e_lfanew")
	end
	local function n8(off: number): number
		return u8(neOff + off)
	end
	local function n16(off: number): number
		return u16(neOff + off)
	end

	const enttab, cbenttab = n16(4), n16(6)
	const flags = n16(0x0C)
	const autodata = n16(0x0E)
	const csip = u32(neOff + 0x14)
	const sssp = u32(neOff + 0x18)
	const cseg = n16(0x1C)
	const cmod = n16(0x1E)
	const segtab = n16(0x22)
	const restab = n16(0x26)
	const modtab = n16(0x28)
	const imptab = n16(0x2A)
	const align = n16(0x32)
	const unit = lshift(1, align)

	if band(flags, 0x0800) ~= 0 then
		error("NE self-loading modules are not supported")
	end

	const entries = parseEntryTable(u8, neOff, enttab, cbenttab)

	-- resident names: [len:1][name][ordinal:2]
	const resident: { [string]: number } = {}
	if restab > 0 then
		local position = restab
		while true do
			const length = n8(position)
			if length == 0 then
				break
			end
			local name = ""
			for index = 1, length do
				name ..= string.char(n8(position + index))
			end
			resident[string.upper(name)] = n16(position + length + 1)
			position = position + length + 3
		end
	end
	-- non-resident names: the table starts with a length-prefixed module
	-- description (skip it), then [len:1][name][ordinal:2] entries. Its offset
	-- at +2Ch is an absolute file offset, unlike the resident table.
	const nonResidentLength = n16(0x20)
	const nonResidentOffset = bor(n16(0x2C), lshift(n16(0x2E), 16))
	if nonResidentLength > 0 and nonResidentOffset > 0 then
		local position = nonResidentOffset
		const limit = nonResidentOffset + nonResidentLength
		const descriptionLength = u8(position)
		if descriptionLength > 0 then
			position += descriptionLength + 1
			while position < limit and u8(position) == 0 do
				position += 1
			end
		end
		while position < limit do
			const length = u8(position)
			if length == 0 then
				break
			end
			local name = ""
			for index = 1, length do
				name ..= string.char(u8(position + index))
			end
			resident[string.upper(name)] = u16(position + length + 1)
			position = position + length + 3
		end
	end

	-- imported names: module ref table words index into length-prefixed names
	const importedNames: { [number]: string } = {}
	if modtab > 0 and imptab > 0 then
		for index = 0, cmod - 1 do
			const entry = imptab + n16(modtab + index * 2)
			const length = n8(entry)
			local name = ""
			for j = 1, length do
				name ..= string.char(n8(entry + j))
			end
			importedNames[index + 1] = name
		end
	end

	-- pass 1: load all segment images into one arena block (fixups come in
	-- pass 2, after every segBase exists -- segment 1's fixups routinely
	-- reference segment 2+)
	const segBases: { [number]: number } = {}
	const segInfo: { [number]: SegmentInfo } = {}
	local totalParas = 0
	for index = 1, cseg do
		const entry = segtab + (index - 1) * 8
		const length = n16(entry + 2)
		const minAlloc = n16(entry + 6)
		totalParas += math.max(math.ceil(math.max(length, minAlloc) / 16), 1)
	end
	local current = machine:dosAlloc(totalParas + 1)
	if not current then
		error("NE load: out of conventional memory for module")
	end
	for index = 1, cseg do
		const entry = segtab + (index - 1) * 8
		const sector = n16(entry)
		const length = n16(entry + 2)
		const segFlags = n16(entry + 4)
		const minAlloc = n16(entry + 6)
		segInfo[index] = { sector = sector, length = length, flags = segFlags, minAlloc = minAlloc }
		segBases[index] = current
		if length > 0 then
			const image = buffer.create(length)
			buffer.copy(image, 0, bytes, sector * unit, length)
			mem:copyFrom(lshift(current, 4), image)
		end
		if band(segFlags, 0x0008) ~= 0 then
			-- iterated segment: repeated [repeat:2][len:2][data] blocks
			const fileOff = sector * unit
			const expanded = buffer.create(math.max(length, minAlloc, 16))
			local src, dst = 0, 0
			while src < length do
				const repeatCount = bor(u8(fileOff + src), lshift(u8(fileOff + src + 1), 8))
				const blockLen = bor(u8(fileOff + src + 2), lshift(u8(fileOff + src + 3), 8))
				src += 4
				for _ = 1, repeatCount do
					buffer.copy(expanded, dst, bytes, fileOff + src, blockLen)
					dst += blockLen
				end
				src += blockLen
			end
			mem:copyFrom(lshift(current, 4), expanded)
		end
		current += math.max(math.ceil(math.max(length, minAlloc) / 16), 1)
	end

	-- pass 2: relocations
	for index = 1, cseg do
		const info = segInfo[index]
		const length = info.length
		if length > 0 and band(info.flags, 0x0100) ~= 0 then
			const cur = segBases[index]
			const relocOff = info.sector * unit + length
			const count = u16(relocOff)
			for r = 0, count - 1 do
				const record = relocOff + 2 + r * 8
				const addrType = band(u8(record), 0x7F)
				const relocType = u8(record + 1)
				const fixOff = u16(record + 2)
				const target1 = u16(record + 4)
				const target2 = u16(record + 6)

				local tgtSeg: number, tgtOff: number
				const rtype = band(relocType, 3)
				if rtype ~= 3 then
					if rtype == 0 then -- internal
						if band(target1, 0xFF) == 0xFF then
							const target = entries[target2]
							if not target or not segBases[target.seg] then
								error(("NE fixup: own entry %d unresolvable"):format(target2))
							end
							tgtSeg, tgtOff = segBases[target.seg], target.off
						else
							tgtSeg, tgtOff = segBases[target1], target2
						end
					elseif rtype == 1 then -- import by ordinal
						const module = importedNames[target1]
						if not module then
							error(("NE fixup: import module %d missing"):format(target1))
						end
						tgtSeg, tgtOff = machine:resolveWinImport(module, target2)
					elseif rtype == 2 then -- import by name
						const nameOff = imptab + target2
						const nameLen = n8(nameOff)
						local name = ""
						for j = 1, nameLen do
							name ..= string.char(n8(nameOff + j))
						end
						const module = importedNames[target1]
						if not module then
							error(("NE fixup: import module %d missing"):format(target1))
						end
						tgtSeg, tgtOff = machine:resolveWinImportByName(module, name)
					end
					-- OSFIXUP (3): floating point, skip

					const addr = lshift(cur, 4) + fixOff
					const additive = band(relocType, 0x04) ~= 0
					if additive then
						if addrType == 0 then
							mem:write8(addr, band(mem:read8(addr) + tgtOff, 0xFF))
						else
							mem:write16(addr, band(mem:read16(addr) + tgtOff, 0xFFFF))
							if addrType == 3 or addrType == 11 then
								mem:write16(addr + 2, band(mem:read16(addr + 2) + tgtSeg, 0xFFFF))
							end
						end
					else
						-- chained: the word at the fixup location links to the next one
						local chain = mem:read16(addr)
						if addrType == 0 then
							mem:write8(addr, band(tgtOff, 0xFF))
						elseif addrType == 2 then
							mem:write16(addr, tgtSeg)
						elseif addrType == 3 or addrType == 11 then
							mem:write16(addr, tgtOff)
							mem:write16(addr + 2, tgtSeg)
						elseif addrType == 5 then
							mem:write16(addr, tgtOff)
						else
							error(("unsupported NE relocation address type %d"):format(addrType))
						end
						local guard = 0
						while chain ~= 0xFFFF and chain ~= fixOff and guard < 1000 do
							guard += 1
							const caddr = lshift(cur, 4) + chain
							const follow = mem:read16(caddr)
							if addrType == 0 then
								mem:write8(caddr, band(tgtOff, 0xFF))
							elseif addrType == 2 then
								mem:write16(caddr, tgtSeg)
							elseif addrType == 3 or addrType == 11 then
								mem:write16(caddr, tgtOff)
								mem:write16(caddr + 2, tgtSeg)
							elseif addrType == 5 then
								mem:write16(caddr, tgtOff)
							end
							if follow == chain then
								break
							end
							chain = follow
						end
					end
				end
			end
		end
	end

	local selfName = moduleName
	if restab > 0 then
		const length = n8(restab)
		if length > 0 then
			local name = ""
			for index = 1, length do
				name ..= string.char(n8(restab + index))
			end
			selfName = name
		end
	end

	const module: Module = {
		name = moduleName,
		segBases = segBases,
		entries = entries,
		resident = resident,
		importedNames = importedNames,
		dgroup = (autodata > 0) and segBases[autodata] or nil,
		entrySeg = band(rshift(csip, 16), 0xFFFF),
		entryOff = band(csip, 0xFFFF),
		ssIdx = band(rshift(sssp, 16), 0xFFFF),
		sp = band(sssp, 0xFFFF),
	}
	if selfName then
		machine.winImages[string.upper(selfName)] = module
	end
	return module
end

-- executable wrapper: PSP + CPU entry state; DS/ES = DGROUP (Windows convention)
function Executables.loadNE(machine: any, bytes: buffer): number
	const module = Executables.loadNEImage(machine, bytes, nil)
	const mem = machine.mem
	const pspSeg = 0x1000
	machine.pspSeg = pspSeg
	buildPSP(mem, pspSeg)

	const cpu = machine.cpu
	cpu.ds = module.dgroup or pspSeg
	cpu.es = module.dgroup or pspSeg
	if module.entrySeg > 0 then
		cpu.cs = module.segBases[module.entrySeg]
		cpu.ip = module.entryOff
	else
		cpu.cs, cpu.ip = pspSeg, 0x100
	end
	if module.ssIdx > 0 then
		cpu.ss = module.segBases[module.ssIdx]
		cpu.r[5] = module.sp
	else
		cpu.ss = pspSeg
		cpu.r[5] = 0xFFFE
	end
	machine.exitCode = nil
	return pspSeg
end

return Executables
