--!strict
-- Bios.lua -- INT 10h teletype into the 0xB8000 text screen, INT 16h keyboard.

const band, bnot, bor, lshift, rshift =
	bit32.band, bit32.bnot, bit32.bor, bit32.lshift, bit32.rshift

const ZF = 64

const Bios = {}
Bios.__index = Bios

Bios.BASE = 0xB8000
Bios.COLS = 80
Bios.ROWS = 25

type CpuLike = {
	r: { number },
	es: number,
	halted: boolean,
	setbits: (self: any, mask: number, on: boolean) -> (),
	wr: (self: any, index: number, value: number) -> (),
	wb: (self: any, index: number, value: number) -> (),
	io: { in8: (port: number) -> number },
}

type ScreenMemory = {
	read8: (self: any, addr: number) -> number,
	write8: (self: any, addr: number, value: number) -> (),
	write16: (self: any, addr: number, value: number) -> (),
	copyTo: (self: any, addr: number, length: number) -> buffer,
	copyFrom: (self: any, addr: number, src: buffer) -> (),
}

export type Host = {
	mem: ScreenMemory,
	cpu: CpuLike,
	vga: any?,
	keys: { number },
	waiting: string?,
	pendingInt: number?,
	picInService: number,
	logChar: (self: any, ch: number) -> (),
	log: (self: any, message: string) -> (),
}

export type Bios = {
	machine: Host,
	cursorX: number,
	cursorY: number,
	attr: number,
	isText: (self: Bios) -> boolean,
	putChar: (self: Bios, ch: number, attr: number?) -> (),
	scroll: (self: Bios) -> (),
	advance: (self: Bios) -> (),
	teletype: (self: Bios, ch: number, attr: number?) -> (),
	write: (self: Bios, str: string) -> (),
	updateBDA: (self: Bios) -> (),
	int9: (self: Bios) -> (),
	int10: (self: Bios) -> (),
	int16: (self: Bios) -> (),
}

function Bios.new(machine: Host): Bios
	return setmetatable({
		machine = machine,
		cursorX = 0,
		cursorY = 0,
		attr = 0x07,
	}, Bios) :: any
end

function Bios.isText(self: Bios): boolean
	const vga = self.machine.vga
	return not vga or vga:modeInfo().kind == "text"
end

function Bios.putChar(self: Bios, ch: number, attr: number?)
	if not self:isText() then
		return
	end
	const cell = Bios.BASE + (self.cursorY * Bios.COLS + self.cursorX) * 2
	self.machine.mem:write8(cell, ch)
	self.machine.mem:write8(cell + 1, attr or self.attr)
end

function Bios.scroll(self: Bios)
	if not self:isText() then
		return
	end
	const mem = self.machine.mem
	const rowBytes = Bios.COLS * 2
	const src = mem:copyTo(Bios.BASE + rowBytes, rowBytes * (Bios.ROWS - 1))
	mem:copyFrom(Bios.BASE, src)
	const last = Bios.BASE + (Bios.ROWS - 1) * rowBytes
	for index = 0, Bios.COLS - 1 do
		mem:write8(last + index * 2, 0x20)
		mem:write8(last + index * 2 + 1, self.attr)
	end
	self.cursorY = Bios.ROWS - 1
end

function Bios.advance(self: Bios)
	self.cursorX += 1
	if self.cursorX >= Bios.COLS then
		self.cursorX = 0
		self.cursorY += 1
		if self.cursorY >= Bios.ROWS then
			self:scroll()
		end
	end
end

-- one character with control-char handling; also appends to the machine log
function Bios.teletype(self: Bios, ch: number, attr: number?)
	if ch == 0x0D then
		self.cursorX = 0
	elseif ch == 0x0A then
		self.cursorY += 1
		if self.cursorY >= Bios.ROWS then
			self:scroll()
		end
	elseif ch == 0x08 then
		if self.cursorX > 0 then
			self.cursorX -= 1
		end
	elseif ch == 0x09 then
		self.cursorX = math.min((math.floor(self.cursorX / 8) + 1) * 8, Bios.COLS - 1)
	else
		self:putChar(ch, attr)
		self:advance()
	end
	self.machine:logChar(ch)
end

-- display a string via teletype (logging happens per character)
function Bios.write(self: Bios, str: string)
	for index = 1, #str do
		self:teletype(string.byte(str, index) :: number)
	end
end

function Bios.updateBDA(self: Bios)
	const mem = self.machine.mem
	mem:write8(0x450, self.cursorX)
	mem:write8(0x451, self.cursorY)
	const vga = self.machine.vga
	if vga then
		const info = vga:modeInfo()
		const columns = info.kind == "text" and 80 or math.floor(info.width / 8)
		const charHeight = info.kind == "text" and 16 or (info.height >= 400 and 16 or 8)
		const rows = info.kind == "text" and 25 or math.max(math.floor(info.height / charHeight), 1)
		mem:write8(0x449, info.mode)
		mem:write16(0x44A, columns)
		mem:write8(0x484, rows - 1)
		mem:write8(0x485, charHeight)
	end
end

function Bios.int10(self: Bios)
	const machine = self.machine
	const cpu = machine.cpu
	const vga = machine.vga
	const ah = band(rshift(cpu.r[1], 8), 0xFF)
	if ah == 0x00 then -- set video mode
		if vga then
			vga:setMode(band(cpu.r[1], 0xFF))
			self.machine:log(("INT10 mode=%d w=%d h=%d"):format(band(cpu.r[1], 0xFF), vga:width(), vga:height()))
			self.machine:log(('INT10 mode=%d w=%d h=%d'):format(
				band(cpu.r[1], 0xFF), vga:width(), vga:height()))
		end
		self.cursorX, self.cursorY = 0, 0
	elseif ah == 0x0F then -- get video mode
		if vga then
			const info = vga:modeInfo()
			cpu:wb(0, info.mode)
			cpu:wb(4, info.kind == "text" and 80 or math.floor(info.width / 8))
			cpu:wb(7, 0)
		else
			cpu:wb(0, 0x03)
			cpu:wb(4, 80)
			cpu:wb(7, 0)
		end
	elseif ah == 0x02 then
		self.cursorY = band(rshift(cpu.r[3], 8), 0xFF)
		self.cursorX = band(cpu.r[3], 0xFF)
	elseif ah == 0x03 then
		cpu.r[3] = bor(lshift(self.cursorY, 8), self.cursorX)
		cpu.r[2] = 0x0607
	elseif ah == 0x06 then -- scroll up AL lines (AL=0 clears)
		const count = band(cpu.r[1], 0xFF)
		if count == 0 then
			for _ = 1, Bios.ROWS do
				self:scroll()
			end
		else
			for _ = 1, count do
				self:scroll()
			end
		end
		self.cursorX, self.cursorY = 0, 0
	elseif ah == 0x0E then
		self:teletype(band(cpu.r[3], 0xFF), band(cpu.r[4], 0xFF))
	elseif ah == 0x13 then -- write string at ES:BP, length CX
		const mem = machine.mem
		const base = lshift(cpu.es, 4) + cpu.r[6]
		const count = cpu.r[2]
		const mode = band(cpu.r[1], 0xFF)
		const stride = mode >= 2 and 2 or 1
		for index = 0, count - 1 do
			const ch = mem:read8(base + index * stride)
			const attr = (mode == 1 or mode == 3) and mem:read8(base + index * stride + 1)
				or band(cpu.r[4], 0xFF)
			self:teletype(ch, attr)
		end
	elseif ah == 0x1A then -- get display combination
		cpu:wb(0, 0x1A)
		cpu:wb(6, 0x08) -- VGA with colour display
		cpu:wb(7, 0)
	elseif ah == 0x1B then -- get functionality/state
		cpu:wb(0, 0x1B)
		cpu:wb(6, 0x08)
		cpu:wb(7, 0)
	elseif ah == 0x10 or ah == 0x12 then
		-- palette / alternate select: VGA.DRV programs the DAC directly
	else
		machine:log(("unhandled INT 10h AH=%02X"):format(ah))
	end
	self:updateBDA()
end

-- BIOS INT 9h entry. The guest driver has already read the scan code from
-- port 0x60; reading it again returns the same latched byte. The BIOS only
-- has to acknowledge IRQ1. Windows' KEYBOARD.DRV handles translation itself
-- and chains here for the keys it wants the BIOS to process.
function Bios.int9(self: Bios)
	const machine = self.machine
	machine.cpu.io.in8(0x60)
	if band(machine.picInService, 2) ~= 0 then
		machine.picInService = band(machine.picInService, bnot(2))
	end
end

function Bios.int16(self: Bios)
	const machine = self.machine
	const cpu = machine.cpu
	const ah = band(rshift(cpu.r[1], 8), 0xFF)
	if ah == 0x00 or ah == 0x10 then
		if #machine.keys == 0 then
			cpu.halted = true
			machine.waiting = "keyboard"
			machine.pendingInt = 0x16
			return
		end
		cpu:wr(0, table.remove(machine.keys, 1) :: number) -- AL = ascii, AH = scan (0)
	elseif ah == 0x01 or ah == 0x11 then
		if #machine.keys == 0 then
			cpu:setbits(ZF, true)
		else
			cpu:setbits(ZF, false)
			cpu:wr(0, machine.keys[1])
		end
	elseif ah == 0x02 then
		cpu:wb(0, 0)
	else
		machine:log(("unhandled INT 16h AH=%02X"):format(ah))
	end
end

return Bios
