--!nonstrict
-- machineTests.lua -- environment invariants: MCB arena, SFT/list of lists,
-- DOS device opens and INT 21 subfunctions that the Windows kernel probes.
local Dos = require("../core/Dos")

local MachineTests = {}

local function str(m, seg, off, len)
	local parts = {}
	for i = 0, len - 1 do
		parts[#parts + 1] = string.char(m.mem:read8(bit32.lshift(seg, 4) + off + i))
	end
	return table.concat(parts)
end

function MachineTests.run(mkMachine, expect)
	do
		local m = mkMachine()
		local e = expect("arena_mcb_chain")
		local blocks = m.memBlocks
		e(blocks[1].start == 0, "first block must own low memory")
		for i = 2, #blocks do
			local prev, b = blocks[i - 1], blocks[i]
			e(
				prev.start + prev.size + 1 == b.start,
				("block %d starts at %#x, expected %#x"):format(
					i,
					b.start,
					prev.start + prev.size + 1
				)
			)
		end
		local last = blocks[#blocks]
		e(last.start + last.size == m.arenaTop, "arena must end at arenaTop")
		for i = 2, #blocks do
			local b = blocks[i]
			local base = bit32.lshift(b.start - 1, 4)
			e(m.mem:read8(base) == (i == #blocks and 0x5A or 0x4D), "MCB type")
			e(m.mem:read16(base + 1) == b.owner, "MCB owner")
			e(m.mem:read16(base + 3) == b.size, "MCB size")
		end
	end

	do
		local m = mkMachine()
		local e = expect("dos_alloc_split_free")
		local seg = m:dosAlloc(100)
		e(seg == 0x0801, "first fit should hand out the low free block, got " .. tostring(seg))
		local blocks = m.memBlocks
		e(blocks[3].start == 0x0801 and blocks[3].size == 100, "allocated block")
		e(blocks[4].start == 0x0801 + 100 + 1, "split remainder must leave an MCB paragraph")
		e(m:dosFree(seg), "free failed")
		e(m.memBlocks[3].start == 0x0801 and m.memBlocks[3].owner == 0, "free did not release")
		e(#m.memBlocks == 6, "free did not merge with neighbour, blocks=" .. #m.memBlocks)
	end

	do
		local m = mkMachine()
		local e = expect("dos_resize")
		local seg = m:dosAlloc(10)
		m.cpu.es = seg
		m.cpu.r[4] = 40
		Dos.FN[0x4A](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "resize failed")
		e(m.memBlocks[3].size == 40, "resized block")
		e(m.memBlocks[4].start == seg + 40 + 1, "remainder after grow")
		m.cpu.r[4] = 5
		Dos.FN[0x4A](m.dos, m.cpu, m)
		e(m.memBlocks[3].size == 5, "shrunk block")
		e(m.memBlocks[4].start == seg + 5 + 1, "remainder after shrink")
	end

	do
		local m = mkMachine()
		local e = expect("dos_zero_alloc")
		e(m:dosAlloc(0) == m.arenaTop, "zero-size allocation must succeed at the arena top")
	end

	do
		local m = mkMachine()
		local e = expect("dos_reserve_program")
		e(m:dosReserve(0x1000, 0x200), "reserve failed")
		const block = m.memBlocks[5]
		e(block.start == 0x1000 and block.size == 0x200, "reserved PSP block")
		const tail = m.memBlocks[6]
		e(tail.start == 0x1201 and tail.owner == 0, "free tail after reserved block")
		e(m:dosLargest() == m.arenaTop - 0x1201, "largest after reserve")
	end

	do
		local m = mkMachine()
		local e = expect("dos_env_trailer")
		m:loadCOM(buffer.fromstring("\205\32"), nil, "C:\\WINDOWS\\WIN.COM")
		const envSeg = m.mem:read16(bit32.lshift(0x1000, 4) + 0x2C)
		const envBase = bit32.lshift(envSeg, 4)
		local position = 0
		while position < 0x3F0 do
			if
				m.mem:read8(envBase + position) == 0
				and m.mem:read8(envBase + position + 1) == 0
			then
				break
			end
			position += 1
		end
		e(m.mem:read16(envBase + position + 2) == 1, "environment word count")
		e(str(m, envSeg, position + 4, 18) == "C:\\WINDOWS\\WIN.COM", "program path trailer")

		local function envStrings(segment)
			const base = bit32.lshift(segment, 4)
			local list = {}
			local cursor = 0
			while cursor < 0x3F0 do
				const start = cursor
				while cursor < 0x3F0 and m.mem:read8(base + cursor) ~= 0 do
					cursor += 1
				end
				if cursor == start then
					break
				end
				local chars = {}
				for index = start, cursor - 1 do
					chars[#chars + 1] = string.char(m.mem:read8(base + index))
				end
				list[#list + 1] = table.concat(chars)
				cursor += 1
			end
			return list
		end

		local sawWindir, sawPath = false, false
		for _, entry in envStrings(envSeg) do
			if entry == "windir=C:\\WINDOWS\\" then
				sawWindir = true
			elseif entry == "PATH=C:\\WINDOWS;C:\\WINDOWS\\SYSTEM" then
				sawPath = true
			end
		end
		e(sawWindir, "WIN.COM environment needs windir with a trailing separator")
		e(sawPath, "PATH must include the Windows SYSTEM directory")

		-- KERNEL's profile code appends its own separator to windir; children
		-- must inherit it without the trailing one or every INI path doubles
		-- the backslash and the profile lookup silently uses defaults.
		const childSeg = 0x4000
		m:loadCOM(buffer.fromstring("\205\32"), childSeg, "C:\\WINDOWS\\KERNEL.EXE", nil, envSeg)
		const childEnvSeg = m.mem:read16(bit32.lshift(childSeg, 4) + 0x2C)
		local childWindir = nil
		for _, entry in envStrings(childEnvSeg) do
			if string.sub(entry, 1, 7) == "windir=" then
				childWindir = entry
			end
		end
		e(
			childWindir == "windir=C:\\WINDOWS",
			"child windir not normalized: " .. tostring(childWindir)
		)
	end

	do
		local m = mkMachine()
		local e = expect("sft_con_names")
		local base = bit32.lshift(Dos.DATA_SEG, 4)
		e(m.mem:read16(base + Dos.SFT_OFF) == 0xFFFF, "SFT chain terminator")
		e(m.mem:read16(base + Dos.SFT_OFF + 2) == 0xFFFF, "SFT chain terminator (segment)")
		e(m.mem:read16(base + Dos.SFT_OFF + 4) == 3, "SFT entry count")
		local name0 = str(m, Dos.DATA_SEG, Dos.SFT_OFF + 6 + 0x1E, 4)
		local name1 = str(m, Dos.DATA_SEG, Dos.SFT_OFF + 6 + Dos.SFT_ENTRY_SIZE + 0x1E, 4)
		local name2 = str(m, Dos.DATA_SEG, Dos.SFT_OFF + 6 + 2 * Dos.SFT_ENTRY_SIZE + 0x1E, 4)
		e(name0 == "CON " and name1 == "CON " and name2 == "CON ", "three CON names")
	end

	do
		local m = mkMachine()
		local e = expect("lol_ah52")
		m.cpu.es = 0
		m.cpu.r[4] = 0
		Dos.FN[0x52](m.dos, m.cpu, m)
		local bx = m.cpu.r[4]
		e(m.cpu.es == Dos.DATA_SEG, "LoL segment")
		e(bx == Dos.LOL_OFF + 2, "LoL pointer")
		local mcbWord = m.mem:read16(bit32.lshift(m.cpu.es, 4) + bx - 2)
		e(mcbWord == 0x0050, "first MCB at [BX-2], got " .. tostring(mcbWord))
		local sftOff = m.mem:read16(bit32.lshift(m.cpu.es, 4) + bx + 4)
		local sftSeg = m.mem:read16(bit32.lshift(m.cpu.es, 4) + bx + 6)
		e(sftSeg == Dos.DATA_SEG and sftOff == Dos.SFT_OFF, "first SFT at [BX+4]")
		local nulOff = m.mem:read16(bit32.lshift(m.cpu.es, 4) + bx + 0x22)
		local nulSeg = m.mem:read16(bit32.lshift(m.cpu.es, 4) + bx + 0x24)
		e(nulSeg == Dos.DATA_SEG and nulOff == Dos.DEV_OFF, "NUL device at [BX+22h]")
		e(str(m, nulSeg, nulOff + 0x0A, 4) == "CON ", "device header name")
	end

	do
		local m = mkMachine()
		local e = expect("con_device_open")
		local name = "CON"
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0100
		local addr = bit32.lshift(m.cpu.ds, 4) + m.cpu.r[3]
		m.mem:writeString(addr, name)
		m.mem:write8(addr + #name, 0)
		Dos.FN[0x3D](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "open CON failed")
		local handle = m.cpu.r[1]
		e(
			m.dos.handles[handle] ~= nil and m.dos.handles[handle].console,
			"CON handle not registered"
		)
		m.cpu.r[4] = handle
		Dos.FN[0x3E](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "close CON failed")
		e(m.dos.handles[handle] == nil, "CON handle not released")
	end

	do
		local m = mkMachine()
		local e = expect("nul_device")
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0100
		m.mem:writeString(0x90100, "NUL")
		m.mem:write8(0x90103, 0)
		Dos.FN[0x3D](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "open NUL failed")
		const handle = m.cpu.r[1]
		const entry = m.dos.handles[handle]
		e(entry ~= nil and entry.nul and not entry.console, "NUL must not be a console")
		m.cpu.r[4] = handle
		m.cpu.r[3] = 0x0120
		m.cpu.r[2] = 3
		m.mem:writeString(0x90120, "abc")
		Dos.FN[0x40](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 3, "NUL write count")
		m.cpu.r[3] = 0x0140
		m.cpu.r[2] = 8
		Dos.FN[0x3F](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0, "NUL read must return zero")
		Dos.FN[0x3E](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "close NUL failed")
	end

	do
		local m = mkMachine()
		local e = expect("dos_create_new")
		m.vfs:ensureDir("C:\\TMP")
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0100
		m.mem:writeString(0x90100, "C:\\TMP\\NEW.TXT")
		m.mem:write8(0x9010E, 0)
		Dos.FN[0x5B](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "create-new failed")
		const handle = m.cpu.r[1]
		e(m.vfs:exists("C:\\TMP\\NEW.TXT"), "created file missing")
		m.cpu.r[4] = handle
		m.cpu.r[2] = 2
		m.cpu.r[3] = 0x0120
		m.mem:writeString(0x90120, "hi")
		Dos.FN[0x40](m.dos, m.cpu, m)
		m.cpu.r[4] = handle
		Dos.FN[0x3E](m.dos, m.cpu, m)
		e(m.vfs:readFile("C:\\TMP\\NEW.TXT") == "hi", "create-new content")
		m.cpu.r[3] = 0x0100
		Dos.FN[0x5B](m.dos, m.cpu, m)
		e(m.cpu:getF(1) and m.cpu.r[1] == 0x50, "create-new must reject an existing file")
	end

	do
		local m = mkMachine()
		local e = expect("dos_find")
		m.vfs:ensureDir("C:\\TMP")
		m.vfs:writeFile("C:\\TMP\\A.TXT", "a")
		m.vfs:writeFile("C:\\TMP\\B.TXT", "bb")
		m.vfs:ensureDir("C:\\TMP\\SUB")
		m.dos.cwd = "C:\\TMP\\"
		m.dos.dtaSeg, m.dos.dtaOff = 0x9000, 0x0200
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0100

		-- FCB search: drive 0, name ????????, ext ???
		m.mem:write8(0x90100, 0)
		m.mem:writeString(0x90101, "???????????")
		Dos.FN[0x11](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0, "FCB find-first failed")
		e(str(m, 0x9000, 0x0201, 8) == "A       ", "FCB first name")
		e(str(m, 0x9000, 0x0209, 3) == "TXT", "FCB first ext")
		Dos.FN[0x12](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0 and str(m, 0x9000, 0x0201, 8) == "B       ", "FCB find-next")
		Dos.FN[0x12](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0xFF, "FCB find must end")

		-- Directories need an explicit 10h attribute in the FCB.
		m.mem:writeString(0x90101, "SUB        ")
		m.mem:write8(0x9010C, 0x10)
		Dos.FN[0x11](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0 and str(m, 0x9000, 0x0201, 8) == "SUB     ", "FCB directory")
		e(m.mem:read8(0x90000 + 0x020C) == 0x10, "FCB directory attribute")

		-- DOS 3+ DTA search: *.* at DS:DX, DTA at 0x9200
		m.dos.dtaOff = 0x0200
		m.cpu.r[3] = 0x0140
		m.mem:writeString(0x90140, "*.*")
		m.mem:write8(0x90143, 0)
		Dos.FN[0x4E](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0, "DTA find-first failed")
		e(m.mem:read8(0x90000 + 0x0200 + 0x15) == 0x20, "DTA file attribute")
		e(str(m, 0x9000, 0x0200 + 0x1E, 5) == "A.TXT", "DTA first name")
		e(m.mem:read8(0x90000 + 0x0200 + 0x23) == 0, "DTA name terminator")
		Dos.FN[0x4F](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0 and str(m, 0x9000, 0x0200 + 0x1E, 5) == "B.TXT", "DTA find-next")
	end

	do
		local m = mkMachine()
		local e = expect("dos_exec_program_block")
		m.vfs:writeFile("C:\\X.COM", "\205\32")
		m.dos.cwd = "C:\\"
		const paramBase = 0x50000
		m.mem:write16(paramBase + 0, 0) -- inherit environment
		m.mem:write16(paramBase + 2, 0x0100) -- command tail offset
		m.mem:write16(paramBase + 4, 0x6000) -- command tail segment
		m.mem:write8(0x60000 + 0x0100, 0)
		m.cpu.ds = 0x7000
		m.cpu.r[3] = 0
		m.mem:writeString(0x70000, "C:\\X.COM")
		m.mem:write8(0x70008, 0)
		m.cpu.es = 0x5000
		m.cpu.r[4] = 0
		Dos.FN[0x4B](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "EXEC failed")
		const psp = m.pspSeg
		e(psp ~= 0x1000, "child must get a fresh block")
		e(m.mem:read16(bit32.lshift(psp, 4) + 2) > psp, "PSP:2 top of program block")
		const envSeg = m.mem:read16(bit32.lshift(psp, 4) + 0x2C)
		e(envSeg ~= 0 and envSeg ~= psp - 0x40, "environment must be its own block")
		local programOwner = nil
		for _, block in m.memBlocks do
			if block.start == psp then
				programOwner = block.owner
			end
		end
		e(programOwner == psp, "program block owner must be the child PSP")
		e(m.cpu.r[5] == 0xFFFE, "EXEC COM stack must be inside a 64K block")
	end

	do
		local m = mkMachine()
		local e = expect("com_stack_inside_block")
		m:loadCOM(buffer.fromstring("\205\32"))
		e(m.cpu.r[5] < 0xFF0, "direct COM stack must fit the initial PSP block")
	end

	do
		local m = mkMachine()
		local e = expect("dos_exec_bound_ne_largest_block")
		-- A bound MZ+NE image (the Windows KERNEL layout): the NE loader runs
		-- inside the child and builds its global heap in the program block.
		-- DOS must hand it the whole free run, not just the image, or the
		-- leftover memory becomes a second heap arena and module segments fail
		-- to allocate.
		local image = buffer.create(1024)
		buffer.writeu8(image, 0, 0x4D) -- MZ
		buffer.writeu8(image, 1, 0x5A)
		buffer.writeu16(image, 2, 0) -- cblp
		buffer.writeu16(image, 4, 2) -- cp: 1024-byte file
		buffer.writeu16(image, 8, 4) -- cparhdr: 64-byte header
		buffer.writeu32(image, 0x3C, 0x40) -- e_lfanew
		buffer.writeu8(image, 0x40, 0x4E) -- NE
		buffer.writeu8(image, 0x41, 0x45)
		m.vfs:writeFile("C:\\X.NE", buffer.tostring(image))
		m.dos.cwd = "C:\\"
		const paramBase = 0x50000
		m.mem:write16(paramBase + 0, 0)
		m.mem:write16(paramBase + 2, 0x0100)
		m.mem:write16(paramBase + 4, 0x6000)
		m.mem:write8(0x60000 + 0x0100, 0)
		m.cpu.ds = 0x7000
		m.cpu.r[3] = 0
		m.mem:writeString(0x70000, "C:\\X.NE")
		m.mem:write8(0x70007, 0)
		m.cpu.es = 0x5000
		m.cpu.r[4] = 0
		Dos.FN[0x4B](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "bound NE EXEC failed")
		const psp = m.pspSeg
		local size: number? = nil
		for _, block in m.memBlocks do
			if block.start == psp then
				size = block.size
			end
		end
		e(size ~= nil, "program block missing")
		e(
			psp + (size or 0) == m.arenaTop,
			"bound NE program block must own the free run to arenaTop"
		)
		e(m.mem:read16(bit32.lshift(psp, 4) + 2) == m.arenaTop, "PSP:2 top of program block")
	end

	do
		local m = mkMachine()
		local e = expect("dos_flush_call")
		m.cpu.r[1] = 0x0C00 -- AH=0C, AL=0 (flush only)
		Dos.FN[0x0C](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "flush call failed")
	end

	do
		local m = mkMachine()
		local e = expect("dos_default_drive")
		m.cpu.r[1] = 0x1900
		Dos.FN[0x19](m.dos, m.cpu)
		e(m.cpu.r[1] == 0x0002, "AH=19 must return AL=drive C: (2), got " .. tostring(m.cpu.r[1]))
	end

	do
		local m = mkMachine()
		local e = expect("dos_get_cwd_format")
		m.dos.cwd = "C:\\WINDOWS"
		m.cpu.r[1] = 0x4700
		m.cpu.ds = 0x9000
		m.cpu.r[7] = 0x0100 -- DS:SI, the DOS buffer convention
		Dos.FN[0x47](m.dos, m.cpu, m)
		e(str(m, 0x9000, 0x0100, 7) == "WINDOWS", "cwd must omit the drive and trailing backslash")
		e(m.mem:read8(0x90100 + 7) == 0, "cwd must be NUL-terminated")
		e(not m.cpu:getF(1), "get cwd failed")
	end

	do
		-- The IVT stub must not swallow the handler's flags: a guest that runs
		-- INT 21h AH=3D on a missing file has to see CF set after the interrupt.
		local m = mkMachine()
		local e = expect("int21_flags_reach_guest")
		m.vfs.cwd = "C:\\"
		m.cpu.cs, m.cpu.ds, m.cpu.ss = 0x9000, 0x9000, 0x9000
		m.cpu.ip, m.cpu.r[5] = 0x0100, 0xFF00
		-- mov ax,3D00h; mov dx,0120h; int 21h; jc 0111h; mov byte [0200h],0;
		-- jmp 0116h; mov al,1; mov [0200h],al; hlt
		local code = {
			0xB8,
			0x00,
			0x3D,
			0xBA,
			0x20,
			0x01,
			0xCD,
			0x21,
			0x72,
			0x07,
			0xC6,
			0x06,
			0x00,
			0x02,
			0x00,
			0xEB,
			0x05,
			0xB0,
			0x01,
			0xA2,
			0x00,
			0x02,
			0xF4,
		}
		for index, byte in code do
			m.mem:write8(0x90100 + index - 1, byte)
		end
		m.mem:writeString(0x90120, "NOPE.TXT")
		m.mem:write8(0x90128, 0)
		for _ = 1, 32 do
			if m.cpu.halted then
				break
			end
			m.cpu:step()
		end
		e(
			m.mem:read8(0x90200) == 1,
			"CF from INT 21h AH=3D must reach the caller (stub IRET restored stale flags)"
		)
	end
	do
		local m = mkMachine()
		local e = expect("dos_time_date")
		m.cpu.r[1] = 0x2C00
		Dos.FN[0x2C](m.dos, m.cpu, m)
		e(m.cpu:rb(5) == 12, "CH hour")
		e(m.cpu:rb(1) == 0, "CL minute")
		e(m.cpu:rb(6) == 0, "DH second")
		e(m.cpu:rb(2) == 0, "DL hundredths")
		m.cpu.r[1] = 0x2A00
		Dos.FN[0x2A](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 1, "1990-01-01 is a Monday")
		e(m.cpu.r[2] == 1990, "CX year")
		e(m.cpu:rb(6) == 1, "DH month")
		e(m.cpu:rb(2) == 1, "DL day")
	end

	do
		local m = mkMachine()
		local e = expect("dos_dta")
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0123
		m.cpu.es = 0
		m.cpu.r[4] = 0
		Dos.FN[0x1A](m.dos, m.cpu, m)
		Dos.FN[0x2F](m.dos, m.cpu, m)
		e(m.cpu.es == 0x9000, "DTA segment")
		e(m.cpu.r[4] == 0x0123, "DTA offset")
	end

	do
		local m = mkMachine()
		local e = expect("bios_timer_stub")
		local lo = m.mem:read16(8 * 4)
		local hi = m.mem:read16(8 * 4 + 2)
		e(lo == m.timerStubOff and hi == m.timerStubSeg, "INT 8 is not the BIOS chaining stub")
		local base = bit32.lshift(hi, 4) + lo
		e(m.mem:read8(base) == 0x50, "timer stub does not preserve AX")
		e(
			m.mem:read8(base + 1) == 0xB0 and m.mem:read8(base + 2) == 0x20,
			"timer stub does not load EOI"
		)
		e(
			m.mem:read8(base + 3) == 0xE6 and m.mem:read8(base + 4) == 0x20,
			"timer stub does not EOI the PIC"
		)
		e(m.mem:read8(base + 5) == 0x58, "timer stub does not restore AX")
		e(m.mem:read8(base + 6) == 0xCF, "timer stub is not IRET")

		-- Execute the stub directly: it must return AX unchanged and IRET to
		-- the interrupted frame. KERNEL chains here with live caller results.
		const frame = bit32.lshift(0x2000, 4) + 0x100
		m.mem:write16(frame, 0x1234)
		m.mem:write16(frame + 2, 0x3000)
		m.mem:write16(frame + 4, 0x0202)
		m.cpu.ss = 0x2000
		m.cpu.r[5] = 0x100
		m.cpu.r[1] = 0x08EE
		m.cpu.cs = m.timerStubSeg
		m.cpu.ip = m.timerStubOff
		for _ = 1, 5 do
			m.cpu:step()
		end
		e(m.cpu.r[1] == 0x08EE, "timer stub clobbered AX")
		e(m.cpu.cs == 0x3000 and m.cpu.ip == 0x1234, "timer stub did not IRET")
		local tick = m.mem:read16(0x46C)
		local sp = m.cpu.r[5]
		m:advanceTimer()
		e(m.mem:read16(0x46C) == tick + 1, "BDA tick did not advance")
		e(m.cpu.r[5] == sp, "timer stub delivery changed the stack")
	end

	do
		local m = mkMachine()
		local e = expect("timer_irq_gate")
		-- a guest handler so interrupt() pushes a real frame
		m.mem:write16(8 * 4, 0x0100)
		m.mem:write16(8 * 4 + 2, 0x2000)
		m.cpu:setbits(512, true)
		local sp = m.cpu.r[5]

		m.picMask = 1
		m:advanceTimer()
		e(m.cpu.r[5] == sp and bit32.band(m.picInService, 1) == 0, "masked IRQ0 was delivered")

		m.picMask = 0
		m.cpu.irqDelay = 1
		m:advanceTimer()
		e(m.cpu.r[5] == sp and bit32.band(m.picInService, 1) == 0, "IRQ0 broke the STI shadow")

		m.cpu.irqDelay = 0
		m:advanceTimer()
		e(m.cpu.r[5] == bit32.band(sp - 6, 0xFFFF), "IRQ0 was not delivered")
		e(bit32.band(m.picInService, 1) ~= 0, "PIC in-service bit was not set")
		e(not m.cpu:getF(512), "interrupt gate did not clear IF")
	end

	do
		local m = mkMachine()
		local e = expect("int33_mouse")
		m.cpu.r[1] = 0x00
		m:mouseInt33()
		e(m.cpu.r[1] == 0xFFFF and m.cpu.r[4] == 2, "mouse reset not installed")
		m.cpu.r[1] = 0x24
		m:mouseInt33()
		e(bit32.rshift(m.cpu.r[1], 8) == 8, "mouse driver version below 6")
		m:setMouse(100, 200, 1)
		m.cpu.r[1] = 0x03
		m:mouseInt33()
		e(m.cpu.r[2] == 100 and m.cpu.r[3] == 200, "mouse position not reported")
		e(m.cpu.r[4] == 1, "mouse buttons not reported")
		m.cpu.r[1] = 0x0B
		m:mouseInt33()
		e(m.cpu.r[2] == bit32.band(-220 * 8, 0xFFFF), "mouse delta X")
		e(m.cpu.r[3] == bit32.band(-40 * 16, 0xFFFF), "mouse delta Y")
		m.cpu.r[1] = 0x0B
		m:mouseInt33()
		e(m.cpu.r[2] == 0 and m.cpu.r[3] == 0, "mouse deltas not cleared")
	end

	do
		local m = mkMachine()
		local e = expect("dos_select_default_drive")
		m.cpu.r[1] = 0x0E02 -- AH=0E, DL=2 (C:)
		m.cpu.r[3] = 2
		Dos.FN[0x0E](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "select C: failed")
		e(m.cpu:rb(0) == 3, "logical drive count")
		m.cpu.r[1] = 0x1900
		Dos.FN[0x19](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 2, "current drive is not C:")
		m.cpu.r[1] = 0x0E05 -- invalid drive
		m.cpu.r[3] = 5
		Dos.FN[0x0E](m.dos, m.cpu, m)
		e(m.cpu:getF(1), "invalid drive accepted")
	end

	do
		local m = mkMachine()
		local e = expect("dos_ioctl_console")
		m.cpu.r[1] = 0x4400 -- AH=44 AL=0, BX=1 (stdout CON)
		m.cpu.r[4] = 1
		Dos.FN[0x44](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "ioctl get device info failed")
		e(bit32.band(m.cpu.r[3], 0x80) ~= 0, "CON not reported as a character device")
		m.cpu.r[1] = 0x4406 -- input status
		Dos.FN[0x44](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0, "input status should be empty")
		m.cpu.r[1] = 0x4408 -- fixed disk
		Dos.FN[0x44](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 1, "removable query")
	end

	do
		local m = mkMachine()
		local e = expect("dos_child_psp")
		local parent = 0x1000
		local child = 0x3000
		m.dos.currentPsp = parent
		m.cpu.r[3] = child
		m.cpu.r[7] = 0x2000
		m.cpu.r[1] = 0x5510
		Dos.FN[0x55](m.dos, m.cpu, m)
		e(m.mem:read16(bit32.lshift(child, 4) + 0x02) == 0x2000, "child PSP top of memory")
		e(m.mem:read16(bit32.lshift(child, 4) + 0x16) == parent, "child PSP parent")
	end

	do
		local m = mkMachine()
		local e = expect("int15_ps2_config_and_handler")
		-- AH=C0h: ES:BX points at the PS/2 configuration table; byte 2 is
		-- the model byte MOUSE.DRV matches (F8h/FCh/FAh).
		m.cpu.r[1] = 0xC000
		m:int15()
		e(not m.cpu:getF(1), "INT 15 C0 must clear CF")
		e(bit32.rshift(m.cpu.r[1], 8) == 0, "INT 15 C0 AH")
		local table = bit32.lshift(m.cpu.es, 4) + m.cpu.r[4]
		e(m.mem:read8(table + 2) == 0xFC, "PS/2 model byte")
		e(m.mem:read16(table) == 0x20, "configuration table size")

		-- C200 enable, C202/C203/C205/C206 parameters, C207 handler.
		for _, call in ipairs({
			{ 0xC200, 0x0100 },
			{ 0xC202, 0x0200 },
			{ 0xC203, 0x0300 },
			{ 0xC205, 0x0300 },
			{ 0xC206, 0x0100 },
		}) do
			m.cpu.r[1] = call[1]
			m.cpu.r[4] = call[2]
			m:int15()
			e(
				not m.cpu:getF(1) and bit32.rshift(m.cpu.r[1], 8) == 0,
				("INT 15 %04X"):format(call[1])
			)
		end
		e(m.mousePs2Enabled, "C200 did not enable the PS/2 device")
		e(m.mouseSampleRate == 2, "C202 sample rate")
		e(m.mouseResolution == 3, "C203 resolution")
		e(m.mousePacketSize == 3, "C205 packet size")
		e(m.mouseScaling == 1, "C206 scaling")
		m.cpu.es = 0x7000
		m.cpu.r[4] = 0x0100
		m.cpu.r[1] = 0xC207
		m:int15()
		e(
			m.mouseDeviceHandler ~= nil
				and m.mouseDeviceHandler.seg == 0x7000
				and m.mouseDeviceHandler.off == 0x0100,
			"C207 device handler"
		)
		m.cpu.r[1] = 0xC2FF
		m:int15()
		e(m.cpu:getF(1) and bit32.rshift(m.cpu.r[1], 8) == 0x86, "unsupported C2xx")
	end

	do
		local m = mkMachine()
		local e = expect("ps2_packet_delivery")
		m.mousePs2Enabled = true
		m.mouseDeviceHandler = { seg = 0x7000, off = 0x0100 }
		-- Fake C207 handler: store status/dx/dy, then RETF to the cleanup
		-- trampoline. Sentinel HLT at 7000:0300 ends the run.
		local handler = {
			0x55, -- push bp
			0x8B,
			0xEC, -- mov bp,sp
			0x8A,
			0x46,
			0x0C, -- mov al,[bp+0C] status
			0xA2,
			0x00,
			0x02, -- mov [0200],al
			0x8A,
			0x46,
			0x0A, -- mov al,[bp+0A] dx
			0xA2,
			0x01,
			0x02,
			0x8A,
			0x46,
			0x08, -- mov al,[bp+08] dy
			0xA2,
			0x02,
			0x02,
			0x5D, -- pop bp
			0xCB, -- retf
		}
		local base = bit32.lshift(0x7000, 4)
		for index, byte in ipairs(handler) do
			m.mem:write8(base + 0x0100 + index - 1, byte)
		end
		m.mem:write8(base + 0x0300, 0xF4) -- HLT
		m:setMouse(330, 250, 1)
		e(#m.mousePackets == 1, "setMouse did not queue a packet")
		e(m.mousePackets[1].status == 0x29, "button/status byte")
		e(m.mousePackets[1].dx == 5 and m.mousePackets[1].dy == -5, "packet deltas")
		-- Interrupted-guest frame: IP, CS, FLAGS.
		m.cpu.ds = 0x7000
		m.cpu.ss = 0x8000
		m.cpu.r[5] = 0xFFF0
		m.cpu:push16(0x0202)
		m.cpu:push16(0x7000)
		m.cpu:push16(0x0300)
		m.mouseIrqActive = true
		m.mouseIrqSs = 0x8000
		m.mouseIrqSp = 0xFFF0
		m:int74()
		e(#m.mousePackets == 0, "int74 did not consume the packet")
		e(m.cpu.cs == 0x7000 and m.cpu.ip == 0x0100, "device handler not entered")
		m:run(100)
		e(m.cpu.halted, "cleanup did not reach the sentinel HLT")
		e(m.cpu.cs == 0x7000 and m.cpu.ip == 0x0301, "wrong return path")
		e(m.mem:read8(base + 0x0200) == 0x29, "handler status argument")
		e(m.mem:read8(base + 0x0201) == 5, "handler dx argument")
		e(m.mem:read8(base + 0x0202) == 0xFB, "handler dy argument")
		e(not m.mouseIrqActive, "cleanup sentinel did not clear the IRQ guard")

		-- Negative deltas must set the PS/2 sign bits.
		m.cpu.halted = false
		m.cpu.r[5] = 0xFFF0
		m.mouseIrqActive = false
		m.mousePackets = {}
		m:setMouse(320, 240, 0)
		e(
			m.mousePackets[1] ~= nil
				and m.mousePackets[1].dx == -5
				and m.mousePackets[1].dy == 5
				and bit32.band(m.mousePackets[1].status, 0x30) == 0x10,
			"screen up-left must flip Y only"
		)

		-- Large host moves must be split into multiple <=127 PS/2 packets so
		-- the sum of the delivered deltas equals the host delta exactly.
		m.mousePackets = {}
		m.mouseX, m.mouseY = 320, 240
		m:setMouse(639, 479, 0)
		e(#m.mousePackets == 2, "large move packet count=" .. #m.mousePackets)
		local sumX, sumY = 0, 0
		for _, packet in ipairs(m.mousePackets) do
			e(math.abs(packet.dx) <= 127 and math.abs(packet.dy) <= 127, "packet delta range")
			sumX += packet.dx
			sumY += packet.dy
		end
		e(sumX == 159, "split dx sum=" .. sumX)
		e(sumY == -119, "split dy sum=" .. sumY)

		-- Slow drags must coalesce into the queued packet instead of growing
		-- an unbounded queue (or dropping motion at the 64-packet cap).
		m.mousePackets = {}
		m.mouseX, m.mouseY = 320, 240
		m.mouseButtons = 0
		m:setMouse(322, 240, 0)
		m:setMouse(324, 240, 0)
		e(#m.mousePackets == 1, "coalesced packet count=" .. #m.mousePackets)
		e(m.mousePackets[1].dx == 2, "coalesced dx=" .. tostring(m.mousePackets[1].dx))

		-- A button edge must stay behind the movement already queued.
		m:setMouse(326, 240, 1)
		e(#m.mousePackets == 2, "button edge was coalesced")
		e(bit32.band(m.mousePackets[2].status, 0x07) == 1, "button edge status")

		-- First-entry sync: push the guest pointer far left/up so the driver
		-- clamps at (0,0), then the host target is an exact absolute delta.
		m.mousePackets = {}
		m.mouseX, m.mouseY = 400, 300
		m.mouseButtons = 1
		e(m:syncMouse(), "syncMouse refused with PS/2 enabled")
		e(m.mouseX == 0 and m.mouseY == 0, "syncMouse origin")
		e(#m.mousePackets == 8, "sync packet count=" .. #m.mousePackets)
		local syncX, syncY = 0, 0
		local cleanButtons = true
		for _, packet in ipairs(m.mousePackets) do
			syncX += packet.dx
			syncY += packet.dy
			if bit32.band(packet.status, 0x07) ~= 0 then
				cleanButtons = false
			end
		end
		e(syncX == -1016 and syncY == 1016, "sync delta sums")
		e(cleanButtons, "sync packets must not carry button state")
		e(m.mouseButtons == 1, "syncMouse must restore button state")

		-- The absolute target must not fold into the clamp packets: doing so
		-- cancels the clamp and leaves the guest cursor short of the target.
		m:setMouse(100, 120, 0)
		e(#m.mousePackets == 9, "post-sync packet count=" .. #m.mousePackets)
		const target = m.mousePackets[9]
		e(target.sync == nil, "target was marked as sync")
		e(target.dx == 50 and target.dy == -60, "post-sync target delta")
	end

	do
		local m = mkMachine()
		local e = expect("keyboard_8042")
		m:keyDown(0x1E)
		e(m.keyboardData == 0x1E and m.keyboardOutputFull, "key was not latched")
		e(bit32.band(m.cpu.io.in8(0x64), 1) == 1, "output buffer full bit")
		e(m.cpu.io.in8(0x60) == 0x1E, "port 60 data")
		e(bit32.band(m.cpu.io.in8(0x64), 1) == 0, "read did not clear OBF")

		-- Guest INT 9 handler: IN AL,60; MOV [1000h],AL; MOV AL,20; OUT 20h,AL; IRET
		const handlerBase = 0x80000 + 0x0100
		const code = { 0xE4, 0x60, 0xA2, 0x00, 0x10, 0xB0, 0x20, 0xE6, 0x20, 0xCF }
		for index, byte in code do
			m.mem:write8(handlerBase + index - 1, byte)
		end
		m.mem:write16(9 * 4, 0x0100)
		m.mem:write16(9 * 4 + 2, 0x8000)
		m.mem:write8(0x71000, 0xEB) -- JMP $
		m.mem:write8(0x71001, 0xFE)
		m.cpu.cs, m.cpu.ip = 0x7000, 0x1000
		m.cpu.ds = 0x8000
		m.cpu:setbits(512, false) -- idle Windows keeps IF clear; input still latches
		m:run(10)
		e(m.mem:read8(0x81000) == 0x1E, "INT 9 handler did not see the scan code")
		e(bit32.band(m.picInService, 2) == 0, "IRQ1 EOI did not clear the PIC")
		e(not m.keyboardIrqActive, "IRQ1 guard stuck")
		m:keyUp(0x1E)
		e(m.keyboardData == 0x9E, "break code")
	end

	do
		local m = mkMachine()
		local e = expect("keyboard_bios_chain")
		m.mem:write8(0x71000, 0xEB)
		m.mem:write8(0x71001, 0xFE)
		m.cpu.cs, m.cpu.ip = 0x7000, 0x1000
		m.cpu:setbits(512, false)
		m:keyDown(0x1E)
		m:run(2)
		e(bit32.band(m.picInService, 2) == 0, "BIOS INT 9 did not EOI")
		e(not m.keyboardPending and #m.keyboardQueue == 0, "BIOS INT 9 left the key pending")
	end

	do
		local m = mkMachine()
		local e = expect("vga_wiring")
		e(m.vga ~= nil, "machine has no VGA device")
		e(m.mem.aperture == m.vga, "VGA aperture is not routed through Memory")
		m.cpu.r[1] = 0x0012 -- AX: AH=00 set mode, AL=12h
		m.bios:int10()
		e(m.vga:mode() == 0x12, "INT 10h AH=00 did not set mode 12h")
		e(m.mem:read8(0x449) == 0x12, "BDA mode byte")
		e(m.mem:read16(0x44A) == 80, "BDA character columns")
		m.mem:write8(0xA0000, 0x0F)
		e(m.vga:read8(0xA0000) == 0x0F, "aperture write did not reach the VGA plane")
		m.cpu.r[1] = 0x0F00 -- AX: AH=0F get mode
		m.bios:int10()
		e(bit32.band(m.cpu.r[1], 0xFF) == 0x12, "INT 10h AH=0F mode")
		e(bit32.band(bit32.rshift(m.cpu.r[1], 8), 0xFF) == 80, "INT 10h AH=0F columns")
	end

	do
		local m = mkMachine()
		local e = expect("vga_region_snapshot")
		m.cpu.r[1] = 0x0012
		m.bios:int10()
		m.vga:fillRect(10, 20, 4, 4, 4)
		const full = m.vga:snapshotRGBA()
		const width = m.vga.widthPx
		const height = m.vga.heightPx
		local expected = buffer.create(width * height * 4)
		buffer.copy(expected, 0, full, 0, width * height * 4)

		-- Sentinel values outside the requested rect must survive: a region
		-- snapshot converts only those four rows, not the whole framebuffer.
		const sentinel = 0x11223344
		buffer.writeu32(m.vga.rgba, 0, sentinel)
		m.vga:snapshotRegionRGBA(10, 20, 4, 4)
		for row = 0, 3 do
			for column = 0, 3 do
				const offset = ((20 + row) * width + 10 + column) * 4
				e(
					buffer.readu32(m.vga.rgba, offset) == buffer.readu32(expected, offset),
					"region pixel mismatch"
				)
			end
		end
		e(buffer.readu32(m.vga.rgba, 0) == sentinel, "region snapshot touched outside pixels")

		-- Write mode 3 is the masked/transparent blit path sprites use: the
		-- CPU data becomes the mask, the latched source fills set bits, and the
		-- destination keeps the cleared bits.
		const vga = m.vga
		vga.misc = bit32.bor(vga.misc, 0x02)
		vga.gfx[5] = 3
		vga.gfx[8] = 0xF0
		vga.gfx[1] = 0
		for plane = 0, 3 do
			vga.latches[plane] = 0xAA
			buffer.writeu8(vga.planes[plane + 1], 0, 0x0F)
		end
		vga:write8(0xA0000, 0xFF)
		e(
			buffer.readu8(vga.planes[1], 0) == 0xAF,
			("VGA write mode 3 masked merge=%02X"):format(buffer.readu8(vga.planes[1], 0))
		)
		vga.gfx[5] = 0
		vga.gfx[8] = 0xFF

		-- Mode 13h uses the linear path; the same region contract applies.
		m.cpu.r[1] = 0x0013
		m.bios:int10()
		m.vga:fillRect(2, 3, 2, 2, 5)
		const linearFull = m.vga:snapshotRGBA()
		local linearExpected = buffer.create(320 * 200 * 4)
		buffer.copy(linearExpected, 0, linearFull, 0, 320 * 200 * 4)
		buffer.writeu32(m.vga.rgba, 0, sentinel)
		m.vga:snapshotRegionRGBA(2, 3, 2, 2)
		for row = 0, 1 do
			for column = 0, 1 do
				const offset = ((3 + row) * 320 + 2 + column) * 4
				e(
					buffer.readu32(m.vga.rgba, offset) == buffer.readu32(linearExpected, offset),
					"linear region pixel mismatch"
				)
			end
		end
		e(buffer.readu32(m.vga.rgba, 0) == sentinel, "linear region touched outside pixels")
	end
end

return MachineTests
