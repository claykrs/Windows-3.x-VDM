--!strict
-- Dos.lua -- INT 21h subset + INT 20h/27h; console, handles, vectors, arena.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const CF = 1
const ZF = 64

const Dos = {}
Dos.__index = Dos

export type Host = {
	mem: any,
	cpu: any,
	xms: any,
	vfs: any,
	bios: any,
	keys: { number },
	waiting: string?,
	pendingInt: number?,
	pspSeg: number?,
	deps: any,
	memBlocks: { { start: number, size: number, owner: number } },
	exit: (self: any, code: number) -> (),
	dosAlloc: (self: any, paras: number) -> number?,
	dosReserve: (self: any, start: number, paras: number) -> boolean,
	dosSetOwner: (self: any, seg: number, owner: number) -> boolean,
	dosFree: (self: any, seg: number) -> boolean,
	dosLargest: (self: any) -> number,
	syncArena: (self: any) -> (),
	log: (self: any, message: string) -> (),
}

export type Handle = {
	console: boolean,
	stdin: boolean?,
	device: boolean?,
	nul: boolean?,
	path: string?,
	data: string?,
	pos: number?,
	ownerPsp: number?,
}

export type Handler = (self: Dos, cpu: any, machine: Host) -> ()

export type Dos = {
	machine: Host,
	handles: { [number]: Handle },
	nextHandle: number,
	cwd: string,
	pendingLine: string?,
	currentPsp: number?,
	defaultDrive: number,
	countryCode: number,
	dtaSeg: number?,
	dtaOff: number?,
	find: {
		entries: { { name: string, size: number, dir: boolean } },
		index: number,
		fcbMode: boolean,
	}?,
	ctrlBreak: boolean?,
	FN: { [number]: Handler },
	initLowMemory: (self: Dos) -> (),
	deviceName: (self: Dos, path: string) -> string?,
	readRawAsciz: (self: Dos, cpu: any) -> string,
	readAsciz: (self: Dos, cpu: any) -> string,
	int21: (self: Dos) -> (),
	int20: (self: Dos) -> (),
	divideOverflow: (self: Dos) -> (),
}

function Dos.new(machine: Host): Dos
	const self = setmetatable({}, Dos) :: any
	self.machine = machine
	self.handles = {
		[0] = { console = true, stdin = true }, -- stdin
		[1] = { console = true }, -- stdout
		[2] = { console = true }, -- stderr
	}
	self.nextHandle = 3
	self.cwd = "C:\\"
	self.pendingLine = nil -- partial AH=0A input across keyboard waits
	self.currentPsp = nil
	self.defaultDrive = 2 -- C:
	self.countryCode = 1 -- United States
	self.ctrlBreak = false
	self:initLowMemory()
	return self
end

-- DOS data area: system file table, list of lists, DPB and device headers.
-- Windows 3.0 locates the SFT by scanning low memory for three equally spaced
-- "CON " names (stdin/stdout/stderr); the 59-byte entry size is what it reels
-- in, so these tables must sit in memory exactly like real DOS.
Dos.DATA_SEG = 0x0060
Dos.SFT_ENTRY_SIZE = 59
Dos.SFT_OFF = 0x0000
Dos.LOL_OFF = 0x0100
Dos.DPB_OFF = 0x0180
Dos.DEV_OFF = 0x01C0
Dos.INDOS_OFF = 0x01D0
Dos.DEV_STUB_OFF = 0x01E0

function Dos.initLowMemory(self: Dos)
	const mem = self.machine.mem
	const seg = Dos.DATA_SEG
	const base = lshift(seg, 4)

	-- System file table: header then 59-byte entries for CON stdin/out/err.
	mem:write16(base + Dos.SFT_OFF, 0xFFFF) -- next SFT: end of chain
	mem:write16(base + Dos.SFT_OFF + 2, 0xFFFF)
	mem:write16(base + Dos.SFT_OFF + 4, 3) -- entries in this table
	for index = 0, 2 do
		const entry = base + Dos.SFT_OFF + 6 + index * Dos.SFT_ENTRY_SIZE
		mem:write16(entry + 0x00, 1) -- handles referring to this entry
		mem:write16(entry + 0x02, 2) -- open mode: read/write
		mem:write8(entry + 0x04, 0x80) -- attribute: device
		mem:write16(entry + 0x05, 0x80D3) -- CON device info: in+out, special
		mem:write16(entry + 0x07, Dos.DEV_OFF) -- device header pointer
		mem:write16(entry + 0x09, seg)
		mem:writeString(entry + 0x1E, "CON        ") -- 11-byte name field
	end

	-- Device header for CON (next device = end of chain, char device). The
	-- strategy/interrupt offsets must point at executable RETF stubs inside
	-- this segment; the request header in ES:BX is left with status 0.
	const dev = base + Dos.DEV_OFF
	mem:write16(dev + 0x00, 0xFFFF)
	mem:write16(dev + 0x02, 0xFFFF)
	mem:write16(dev + 0x04, 0x8013) -- char, CONIN, CONOUT, special
	mem:write16(dev + 0x06, Dos.DEV_STUB_OFF)
	mem:write16(dev + 0x08, Dos.DEV_STUB_OFF)
	mem:writeString(dev + 0x0A, "CON     ") -- 8-byte device name
	mem:write8(base + Dos.DEV_STUB_OFF, 0xCB) -- RETF (strategy + interrupt)

	-- Disk parameter block: one drive, chain terminated.
	const dpb = base + Dos.DPB_OFF
	mem:write8(dpb + 0x00, 0) -- drive A:
	mem:write8(dpb + 0x01, 0)
	mem:write16(dpb + 0x02, 512) -- bytes per sector
	mem:write8(dpb + 0x04, 1) -- sectors per cluster - 1
	mem:write8(dpb + 0x05, 0) -- cluster shift
	mem:write16(dpb + 0x06, 1) -- first FAT sector
	mem:write8(dpb + 0x08, 2) -- number of FATs
	mem:write16(dpb + 0x09, 112) -- root dir entries
	mem:write16(dpb + 0x0B, 14) -- first data sector
	mem:write16(dpb + 0x0D, 354) -- clusters
	mem:write16(dpb + 0x0F, 9) -- sectors per FAT
	mem:write16(dpb + 0x11, 19) -- first root dir sector
	mem:write16(dpb + 0x13, Dos.DEV_OFF) -- device driver
	mem:write16(dpb + 0x15, seg)
	mem:write8(dpb + 0x17, 0xF9) -- media descriptor
	mem:write8(dpb + 0x18, 0)
	mem:write16(dpb + 0x19, 0xFFFF) -- next DPB: end of chain
	mem:write16(dpb + 0x1B, 0xFFFF)

	-- List of lists. AH=52 returns a pointer to the first DPB field, so the
	-- first MCB sits at ptr-2 and the first SFT at ptr+4.
	const lol = base + Dos.LOL_OFF
	mem:write16(lol + 0x00, 0x0050) -- first MCB segment
	mem:write16(lol + 0x02, Dos.DPB_OFF) -- first DPB
	mem:write16(lol + 0x04, seg)
	mem:write16(lol + 0x06, Dos.SFT_OFF) -- first SFT
	mem:write16(lol + 0x08, seg)
	mem:write16(lol + 0x0A, Dos.DEV_OFF) -- CLOCK$ (placeholder)
	mem:write16(lol + 0x0C, seg)
	mem:write16(lol + 0x0E, Dos.DEV_OFF) -- CON
	mem:write16(lol + 0x10, seg)
	mem:write16(lol + 0x12, 512) -- max bytes per sector
	mem:write16(lol + 0x20, 1) -- block devices
	mem:write8(lol + 0x22, 0) -- last drive
	mem:write16(lol + 0x24, Dos.DEV_OFF) -- NUL device chain head
	mem:write16(lol + 0x26, seg)

	mem:write8(base + Dos.INDOS_OFF, 0)
end

-- device names short-circuit file opens ("CON" and friends)
function Dos.deviceName(_self: Dos, path: string): string?
	const name = string.upper(path):gsub("%s+$", ""):gsub(":$", "")
	if name == "CON" or name == "NUL" or name == "AUX" or name == "PRN" then
		return name
	end
	return nil
end

-- helpers over cpu registers (r: AX CX DX BX SP BP SI DI)
local function al(cpu: any): number
	return band(cpu.r[1], 0xFF)
end

local function ah(cpu: any): number
	return band(rshift(cpu.r[1], 8), 0xFF)
end

local function setAX(cpu: any, value: number)
	cpu.r[1] = band(value, 0xFFFF)
end

local function ok(cpu: any)
	cpu:setbits(CF, false)
end

local function fail(cpu: any, code: number)
	cpu:setbits(CF, true)
	setAX(cpu, code)
end

function Dos.readRawAsciz(self: Dos, cpu: any): string
	const base = lshift(cpu.ds, 4) + cpu.r[3]
	local chars: { string } = {}
	for index = 0, 255 do
		const ch = self.machine.mem:read8(base + index)
		if ch == 0 then
			break
		end
		chars[#chars + 1] = string.char(ch)
	end
	return table.concat(chars)
end

function Dos.readAsciz(self: Dos, cpu: any): string
	return self.machine.vfs:resolve(self:readRawAsciz(cpu), self.cwd)
end

function Dos.int21(self: Dos)
	const machine = self.machine
	const cpu = machine.cpu
	const number = ah(cpu)
	const handler = Dos.FN[number]
	if not handler then
		-- Functions >= B0 are Windows-internal hooks probing the DOS layer;
		-- fail them gracefully so the caller decides, and keep the loud error
		-- for genuinely expected DOS calls during development.
		if number >= 0xB0 then
			fail(cpu, 1) -- invalid function
			return
		end
		error(("unsupported INT 21h function AH=%02X at %04X:%04X"):format(number, cpu.cs, cpu.ip))
	end
	handler(self, cpu, machine)
end

function Dos.int20(self: Dos)
	self.machine:exit(0)
end

-- divide error default: print message, terminate (real DOS behavior)
function Dos.divideOverflow(self: Dos)
	self.machine.bios:write("Divide overflow\r\n")
	self.machine:exit(0)
end

Dos.FN = {} :: { [number]: Handler }

Dos.FN[0x00] = function(_self, _cpu, machine)
	machine:exit(0)
end

Dos.FN[0x01] = function(_self: Dos, cpu: any, machine: Host) -- read key with echo
	if #machine.keys == 0 then
		cpu.halted = true
		machine.waiting = "keyboard"
		machine.pendingInt = 0x21
		return
	end
	const key = table.remove(machine.keys, 1) :: number
	machine.bios:teletype(key)
	setAX(cpu, key)
end

Dos.FN[0x02] = function(_self: Dos, cpu: any, machine: Host) -- write DL
	const dl = band(cpu.r[3], 0xFF)
	machine.bios:teletype(dl)
	cpu:wb(0, dl) -- AL = DL per documented return
end

Dos.FN[0x06] = function(_self: Dos, cpu: any, machine: Host) -- direct console I/O
	const dl = band(cpu.r[3], 0xFF)
	if dl == 0xFF then
		if #machine.keys == 0 then
			cpu:setbits(ZF, true)
			setAX(cpu, 0)
		else
			cpu:setbits(ZF, false)
			const key = table.remove(machine.keys, 1) :: number
			setAX(cpu, key)
		end
	else
		machine.bios:teletype(dl)
		setAX(cpu, dl)
	end
end

Dos.FN[0x07] = function(self: Dos, cpu: any, machine: Host)
	Dos.FN[0x08](self, cpu, machine)
end

Dos.FN[0x08] = function(_self: Dos, cpu: any, machine: Host) -- read key, no echo
	if #machine.keys == 0 then
		cpu.halted = true
		machine.waiting = "keyboard"
		machine.pendingInt = 0x21
		return
	end
	setAX(cpu, table.remove(machine.keys, 1) :: number)
end

Dos.FN[0x09] = function(_self: Dos, cpu: any, machine: Host) -- print $-terminated string at DS:DX
	const mem = machine.mem
	const base = lshift(cpu.ds, 4) + cpu.r[3]
	local parts: { string } = {}
	for index = 0, 4095 do
		const ch = mem:read8(base + index)
		if ch == 0x24 then
			break
		end
		parts[#parts + 1] = string.char(ch)
	end
	machine.bios:write(table.concat(parts))
end

Dos.FN[0x0A] = function(self: Dos, cpu: any, machine: Host) -- buffered line input
	const mem = machine.mem
	const base = lshift(cpu.ds, 4) + cpu.r[3]
	const maxLength = mem:read8(base)
	local buffer = self.pendingLine or ""
	while #buffer < maxLength - 1 do
		if #machine.keys == 0 then
			cpu.halted = true
			machine.waiting = "keyboard"
			machine.pendingInt = 0x21
			self.pendingLine = buffer
			return
		end
		const key = table.remove(machine.keys, 1) :: number
		if key == 13 then
			break
		end
		buffer ..= string.char(key)
	end
	self.pendingLine = nil
	mem:write8(base + 1, #buffer)
	mem:writeString(base + 2, buffer)
	mem:write8(base + 2 + #buffer, 13)
	machine.bios:write(buffer)
	machine.bios:teletype(13)
	machine.bios:teletype(10)
end

Dos.FN[0x0B] = function(_self: Dos, cpu: any, machine: Host)
	setAX(cpu, (#machine.keys > 0) and 0x00FF or 0)
end

Dos.FN[0x0C] = function(self: Dos, cpu: any, machine: Host) -- flush input, then AL function
	table.clear(machine.keys)
	const sub = al(cpu)
	if sub == 0x01 or sub == 0x06 or sub == 0x07 or sub == 0x08 or sub == 0x0A then
		cpu.r[1] = bor(band(cpu.r[1], 0x00FF), lshift(sub, 8))
		Dos.FN[sub](self, cpu, machine)
	else
		self.pendingLine = nil
		setAX(cpu, sub)
		ok(cpu)
	end
end

Dos.FN[0x19] = function(self: Dos, cpu: any)
	-- AL = current default drive (0 = A, 1 = B, 2 = C); AH = 0
	setAX(cpu, self.defaultDrive)
end

Dos.FN[0x0D] = function(_self: Dos, cpu: any) -- disk reset: flush buffers
	ok(cpu)
end

-- select default drive (DL). The VFS is a single C: tree, but DOS programs
-- still probe/select drives, so accept the standard three and report success.
Dos.FN[0x0E] = function(self: Dos, cpu: any)
	const drive = band(cpu.r[3], 0xFF)
	if drive > 2 then
		fail(cpu, 0x0F) -- invalid drive
		return
	end
	self.defaultDrive = drive
	setAX(cpu, 3) -- number of logical drives
	ok(cpu)
end

Dos.FN[0x25] = function(_self: Dos, cpu: any, machine: Host) -- set interrupt vector AL <- DS:DX
	const vector = lshift(al(cpu), 2)
	machine.mem:write16(vector, cpu.r[3])
	machine.mem:write16(vector + 2, cpu.ds)
end

-- Parse an ASCIIZ filename into an FCB (INT 21h AH=29h). WIN.CNF/WSWAP use
-- this to split a path before opening it. AL=0 plain name, 1 wildcards,
-- 0FFh invalid drive; DS:SI advances to the terminating character.
Dos.FN[0x29] = function(_self: Dos, cpu: any, machine: Host)
	const mem = machine.mem
	local si = cpu.r[7]
	const base = lshift(cpu.ds, 4)
	const fcb = lshift(cpu.es, 4) + cpu.r[8]
	for index = 0, 36 do
		mem:write8(fcb + index, 0)
	end
	local function peek(): number
		return mem:read8(base + si)
	end
	local function advance()
		si = band(si + 1, 0xFFFF)
	end
	local drive = 0
	if peek() ~= 0 and mem:read8(base + band(si + 1, 0xFFFF)) == 0x3A then
		const letter = peek()
		if letter >= 0x61 and letter <= 0x7A then
			drive = letter - 0x60
		else
			drive = letter - 0x40
		end
		si = band(si + 2, 0xFFFF)
		if drive < 1 or drive > 2 then
			cpu:wb(0, 0xFF)
			return
		end
	end
	mem:write8(fcb, drive)
	local name, ext = {}, {}
	local wildcard = false
	local inExt = false
	while true do
		const ch = peek()
		if
			ch == 0
			or ch == 0x5C
			or ch == 0x2F
			or ch == 0x20
			or ch == 0x09
			or ch == 0x3B
			or ch == 0x2C
			or ch == 0x3D
			or ch == 0x2B
		then
			break
		end
		if ch == 0x2E then
			inExt = true
		else
			local upper = ch
			if upper >= 0x61 and upper <= 0x7A then
				upper -= 0x20
			end
			if upper == 0x2A then
				wildcard = true
			end
			if inExt then
				if #ext < 3 then
					ext[#ext + 1] = string.char(upper)
				end
			elseif #name < 8 then
				name[#name + 1] = string.char(upper)
			end
		end
		advance()
	end
	const nameText = table.concat(name)
	const extText = table.concat(ext)
	mem:writeString(fcb + 1, nameText .. string.rep(" ", 8 - #nameText))
	if nameText:find("?") or nameText:find("*") then
		wildcard = true
	end
	mem:writeString(fcb + 9, extText .. string.rep(" ", 3 - #extText))
	if extText:find("?") or extText:find("*") then
		wildcard = true
	end
	cpu.r[7] = si
	cpu:wb(0, if wildcard then 1 else 0)
end

Dos.FN[0x2A] = function(_self: Dos, cpu: any) -- get date (fixed): 1990-01-01, Monday
	cpu:wb(0, 1) -- AL day of week (0 = Sunday, 1 = Monday)
	cpu.r[2] = 1990 -- CX year
	cpu:wb(6, 1) -- DH month
	cpu:wb(2, 1) -- DL day
end

Dos.FN[0x2B] = function(_self: Dos, cpu: any) -- set date: accept and report success
	cpu:wb(0, 0)
	ok(cpu)
end

Dos.FN[0x2C] = function(_self: Dos, cpu: any, machine: Host) -- get time
	-- Keep the noon baseline but advance with the BDA tick. CLOCK polls this
	-- until the second changes; a frozen clock spins forever before SetTimer.
	const ticks = machine.mem:read16(0x46C)
	const seconds = 12 * 3600 + math.floor(ticks / 18.2065)
	const hundredths = math.floor((ticks % 18.2065) * 100 / 18.2065)
	cpu:wb(5, math.floor(seconds / 3600) % 24) -- CH hour
	cpu:wb(1, math.floor(seconds / 60) % 60) -- CL minute
	cpu:wb(6, seconds % 60) -- DH second
	cpu:wb(2, hundredths) -- DL hundredths
end

Dos.FN[0x30] = function(_self: Dos, cpu: any) -- DOS version 5.0
	setAX(cpu, 0x0005)
	cpu.r[4] = 0
	cpu.r[2] = 0
end

Dos.FN[0x35] = function(_self: Dos, cpu: any, machine: Host) -- get interrupt vector AL -> ES:BX
	const vector = lshift(al(cpu), 2)
	cpu.r[4] = machine.mem:read16(vector)
	cpu.es = machine.mem:read16(vector + 2)
end

-- Country information (INT 21h AH=38h). WIN.CNF sets country 1 and then reads
-- the block before it hands off to DOSX. Only the US layout is modelled, but
-- the returned 34-byte structure is complete enough for DOS/Win16 callers.
Dos.FN[0x38] = function(self: Dos, cpu: any, machine: Host)
	const mem = machine.mem
	const sub = al(cpu)
	if sub == 1 or sub == 0xFF then
		const requested = cpu.r[4]
		if requested ~= 0 then
			self.countryCode = requested
		end
	end
	const base = lshift(cpu.ds, 4) + cpu.r[3]
	for index = 0, 33 do
		mem:write8(base + index, 0)
	end
	mem:write8(base + 0, 0) -- date format: m/d/y
	mem:write8(base + 1, 0x24) -- currency symbol "$"
	mem:write8(base + 2, 0)
	mem:write8(base + 3, 0)
	mem:write8(base + 4, 0)
	mem:write8(base + 5, 0)
	mem:write8(base + 6, 0x2C) -- thousands separator ","
	mem:write8(base + 7, 0x2E) -- decimal separator "."
	mem:write8(base + 8, 0x2F) -- date separator "/"
	mem:write8(base + 9, 0x3A) -- time separator ":"
	mem:write8(base + 10, 0) -- currency format
	mem:write8(base + 11, 2) -- digits after decimal
	mem:write8(base + 12, 0) -- 12-hour clock
	mem:write8(base + 17, 0x2C) -- data list separator ","
	setAX(cpu, self.countryCode)
	cpu.r[4] = self.countryCode
	ok(cpu)
end

Dos.FN[0x39] = function(self: Dos, cpu: any, machine: Host)
	const made, err = machine.vfs:mkdir(self:readAsciz(cpu))
	if not made then
		fail(cpu, err or 3)
	else
		ok(cpu)
	end
end

Dos.FN[0x3B] = function(self: Dos, cpu: any, machine: Host)
	const good, err = machine.vfs:setCwd(self:readAsciz(cpu), self.cwd)
	if not good then
		fail(cpu, err or 3)
	else
		self.cwd = machine.vfs.cwd
		ok(cpu)
	end
end

Dos.FN[0x3C] = function(self: Dos, cpu: any, machine: Host) -- create/truncate file
	const path = self:readAsciz(cpu)
	if not machine.vfs:writeFile(path, "") then
		fail(cpu, 3)
		return
	end
	self.handles[self.nextHandle] = {
		console = false,
		path = path,
		data = "",
		pos = 0,
		ownerPsp = self.currentPsp or machine.pspSeg or 0,
	}
	setAX(cpu, self.nextHandle)
	self.nextHandle += 1
	ok(cpu)
end

Dos.FN[0x5B] = function(self: Dos, cpu: any, machine: Host) -- create new file
	const path = machine.vfs:resolve(self:readRawAsciz(cpu), self.cwd)
	if machine.vfs:exists(path) then
		fail(cpu, 0x50) -- file already exists
		return
	end
	if not machine.vfs:writeFile(path, "") then
		fail(cpu, 3)
		return
	end
	self.handles[self.nextHandle] = {
		console = false,
		path = path,
		data = "",
		pos = 0,
		ownerPsp = self.currentPsp or machine.pspSeg or 0,
	}
	setAX(cpu, self.nextHandle)
	self.nextHandle += 1
	ok(cpu)
end

Dos.FN[0x3D] = function(self: Dos, cpu: any, machine: Host) -- open file
	machine:log(("OPEN [%s]"):format(self:readRawAsciz(cpu)))
	const raw = self:readRawAsciz(cpu)
	const device = self:deviceName(raw)
	if device then
		if device == "NUL" then
			self.handles[self.nextHandle] = {
				console = false,
				device = true,
				nul = true,
				ownerPsp = self.currentPsp or machine.pspSeg or 0,
			}
		elseif device == "CON" then
			self.handles[self.nextHandle] = {
				console = true,
				stdin = true,
				device = true,
				ownerPsp = self.currentPsp or machine.pspSeg or 0,
			}
		else
			fail(cpu, 2) -- AUX/PRN are not present on this machine
			return
		end
		setAX(cpu, self.nextHandle)
		self.nextHandle += 1
		ok(cpu)
		return
	end
	const path = machine.vfs:resolve(raw, self.cwd)
	const data = machine.vfs:readFile(path)
	if data == nil then
		fail(cpu, 2)
		return
	end
	self.handles[self.nextHandle] = {
		console = false,
		path = path,
		data = data,
		pos = 0,
		ownerPsp = self.currentPsp or machine.pspSeg or 0,
	}
	setAX(cpu, self.nextHandle)
	self.nextHandle += 1
	ok(cpu)
end

Dos.FN[0x3E] = function(self: Dos, cpu: any, machine: Host) -- close handle BX
	const handle = self.handles[cpu.r[4]]
	if not handle then
		fail(cpu, 6)
		return
	end
	-- A child PSP inherits a copy of the parent's JFT. Closing that copy must
	-- not free the shared entry while the owner/parent still has it open; this
	-- bit KERNEL's lazily-read VGA.DRV/ VGA font handles (CALENDAR/REVERSI).
	const psp = self.currentPsp or machine.pspSeg or 0
	if handle.ownerPsp and psp ~= handle.ownerPsp then
		ok(cpu)
		return
	end
	if not handle.console and handle.path and handle.data then
		machine.vfs:writeFile(handle.path, handle.data)
	end
	self.handles[cpu.r[4]] = nil
	ok(cpu)
end

Dos.FN[0x3F] = function(self: Dos, cpu: any, machine: Host) -- read from handle
	const handle = self.handles[cpu.r[4]]
	if not handle then
		fail(cpu, 6)
		return
	end
	const want = cpu.r[2]
	if handle.nul then
		setAX(cpu, 0)
		ok(cpu)
		return
	end
	if handle.console then
		if handle.stdin and #machine.keys == 0 then
			cpu.halted = true
			machine.waiting = "keyboard"
			machine.pendingInt = 0x21
			return
		end
		local got: { string } = {}
		while #machine.keys > 0 and #got < want do
			got[#got + 1] = string.char(table.remove(machine.keys, 1) :: number)
		end
		const text = table.concat(got)
		machine.mem:writeString(lshift(cpu.ds, 4) + cpu.r[3], text)
		setAX(cpu, #text)
	else
		const data = handle.data or ""
		const pos = handle.pos or 0
		const text = string.sub(data, pos + 1, pos + want)
		handle.pos = pos + #text
		machine.mem:writeString(lshift(cpu.ds, 4) + cpu.r[3], text)
		setAX(cpu, #text)
	end
	ok(cpu)
end

Dos.FN[0x40] = function(self: Dos, cpu: any, machine: Host) -- write to handle
	const handle = self.handles[cpu.r[4]]
	if not handle then
		fail(cpu, 6)
		return
	end
	const text = machine.mem:readString(lshift(cpu.ds, 4) + cpu.r[3], cpu.r[2])
	if handle.nul then
		setAX(cpu, #text)
		ok(cpu)
		return
	end
	if handle.console then
		machine.bios:write(text)
	else
		const data = handle.data or ""
		const pos = handle.pos or 0
		handle.data = string.sub(data, 1, pos) .. text .. string.sub(data, pos + #text + 1)
		handle.pos = pos + #text
		if handle.path then
			machine.vfs:writeFile(handle.path, handle.data)
		end
	end
	setAX(cpu, #text)
	ok(cpu)
end

Dos.FN[0x41] = function(self: Dos, cpu: any, machine: Host) -- delete file
	const gone, err = machine.vfs:delete(self:readAsciz(cpu))
	if not gone then
		fail(cpu, err or 2)
	else
		ok(cpu)
	end
end

Dos.FN[0x42] = function(self: Dos, cpu: any, _machine: Host) -- lseek
	const handle = self.handles[cpu.r[4]]
	if not handle or handle.console then
		fail(cpu, 6)
		return
	end
	const offset = band(cpu.r[2], 0xFFFF) * 65536 + cpu.r[3]
	const origin = al(cpu)
	const size = #(handle.data or "")
	local base = 0
	if origin == 1 then
		base = handle.pos or 0
	elseif origin ~= 0 then
		base = size
	end
	local position = base + offset
	if position < 0 then
		position = 0
	end
	handle.pos = position
	setAX(cpu, band(position, 0xFFFF))
	cpu:wr(2, band(rshift(position, 16), 0xFFFF))
	ok(cpu)
end

Dos.FN[0x43] = function(self: Dos, cpu: any, machine: Host) -- get/set file attributes
	const path = self:readAsciz(cpu)
	const node = machine.vfs:lookup(path)
	if not node then
		fail(cpu, 2)
		return
	end
	if al(cpu) == 0 then
		cpu.r[2] = node.type == "dir" and 0x10 or 0x20 -- CX: directory / archive
		ok(cpu)
	elseif al(cpu) == 1 then
		ok(cpu) -- attributes are not modelled; accept the request
	else
		fail(cpu, 1)
	end
end

Dos.FN[0x57] = function(_self: Dos, cpu: any, _machine: Host) -- file date/time
	if al(cpu) == 0 then
		const handle = cpu.r[4] -- BX
		if handle == 0 then
			fail(cpu, 6)
			return
		end
		cpu.r[2] = 0x1421 -- CX: 1990-01-01
		cpu.r[3] = 0x6000 -- DX: 12:00:00
		ok(cpu)
	elseif al(cpu) == 1 then
		ok(cpu) -- timestamps are not modelled
	else
		fail(cpu, 1)
	end
end

-- IOCTL. Windows uses this to classify handles and drives: CON must report a
-- character device (bit 7) or KERNEL treats the console as a file and never
-- starts the shell. The rest of the subfunctions are the harmless single-drive
-- answers a plain DOS box gives.
Dos.FN[0x44] = function(self: Dos, cpu: any, machine: Host)
	const sub = al(cpu)
	if sub == 0 then -- get device info
		const handle = self.handles[cpu.r[4]]
		if not handle then
			fail(cpu, 6)
			return
		end
		cpu.r[3] = handle.console and 0x80D3 or 0x0002
		ok(cpu)
	elseif sub == 1 then -- set device info (not modelled)
		ok(cpu)
	elseif sub == 6 then -- input status
		cpu:wb(0, (#machine.keys > 0) and 0xFF or 0x00)
		ok(cpu)
	elseif sub == 7 then -- output status
		cpu:wb(0, 0xFF)
		ok(cpu)
	elseif sub == 8 then -- is drive removable -> A:/B: floppy, C: fixed
		local drive = band(cpu.r[4], 0xFF)
		if drive == 0 then
			drive = self.defaultDrive + 1
		end
		if drive < 1 or drive > 3 then
			fail(cpu, 0x0F)
			return
		end
		setAX(cpu, drive <= 2 and 1 or 0)
		ok(cpu)
	elseif sub == 9 then -- is drive remote -> this machine has only local drives
		local drive = band(cpu.r[4], 0xFF)
		if drive == 0 then
			drive = self.defaultDrive + 1
		end
		if drive < 1 or drive > 3 then
			fail(cpu, 0x0F)
			return
		end
		cpu.r[3] = 0 -- DX: no remote/network attributes
		setAX(cpu, 0)
		ok(cpu)
	elseif sub == 0x0E then -- get logical drive map -> no mapped drive
		local drive = band(cpu.r[4], 0xFF)
		if drive == 0 then
			drive = self.defaultDrive + 1
		end
		if drive < 1 or drive > 3 then
			fail(cpu, 0x0F)
			return
		end
		setAX(cpu, 0)
		ok(cpu)
	elseif sub == 0x0A then -- is handle remote -> local
		cpu.r[3] = 0
		ok(cpu)
	else
		fail(cpu, 1)
	end
end

Dos.FN[0x47] = function(self: Dos, cpu: any, machine: Host) -- get cwd -> DS:SI
	-- DOS convention: path from the root, no drive, NO trailing backslash
	-- (the root itself is the empty string), NUL-terminated.
	local path = string.sub(self.cwd, 4) -- strip "C:\"
	if string.sub(path, -1) == "\\" then
		path = string.sub(path, 1, -2)
	end
	machine.mem:writeString(lshift(cpu.ds, 4) + cpu.r[7], path)
	machine.mem:write8(lshift(cpu.ds, 4) + cpu.r[7] + #path, 0)
	-- DOS returns AH=1, AL=0 on success. WRITE's path helper scans for the
	-- terminator by comparing bytes to AL, so leaving AL='A' wraps the segment
	-- and turns its startup into a false "Insufficient memory" dialog.
	setAX(cpu, 0x0100)
	ok(cpu)
end

Dos.FN[0x48] = function(_self: Dos, cpu: any, machine: Host) -- allocate block (BX paras) -> AX base
	const segment = machine:dosAlloc(cpu.r[4])
	if not segment then
		fail(cpu, 8) -- INSUFFICIENT_MEMORY
		cpu:wr(3, machine:dosLargest()) -- BX = largest available
		return
	end
	setAX(cpu, segment)
	ok(cpu)
end

Dos.FN[0x49] = function(_self: Dos, cpu: any, machine: Host) -- free block (ES = base)
	if machine:dosFree(cpu.es) then
		ok(cpu)
	else
		fail(cpu, 9) -- invalid memory block address
	end
end

Dos.FN[0x4A] = function(_self: Dos, cpu: any, machine: Host) -- resize block (ES = base, BX = new size)
	const segment = cpu.es
	const newSize = cpu.r[4]
	for index, block in machine.memBlocks do
		if block.start == segment then
			if block.size >= newSize then
				-- shrink / same: carve the remainder into a free block
				if block.size >= newSize + 2 then
					const rest = {
						start = block.start + newSize + 1,
						size = block.size - newSize - 1,
						owner = 0,
					}
					block.size = newSize
					table.insert(machine.memBlocks, index + 1, rest)
					machine:syncArena()
				end
				ok(cpu)
			else
				-- grow: only if the next block is free and big enough
				const next = machine.memBlocks[index + 1]
				if next and next.owner == 0 and block.size + 1 + next.size >= newSize then
					const spare = next.size + block.size - newSize
					block.size = newSize
					if spare >= 2 then
						next.start = block.start + newSize + 1
						next.size = spare - 1
					else
						table.remove(machine.memBlocks, index + 1)
					end
					machine:syncArena()
					ok(cpu)
				else
					fail(cpu, 8)
					cpu:wr(3, machine:dosLargest())
				end
			end
			return
		end
	end
	fail(cpu, 9) -- invalid memory block address
end

Dos.FN[0x4B] = function(self: Dos, cpu: any, machine: Host) -- EXEC
	const mode = band(cpu.r[1], 0xFF)
	const path = self:readAsciz(cpu)
	const data: string? = machine.vfs:readFile(path)
	machine:log(("EXEC %s (%s bytes)"):format(path, data and tostring(#data) or "missing"))
	if not data then
		fail(cpu, 2)
		return
	end
	if mode == 3 then
		error("EXEC load-overlay (AL=3) not implemented for " .. path)
	end
	if mode ~= 0 then
		error(("unsupported EXEC mode AL=%d for %s"):format(mode, path))
	end

	const esbx = lshift(cpu.es, 4) + cpu.r[4]
	const envSeg = machine.mem:read16(esbx)
	const cmdOff = machine.mem:read16(esbx + 2)
	const cmdSeg = machine.mem:read16(esbx + 4)

	const isMZ = string.byte(data, 1) == 0x4D and string.byte(data, 2) == 0x5A
	const buf = buffer.fromstring(data)
	if machine.xms then
		machine.xms:releaseAll()
	end

	-- Inherit the parent environment strings unless the caller supplied one.
	const parentPsp = self.currentPsp or machine.pspSeg or 0x1000
	const parentEnv = machine.mem:read16(lshift(parentPsp, 4) + 0x2C)
	const inherited = envSeg ~= 0 and envSeg or parentEnv

	-- DOS allocates a fresh environment block and a fresh program block.
	const newEnv = machine:dosAlloc(0x40)
	if not newEnv then
		fail(cpu, 8)
		return
	end
	local programParas: number
	if isMZ then
		const cblp = buffer.readu16(buf, 2)
		const cp = buffer.readu16(buf, 4)
		const cparhdr = buffer.readu16(buf, 8)
		local fileLen = cp * 512
		if cblp > 0 then
			fileLen -= 512 - cblp
		end
		const imageParas = math.ceil(math.max(fileLen - cparhdr * 16, 0) / 16)
		-- A bound NE image is mapped at the top of the program block and its
		-- own loader copies the NE segments down below the image. Reserve a
		-- second image-sized area for that copy plus 0x1000 paragraphs of
		-- heap. With only 0x1000 below the image, KERNEL's relocated segments
		-- and local heap collide with its stack (the AnsiUpper code gets
		-- overwritten from a module-data read).
		--
		-- A bound-NE KERNEL self-relocates and builds its global heap inside
		-- the program block, then loads NE segments from that heap. If the
		-- block ends where the image was mapped, the leftover memory above it
		-- becomes a separate heap arena; KERNEL's first-fit scan stops at that
		-- arena boundary before it can reach GDI's 21 KB segment hole, and the
		-- load fails. Reserve the whole free run for the program block, as DOS
		-- does when an EXE asks for maximum allocation, so the heap arena
		-- covers the segment area.
		const neOff = buffer.readu32(buf, 0x3C)
		const boundNE = neOff + 1 < buffer.len(buf)
			and buffer.readu8(buf, neOff) == 0x4E
			and buffer.readu8(buf, neOff + 1) == 0x45
		const minimumParas = 0x10 + imageParas + (if boundNE then imageParas else 0) + 0x1000
		programParas = if boundNE
			then math.max(minimumParas, machine:dosLargest())
			else minimumParas
	else
		programParas = math.max(0x100 + math.ceil(buffer.len(buf) / 16), 0x1000)
	end
	const pspSeg = machine:dosAlloc(programParas)
	if not pspSeg then
		machine:dosFree(newEnv)
		fail(cpu, 8)
		return
	end
	machine:dosSetOwner(newEnv, pspSeg)
	machine:dosSetOwner(pspSeg, pspSeg)

	if isMZ then
		-- Bound NE images self-relocate, so the MZ image is mapped at the top
		-- of the block and no eager NE fixups are applied here.
		machine.deps.Executables.loadMZ(machine, buf, path, pspSeg, newEnv, inherited, programParas)
	else
		machine.deps.Executables.loadCOM(
			machine,
			buf,
			pspSeg,
			path,
			newEnv,
			inherited,
			programParas
		)
	end

	-- PSP:2 is the top of the program's memory block.
	const pspBase = lshift(pspSeg, 4)
	machine.mem:write16(pspBase + 2, pspSeg + programParas)

	-- command tail -> child PSP:80
	local tail = ""
	if cmdSeg ~= 0 then
		const cmdBase = lshift(cmdSeg, 4) + cmdOff
		const length = machine.mem:read8(cmdBase)
		for index = 1, length do
			tail ..= string.char(machine.mem:read8(cmdBase + index))
		end
	end
	machine.mem:write8(pspBase + 0x80, #tail)
	if #tail > 0 then
		machine.mem:writeString(pspBase + 0x81, tail)
	end
	machine.mem:write8(pspBase + 0x81 + #tail, 0x0D)
	ok(cpu)
end

Dos.FN[0x4C] = function(_self: Dos, cpu: any, machine: Host)
	machine:exit(al(cpu))
end

-- Undocumented DOS "create child PSP" (used by EXEC and by KERNEL's own
-- loader): copy the current PSP to DX, put SI in the new PSP:0002, and record
-- the parent. No handle-table split is modelled; the child shares the JFT.
Dos.FN[0x55] = function(self: Dos, cpu: any, machine: Host)
	const childSeg = cpu.r[3] -- DX
	const parentSeg = self.currentPsp or machine.pspSeg or 0x1000
	const src = lshift(parentSeg, 4)
	const dst = lshift(childSeg, 4)
	for index = 0, 0xFF do
		machine.mem:write8(dst + index, machine.mem:read8(src + index))
	end
	machine.mem:write16(dst + 0x02, cpu.r[7]) -- SI: top of memory
	machine.mem:write16(dst + 0x16, parentSeg) -- parent PSP
	ok(cpu)
end

Dos.FN[0x33] = function(self: Dos, cpu: any, _machine: Host) -- ctrl-break flag
	if al(cpu) == 1 then
		self.ctrlBreak = band(cpu.r[3], 0xFF) ~= 0 -- DL
	end
	cpu:wb(2, self.ctrlBreak and 1 or 0) -- DL = current state
	ok(cpu)
end

Dos.FN[0x34] = function(_self: Dos, cpu: any, machine: Host) -- get InDOS flag address -> ES:BX
	const address = lshift(Dos.DATA_SEG, 4) + Dos.INDOS_OFF
	machine.mem:write8(address, 0) -- never inside DOS
	cpu.es = Dos.DATA_SEG
	cpu.r[4] = Dos.INDOS_OFF
	ok(cpu)
end

Dos.FN[0x52] = function(_self: Dos, cpu: any, _machine: Host) -- get list of lists -> ES:BX
	-- BX points at the first-DPB field: [BX-2] is the first MCB, [BX+4] the
	-- first SFT, [BX+22h] the NUL device header (standard DOS layout).
	cpu.es = Dos.DATA_SEG
	cpu.r[4] = Dos.LOL_OFF + 2
	ok(cpu)
end

Dos.FN[0x50] = function(self: Dos, cpu: any, _machine: Host) -- set PSP
	self.currentPsp = cpu.r[4]
	ok(cpu)
end

Dos.FN[0x51] = function(self: Dos, cpu: any, machine: Host) -- get PSP
	const psp = self.currentPsp or machine.pspSeg or 0
	setAX(cpu, psp)
	cpu.r[4] = psp -- DOS documents BX=PSP; some callers read AX
	ok(cpu)
end

Dos.FN[0x62] = Dos.FN[0x51]

Dos.FN[0x1A] = function(self: Dos, cpu: any, _machine: Host) -- set DTA (DS:DX)
	self.dtaSeg = cpu.ds
	self.dtaOff = cpu.r[3]
	ok(cpu)
end

Dos.FN[0x2F] = function(self: Dos, cpu: any, machine: Host) -- get DTA -> ES:BX
	cpu.es = self.dtaSeg or self.currentPsp or machine.pspSeg or 0
	cpu.r[4] = self.dtaOff or 0x80
	ok(cpu)
end

-- ---------------------------------------------------------- find first/next
-- DOS directory searches come in two layouts: FCB searches (AH=11/12) fill a
-- 43-byte FCB-style entry in the DTA, while DOS 3+ searches (AH=4E/4F) fill
-- the 43-byte DTA entry with the attribute at +21h and the ASCIIZ name at
-- +20h.  Both share the same wildcard matcher and VFS listing.

local function splitName(name: string): (string, string)
	const base, ext = string.match(name, "^([^%.]*)%.?(.*)$")
	return base or name, ext or ""
end

local function padded11(name: string): string
	const base, ext = splitName(name)
	return (base .. "        "):sub(1, 8) .. (ext .. "   "):sub(1, 3)
end

local function fcbPattern(text: string): string
	text = string.upper(text)
	const base, ext = splitName(text)
	local function field(value: string, width: number): string
		local out = {}
		for index = 1, width do
			const ch = string.sub(value, index, index)
			if ch == "*" then
				for _ = index, width do
					out[#out + 1] = "?"
				end
				break
			elseif ch == "" then
				out[#out + 1] = " "
			else
				out[#out + 1] = ch
			end
		end
		return table.concat(out)
	end
	return field(base, 8) .. field(ext, 3)
end

local function matchesFcb(pattern: string, name: string): boolean
	if #pattern ~= 11 or #name ~= 11 then
		return false
	end
	for index = 1, 11 do
		const want = string.sub(pattern, index, index)
		if want ~= "?" and want ~= string.sub(name, index, index) then
			return false
		end
	end
	return true
end

local function writeFixed(mem: any, address: number, text: string, width: number)
	for index = 1, width do
		mem:write8(address + index - 1, string.byte(text, index) or 0x20)
	end
end

local function writeFindEntry(
	self: Dos,
	machine: Host,
	entry: { name: string, size: number, dir: boolean },
	fcbMode: boolean
)
	const mem = machine.mem
	const dtaSeg = self.dtaSeg or self.currentPsp or machine.pspSeg or 0
	const dtaOff = self.dtaOff or 0x80
	const base = lshift(dtaSeg, 4) + dtaOff
	const baseName, ext = splitName(entry.name)
	const attr = entry.dir and 0x10 or 0x20
	if fcbMode then
		mem:write8(base, 0) -- default drive
		writeFixed(mem, base + 1, (baseName .. "        "):sub(1, 8), 8)
		writeFixed(mem, base + 9, (ext .. "   "):sub(1, 3), 3)
		mem:write8(base + 12, attr)
		for offset = 13, 22 do
			mem:write8(base + offset, 0)
		end
		mem:write16(base + 23, 0)
		mem:write16(base + 25, 0x21) -- 1980-01-01
		mem:write16(base + 27, 0)
		mem:write16(base + 29, entry.size % 65536)
		mem:write16(base + 31, math.floor(entry.size / 65536))
	else
		for offset = 0, 20 do
			mem:write8(base + offset, 0)
		end
		mem:write8(base + 21, attr)
		mem:write16(base + 22, 0) -- time
		mem:write16(base + 24, 0x21) -- 1980-01-01
		mem:write16(base + 26, entry.size % 65536) -- size low
		mem:write16(base + 28, math.floor(entry.size / 65536)) -- size high
		const display = if ext == "" then baseName else baseName .. "." .. ext
		mem:writeString(base + 30, display)
		mem:write8(base + 30 + #display, 0)
	end
end

local function matchesSearchAttr(entry: { dir: boolean }, mask: number): boolean
	if entry.dir then
		return band(mask, 0x10) ~= 0
	end
	-- The VFS has no volume labels. A volume-only search must not return a
	-- normal file; that is what WINFILE was displaying as its bogus [TXT] label.
	return not (band(mask, 0x08) ~= 0 and band(mask, 0x10) == 0)
end

local function beginFind(
	self: Dos,
	machine: Host,
	pattern: string,
	fcbMode: boolean,
	directory: string?,
	attrMask: number?
)
	if self.defaultDrive > 2 then
		self.find = { entries = {}, index = 0, fcbMode = fcbMode }
		return
	end
	const mask = attrMask or 0
	local entries = {}
	for _, entry in machine.vfs:list(directory or self.cwd) or {} do
		if matchesFcb(pattern, padded11(entry.name)) and matchesSearchAttr(entry, mask) then
			entries[#entries + 1] = entry
		end
	end
	self.find = { entries = entries, index = 0, fcbMode = fcbMode }
end

local function nextFind(self: Dos, machine: Host): boolean
	const find = self.find
	if not find then
		return false
	end
	find.index += 1
	const entry = find.entries[find.index]
	if not entry then
		return false
	end
	writeFindEntry(self, machine, entry, find.fcbMode)
	return true
end

Dos.FN[0x11] = function(self: Dos, cpu: any, machine: Host) -- find first (FCB)
	const fcb = lshift(cpu.ds, 4) + cpu.r[3]
	-- DOS 4+ extended FCB: FF, 5 reserved, attribute, drive, then name/ext.
	-- MS-DOS Executive passes one of these, so the name starts at +8 and the
	-- search attribute at +6; a normal FCB keeps it at +0Ch.
	const extended = machine.mem:read8(fcb) == 0xFF
	const nameBase = if extended then fcb + 8 else fcb + 1
	const attr = machine.mem:read8(if extended then fcb + 6 else fcb + 0x0C)
	local pattern = {}
	for index = 0, 10 do
		pattern[index + 1] = string.char(machine.mem:read8(nameBase + index))
	end
	beginFind(self, machine, table.concat(pattern):gsub("%*", "?"), true, nil, attr)
	cpu:wb(0, if nextFind(self, machine) then 0 else 0xFF)
	ok(cpu)
end

Dos.FN[0x12] = function(self: Dos, cpu: any, machine: Host) -- find next (FCB)
	cpu:wb(0, if nextFind(self, machine) then 0 else 0xFF)
	ok(cpu)
end

Dos.FN[0x36] = function(self: Dos, cpu: any, _machine: Host) -- get free disk space
	local drive = band(cpu.r[3], 0xFF)
	if drive == 0 then
		drive = self.defaultDrive + 1
	end
	if drive < 1 or drive > 3 then
		fail(cpu, 0x0F)
		return
	end
	setAX(cpu, 4) -- sectors per cluster
	cpu.r[4] = 0x7000 -- free clusters
	cpu.r[2] = 512 -- bytes per sector
	cpu.r[3] = 0x9000 -- total clusters
	ok(cpu)
end

Dos.FN[0x4E] = function(self: Dos, cpu: any, machine: Host) -- find first (DTA)
	const raw = self:readRawAsciz(cpu)
	const matched = { string.match(raw, "^(.*)\\([^\\]*)$") }
	local directory = matched[1]
	const pattern = matched[2] or raw
	if directory == "" then
		directory = "C:\\"
	end
	beginFind(self, machine, fcbPattern(pattern), false, directory, band(cpu.r[2], 0xFF))
	if nextFind(self, machine) then
		setAX(cpu, 0)
		ok(cpu)
	else
		fail(cpu, 0x12)
	end
end

Dos.FN[0x4F] = function(self: Dos, cpu: any, machine: Host) -- find next (DTA)
	if nextFind(self, machine) then
		setAX(cpu, 0)
		ok(cpu)
	else
		fail(cpu, 0x12)
	end
end

return Dos
