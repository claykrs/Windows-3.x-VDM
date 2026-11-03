--!strict
-- Machine.lua -- wires memory + cpu + bios + dos + vfs; run(maxSteps) slices.

const band, bnot, bor, rshift, lshift =
	bit32.band, bit32.bnot, bit32.bor, bit32.rshift, bit32.lshift

const Machine = {}
Machine.__index = Machine

const PIT_HZ = 1_193_182

export type MemBlock = {
	start: number,
	size: number,
	owner: number,
}

export type WinFn = {
	fn: (machine: Machine, cpu: any) -> (),
	args: number,
	fnId: number?,
}

export type WinModule = {
	[number]: WinFn,
}

export type WinEntry = {
	seg: number,
	off: number,
	movable: boolean?,
}

export type WinImage = {
	segBases: { [number]: number },
	entries: { [number]: WinEntry },
	resident: { [string]: number },
	dgroup: number?,
	entrySeg: number,
	entryOff: number,
	ssIdx: number,
	sp: number,
}

export type Deps = {
	Memory: any,
	Cpu: any,
	Vfs: any,
	Bios: any,
	Dos: any,
	TextScreen: any,
	Executables: any,
	Xms: any,
	Vga: any?,
	logger: ((message: string) -> ())?,
}

export type Config = {
	io: any?,
	cpu: any?,
	memorySize: number?,
	timerInterval: number?,
}

export type Machine = {
	deps: Deps,
	config: Config,
	mem: any,
	cpu: any,
	xms: any,
	vfs: any,
	vga: any?,
	bios: any,
	dos: any,
	keys: { number },
	output: { string },
	diagnostics: { string },
	waiting: string?,
	pendingInt: number?,
	exitCode: number?,
	timerInterval: number,
	timerPhase: number,
	arenaTop: number,
	memBlocks: { MemBlock },
	dosOwner: number,
	winModules: { [string]: WinModule },
	winFnIds: { [number]: WinFn },
	winImages: { [string]: WinImage },
	nextFnId: number,
	thunkSeg: number,
	thunkOff: number,
	pspSeg: number?,
	timerStubSeg: number,
	timerStubOff: number,
	picInService: number,
	picMask: number,
	mouseX: number,
	mouseY: number,
	mouseButtons: number,
	mouseVisible: boolean,
	mouseMinX: number,
	mouseMaxX: number,
	mouseMinY: number,
	mouseMaxY: number,
	mouseDeltaX: number,
	mouseDeltaY: number,
	mouseMickeyX: number,
	mouseMickeyY: number,
	mouseCountX: number,
	mouseCountY: number,
	mouseHandler: { seg: number, off: number }?,
	mouseDeviceHandler: { seg: number, off: number }?,
	mousePs2Enabled: boolean,
	mouseSampleRate: number,
	mouseResolution: number,
	mouseScaling: number,
	mousePacketSize: number,
	mousePackets: { { status: number, dx: number, dy: number, sync: boolean? } },
	mouseIrqActive: boolean,
	mouseIrqAge: number,
	mouseIrqSs: number,
	mouseIrqSp: number,
	mouseConfigSeg: number,
	mouseConfigOff: number,
	mouseCleanupSeg: number,
	mouseCleanupOff: number,
	mouseIrqStubSeg: number,
	mouseIrqStubOff: number,
	keyboardQueue: { number },
	keyboardData: number?,
	keyboardOutputFull: boolean,
	keyboardPending: boolean,
	keyboardEnabled: boolean,
	keyboardIrqActive: boolean,
	keyboardIrqSs: number,
	keyboardIrqSp: number,
	port61: number,
	pit2Access: number,
	cmos: { [number]: number },
	cmosIndex: number,
	pit2Mode: number,
	pit2Latch: number,
	pit2Low: number,
	pit2Divisor: number,
	speakerEnabled: boolean,
	speakerFrequency: number,
	speakerSequence: number,

	run: (self: Machine, maxSteps: number?) -> number,
	exit: (self: Machine, code: number) -> (),
	logChar: (self: Machine, ch: number) -> (),
	logString: (self: Machine, message: string) -> (),
	log: (self: Machine, message: string) -> (),
	outputText: (self: Machine) -> string,
	screenText: (self: Machine) -> string,
	pushKeys: (self: Machine, keys: string) -> (),
	maybeResume: (self: Machine) -> (),
	setMouse: (self: Machine, x: number, y: number, buttons: number) -> (),
	keyDown: (self: Machine, scan: number) -> (),
	keyUp: (self: Machine, scan: number) -> (),
	queueScanCode: (self: Machine, scan: number) -> (),
	latchKeyboard: (self: Machine) -> (),
	dispatchKeyboardIrq: (self: Machine) -> boolean,
	mouseInt33: (self: Machine) -> (),
	int15: (self: Machine) -> (),
	int74: (self: Machine) -> (),
	queueMousePacket: (self: Machine, dx: number, dy: number, sync: boolean?) -> (),
	syncMouse: (self: Machine) -> boolean,
	dispatchMouseIrq: (self: Machine) -> boolean,
	writePit2: (self: Machine, value: number) -> (),
	updateSpeaker: (self: Machine) -> (),
	shutdownResume: (self: Machine, cpu: any) -> (),
	speakerState: (self: Machine) -> { enabled: boolean, frequency: number, sequence: number },
	loadCOM: (
		self: Machine,
		bytes: buffer,
		pspSeg: number?,
		programPath: string?,
		envSeg: number?,
		parentEnvSeg: number?,
		stackParas: number?
	) -> number,
	loadMZ: (
		self: Machine,
		bytes: buffer,
		programPath: string?,
		pspSeg: number?,
		envSeg: number?,
		parentEnvSeg: number?,
		programParas: number?
	) -> number,
	loadNE: (self: Machine, bytes: buffer) -> any,
	dosAlloc: (self: Machine, paras: number) -> number?,
	dosReserve: (self: Machine, start: number, paras: number) -> boolean,
	dosSetOwner: (self: Machine, seg: number, owner: number) -> boolean,
	dosFree: (self: Machine, seg: number) -> boolean,
	dosLargest: (self: Machine) -> number,
	syncArena: (self: Machine) -> (),
	advanceTimer: (self: Machine) -> (),
	resolveWinImport: (self: Machine, moduleName: string?, ordinal: number) -> (number, number),
	resolveWinImportByName: (
		self: Machine,
		moduleName: string,
		funcName: string
	) -> (number, number),
	defineWinModule: (self: Machine, name: string, exports: WinModule) -> (),
	getImportThunk: (self: Machine, name: string, ordinal: number) -> (number, number),
	winInt80: (self: Machine) -> (),
}

function Machine.new(deps: Deps, config: Config?): Machine
	const self = setmetatable({}, Machine) :: any
	self.deps = deps
	self.config = config or {}
	self.mem = deps.Memory.new(self.config.memorySize)
	self.vga = if deps.Vga then deps.Vga.new(self.mem) else nil
	if self.vga then
		self.mem.aperture = self.vga
	end
	-- Minimal 8259A state. IRQ0 is the only interrupt the host sources, but
	-- the guest still programs/reads the PIC (OCW2 EOI, OCW3 read-ISR), so
	-- keep the in-service bit honest. Without it Windows' timer handler can be
	-- re-entered while its previous invocation is still processing callbacks.
	self.picInService = 0
	self.picMask = 0
	-- Microsoft mouse driver INT 33h state. The driver polls deltas (AX=0Bh)
	-- and position (AX=03h), so host pointer motion only has to update these.
	self.mouseX = 320
	self.mouseY = 240
	self.mouseButtons = 0
	self.mouseVisible = false
	self.mouseMinX = 0
	self.mouseMaxX = 639
	self.mouseMinY = 0
	self.mouseMaxY = 479
	self.mouseDeltaX = 0
	self.mouseDeltaY = 0
	self.mouseMickeyX = 8
	self.mouseMickeyY = 16
	self.mouseCountX = 0
	self.mouseCountY = 0
	self.mouseHandler = nil
	-- PS/2 BIOS pointing-device state (INT 15h AH=C2xx). MOUSE.DRV's PS/2
	-- path installs a device handler via C207 and expects the BIOS to call it
	-- with the three-byte packet (status, dx, dy) once per IRQ12.
	self.mouseDeviceHandler = nil
	self.mousePs2Enabled = false
	self.mouseSampleRate = 40
	self.mouseResolution = 3
	self.mouseScaling = 1
	self.mousePacketSize = 3
	self.mousePackets = {}
	self.mouseIrqActive = false
	self.mouseIrqAge = 0
	self.mouseIrqSs = 0
	self.mouseIrqSp = 0
	-- INT 15h AH=C0h system configuration table. Byte 2 is the machine
	-- model byte; 0FCh is a PS/2 model whose pointing-device port uses
	-- IRQ12 (INT 74h). MOUSE.DRV rejects anything but F8h/FCh/FAh.
	self.mouseConfigSeg = 0xF100
	self.mouseConfigOff = 0x0200
	const configBase = lshift(self.mouseConfigSeg, 4) + self.mouseConfigOff
	self.mem:write16(configBase, 0x0020) -- table size in bytes
	self.mem:write8(configBase + 2, 0xFC) -- model byte: PS/2
	self.mem:write8(configBase + 3, 0x00) -- submodel
	self.mem:write8(configBase + 4, 0x00) -- BIOS revision
	self.mem:write8(configBase + 5, 0x01) -- feature information
	-- cleanup trampoline for a synthetic C207 device-handler call:
	-- ADD SP,8 (flags + status/dx/dy) ; INT 9Eh ; IRET
	self.mouseCleanupSeg = 0xF100
	self.mouseCleanupOff = 0x0068
	self.mouseIrqStubSeg = 0xF100
	self.mouseIrqStubOff = 0
	const cleanupBase = lshift(self.mouseCleanupSeg, 4) + self.mouseCleanupOff
	self.mem:write8(cleanupBase, 0x83) -- ADD SP, imm8
	self.mem:write8(cleanupBase + 1, 0xC4)
	self.mem:write8(cleanupBase + 2, 0x08)
	self.mem:write8(cleanupBase + 3, 0xCD) -- INT 9Eh
	self.mem:write8(cleanupBase + 4, 0x9E)
	self.mem:write8(cleanupBase + 5, 0xCF) -- IRET
	-- 8042 keyboard controller: one latched output byte, IRQ1, and the usual
	-- status port. KEYBOARD.DRV reads 0x60 from its INT 9 handler and chains to
	-- the BIOS vector for keys it does not translate itself.
	self.keyboardQueue = {}
	self.keyboardData = nil
	self.keyboardOutputFull = false
	self.keyboardPending = false
	self.keyboardEnabled = true
	self.keyboardIrqActive = false
	self.keyboardIrqSs = 0
	self.keyboardIrqSp = 0
	self.port61 = 0
	self.cmos = {}
	self.cmosIndex = 0
	self.pit2Access = 3
	self.pit2Mode = 3
	self.pit2Latch = 0
	self.pit2Low = 0
	self.pit2Divisor = 0
	self.speakerEnabled = false
	self.speakerFrequency = 0
	self.speakerSequence = 0
	local io = self.config.io
	if self.vga then
		const vga = self.vga :: any
		-- VGA owns the 0x3B0..0x3DF display ports; the PIC owns 0x20/0x21.
		io = {
			in8 = function(port: number): number
				if port >= 0x3B0 and port <= 0x3DF then
					return vga:in8(port)
				end
				if port == 0x20 then
					return self.picInService
				end
				if port == 0x21 then
					return self.picMask
				end
				if port == 0x60 then
					-- The output latch keeps returning the last byte until the
					-- next one arrives, so a chained INT 9 handler sees the same
					-- scan code its caller read.
					self.keyboardOutputFull = false
					return self.keyboardData or 0
				end
				if port == 0x64 then
					return bor(0x04, if self.keyboardOutputFull then 1 else 0)
				end
				if port == 0x61 then
					return self.port61
				end
				return 0
			end,
			out8 = function(port: number, value: number)
				if port >= 0x3B0 and port <= 0x3DF then
					vga:out8(port, value)
					return
				end
				if port == 0x21 then
					self.picMask = band(value, 0xFF)
					return
				end
				if port == 0x60 then
					return
				end
				if port == 0x64 then
					if value == 0xAE then
						self.keyboardEnabled = true
					elseif value == 0xAD then
						self.keyboardEnabled = false
					end
					return
				end
				if port == 0x43 then
					-- 8254 control word: remember channel 2's access mode. The
					-- speaker is the only channel 2 consumer we model; channel 0
					-- remains the instruction-counted IRQ0 source.
					const control = band(value, 0xFF)
					if band(rshift(control, 6), 0x03) == 2 then
						self.pit2Access = band(rshift(control, 4), 0x03)
						self.pit2Mode = band(rshift(control, 1), 0x07)
						self.pit2Latch = 0
						self.pit2Low = 0
					end
					return
				end
				if port == 0x42 then
					self:writePit2(band(value, 0xFF))
					return
				end
				if port == 0x61 then
					self.port61 = band(value, 0xFF)
					self:updateSpeaker()
					return
				end
				if port == 0x20 then
					const ocw2 = band(value, 0xE0)
					if ocw2 == 0x20 then
						-- non-specific EOI: clear the highest in-service bit
						for irq = 7, 0, -1 do
							if band(self.picInService, lshift(1, irq)) ~= 0 then
								self.picInService = band(self.picInService, bnot(lshift(1, irq)))
								break
							end
						end
					elseif ocw2 == 0x60 then
						-- specific EOI
						self.picInService = band(self.picInService, bnot(lshift(1, band(value, 7))))
					elseif band(value, 0x10) ~= 0 then
						self.picMask = band(value, 0xFF) -- OCW1
					end
				end
			end,
		}
	end
	const innerIn8 = io.in8
	const innerOut8 = io.out8
	io = {
		in8 = function(port: number): number
			if port == 0x71 then
				return self.cmos[self.cmosIndex] or 0
			end
			return innerIn8(port)
		end,
		out8 = function(port: number, value: number)
			if port == 0x70 then
				self.cmosIndex = band(value, 0x7F)
				return
			end
			if port == 0x71 then
				self.cmos[self.cmosIndex] = band(value, 0xFF)
				return
			end
			innerOut8(port, value)
		end,
	}
	self.cpu = deps.Cpu.new(self.mem, io, self.config.cpu)
	self.cpu.onTripleFault = function(cpu: any)
		self:shutdownResume(cpu)
	end
	self.xms = deps.Xms.new(self)
	self.vfs = deps.Vfs.new()
	self.bios = deps.Bios.new(self)
	self.dos = deps.Dos.new(self)
	self.keys = {} -- queue of ASCII codes
	self.output = {} -- console log fragments (tests assert on this)
	self.diagnostics = {} -- host-side diagnostics; never guest output
	self.waiting = nil -- "keyboard" when halted on empty queue
	self.pendingInt = nil -- interrupt to re-dispatch after a keyboard wait
	self.exitCode = nil

	-- BIOS data area: conventional memory size in KB (640) + equipment word
	-- (floppy present, pointing device, math coprocessor, 80x25 color video,
	-- 1 floppy drive). MOUSE.DRV's PS/2 probe checks bit 2 of INT 11h before
	-- it will program the auxiliary port through INT 15h AX=C2xx.
	self.mem:write16(0x413, 640)
	self.mem:write16(0x410, 0x0025)

	-- PIT/IRQ0: raise INT 8 every timerInterval steps once the guest installs
	-- a handler (IVT entry nonzero); the scheduler depends on timer ticks.
	-- Instruction-counted approximation of 18.2 Hz at roughly 1M instr/sec;
	-- override with config.timerInterval for faster/slower hosts.
	self.timerInterval = self.config.timerInterval or 55_000
	self.timerPhase = 0

	-- DOS memory arena: an MCB chain over conventional memory that guest code
	-- can walk like real DOS. Blocks: {start, size, owner} paragraphs.
	-- MCB paragraphs sit one paragraph BEFORE each block in emulated memory:
	-- [0]=M/Z [1..2]=owner [3..4]=size.
	self.arenaTop = 0xA000
	self.memBlocks = {
		{ start = 0x0000, size = 0x0050, owner = 8 }, -- IVT + BDA (no MCB)
		{ start = 0x0051, size = 0x07AF, owner = 8 }, -- DOS data: SFT/list of lists
		{ start = 0x0801, size = 0x07BE, owner = 0 }, -- free (MCB 0x0800)
		{ start = 0x0FC0, size = 0x003F, owner = 8 }, -- environment (MCB 0x0FBF)
		{ start = 0x1000, size = 0x00FF, owner = 8 }, -- PSP (MCB 0x0FFF)
		{ start = 0x1100, size = self.arenaTop - 0x1100, owner = 0 }, -- free
	}
	self.dosOwner = 8
	self:syncArena()

	self.cpu.defaultInts = {
		[0x00] = function()
			self.dos:divideOverflow()
		end,
		[0x09] = function()
			self.bios:int9()
		end,
		[0x10] = function()
			self.bios:int10()
		end,
		[0x11] = function()
			self.cpu:wr(0, self.mem:read16(0x410)) -- equipment list
		end,
		[0x12] = function()
			self.cpu:wr(0, 640) -- BIOS memory size
		end,
		[0x13] = function()
			const cpu = self.cpu
			-- BIOS disk: report success with no media; loud-fail if sectors read
			const ah = band(rshift(cpu.r[1], 8), 0xFF)
			if ah ~= 0x00 then
				error(("unsupported INT 13h function AH=%02X"):format(ah))
			end
			cpu:setbits(1, false) -- CF clear
			cpu:wb(4, 0) -- AH = 0
		end,
		[0x16] = function()
			self.bios:int16()
		end,
		[0x1A] = function()
			const cpu = self.cpu
			-- RTC: AH=0 ticks since midnight from the BDA
			const ah = band(rshift(cpu.r[1], 8), 0xFF)
			if ah == 0 then
				cpu:wr(2, self.mem:read16(0x46E)) -- CX high
				cpu:wr(3, self.mem:read16(0x46C)) -- DX low
				cpu:wb(0, 0) -- no midnight rollover
			else
				error(("unsupported INT 1Ah function AH=%02X"):format(ah))
			end
			cpu:setbits(1, false)
		end,
		[0x20] = function()
			self:exit(0)
		end,
		[0x21] = function()
			self.dos:int21()
		end,
		[0x27] = function()
			self:exit(0)
		end,
		[0x2F] = function()
			-- multiplexor: XMS owns 4300/4310; everything else reports nothing
			-- installed (no prior Windows), matching the 3.0a baseline.
			if not self.xms:int2f() then
				if self.cpu.r[1] == 0x4A05 then
					-- WSWAP probes this before freeing its XMS swap block; it
					-- subtracts AH from AL, so both halves must be zero.
					self.cpu:wr(0, 0)
				else
					self.cpu:wb(0, 0)
				end
			end
		end,
		[0x9F] = function()
			self.xms:dispatch()
		end,
		[0x15] = function()
			self:int15()
		end,
		[0x33] = function()
			self:mouseInt33()
		end,
		[0x74] = function()
			self:int74()
		end,
		-- Completion marker for the synthetic C207 handler call. The handler
		-- itself only stores the packet; the guest's outer INT 74h handler
		-- still has to decode it and call the Windows mouse callback, so the
		-- IRQ guard stays set until that handler restores SS:SP.
		[0x9E] = function() end,
		[0x80] = function()
			self:winInt80()
		end,
	}

	-- Materialize real-mode IVT stubs (INT 90+i; IRET at segment 0xF100) so
	-- guest code can hook and chain our services like a real DOS/BIOS: the
	-- kernel reads these vectors, replaces them, and far-calls the saved
	-- originals, which must be real addresses, not hypervisor fictions.
	const stubSeg = 0xF100
	const handled = {
		0x00,
		0x10,
		0x11,
		0x12,
		0x13,
		0x15,
		0x16,
		0x1A,
		0x20,
		0x21,
		0x27,
		0x2F,
		0x33,
		0x74,
		0x09,
		0x9F,
	}
	for index, interrupt in handled do
		const off = (index - 1) * 4
		const base = lshift(stubSeg, 4) + off
		self.mem:write8(base, 0xCD) -- INT
		self.mem:write8(base + 1, 0x90 + index - 1)
		self.mem:write8(base + 2, 0xCF) -- IRET
		self.mem:write16(lshift(interrupt, 2), off)
		self.mem:write16(lshift(interrupt, 2) + 2, stubSeg)
		self.cpu.defaultInts[0x90 + index - 1] = self.cpu.defaultInts[interrupt]
		-- let the CPU recognise the un-hooked vector and call the handler inline
		self.cpu:registerStub(interrupt, stubSeg, off)
		if interrupt == 0x74 then
			self.mouseIrqStubSeg, self.mouseIrqStubOff = stubSeg, off
		end
	end
	-- bare-IRET stubs for DOS/BIOS vectors real DOS always provides
	const iretOnly = { 0x1C, 0x23, 0x24, 0x28 }
	for index, interrupt in iretOnly do
		const off = 64 + (index - 1) * 4
		const base = lshift(stubSeg, 4) + off
		self.mem:write8(base, 0xCF) -- IRET
		self.mem:write16(lshift(interrupt, 2), off)
		self.mem:write16(lshift(interrupt, 2) + 2, stubSeg)
	end

	-- EMM (INT 67h): report "not installed" and return
	const emmOff = 0x50
	const emmBase = lshift(stubSeg, 4) + emmOff
	self.mem:write8(emmBase, 0xB4) -- MOV AH,84h
	self.mem:write8(emmBase + 1, 0x84)
	self.mem:write8(emmBase + 2, 0xCF) -- IRET
	self.mem:write16(lshift(0x67, 2), emmOff)
	self.mem:write16(lshift(0x67, 2) + 2, stubSeg)

	-- BIOS timer tick (INT 8). Guest ISRs chain to the vector that was
	-- installed before theirs; a real BIOS provides one. A real BIOS INT 8
	-- handler also acknowledges the PIC with a non-specific EOI before
	-- returning and preserves the interrupted program's registers. KERNEL
	-- chains to it and then reads the PIC's ISR; a bare IRET leaves IRQ0 in
	-- service, while MOV AL,20h alone silently clobbers the caller's AX
	-- (observed: GDI CreateCompatibleDC returned 0x0820 instead of 0x08EE).
	const timerOff = 0x58
	const timerBase = lshift(stubSeg, 4) + timerOff
	self.mem:write8(timerBase, 0x50) -- PUSH AX
	self.mem:write8(timerBase + 1, 0xB0) -- MOV AL, 20h
	self.mem:write8(timerBase + 2, 0x20)
	self.mem:write8(timerBase + 3, 0xE6) -- OUT 20h, AL
	self.mem:write8(timerBase + 4, 0x20)
	self.mem:write8(timerBase + 5, 0x58) -- POP AX
	self.mem:write8(timerBase + 6, 0xCF) -- IRET
	self.mem:write16(lshift(8, 2), timerOff)
	self.mem:write16(lshift(8, 2) + 2, stubSeg)
	self.timerStubOff = timerOff
	self.timerStubSeg = stubSeg

	-- Win16 module registry: imports patch to thunks that dispatch through INT 80h
	self.winModules = {} -- name -> exports array (1-based ordinals)
	self.winFnIds = {} -- fnId -> { fn = handler, args = bytes }
	self.winImages = {} -- uppercased module name -> loaded NE image record
	self.nextFnId = 1
	self.thunkSeg = 0xF000
	self.thunkOff = 0
	-- Protect the stubs from guests that zero all free RAM (Windows 3.1's
	-- WSWAP does this on 286+). 3.0a keeps the old writable behaviour.
	if self.cpu.level >= 1 then
		self.mem.protectStart = lshift(stubSeg, 4)
		self.mem.protectEnd = lshift(stubSeg, 4) + 0xFFF
	end
	return self
end

-- resolve an import: a real loaded NE image wins, else a Lua export thunk
function Machine.resolveWinImport(
	self: Machine,
	moduleName: string?,
	ordinal: number
): (number, number)
	const key = string.upper(moduleName or "")
	const image = self.winImages[key]
	if image then
		const entry = image.entries[ordinal]
		if not entry then
			error(("undefined export %s#%d"):format(key, ordinal))
		end
		return image.segBases[entry.seg], entry.off
	end
	const exports = self.winModules[key]
	if exports and exports[ordinal] then
		return self:getImportThunk(moduleName or "", ordinal)
	end
	error(("undefined Win16 import: %s#%d"):format(key, ordinal))
end

function Machine.resolveWinImportByName(
	self: Machine,
	moduleName: string,
	funcName: string
): (number, number)
	const image = self.winImages[string.upper(moduleName)]
	if image then
		const ordinal = image.resident[string.upper(funcName)]
		if not ordinal then
			error(("undefined export %s!%s"):format(moduleName, funcName))
		end
		return self:resolveWinImport(moduleName, ordinal)
	end
	error(("import by name needs a real image: %s!%s"):format(moduleName, funcName))
end

-- defineWinModule("KERNEL", { { args = 4, fn = function(machine, cpu) ... end }, ... })
-- Ordinals are 1-based (real KERNEL export numbers).
function Machine.defineWinModule(self: Machine, name: string, exports: WinModule)
	self.winModules[name] = exports
	for _, definition in pairs(exports) do -- sparse ordinal arrays have gaps
		if not definition.fnId then
			self.winFnIds[self.nextFnId] = definition
			definition.fnId = self.nextFnId
			self.nextFnId += 1
		end
	end
end

-- far pointer (seg, off) of an auto-generated import thunk:
--   push cx ; mov cx, fnId ; int 80h ; pop cx ; retf N
-- Fully register-transparent: the dispatcher reads fnId from the pushed CX on
-- the stack, and the retf N cleans Pascal-style arguments like a real DLL entry.
function Machine.getImportThunk(self: Machine, name: string, ordinal: number): (number, number)
	const exports = self.winModules[name]
	if not exports or not exports[ordinal] then
		error(("undefined Win16 import: %s#%d"):format(name, ordinal))
	end
	const definition = exports[ordinal]
	const off = self.thunkOff
	const fnId = definition.fnId or 0
	const code = {
		0x51, -- PUSH CX (save caller CX)
		0xB9,
		band(fnId, 0xFF),
		band(rshift(fnId, 8), 0xFF), -- MOV CX, fnId
		0xCD,
		0x80, -- INT 80h (dispatcher reads CX)
		0x59, -- POP CX (restore caller CX)
		0xCA,
		band(definition.args, 0xFF),
		band(rshift(definition.args, 8), 0xFF), -- RETF N
	}
	for index, byte in code do
		self.mem:write8(lshift(self.thunkSeg, 4) + off + index - 1, byte)
	end
	self.thunkOff += 10
	return self.thunkSeg, off
end

-- INT 80h dispatch: CX holds the Win16 function id (set by the thunk);
-- args are Pascal-convention words pushed by the caller, starting at SS:SP+8
-- (thunk pushed CX, far call pushed IP, CS).
function Machine.winInt80(self: Machine)
	const cpu = self.cpu
	const definition = self.winFnIds[cpu.r[2]]
	if not definition then
		error(("undefined Win16 function id %d"):format(cpu.r[2]))
	end
	definition.fn(self, cpu)
end

-- materialize MCB paragraphs from the block list (called after any change).
-- The first block owns low memory (IVT/BDA/DOS data) and has no MCB; every
-- block after it lives at start-1 like a real DOS arena.
function Machine.syncArena(self: Machine)
	const blocks = self.memBlocks
	for index, block in blocks do
		if index > 1 then
			const base = lshift(block.start - 1, 4)
			self.mem:write8(base, index == #blocks and 0x5A or 0x4D)
			self.mem:write16(base + 1, block.owner)
			self.mem:write16(base + 3, block.size)
		end
	end
end

-- allocate a run of paragraphs (first fit); returns base segment or nil.
-- Splits the free block and writes MCBs so guest arena walks stay coherent.
function Machine.dosAlloc(self: Machine, paras: number): number?
	const blocks = self.memBlocks
	if paras == 0 then
		-- DOS treats a zero-paragraph request as a successful empty block
		return self.arenaTop
	end
	for index, block in blocks do
		if block.owner == 0 and block.size >= paras then
			const base = block.start
			if block.size >= paras + 2 then
				-- split; the remainder needs its own MCB paragraph
				const restSize = block.size - paras - 1
				block.size = paras
				block.owner = self.dosOwner
				table.insert(
					blocks,
					index + 1,
					{ start = base + paras + 1, size = restSize, owner = 0 }
				)
			else
				-- too small to split cleanly: hand over the whole block
				block.owner = self.dosOwner
			end
			self:syncArena()
			return base
		end
	end
	return nil
end

-- reserve [start, start+paras) for the current program: extend the PSP block
-- over the free blocks the loaded image now occupies.
function Machine.dosReserve(self: Machine, start: number, paras: number): boolean
	const blocks = self.memBlocks
	local index: number? = nil
	for i, block in blocks do
		if block.start == start then
			index = i
			break
		end
	end
	if not index then
		return false
	end
	const endSeg = start + paras
	local j = index + 1
	while j <= #blocks and blocks[j].start < endSeg do
		const block = blocks[j]
		const blockEnd = block.start + block.size
		if block.owner ~= 0 then
			return false
		end
		if blockEnd > endSeg then
			block.size = blockEnd - (endSeg + 1)
			block.start = endSeg + 1
			break
		end
		table.remove(blocks, j)
	end
	blocks[index].size = paras
	blocks[index].owner = self.dosOwner
	self:syncArena()
	return true
end

-- set the owner word of the MCB block starting at `seg`
function Machine.dosSetOwner(self: Machine, seg: number, owner: number): boolean
	for _, block in self.memBlocks do
		if block.start == seg then
			block.owner = owner
			self:syncArena()
			return true
		end
	end
	return false
end

-- free a block by base segment (merges with adjacent free neighbours)
function Machine.dosFree(self: Machine, seg: number): boolean
	const blocks = self.memBlocks
	for index, block in blocks do
		if block.start == seg then
			block.owner = 0
			const next = blocks[index + 1]
			if next and next.owner == 0 then
				block.size += next.size
				table.remove(blocks, index + 1)
			end
			const previous = blocks[index - 1]
			if previous and previous.owner == 0 then
				previous.size += block.size
				table.remove(blocks, index)
			end
			self:syncArena()
			return true
		end
	end
	return false
end

-- largest free block size in paragraphs
function Machine.dosLargest(self: Machine): number
	local largest = 0
	for _, block in self.memBlocks do
		if block.owner == 0 and block.size > largest then
			largest = block.size
		end
	end
	return largest
end

function Machine.exit(self: Machine, code: number)
	self.exitCode = code
	self.cpu.halted = true
end

function Machine.logChar(self: Machine, ch: number)
	self.output[#self.output + 1] = string.char(ch)
end

function Machine.logString(self: Machine, message: string)
	self.output[#self.output + 1] = message
end

-- host diagnostics: never mixed into guest console output
function Machine.log(self: Machine, message: string)
	self.diagnostics[#self.diagnostics + 1] = message
	const logger = self.deps.logger
	if logger then
		logger(message)
	end
end

function Machine.outputText(self: Machine): string
	return table.concat(self.output)
end

function Machine.screenText(self: Machine): string
	return self.deps.TextScreen.plain(self.mem)
end

function Machine.loadCOM(
	self: Machine,
	bytes: buffer,
	pspSeg: number?,
	programPath: string?,
	envSeg: number?,
	parentEnvSeg: number?,
	stackParas: number?
): number
	return self.deps.Executables.loadCOM(
		self,
		bytes,
		pspSeg,
		programPath,
		envSeg,
		parentEnvSeg,
		stackParas
	)
end

function Machine.loadMZ(
	self: Machine,
	bytes: buffer,
	programPath: string?,
	pspSeg: number?,
	envSeg: number?,
	parentEnvSeg: number?,
	programParas: number?
): number
	return self.deps.Executables.loadMZ(
		self,
		bytes,
		programPath,
		pspSeg,
		envSeg,
		parentEnvSeg,
		programParas
	)
end

function Machine.loadNE(self: Machine, bytes: buffer): any
	return self.deps.Executables.loadNE(self, bytes)
end

function Machine.pushKeys(self: Machine, keys: string)
	for index = 1, #keys do
		self.keys[#self.keys + 1] = string.byte(keys, index) :: number
	end
	self:maybeResume()
end

function Machine.maybeResume(self: Machine)
	if self.waiting == "keyboard" and #self.keys > 0 then
		self.waiting = nil
		self.cpu.halted = false
		const pending = self.pendingInt
		if pending then
			self.pendingInt = nil
			self.cpu.defaultInts[pending](pending)
		end
	end
end

-- 8042-style scan-code queue. The guest's INT 9 handler reads the latched byte
-- from port 0x60; a chained BIOS handler reads the same byte again. Queue a
-- make code on key down and the same code with bit 7 set on key up.
function Machine.queueScanCode(self: Machine, scan: number)
	if not self.keyboardEnabled then
		return
	end
	if #self.keyboardQueue >= 64 then
		table.remove(self.keyboardQueue, 1)
	end
	self.keyboardQueue[#self.keyboardQueue + 1] = band(scan, 0xFF)
	if not self.keyboardPending and not self.keyboardOutputFull and not self.keyboardIrqActive then
		self:latchKeyboard()
	end
end

function Machine.latchKeyboard(self: Machine)
	if self.keyboardOutputFull or #self.keyboardQueue == 0 then
		return
	end
	self.keyboardData = table.remove(self.keyboardQueue, 1)
	self.keyboardOutputFull = true
	self.keyboardPending = true
end

function Machine.keyDown(self: Machine, scan: number)
	self:queueScanCode(scan)
end

function Machine.keyUp(self: Machine, scan: number)
	self:queueScanCode(bor(scan, 0x80))
end

-- Deliver one latched scan code through IRQ1. Windows' real-mode idle loop
-- runs with IF clear for long stretches (the same state that parks timer
-- delivery), so latch the event at an instruction boundary like the PS/2
-- mouse path. The PIC mask still holds the byte while a driver critical
-- section has IRQ1 masked.
function Machine.dispatchKeyboardIrq(self: Machine): boolean
	const cpu = self.cpu
	-- Maskable IRQ: honour the guest's interrupt-enable flag. Delivering while
	-- IF is clear pushes a frame with IF=0, and the guest handler's IRET then
	-- leaves interrupts disabled forever (observed: Tetris/Clock timers stop
	-- after a key press inside a KERNEL critical section).
	if
		not self.keyboardPending
		or self.keyboardIrqActive
		or not self.keyboardEnabled
		or not cpu:getF(512)
		or cpu.irqDelay ~= 0
		or band(self.picInService, 2) ~= 0
		or band(self.picMask, 2) ~= 0
	then
		return false
	end
	const lo = self.mem:read16(9 * 4)
	const hi = self.mem:read16(9 * 4 + 2)
	if lo + hi == 0 then
		return false
	end
	const ss, sp = cpu.ss, cpu.r[5]
	self.keyboardPending = false
	self.keyboardIrqActive = true
	self.keyboardIrqSs, self.keyboardIrqSp = ss, sp
	self.picInService = bor(self.picInService, 2)
	cpu:interrupt(9)
	if cpu.ss == ss and cpu.r[5] == sp then
		-- The vector still points at the BIOS stub, so the handler ran inline
		-- and there is no IRET frame to wait for.
		self.keyboardIrqActive = false
		self.keyboardOutputFull = false
		self:latchKeyboard()
	end
	return true
end

-- 8254 channel 2 latch. The PC speaker is a square wave on channel 2 gated by
-- port 0x61 bits 0 and 1; the guest programs the divisor through 0x43/0x42.
function Machine.writePit2(self: Machine, value: number)
	if self.pit2Access == 1 then
		self.pit2Low = value
		self.pit2Divisor = value
	elseif self.pit2Access == 2 then
		self.pit2Divisor = bor(lshift(value, 8), self.pit2Low)
	elseif self.pit2Access == 3 then
		if self.pit2Latch == 0 then
			self.pit2Low = value
			self.pit2Latch = 1
			return
		end
		self.pit2Divisor = bor(lshift(value, 8), self.pit2Low)
		self.pit2Latch = 0
	else
		return
	end
	const divisor = if self.pit2Divisor == 0 then 0x10000 else self.pit2Divisor
	const previousFrequency = self.speakerFrequency
	const wasEnabled = self.speakerEnabled
	self.speakerFrequency = math.floor(PIT_HZ / divisor + 0.5)
	self:updateSpeaker()
	if wasEnabled and self.speakerEnabled and self.speakerFrequency ~= previousFrequency then
		self.speakerSequence += 1
	end
end

-- PC/AT shutdown handler used by 286 standard-mode DOSX. A triple fault
-- resets the CPU; CMOS shutdown status 09h/0Ah then resumes through the
-- BDA. 09h is the INT 15h/87h block-move return: SS:SP at 0040:0067/0069
-- points at the saved DS/ES/PUSHAW/far-return frame; the handler pops it and
-- RETF 2. 0Ah is SHUTA: jump to the CS:IP at 0040:0067. 09h also disables
-- A20; 0Ah leaves it alone.
function Machine.shutdownResume(self: Machine, cpu: any)
	const status = self.cmos[0x0F] or 0
	cpu:reset()
	if status == 0x09 then
		self.xms.a20 = false
		self.mem.a20 = false
		const savedSp = self.mem:read16(0x467)
		const savedSs = self.mem:read16(0x469)
		if savedSs ~= 0 then
			cpu:loadSeg("ss", savedSs)
			cpu.r[5] = savedSp
			const ds = cpu:pop16()
			const es = cpu:pop16()
			cpu:loadSeg("ds", ds)
			cpu:loadSeg("es", es)
			const ax = cpu:pop16()
			const cx = cpu:pop16()
			const dx = cpu:pop16()
			const bx = cpu:pop16()
			cpu:pop16() -- PUSHAW's saved SP is ignored by POPA
			const bp = cpu:pop16()
			const si = cpu:pop16()
			const di = cpu:pop16()
			cpu.r[1], cpu.r[2], cpu.r[3], cpu.r[4] = ax, cx, dx, bx
			cpu.r[6], cpu.r[7], cpu.r[8] = bp, si, di
			const ip = cpu:pop16()
			const cs = cpu:pop16()
			cpu:pop16() -- RET 2 skips the flags word
			cpu:loadSeg("cs", cs)
			cpu.ip = ip
			cpu:setbits(512, true) -- SHUT9 executes STI before RET 2
		end
	elseif status == 0x0A then
		const ip = self.mem:read16(0x467)
		const cs = self.mem:read16(0x469)
		if cs ~= 0 then
			cpu:loadSeg("cs", cs)
			cpu.ip = ip
		end
	end
	self.cmos[0x0F] = 0
end

function Machine.updateSpeaker(self: Machine)
	const enabled = band(self.port61, 0x03) == 0x03 and self.pit2Divisor ~= 0
	if enabled ~= self.speakerEnabled then
		self.speakerEnabled = enabled
		self.speakerSequence += 1
	end
end

-- Host-facing view of the guest speaker. The Roblox client polls this and
-- plays a short beep on each state change; Lune tests use the same fields.
function Machine.speakerState(
	self: Machine
): { enabled: boolean, frequency: number, sequence: number }
	return {
		enabled = self.speakerEnabled,
		frequency = self.speakerFrequency,
		sequence = self.speakerSequence,
	}
end

function Machine.setMouse(self: Machine, x: number, y: number, buttons: number)
	const nextX = math.clamp(math.floor(x), self.mouseMinX, self.mouseMaxX)
	const nextY = math.clamp(math.floor(y), self.mouseMinY, self.mouseMaxY)
	const nextButtons = band(buttons, 3)
	const dx = nextX - self.mouseX
	const dy = nextY - self.mouseY
	const changed = dx ~= 0 or dy ~= 0 or nextButtons ~= self.mouseButtons
	self.mouseDeltaX += dx * self.mouseMickeyX
	self.mouseDeltaY += dy * self.mouseMickeyY
	self.mouseX = nextX
	self.mouseY = nextY
	self.mouseButtons = nextButtons
	if changed then
		-- MOUSE.DRV's PS/2 path moves the Windows cursor two pixels per
		-- reported count. Feed it half-counts with a remainder so host and
		-- guest stay 1:1 instead of the guest running twice as fast.
		local packetDx, packetDy = 0, 0
		if dx ~= 0 or dy ~= 0 then
			self.mouseCountX += dx
			self.mouseCountY += dy
			packetDx = math.floor(self.mouseCountX / 2)
			packetDy = math.floor(self.mouseCountY / 2)
			self.mouseCountX -= packetDx * 2
			self.mouseCountY -= packetDy * 2
		end
		-- PS/2 DX is positive right (same as the screen), but PS/2 DY is
		-- positive up while host/screen Y is positive down. Flip Y exactly
		-- once here; INT 33 AX=03h/04h keep screen coordinates and AX=0Bh
		-- keeps screen-positive motion counters.
		self:queueMousePacket(packetDx, -packetDy)
	end
end

-- Queue one PS/2 packet for the registered INT 15h C207 device handler. The
-- packet is only relevant while the BIOS interface is enabled; the INT 74h
-- dispatcher drains it between guest instructions.
local function mousePacketStatus(dx: number, dy: number, buttons: number): number
	-- PS/2 status byte: bit 3 is always set, bits 4/5 carry the X/Y sign.
	-- The movement bytes stay two's-complement; MOUSE.DRV reads the sign bits
	-- to reconstruct negative deltas.
	local status = bor(0x08, band(buttons, 0x07))
	if dx < 0 then
		status = bor(status, 0x10)
	end
	if dy < 0 then
		status = bor(status, 0x20)
	end
	return status
end

function Machine.queueMousePacket(self: Machine, dx: number, dy: number, sync: boolean?)
	if not self.mousePs2Enabled or not self.mouseDeviceHandler then
		return
	end
	-- A single PS/2 packet can carry only -128..127 per axis. Split larger
	-- host moves instead of clamping, or the guest cursor lags behind the
	-- physical pointer by the discarded remainder (visible as a positional
	-- offset after fast moves).
	local remainingX, remainingY = dx, dy
	repeat
		const packetDx = math.clamp(remainingX, -127, 127)
		const packetDy = math.clamp(remainingY, -127, 127)
		const buttons = band(self.mouseButtons, 0x07)
		const last = self.mousePackets[#self.mousePackets]
		-- Coalesce movement while the guest has not consumed the previous
		-- packet. A slow drag otherwise queues one packet every two pixels;
		-- the guest processes them slower than the host and the cursor trails
		-- (or the 64-packet cap drops motion entirely).
		if
			last ~= nil
			and not last.sync
			and not sync
			and band(last.status, 0x07) == buttons
			and last.dx + packetDx >= -127
			and last.dx + packetDx <= 127
			and last.dy + packetDy >= -127
			and last.dy + packetDy <= 127
		then
			last.dx += packetDx
			last.dy += packetDy
			last.status = mousePacketStatus(last.dx, last.dy, buttons)
		else
			if #self.mousePackets >= 64 then
				table.remove(self.mousePackets, 1)
			end
			self.mousePackets[#self.mousePackets + 1] = {
				status = mousePacketStatus(packetDx, packetDy, buttons),
				dx = packetDx,
				dy = packetDy,
				sync = sync or nil,
			}
		end
		remainingX -= packetDx
		remainingY -= packetDy
	until remainingX == 0 and remainingY == 0
end

-- Force the guest pointer to a known corner before the first absolute host
-- sample. Host and guest start at different positions after a Windows boot,
-- and relative PS/2 packets alone preserve that offset forever. Sending
-- enough left/up movement clamps the driver at (0,0); the caller then applies
-- the real target delta from a known origin.
function Machine.syncMouse(self: Machine): boolean
	if not self.mousePs2Enabled or not self.mouseDeviceHandler then
		return false
	end
	const buttons = self.mouseButtons
	-- Pending relative motion is stale once we switch to an absolute anchor.
	-- Drop it so a queued click or drag cannot reapply before the clamp.
	self.mousePackets = {}
	self.mouseButtons = 0
	for _ = 1, 8 do
		-- PS/2: negative X = left, positive Y = up.
		self:queueMousePacket(-127, 127, true)
	end
	self.mouseButtons = buttons
	self.mouseX, self.mouseY = 0, 0
	self.mouseDeltaX, self.mouseDeltaY = 0, 0
	self.mouseCountX, self.mouseCountY = 0, 0
	return true
end

-- INT 15h BIOS services. AH=C0h reports the PS/2 system configuration table;
-- AX=C2xx is the pointing-device BIOS interface MOUSE.DRV probes before it
-- installs a PS/2 packet handler.
function Machine.int15(self: Machine)
	const cpu = self.cpu
	const ah = band(rshift(cpu.r[1], 8), 0xFF)
	if ah == 0x88 then
		-- extended memory size above 1 MiB, in KB (0 on a 1 MiB machine)
		cpu:wr(0, math.floor(math.max(0, self.mem.size - 0x100000) / 1024))
		cpu:setbits(1, false)
		return
	end
	if ah == 0xC0 then
		-- Real BIOSes return a far pointer in ES:BX and AH=0. Byte 2 of the
		-- table is the model byte; 0FCh tells MOUSE.DRV this is a PS/2 whose
		-- auxiliary port raises IRQ12 (INT 74h).
		cpu.es = self.mouseConfigSeg
		cpu.r[4] = self.mouseConfigOff
		cpu:wb(4, 0)
		cpu:setbits(1, false)
		return
	end
	if ah ~= 0xC2 then
		cpu:wb(4, 0x86) -- function not supported
		cpu:setbits(1, true)
		return
	end
	const fn = band(cpu.r[1], 0xFF)
	const bh = band(rshift(cpu.r[4], 8), 0xFF)
	if fn == 0x00 then -- enable/disable (BH=1 enable, 0 disable)
		self.mousePs2Enabled = bh ~= 0
		if not self.mousePs2Enabled then
			self.mousePackets = {}
		end
	elseif fn == 0x01 then -- reset
		self.mouseButtons = 0
		self.mouseDeltaX, self.mouseDeltaY = 0, 0
		self.mouseSampleRate = 100
		self.mouseResolution = 3
		self.mouseScaling = 1
	elseif fn == 0x02 then -- set sample rate
		self.mouseSampleRate = bh
	elseif fn == 0x03 then -- set resolution
		self.mouseResolution = bh
	elseif fn == 0x04 then -- get type
		cpu:wb(3, 0) -- BL=0: standard mouse
		cpu:wb(7, 0) -- BH=0
	elseif fn == 0x05 then -- initialize
		self.mousePacketSize = math.max(1, bh)
	elseif fn == 0x06 then -- set scaling
		self.mouseScaling = bh
	elseif fn == 0x07 then -- set device handler (ES:BX)
		self.mouseDeviceHandler = { seg = cpu.es, off = cpu.r[4] }
	elseif fn == 0x08 then -- write byte to auxiliary device
		-- No 8042 model; accepting the command is enough for the driver.
	elseif fn == 0x09 then -- read byte from auxiliary device
		cpu:wb(3, 0) -- no pending byte
	else
		cpu:wb(4, 0x86)
		cpu:setbits(1, true)
		return
	end
	cpu:wb(4, 0)
	cpu:setbits(1, false)
end

-- BIOS INT 74h / IRQ12 entry. The guest's installed INT 74h handler chains
-- here after reading the packet. Hand the packet to the C207 device handler
-- with the calling convention MOUSE.DRV expects:
--   SS:SP+0Ch = status, +0Ah = dx, +08h = dy (after the handler's PUSH BP)
-- so the BIOS pushes status, dx, dy and a flags word before the far call.
-- The cleanup trampoline skips those four words after the handler's RETF and
-- IRETs back to the interrupted guest.
function Machine.int74(self: Machine)
	const handler = self.mouseDeviceHandler
	const packet = table.remove(self.mousePackets, 1)
	if not handler or not packet then
		return
	end
	const cpu = self.cpu
	cpu:push16(packet.status)
	cpu:push16(band(packet.dx, 0xFF))
	cpu:push16(band(packet.dy, 0xFF))
	cpu:push16(cpu.flags)
	cpu:push16(self.mouseCleanupSeg)
	cpu:push16(self.mouseCleanupOff)
	cpu.cs = handler.seg
	cpu.ip = handler.off
end

-- INT 33h Microsoft mouse services. MOUSE.DRV probes AX=24h, resets if the
-- major version is below 6, then polls AX=0Bh/03h for motion and buttons.
function Machine.mouseInt33(self: Machine)
	const cpu = self.cpu
	const fn = band(cpu.r[1], 0xFF)
	if fn == 0x00 then -- reset
		self.mouseVisible = false
		self.mouseButtons = 0
		self.mouseX, self.mouseY = 320, 240
		self.mouseDeltaX, self.mouseDeltaY = 0, 0
		self.mouseCountX, self.mouseCountY = 0, 0
		cpu:wr(0, 0xFFFF)
		cpu.r[4] = 2
	elseif fn == 0x01 then
		self.mouseVisible = true
	elseif fn == 0x02 then
		self.mouseVisible = false
	elseif fn == 0x03 then
		cpu.r[2], cpu.r[3], cpu.r[4] = self.mouseX, self.mouseY, self.mouseButtons
	elseif fn == 0x04 then
		self:setMouse(cpu.r[2], cpu.r[3], self.mouseButtons)
	elseif fn == 0x05 or fn == 0x06 then
		cpu:wr(0, 0)
		cpu.r[4] = 0
		cpu.r[2], cpu.r[3] = self.mouseX, self.mouseY
	elseif fn == 0x07 then
		self.mouseMinX, self.mouseMaxX = cpu.r[2], cpu.r[3]
	elseif fn == 0x08 then
		self.mouseMinY, self.mouseMaxY = cpu.r[2], cpu.r[3]
	elseif fn == 0x0B then
		cpu.r[2] = band(self.mouseDeltaX, 0xFFFF)
		cpu.r[3] = band(self.mouseDeltaY, 0xFFFF)
		self.mouseDeltaX, self.mouseDeltaY = 0, 0
	elseif fn == 0x0C then
		self.mouseHandler = { seg = cpu.es, off = cpu.r[3] }
	elseif fn == 0x0F then
		self.mouseMickeyX = math.max(1, cpu.r[2])
		self.mouseMickeyY = math.max(1, cpu.r[3])
	elseif fn == 0x14 then
		const old = self.mouseHandler
		if cpu.es ~= 0 or cpu.r[3] ~= 0 then
			self.mouseHandler = { seg = cpu.es, off = cpu.r[3] }
		end
		cpu.r[2] = old and old.off or 0
		cpu.r[3] = old and old.seg or 0
	elseif fn == 0x24 then
		cpu:wr(0, 0x0800) -- BH=8 (version 8.0), BL=0
		cpu.r[4] = 0
		cpu.r[2] = 0x0400 -- CH=4 (PS/2), CL=0
		cpu.r[3] = 0
	elseif fn == 0x26 then
		cpu.r[2], cpu.r[3] = self.mouseMaxX, self.mouseMaxY
	elseif fn == 0x2A then
		cpu.r[2], cpu.r[3] = 0, 0 -- cursor hot spot
	elseif fn == 0x31 then
		cpu.r[2], cpu.r[3] = self.mouseMickeyX, self.mouseMickeyY
	end
	cpu:setbits(1, false)
end

-- Raise IRQ12 if a packet is queued and the guest's INT 74h vector has been
-- hooked. Returns true when the CPU was redirected into the handler.
-- Windows 3.0's real-mode idle path runs with IF clear for long stretches in
-- this machine (the same state also parks normal timer delivery), so mouse
-- packets are injected at instruction boundaries like a latched PS/2 event.
-- The C207 handler preserves all registers/flags and the cleanup trampoline
-- returns through the interrupted guest's own IRET frame.
function Machine.dispatchMouseIrq(self: Machine): boolean
	const cpu = self.cpu
	-- Maskable IRQ: see dispatchKeyboardIrq. A frame captured with IF=0 makes
	-- the guest handler's IRET leave the whole machine with interrupts off.
	if
		#self.mousePackets == 0
		or self.mouseIrqActive
		or not cpu:getF(512)
		or cpu.irqDelay ~= 0
		or cpu.cs == self.mouseIrqStubSeg
	then
		return false
	end
	const ivtOff = self.mem:read16(0x74 * 4)
	const ivtSeg = self.mem:read16(0x74 * 4 + 2)
	if ivtOff == self.mouseIrqStubOff and ivtSeg == self.mouseIrqStubSeg then
		return false
	end
	self.mouseIrqActive = true
	self.mouseIrqAge = 0
	-- The outer INT 74h handler finishes when it IRETs through the frame that
	-- cpu:interrupt pushes below, restoring the interrupted SS:SP. Keep the
	-- guard set until then: clearing it when the C207 soft handler returns is
	-- too early and lets the next packet overwrite [0x90]/[0x8F] before the
	-- driver decodes the previous one.
	self.mouseIrqSs = cpu.ss
	self.mouseIrqSp = cpu.r[5]
	cpu:interrupt(0x74)
	return true
end

-- advance the PIT tick and deliver IRQ0 when the guest has hooked INT 8 and
-- interrupts are enabled. The BDA tick runs even before the handler exists.
-- Skip delivery while the vector still points at the BIOS chaining stub: the
-- tick is already accounted for here, and the stub exists only so a guest ISR
-- can chain to the previous handler.
function Machine.advanceTimer(self: Machine)
	local ticks = self.mem:read16(0x46C) + 1
	if ticks >= 0x1800B0 then
		ticks = 0
	end
	self.mem:write16(0x46C, ticks)
	const ivtOff = self.mem:read16(8 * 4)
	const ivtSeg = self.mem:read16(8 * 4 + 2)
	const ownStub = ivtOff == self.timerStubOff and ivtSeg == self.timerStubSeg
	if
		ivtOff + ivtSeg ~= 0
		and not ownStub
		and band(self.picInService, 1) == 0
		and band(self.picMask, 1) == 0
		and self.cpu:getF(512)
		and self.cpu.irqDelay == 0
	then
		self.picInService = bor(self.picInService, 1)
		self.cpu:interrupt(8)
	end
end

-- run up to maxSteps instructions; returns steps executed.
-- stops on HLT/exit; pushKeys + run again to resume keyboard waits.
function Machine.run(self: Machine, maxSteps: number?): number
	const cpu = self.cpu
	if
		self.mouseIrqActive
		and (
			(cpu.ss == self.mouseIrqSs and cpu.r[5] == self.mouseIrqSp)
			or self.mouseIrqAge > 30_000
		)
	then
		-- A dialog or menu can unwind the guest stack without returning through
		-- the frame we saved. Without a watchdog the guard sticks forever and
		-- every later mouse packet is queued but never delivered.
		self.mouseIrqActive = false
		self.mouseIrqAge = 0
	end
	if
		self.keyboardIrqActive
		and cpu.ss == self.keyboardIrqSs
		and cpu.r[5] == self.keyboardIrqSp
	then
		self.keyboardIrqActive = false
		self.keyboardOutputFull = false
		self:latchKeyboard()
	end
	-- A HLT with interrupts enabled is woken by the next PIT tick. This keeps
	-- idle Windows loops alive instead of freezing the machine forever.
	if cpu.halted and not self.waiting and not self.exitCode then
		const ivt8 = self.mem:read16(8 * 4) + self.mem:read16(8 * 4 + 2)
		if ivt8 ~= 0 and cpu:getF(512) then
			cpu.halted = false
			-- Windows idles in HLT between timer ticks; deliver queued input
			-- before the tick so the handler chain runs on the same wake.
			self:dispatchKeyboardIrq()
			self:dispatchMouseIrq()
			self:advanceTimer()
		elseif #self.mousePackets > 0 or self.keyboardPending then
			cpu.halted = false
			self:dispatchKeyboardIrq()
			self:dispatchMouseIrq()
		end
	end
	local steps = 0
	const budget = maxSteps or math.huge
	while steps < budget and not cpu.halted do
		if self.mouseIrqActive then
			if
				(cpu.ss == self.mouseIrqSs and cpu.r[5] == self.mouseIrqSp)
				or self.mouseIrqAge > 30_000
			then
				self.mouseIrqActive = false
				self.mouseIrqAge = 0
			else
				self.mouseIrqAge += 1
			end
		end
		if
			self.keyboardIrqActive
			and cpu.ss == self.keyboardIrqSs
			and cpu.r[5] == self.keyboardIrqSp
		then
			self.keyboardIrqActive = false
			self.keyboardOutputFull = false
			self:latchKeyboard()
		end
		cpu:step()
		steps += 1
		self:dispatchKeyboardIrq()
		self:dispatchMouseIrq()
		self.timerPhase += 1
		if self.timerPhase >= self.timerInterval and cpu.cs ~= 0xF100 then
			-- interrupt shadow: never fire inside our IVT stubs
			self.timerPhase = 0
			self:advanceTimer()
		end
	end
	return steps
end

return Machine
