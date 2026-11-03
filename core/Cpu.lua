--!strict
-- Cpu.lua -- complete 8086 real-mode core (bit32 only, no native bitwise ops).
-- r[1..8] = AX CX DX BX SP BP SI DI; SP is r[5]; 8-bit reg i<4 low / i>=4 high.

const band, bor, bxor, bnot, lshift, rshift =
	bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.lshift, bit32.rshift

const CF, PF, AF, ZF, SF, TF, IFF, DFF, OFLG = 1, 4, 16, 64, 128, 256, 512, 1024, 2048
const ALWAYS = 2
const FLAGMASK = 4053 -- CF|PF|AF|ZF|SF|TF|IF|DF|OF (0xFD5)
const FIXEDFLAGS = bor(0xF000, ALWAYS) -- bits 15-12 plus bit 1 read as 1 on 8086

export type ModRM = {
	mod: number,
	reg: number,
	rm: number,
	off: number?,
	addr: number?,
}

export type Io = {
	in8: (port: number) -> number,
	out8: (port: number, value: number) -> (),
}

export type InterruptHandler = (n: number) -> ()

export type Cpu = {
	mem: any,
	io: Io,
	config: any,
	r: { number },
	es: number,
	cs: number,
	ss: number,
	ds: number,
	ip: number,
	flags: number,
	halted: boolean,
	-- 8086 STI/POPF/IRET interrupt shadow: no hardware IRQ is recognized until
	-- the instruction after the flag change has executed.
	irqDelay: number,
	oseg: number?,
	rep: number?,
	defaultInts: { [number]: InterruptHandler },
	stubSeg: number?,
	intStubs: { [number]: { seg: number, off: number } },
	registerStub: (self: Cpu, n: number, seg: number, off: number) -> (),
	rb: (self: Cpu, i: number) -> number,
	wb: (self: Cpu, i: number, v: number) -> (),
	rr: (self: Cpu, i: number) -> number,
	wr: (self: Cpu, i: number, v: number) -> (),
	fetch8: (self: Cpu) -> number,
	fetch16: (self: Cpu) -> number,
	push16: (self: Cpu, v: number) -> (),
	pop16: (self: Cpu) -> number,
	setbits: (self: Cpu, mask: number, on: boolean) -> (),
	getF: (self: Cpu, mask: number) -> boolean,
	setSZP: (self: Cpu, res: number, w: boolean) -> (),
	modrm: (self: Cpu) -> ModRM,
	readRM8: (self: Cpu, e: ModRM) -> number,
	writeRM8: (self: Cpu, e: ModRM, v: number) -> (),
	readRM16: (self: Cpu, e: ModRM) -> number,
	writeRM16: (self: Cpu, e: ModRM, v: number) -> (),
	interrupt: (self: Cpu, n: number) -> (),
	step: (self: Cpu) -> number,
	dump: (self: Cpu) -> { [string]: number },
}

const PARITY: { [number]: number } = {}
for i = 0, 255 do
	local v, bits = i, 0
	while v > 0 do
		bits += band(v, 1)
		v = rshift(v, 1)
	end
	PARITY[i] = (bits % 2 == 0) and PF or 0
end

local function sign8(v: number): number
	if v >= 0x80 then
		return v - 0x100
	end
	return v
end

local function sign16(v: number): number
	if v >= 0x8000 then
		return v - 0x10000
	end
	return v
end

local function sign32(v: number): number
	if v >= 0x80000000 then
		return v - 0x100000000
	end
	return v
end

-- integer division truncated toward zero (IDIV semantics)
local function truncDiv(n: number, d: number): number
	return (math.modf(n / d))
end

local Cpu = {}
Cpu.__index = Cpu

function Cpu.new(mem: any, io: Io?, config: any?): Cpu
	local self = setmetatable({}, Cpu) :: any
	self.mem = mem
	self.io = io or {
		in8 = function()
			return 0
		end,
		out8 = function() end,
	}
	self.config = config or {}
	self.r = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.es, self.cs, self.ss, self.ds = 0, 0, 0, 0
	self.ip = 0
	self.flags = bor(FIXEDFLAGS, IFF)
	self.halted = false
	self.irqDelay = 0
	self.oseg = nil
	self.rep = nil
	self.defaultInts = {}
	self.stubSeg = nil
	self.intStubs = {}
	return self
end

-- Record that interrupt `n`'s IVT entry currently points at the machine's
-- own stub at `seg:off`. Cpu.interrupt uses this to recognise an un-hooked
-- vector and dispatch the emulated handler directly (see below).
function Cpu.registerStub(self: Cpu, n: number, seg: number, off: number)
	self.stubSeg = seg
	self.intStubs[n] = { seg = seg, off = off }
end

function Cpu.rb(self: Cpu, i: number): number
	if i < 4 then
		return band(self.r[i + 1], 0xFF)
	end
	return band(rshift(self.r[i - 3], 8), 0xFF)
end

function Cpu.wb(self: Cpu, i: number, v: number)
	v = band(v, 0xFF)
	if i < 4 then
		self.r[i + 1] = bor(band(self.r[i + 1], 0xFF00), v)
	else
		self.r[i - 3] = bor(band(self.r[i - 3], 0x00FF), lshift(v, 8))
	end
end

function Cpu.rr(self: Cpu, i: number): number
	return self.r[i + 1]
end

function Cpu.wr(self: Cpu, i: number, v: number)
	self.r[i + 1] = band(v, 0xFFFF)
end

function Cpu.fetch8(self: Cpu): number
	local b = self.mem:read8(lshift(self.cs, 4) + self.ip)
	self.ip = band(self.ip + 1, 0xFFFF)
	return b
end

function Cpu.fetch16(self: Cpu): number
	local lo = self:fetch8()
	return bor(lo, lshift(self:fetch8(), 8))
end

function Cpu.push16(self: Cpu, v: number)
	self.r[5] = band(self.r[5] - 2, 0xFFFF) -- r[5] is SP
	self.mem:write16(lshift(self.ss, 4) + self.r[5], v)
end

function Cpu.pop16(self: Cpu): number
	local v = self.mem:read16(lshift(self.ss, 4) + self.r[5])
	self.r[5] = band(self.r[5] + 2, 0xFFFF)
	return v
end

function Cpu.setbits(self: Cpu, mask: number, on: boolean)
	if on then
		self.flags = bor(self.flags, mask)
	else
		self.flags = band(self.flags, bnot(mask))
	end
end

function Cpu.getF(self: Cpu, mask: number): boolean
	return band(self.flags, mask) ~= 0
end

function Cpu.setSZP(self: Cpu, res: number, w: boolean)
	local f = band(self.flags, bnot(ZF + SF + PF))
	if res == 0 then
		f = bor(f, ZF)
	end
	if w then
		if res >= 0x8000 then
			f = bor(f, SF)
		end
	else
		if res >= 0x80 then
			f = bor(f, SF)
		end
	end
	self.flags = bor(f, PARITY[band(res, 0xFF)])
end

function Cpu.modrm(self: Cpu): ModRM
	local m = self:fetch8()
	local mod = rshift(m, 6)
	local reg = band(rshift(m, 3), 7)
	local rm = band(m, 7)
	if mod == 3 then
		return { mod = 3, reg = reg, rm = rm, off = nil, addr = nil }
	end
	local off, seg
	if mod == 0 and rm == 6 then
		off, seg = self:fetch16(), self.ds
	else
		local r = self.r
		if rm == 0 then
			off, seg = r[4] + r[7], self.ds
		elseif rm == 1 then
			off, seg = r[4] + r[8], self.ds
		elseif rm == 2 then
			off, seg = r[6] + r[7], self.ss
		elseif rm == 3 then
			off, seg = r[6] + r[8], self.ss
		elseif rm == 4 then
			off, seg = r[7], self.ds
		elseif rm == 5 then
			off, seg = r[8], self.ds
		elseif rm == 6 then
			off, seg = r[6], self.ss
		else
			off, seg = r[4], self.ds
		end
		if mod == 1 then
			local d = self:fetch8()
			if d >= 0x80 then
				d -= 0x100
			end
			off += d
		elseif mod == 2 then
			off += self:fetch16()
		end
		off = band(off, 0xFFFF)
	end
	if self.oseg then
		seg = self.oseg
	end
	return { mod = mod, reg = reg, rm = rm, off = off, addr = lshift(seg, 4) + off }
end

function Cpu.readRM8(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rb(e.rm)
	end
	return self.mem:read8(e.addr)
end

function Cpu.writeRM8(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wb(e.rm, v)
	else
		self.mem:write8(e.addr, v)
	end
end

function Cpu.readRM16(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rr(e.rm)
	end
	return self.mem:read16(e.addr)
end

function Cpu.writeRM16(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wr(e.rm, v)
	else
		self.mem:write16(e.addr, v)
	end
end

-- op: 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP
local function doALU(cpu: any, op: number, a: number, b: number, w: boolean): number
	local maxv = w and 0xFFFF or 0xFF
	local signv = w and 0x8000 or 0x80
	local res, cf, of
	if op == 0 or op == 2 then
		local c = 0
		if op == 2 and cpu:getF(CF) then
			c = 1
		end
		res = a + b + c
		cf = res > maxv
		of = band(band(bnot(bxor(a, b)), bxor(a, res)), signv) ~= 0
	elseif op == 3 or op == 5 or op == 7 then
		local c = 0
		if op == 3 and cpu:getF(CF) then
			c = 1
		end
		res = a - b - c
		cf = res < 0
		of = band(band(bxor(a, b), bxor(a, res)), signv) ~= 0
	else
		if op == 1 then
			res = bor(a, b)
		elseif op == 4 then
			res = band(a, b)
		else
			res = bxor(a, b)
		end
		cf, of = false, false
	end
	res = band(res, maxv)
	cpu:setbits(CF, cf)
	cpu:setbits(OFLG, of)
	cpu:setbits(AF, band(bxor(bxor(a, b), res), 16) ~= 0)
	cpu:setSZP(res, w)
	return res
end

-- op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SHL alias, 7 SAR
-- 8086 semantics for the count (not masked; CF/OF as documented). On the
-- 80186+ the shift group also updates SZP for SHL/SHR/SAR (rotates leave SZP
-- alone); Windows 3.0 real-mode code branches on those flags right after a
-- shift, so they cannot be left stale.
local function doShift(cpu: any, op: number, v: number, cnt: number, w: boolean): number
	local bits = w and 16 or 8
	local maxv = w and 0xFFFF or 0xFF
	local msb = w and 0x8000 or 0x80
	if cnt == 0 then
		return v
	end
	local cf = cpu:getF(CF)
	local res, of = v, false

	if op == 4 or op == 6 then
		res = v
		for _ = 1, cnt do
			cf = band(res, msb) ~= 0
			res = band(lshift(res, 1), maxv)
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 5 then
		res = v
		of = cnt == 1 and (band(v, msb) ~= 0) or false
		for _ = 1, cnt do
			cf = band(res, 1) ~= 0
			res = rshift(res, 1)
		end
	elseif op == 7 then
		local sv = w and sign16(v) or sign8(v)
		if cnt >= bits then
			res = sv < 0 and maxv or 0
			cf = sv < 0
		else
			res = band(math.floor(sv / lshift(1, cnt)), maxv)
			cf = band(rshift(sv, cnt - 1), 1) == 1
		end
		of = false
	elseif op == 0 then
		local c = cnt % bits
		if c == 0 then
			res = v
			cf = band(v, 1) == 1
		else
			res = band(bor(lshift(v, c), rshift(v, bits - c)), maxv)
			cf = band(res, 1) == 1
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 1 then
		local c = cnt % bits
		if c == 0 then
			res = v
			cf = band(v, msb) ~= 0
		else
			res = band(bor(rshift(v, c), lshift(v, bits - c)), maxv)
			cf = band(res, msb) ~= 0
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	elseif op == 2 then
		local width = bits + 1
		local c = cnt % width
		if c == 0 then
			res = v
		else
			local combined = bor(lshift(v, 1), cf and 1 or 0)
			local mask = lshift(1, width) - 1
			local rot = band(bor(lshift(combined, c), rshift(combined, width - c)), mask)
			res = band(rshift(rot, 1), maxv)
			cf = band(rot, 1) == 1
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	else
		local width = bits + 1
		local c = cnt % width
		local combined = bor(v, cf and lshift(1, bits) or 0)
		if c == 0 then
			res = v
		else
			local mask = lshift(1, width) - 1
			local rot = band(bor(rshift(combined, c), lshift(combined, width - c)), mask)
			res = band(rot, maxv)
			cf = band(rshift(rot, bits), 1) == 1
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	end

	cpu:setbits(CF, cf)
	cpu:setbits(OFLG, of)
	if op == 4 or op == 5 or op == 6 or op == 7 then
		cpu:setSZP(res, w)
	end
	return res
end

const H: { [number]: any } = {}

-- ALU families: opcode = aluOp*8 + form
-- form: 0 rm8,r8 | 1 rm16,r16 | 2 r8,rm8 | 3 r16,rm16 | 4 AL,imm8 | 5 AX,imm16
for aluOp = 0, 7 do
	local base = aluOp * 8
	H[base + 0] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:readRM8(e), cpu:rb(e.reg), false)
		if aluOp ~= 7 then
			cpu:writeRM8(e, res)
		end
	end
	H[base + 1] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:readRM16(e), cpu:rr(e.reg), true)
		if aluOp ~= 7 then
			cpu:writeRM16(e, res)
		end
	end
	H[base + 2] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:rb(e.reg), cpu:readRM8(e), false)
		if aluOp ~= 7 then
			cpu:wb(e.reg, res)
		end -- CMP r8,r/m8 (0x38) must not write
	end
	H[base + 3] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:rr(e.reg), cpu:readRM16(e), true)
		if aluOp ~= 7 then
			cpu:wr(e.reg, res)
		end -- CMP r16,r/m16 (0x39) must not write
	end
	H[base + 4] = function(cpu: any)
		local res = doALU(cpu, aluOp, cpu:rb(0), cpu:fetch8(), false)
		if aluOp ~= 7 then
			cpu:wb(0, res)
		end -- CMP AL,imm8 (0x3C) must not write
	end
	H[base + 5] = function(cpu: any)
		local res = doALU(cpu, aluOp, cpu:rr(0), cpu:fetch16(), true)
		if aluOp ~= 7 then
			cpu:wr(0, res)
		end -- CMP AX,imm16 (0x3D) must not write
	end
end

-- segment push/pop
H[0x06] = function(cpu: any)
	cpu:push16(cpu.es)
end
H[0x07] = function(cpu: any)
	cpu.es = cpu:pop16()
end
H[0x0E] = function(cpu: any)
	cpu:push16(cpu.cs)
end
H[0x0F] = function(cpu: any)
	if cpu.config.popCS == false then
		error("opcode 0F (POP CS) disabled; reserved for 386 two-byte escape")
	end
	cpu.cs = cpu:pop16()
end
H[0x16] = function(cpu: any)
	cpu:push16(cpu.ss)
end
H[0x17] = function(cpu: any)
	cpu.ss = cpu:pop16()
end
H[0x1E] = function(cpu: any)
	cpu:push16(cpu.ds)
end
H[0x1F] = function(cpu: any)
	cpu.ds = cpu:pop16()
end

-- BCD adjust
H[0x27] = function(cpu: any) -- DAA
	local al = cpu:rb(0)
	local oldal, oldcf = al, cpu:getF(CF)
	local cf = false
	if band(al, 0x0F) > 9 or cpu:getF(AF) then
		cf = (al + 6 > 0xFF) or oldcf
		al = band(al + 6, 0xFF)
		cpu:setbits(AF, true)
	else
		cpu:setbits(AF, false)
	end
	if oldal > 0x99 or oldcf then
		al = band(al + 0x60, 0xFF)
		cf = true
	end
	cpu:wb(0, al)
	cpu:setbits(CF, cf)
	cpu:setSZP(al, false)
end
H[0x2F] = function(cpu: any) -- DAS
	local al = cpu:rb(0)
	local oldal, oldcf = al, cpu:getF(CF)
	local cf = false
	if band(al, 0x0F) > 9 or cpu:getF(AF) then
		cf = (al < 6) or oldcf
		al = band(al - 6, 0xFF)
		cpu:setbits(AF, true)
	else
		cpu:setbits(AF, false)
	end
	if oldal > 0x99 or oldcf then
		al = band(al - 0x60, 0xFF)
		cf = true
	end
	cpu:wb(0, al)
	cpu:setbits(CF, cf)
	cpu:setSZP(al, false)
end
H[0x37] = function(cpu: any) -- AAA
	if band(cpu:rb(0), 0x0F) > 9 or cpu:getF(AF) then
		cpu.r[1] = band(cpu.r[1] + 0x106, 0xFFFF)
		cpu:setbits(AF, true)
		cpu:setbits(CF, true)
	else
		cpu:setbits(AF, false)
		cpu:setbits(CF, false)
	end
	cpu:wb(0, band(cpu:rb(0), 0x0F))
end
H[0x3F] = function(cpu: any) -- AAS
	if band(cpu:rb(0), 0x0F) > 9 or cpu:getF(AF) then
		cpu.r[1] = band(cpu.r[1] - 6, 0xFFFF)
		cpu:wb(4, cpu:rb(4) - 1)
		cpu:setbits(AF, true)
		cpu:setbits(CF, true)
	else
		cpu:setbits(AF, false)
		cpu:setbits(CF, false)
	end
	cpu:wb(0, band(cpu:rb(0), 0x0F))
end

-- INC/DEC/PUSH/POP r16 (reg index i)
for i = 0, 7 do
	H[0x40 + i] = function(cpu: any)
		local cf = cpu:getF(CF)
		cpu:wr(i, doALU(cpu, 0, cpu:rr(i), 1, true))
		cpu:setbits(CF, cf)
	end
	H[0x48 + i] = function(cpu: any)
		local cf = cpu:getF(CF)
		cpu:wr(i, doALU(cpu, 5, cpu:rr(i), 1, true))
		cpu:setbits(CF, cf)
	end
	H[0x50 + i] = function(cpu: any)
		if i == 4 then
			-- 8086 quirk: PUSH SP pushes the DECREMENTED value
			cpu:push16(band(cpu.r[5] - 2, 0xFFFF))
		else
			cpu:push16(cpu:rr(i))
		end
	end
	H[0x58 + i] = function(cpu: any)
		cpu:wr(i, cpu:pop16())
	end
end

-- Jcc (70-7F rel8); 60-6F alias them on 8086
-- Signed conditions compare SF and OF as booleans, not as their mask values:
-- SF=0x80 and OF=0x800 are unequal even though both flags are set.
local function signDiff(f: number): boolean
	return (band(f, SF) ~= 0) ~= (band(f, OFLG) ~= 0)
end
const COND: { (flags: number) -> boolean } = {
	function(f)
		return band(f, OFLG) ~= 0
	end,
	function(f)
		return band(f, OFLG) == 0
	end,
	function(f)
		return band(f, CF) ~= 0
	end,
	function(f)
		return band(f, CF) == 0
	end,
	function(f)
		return band(f, ZF) ~= 0
	end,
	function(f)
		return band(f, ZF) == 0
	end,
	function(f)
		return band(f, bor(CF, ZF)) ~= 0
	end,
	function(f)
		return band(f, bor(CF, ZF)) == 0
	end,
	function(f)
		return band(f, SF) ~= 0
	end,
	function(f)
		return band(f, SF) == 0
	end,
	function(f)
		return band(f, PF) ~= 0
	end,
	function(f)
		return band(f, PF) == 0
	end,
	function(f)
		return signDiff(f)
	end,
	function(f)
		return not signDiff(f)
	end,
	function(f)
		return band(f, ZF) ~= 0 or signDiff(f)
	end,
	function(f)
		return band(f, ZF) == 0 and not signDiff(f)
	end,
}
for i = 0, 15 do
	H[0x70 + i] = function(cpu: any)
		local d = cpu:fetch8()
		if d >= 0x80 then
			d -= 0x100
		end
		if COND[i + 1](cpu.flags) then
			cpu.ip = band(cpu.ip + d, 0xFFFF)
		end
	end
	H[0x60 + i] = H[0x70 + i]
end

-- group 1: 80/81/82/83
local function group1(cpu: any, w: boolean, signExtImm: boolean)
	local e = cpu:modrm()
	local op = e.reg
	local a = w and cpu:readRM16(e) or cpu:readRM8(e)
	local b
	if w and signExtImm then
		b = cpu:fetch8()
		if b >= 0x80 then
			b += 0xFF00
		end
	else
		b = w and cpu:fetch16() or cpu:fetch8()
	end
	local res = doALU(cpu, op, a, b, w)
	if op ~= 7 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0x80] = function(cpu: any)
	group1(cpu, false, false)
end
H[0x81] = function(cpu: any)
	group1(cpu, true, false)
end
H[0x82] = H[0x80]
H[0x83] = function(cpu: any)
	group1(cpu, true, true)
end

-- TEST r/m,reg
H[0x84] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM8(e), cpu:rb(e.reg), false)
end
H[0x85] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM16(e), cpu:rr(e.reg), true)
end

-- XCHG r/m,reg
H[0x86] = function(cpu: any)
	local e = cpu:modrm()
	local a, b = cpu:readRM8(e), cpu:rb(e.reg)
	cpu:writeRM8(e, b)
	cpu:wb(e.reg, a)
end
H[0x87] = function(cpu: any)
	local e = cpu:modrm()
	local a, b = cpu:readRM16(e), cpu:rr(e.reg)
	cpu:writeRM16(e, b)
	cpu:wr(e.reg, a)
end

-- MOV family
H[0x88] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:rb(e.reg))
end
H[0x89] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:rr(e.reg))
end
H[0x8A] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wb(e.reg, cpu:readRM8(e))
end
H[0x8B] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wr(e.reg, cpu:readRM16(e))
end

local SEGREG = { "es", "cs", "ss", "ds" }
H[0x8C] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu[SEGREG[e.reg + 1]])
end
H[0x8D] = function(cpu: any)
	local e = cpu:modrm()
	if e.mod == 3 then
		error("LEA with register operand")
	end
	cpu:wr(e.reg, e.off)
end
H[0x8E] = function(cpu: any)
	local e = cpu:modrm()
	if e.reg == 1 then
		error("MOV CS, r/m is reserved")
	end
	cpu[SEGREG[e.reg + 1]] = cpu:readRM16(e)
end
H[0x8F] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:pop16())
end

H[0x90] = function() end -- NOP
for i = 1, 7 do
	H[0x90 + i] = function(cpu: any) -- XCHG AX,r
		local a = cpu:rr(0)
		cpu:wr(0, cpu:rr(i))
		cpu:wr(i, a)
	end
end

H[0x98] = function(cpu: any) -- CBW
	local al = cpu:rb(0)
	cpu:wr(0, al >= 0x80 and bor(0xFF00, al) or al)
end
H[0x99] = function(cpu: any) -- CWD
	cpu:wr(2, cpu:rr(0) >= 0x8000 and 0xFFFF or 0)
end
H[0x9A] = function(cpu: any) -- CALL far imm
	local ip = cpu:fetch16()
	local cs = cpu:fetch16()
	cpu:push16(cpu.cs)
	cpu:push16(cpu.ip)
	cpu.cs = cs
	cpu.ip = ip
end
H[0x9B] = function() end -- WAIT
H[0x9C] = function(cpu: any)
	cpu:push16(cpu.flags)
end
H[0x9D] = function(cpu: any)
	const wasEnabled = cpu:getF(IFF)
	cpu.flags = bor(band(cpu:pop16(), FLAGMASK), FIXEDFLAGS)
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- 8086 interrupt shadow after POPF
	end
end
H[0x9E] = function(cpu: any) -- SAHF
	local ah = cpu:rb(4)
	cpu.flags = bor(band(cpu.flags, bnot(0xD5)), band(ah, 0xD5), ALWAYS)
end
H[0x9F] = function(cpu: any) -- LAHF
	cpu:wb(4, bor(band(cpu.flags, 0xD5), ALWAYS))
end

-- MOV AL/AX <-> moffs16 (segment override allowed)
local function moffs(cpu: any)
	return lshift(cpu.oseg or cpu.ds, 4) + cpu:fetch16()
end
H[0xA0] = function(cpu: any)
	cpu:wb(0, cpu.mem:read8(moffs(cpu)))
end
H[0xA1] = function(cpu: any)
	cpu:wr(0, cpu.mem:read16(moffs(cpu)))
end
H[0xA2] = function(cpu: any)
	cpu.mem:write8(moffs(cpu), cpu:rb(0))
end
H[0xA3] = function(cpu: any)
	cpu.mem:write16(moffs(cpu), cpu:rr(0))
end

-- string ops: 0 MOVS, 1 CMPS, 2 STOS, 3 LODS, 4 SCAS
local function stringOp(cpu: any, id: number, w: boolean)
	local sz = w and 2 or 1
	local d = cpu:getF(DFF) and -sz or sz
	local mem = cpu.mem
	local sSeg = lshift(cpu.oseg or cpu.ds, 4)
	local eSeg = lshift(cpu.es, 4)

	local function step()
		if id == 0 then
			if w then
				mem:write16(eSeg + cpu.r[8], mem:read16(sSeg + cpu.r[7]))
			else
				mem:write8(eSeg + cpu.r[8], mem:read8(sSeg + cpu.r[7]))
			end
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 1 then
			local a = w and mem:read16(sSeg + cpu.r[7]) or mem:read8(sSeg + cpu.r[7])
			local b = w and mem:read16(eSeg + cpu.r[8]) or mem:read8(eSeg + cpu.r[8])
			doALU(cpu, 5, a, b, w)
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 2 then
			if w then
				mem:write16(eSeg + cpu.r[8], cpu:rr(0))
			else
				mem:write8(eSeg + cpu.r[8], cpu:rb(0))
			end
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 3 then
			if w then
				cpu:wr(0, mem:read16(sSeg + cpu.r[7]))
			else
				cpu:wb(0, mem:read8(sSeg + cpu.r[7]))
			end
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
		else
			local b = w and mem:read16(eSeg + cpu.r[8]) or mem:read8(eSeg + cpu.r[8])
			doALU(cpu, 5, w and cpu:rr(0) or cpu:rb(0), b, w)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		end
	end

	if not cpu.rep then
		step()
		return
	end
	local isCmp = (id == 1 or id == 4)
	while cpu.r[2] ~= 0 do
		step()
		cpu.r[2] = band(cpu.r[2] - 1, 0xFFFF)
		if isCmp then
			local zf = cpu:getF(ZF)
			if cpu.rep == 1 and not zf then
				break
			end
			if cpu.rep == 2 and zf then
				break
			end
		end
	end
end
H[0xA4] = function(cpu: any)
	stringOp(cpu, 0, false)
end
H[0xA5] = function(cpu: any)
	stringOp(cpu, 0, true)
end
H[0xA6] = function(cpu: any)
	stringOp(cpu, 1, false)
end
H[0xA7] = function(cpu: any)
	stringOp(cpu, 1, true)
end
H[0xAA] = function(cpu: any)
	stringOp(cpu, 2, false)
end
H[0xAB] = function(cpu: any)
	stringOp(cpu, 2, true)
end
H[0xAC] = function(cpu: any)
	stringOp(cpu, 3, false)
end
H[0xAD] = function(cpu: any)
	stringOp(cpu, 3, true)
end
H[0xAE] = function(cpu: any)
	stringOp(cpu, 4, false)
end
H[0xAF] = function(cpu: any)
	stringOp(cpu, 4, true)
end

H[0xA8] = function(cpu: any)
	doALU(cpu, 4, cpu:rb(0), cpu:fetch8(), false)
end
H[0xA9] = function(cpu: any)
	doALU(cpu, 4, cpu:rr(0), cpu:fetch16(), true)
end

for i = 0, 7 do
	H[0xB0 + i] = function(cpu: any)
		cpu:wb(i, cpu:fetch8())
	end
	H[0xB8 + i] = function(cpu: any)
		cpu:wr(i, cpu:fetch16())
	end
end

H[0xC2] = function(cpu: any) -- RET imm16
	local n = cpu:fetch16()
	cpu.ip = cpu:pop16()
	cpu.r[5] = band(cpu.r[5] + n, 0xFFFF)
end
H[0xC3] = function(cpu: any)
	cpu.ip = cpu:pop16()
end

H[0xC4] = function(cpu: any) -- LES r16, m32
	local e = cpu:modrm()
	cpu:wr(e.reg, cpu.mem:read16(e.addr))
	cpu.es = cpu.mem:read16(e.addr + 2)
end
H[0xC5] = function(cpu: any) -- LDS r16, m32
	local e = cpu:modrm()
	cpu:wr(e.reg, cpu.mem:read16(e.addr))
	cpu.ds = cpu.mem:read16(e.addr + 2)
end

H[0xC6] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:fetch8())
end
H[0xC7] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:fetch16())
end

H[0xCA] = function(cpu: any) -- RETF imm16
	local n = cpu:fetch16()
	cpu.ip = cpu:pop16()
	cpu.cs = cpu:pop16()
	cpu.r[5] = band(cpu.r[5] + n, 0xFFFF)
end
H[0xCB] = function(cpu: any)
	cpu.ip = cpu:pop16()
	cpu.cs = cpu:pop16()
end

H[0xCC] = function(cpu: any)
	cpu:interrupt(3)
end
H[0xCD] = function(cpu: any)
	cpu:interrupt(cpu:fetch8())
end
H[0xCE] = function(cpu: any)
	if cpu:getF(OFLG) then
		cpu:interrupt(4)
	end
end
H[0xCF] = function(cpu: any) -- IRET
	cpu.ip = cpu:pop16()
	cpu.cs = cpu:pop16()
	const wasEnabled = cpu:getF(IFF)
	cpu.flags = bor(band(cpu:pop16(), FLAGMASK), FIXEDFLAGS)
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- 8086 interrupt shadow after IRET
	end
end

-- group 2: shifts/rotates
local function group2(cpu: any, w: boolean, useCL: boolean)
	local e = cpu:modrm()
	local v = w and cpu:readRM16(e) or cpu:readRM8(e)
	local cnt = useCL and cpu:rb(1) or 1
	local res = doShift(cpu, e.reg, v, cnt, w)
	if cnt > 0 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0xD0] = function(cpu: any)
	group2(cpu, false, false)
end
H[0xD1] = function(cpu: any)
	group2(cpu, true, false)
end
H[0xD2] = function(cpu: any)
	group2(cpu, false, true)
end
H[0xD3] = function(cpu: any)
	group2(cpu, true, true)
end

-- group 2 with an 8-bit immediate count (80186+): SHL/SHR/SAR/ROL/ROR/RCL/RCR
-- r/m,imm8. Windows 3.0 real-mode code uses these even though an 8086 decodes
-- C0/C1 as the undocumented RET/RET imm16 aliases.
local function group2Imm(cpu: any, w: boolean)
	local e = cpu:modrm()
	local v = w and cpu:readRM16(e) or cpu:readRM8(e)
	local cnt = cpu:fetch8()
	local res = doShift(cpu, e.reg, v, cnt, w)
	if cnt > 0 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0xC0] = function(cpu: any)
	group2Imm(cpu, false)
end
H[0xC1] = function(cpu: any)
	group2Imm(cpu, true)
end

H[0xD4] = function(cpu: any) -- AAM imm
	local base = cpu:fetch8()
	if base == 0 then
		cpu:interrupt(0)
		return
	end
	local al = cpu:rb(0)
	cpu:wb(4, math.floor(al / base))
	cpu:wb(0, al % base)
	cpu:setSZP(cpu:rb(0), false)
end
H[0xD5] = function(cpu: any) -- AAD imm
	local base = cpu:fetch8()
	local al = band(cpu:rb(0) + cpu:rb(4) * base, 0xFF)
	cpu:wb(0, al)
	cpu:wb(4, 0)
	cpu:setSZP(al, false)
end
H[0xD6] = function(cpu: any)
	cpu:wb(0, cpu:getF(CF) and 0xFF or 0)
end -- SALC
H[0xD7] = function(cpu: any) -- XLAT
	cpu:wb(0, cpu.mem:read8(lshift(cpu.oseg or cpu.ds, 4) + band(cpu.r[4] + cpu:rb(0), 0xFFFF)))
end

for i = 0, 7 do
	H[0xD8 + i] = function(cpu: any)
		cpu:modrm()
	end -- ESC (x87 stub)
end

local function loopCommon(cpu: any, mode: number)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	local cx = band(cpu.r[2] - 1, 0xFFFF)
	cpu.r[2] = cx
	local take
	if mode == 0 then
		take = cx ~= 0 and not cpu:getF(ZF)
	elseif mode == 1 then
		take = cx ~= 0 and cpu:getF(ZF)
	else
		take = cx ~= 0
	end
	if take then
		cpu.ip = band(cpu.ip + d, 0xFFFF)
	end
end
H[0xE0] = function(cpu: any)
	loopCommon(cpu, 0)
end
H[0xE1] = function(cpu: any)
	loopCommon(cpu, 1)
end
H[0xE2] = function(cpu: any)
	loopCommon(cpu, 2)
end
H[0xE3] = function(cpu: any)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	if cpu.r[2] == 0 then
		cpu.ip = band(cpu.ip + d, 0xFFFF)
	end
end

H[0xE4] = function(cpu: any)
	local p = cpu:fetch8()
	cpu:wb(0, cpu.io.in8(p))
end
H[0xE5] = function(cpu: any)
	local p = cpu:fetch8()
	cpu:wr(0, bor(cpu.io.in8(p), lshift(cpu.io.in8(band(p + 1, 0xFFFF)), 8)))
end
H[0xE6] = function(cpu: any)
	local p = cpu:fetch8()
	cpu.io.out8(p, cpu:rb(0))
end
H[0xE7] = function(cpu: any)
	local p = cpu:fetch8()
	cpu.io.out8(p, cpu:rb(0))
	cpu.io.out8(band(p + 1, 0xFFFF), band(rshift(cpu:rr(0), 8), 0xFF))
end

H[0xE8] = function(cpu: any) -- CALL rel16
	local d = cpu:fetch16()
	cpu:push16(cpu.ip)
	cpu.ip = band(cpu.ip + sign16(d), 0xFFFF)
end
H[0xE9] = function(cpu: any)
	local d = cpu:fetch16()
	cpu.ip = band(cpu.ip + sign16(d), 0xFFFF)
end
H[0xEA] = function(cpu: any)
	local ip = cpu:fetch16()
	local cs = cpu:fetch16()
	cpu.cs = cs
	cpu.ip = ip
end
H[0xEB] = function(cpu: any)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	cpu.ip = band(cpu.ip + d, 0xFFFF)
end

H[0xEC] = function(cpu: any)
	cpu:wb(0, cpu.io.in8(cpu.r[3]))
end
H[0xED] = function(cpu: any)
	local p = cpu.r[3]
	cpu:wr(0, bor(cpu.io.in8(p), lshift(cpu.io.in8(band(p + 1, 0xFFFF)), 8)))
end
H[0xEE] = function(cpu: any)
	cpu.io.out8(cpu.r[3], cpu:rb(0))
end
H[0xEF] = function(cpu: any)
	local p = cpu.r[3]
	cpu.io.out8(p, cpu:rb(0))
	cpu.io.out8(band(p + 1, 0xFFFF), band(rshift(cpu:rr(0), 8), 0xFF))
end

H[0xF1] = function() end -- undefined on 8086, treat as NOP
H[0xF4] = function(cpu: any)
	cpu.halted = true
end
H[0xF5] = function(cpu: any)
	cpu.flags = bxor(cpu.flags, CF)
end

local function group3(cpu: any, w: boolean)
	local e = cpu:modrm()
	local op = e.reg
	if op == 0 or op == 1 then
		local a = w and cpu:readRM16(e) or cpu:readRM8(e)
		local b = w and cpu:fetch16() or cpu:fetch8()
		doALU(cpu, 4, a, b, w)
	elseif op == 2 then
		local res = band(bnot(w and cpu:readRM16(e) or cpu:readRM8(e)), w and 0xFFFF or 0xFF)
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	elseif op == 3 then
		local a = w and cpu:readRM16(e) or cpu:readRM8(e)
		local res = doALU(cpu, 5, 0, a, w)
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	elseif op == 4 then
		if w then
			local prod = cpu:rr(0) * cpu:readRM16(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(rshift(prod, 16), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFFFF)
		else
			local prod = cpu:rb(0) * cpu:readRM8(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFF)
		end
	elseif op == 5 then
		if w then
			local prod = sign16(cpu:rr(0)) * sign16(cpu:readRM16(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(truncDiv(prod, 0x10000), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x8000 or prod > 0x7FFF)
		else
			local prod = sign8(cpu:rb(0)) * sign8(cpu:readRM8(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x80 or prod > 0x7F)
		end
	elseif op == 6 then
		if w then
			local dv = cpu:readRM16(e)
			local n = bor(lshift(cpu:rr(2), 16), cpu:rr(0))
			if dv == 0 or n >= lshift(dv, 16) then
				cpu:interrupt(0)
				return
			end
			cpu:wr(0, math.floor(n / dv))
			cpu:wr(2, n % dv)
		else
			local dv = cpu:readRM8(e)
			local n = cpu:rr(0)
			if dv == 0 or n >= lshift(dv, 8) then
				cpu:interrupt(0)
				return
			end
			cpu:wb(0, math.floor(n / dv))
			cpu:wb(4, n % dv)
		end
	else
		if w then
			local dv = sign16(cpu:readRM16(e))
			if dv == 0 then
				cpu:interrupt(0)
				return
			end
			local n = sign32(bor(lshift(cpu:rr(2), 16), cpu:rr(0)))
			local q = truncDiv(n, dv)
			local r = n - q * dv
			if q < -0x8000 or q > 0x7FFF then
				cpu:interrupt(0)
				return
			end
			cpu:wr(0, band(q, 0xFFFF))
			cpu:wr(2, band(r, 0xFFFF))
		else
			local dv = sign8(cpu:readRM8(e))
			if dv == 0 then
				cpu:interrupt(0)
				return
			end
			local n = sign16(cpu:rr(0))
			local q = truncDiv(n, dv)
			local r = n - q * dv
			if q < -0x80 or q > 0x7F then
				cpu:interrupt(0)
				return
			end
			cpu:wb(0, band(q, 0xFF))
			cpu:wb(4, band(r, 0xFF))
		end
	end
end
H[0xF6] = function(cpu: any)
	group3(cpu, false)
end
H[0xF7] = function(cpu: any)
	group3(cpu, true)
end

H[0xF8] = function(cpu: any)
	cpu:setbits(CF, false)
end
H[0xF9] = function(cpu: any)
	cpu:setbits(CF, true)
end
H[0xFA] = function(cpu: any)
	cpu:setbits(IFF, false)
end
H[0xFB] = function(cpu: any)
	cpu:setbits(IFF, true)
	cpu.irqDelay = 1 -- 8086 interrupt shadow after STI
end
H[0xFC] = function(cpu: any)
	cpu:setbits(DFF, false)
end
H[0xFD] = function(cpu: any)
	cpu:setbits(DFF, true)
end

H[0xFE] = function(cpu: any)
	local e = cpu:modrm()
	local cf = cpu:getF(CF)
	local res
	if e.reg == 0 then
		res = doALU(cpu, 0, cpu:readRM8(e), 1, false)
	elseif e.reg == 1 then
		res = doALU(cpu, 5, cpu:readRM8(e), 1, false)
	else
		error("bad FE /" .. e.reg)
	end
	cpu:writeRM8(e, res)
	cpu:setbits(CF, cf)
end
H[0xFF] = function(cpu: any)
	local e = cpu:modrm()
	local reg = e.reg
	if reg == 0 or reg == 1 then
		local cf = cpu:getF(CF)
		local res = doALU(cpu, reg == 0 and 0 or 5, cpu:readRM16(e), 1, true)
		cpu:writeRM16(e, res)
		cpu:setbits(CF, cf)
	elseif reg == 2 then
		local t = cpu:readRM16(e)
		cpu:push16(cpu.ip)
		cpu.ip = t
	elseif reg == 3 then
		local ip = cpu.mem:read16(e.addr)
		local cs = cpu.mem:read16(e.addr + 2)
		cpu:push16(cpu.cs)
		cpu:push16(cpu.ip)
		cpu.cs = cs
		cpu.ip = ip
	elseif reg == 4 then
		cpu.ip = cpu:readRM16(e)
	elseif reg == 5 then
		cpu.cs = cpu.mem:read16(e.addr + 2)
		cpu.ip = cpu.mem:read16(e.addr)
	elseif reg == 6 then
		cpu:push16(cpu:readRM16(e))
	else
		error(("bad FF /7 at %04X:%04X"):format(cpu.cs, cpu.ip - 2))
	end
end

-- 8086 aliasing: C8/C9 -> RETF imm16/RETF. C0/C1 are *not* 8086 aliases
-- here: 80186+ defines them as shift/rotate r/m,imm8, and Windows 3.0's
-- real-mode drivers emit them (VGA.DRV does `SHR DX,3` = C1 EA 03). Treating
-- C1 as RET pops a saved register as the return address and derails the
-- guest, so implement the 80186 group-2 immediate forms instead.
H[0xC8] = H[0xCA]
H[0xC9] = H[0xCB]

-- Real-mode interrupt dispatch. The machine materialises an IVT stub
-- (`int 90h+i; iret`) for every service it emulates so guest code can hook and
-- chain vectors. Two rules keep the emulated handlers' flag results (CF/ZF are
-- how DOS and BIOS report errors) visible to callers:
--   * while a vector still points at our stub, dispatch the Lua handler
--     inline. Pushing the interrupt frame and letting the stub IRET would
--     restore the pre-interrupt flags and silently drop the result bits.
--   * when a guest chains to a saved stub itself (`pushf; call far F100:xxxx`),
--     the stub's IRET pops the frame the guest built; write the handler's flags
--     into that frame, exactly like a real DOS/BIOS ISR does.
function Cpu.interrupt(self: Cpu, n: number)
	local mem = self.mem
	local base = lshift(n, 2)
	local lo = mem:read16(base)
	local hi = mem:read16(base + 2)
	const handler = self.defaultInts[n]
	const stub = self.intStubs[n]
	if handler and stub and lo == stub.off and hi == stub.seg then
		handler(n)
		return
	end
	if lo ~= 0 or hi ~= 0 then
		self:push16(self.flags)
		self:push16(self.cs)
		self:push16(self.ip)
		self.flags = bor(band(self.flags, bnot(bor(TF, IFF))), ALWAYS)
		self.ip = lo
		self.cs = hi
		return
	end
	if not handler then
		error(
			("unhandled interrupt %02X (zero IVT entry) at %04X:%04X"):format(n, self.cs, self.ip)
		)
	end
	const chained = self.stubSeg ~= nil and self.cs == self.stubSeg
	handler(n)
	if chained then
		-- frame on entry to the stub: [SP]=return IP, [SP+2]=return CS,
		-- [SP+4]=saved FLAGS (the word the stub's IRET will pop)
		const frame = band(lshift(self.ss, 4) + band(self.r[5] + 4, 0xFFFF), 0xFFFFF)
		mem:write16(frame, band(self.flags, FLAGMASK))
	end
end

function Cpu.step(self: Cpu): number
	if self.halted then
		return 0
	end
	if self.irqDelay > 0 then
		self.irqDelay -= 1
	end
	self.oseg = nil
	self.rep = nil
	local op = 0
	while true do
		op = self:fetch8()
		if op == 0x26 then
			self.oseg = self.es
		elseif op == 0x2E then
			self.oseg = self.cs
		elseif op == 0x36 then
			self.oseg = self.ss
		elseif op == 0x3E then
			self.oseg = self.ds
		elseif op == 0xF2 then
			self.rep = 2
		elseif op == 0xF3 then
			self.rep = 1
		elseif op == 0xF0 then
			-- LOCK: ignore
		else
			break
		end
	end
	const h = H[op] :: ((cpu: any) -> ())?
	if not h then
		error(
			("unimplemented opcode %02X at %04X:%04X"):format(
				op,
				self.cs,
				band(self.ip - 1, 0xFFFF)
			)
		)
	end
	h(self)
	self.oseg = nil
	self.rep = nil
	return 1
end

function Cpu.dump(self: Cpu): { [string]: number }
	return {
		ax = self.r[1],
		cx = self.r[2],
		dx = self.r[3],
		bx = self.r[4],
		sp = self.r[5],
		bp = self.r[6],
		si = self.r[7],
		di = self.r[8],
		cs = self.cs,
		ds = self.ds,
		es = self.es,
		ss = self.ss,
		ip = self.ip,
		flags = self.flags,
	}
end

return Cpu
