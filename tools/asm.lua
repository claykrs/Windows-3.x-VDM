-- asm.lua -- two-pass 8086 micro-assembler producing a Luau buffer.

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local function modrm(mod, reg, rm)
	return bor(lshift(mod, 6), lshift(reg, 3), rm)
end

local A = {}
A.__index = A

function A.new()
	return setmetatable({ parts = {}, labels = {}, cur = 0 }, A)
end

function A:byte(n)
	self.parts[#self.parts + 1] = band(n, 0xFF)
	self.cur += 1
end

function A:word(n)
	self:byte(band(n, 0xFF))
	self:byte(band(rshift(n, 8), 0xFF))
end

-- kind: "rel8" | "rel16" | "abs16"
function A:ref(kind, label)
	self.parts[#self.parts + 1] = { kind = kind, label = label }
	self.cur += (kind == "rel8") and 1 or 2
end

function A:label(name)
	self.labels[name] = self.cur
end

-- instruction helpers (reg indexes: AX CX DX BX SP BP SI DI = 0..7;
-- 8-bit: AL CL DL BL AH CH DH BH = 0..7)

function A:mov_r16_imm(reg, imm)
	self:byte(0xB8 + reg)
	self:word(imm)
end
function A:mov_r16_label(reg, label)
	self:byte(0xB8 + reg)
	self:ref("abs16", label)
end
function A:mov_r8_imm(reg, imm)
	self:byte(0xB0 + reg)
	self:byte(imm)
end
function A:mov_r_r(dst, src)
	self:byte(0x89)
	self:byte(modrm(3, src, dst))
end
function A:mov_rm8_r8(rm, reg)
	self:byte(0x88)
	self:byte(modrm(3, reg, rm))
end
function A:mov_r16_sreg(reg, s)
	self:byte(0x8C)
	self:byte(modrm(3, s, reg))
end
function A:mov_sreg_r16(s, reg)
	self:byte(0x8E)
	self:byte(modrm(3, s, reg))
end
function A:mov_ax_moffs(off)
	self:byte(0xA1)
	self:word(off)
end
function A:mov_ax_label(label)
	self:byte(0xA1)
	self:ref("abs16", label)
end
function A:push_sreg(s)
	self:byte(bor(0x06, lshift(s, 3)))
end -- ES CS SS DS = 0 1 2 3
function A:pop_sreg(s)
	self:byte(bor(0x07, lshift(s, 3)))
end
function A:mov_moffs_ax(off)
	self:byte(0xA3)
	self:word(off)
end -- MOV [off], AX
function A:int(n)
	self:byte(0xCD)
	self:byte(n)
end
function A:push_r(reg)
	self:byte(0x50 + reg)
end
function A:pop_r(reg)
	self:byte(0x58 + reg)
end
function A:inc_r(reg)
	self:byte(0x40 + reg)
end
function A:xor_r_r(dst, src)
	self:byte(0x31)
	self:byte(modrm(3, src, dst))
end
function A:add_r_r(dst, src)
	self:byte(0x01)
	self:byte(modrm(3, src, dst))
end
function A:add_rm8_imm(rm, imm)
	self:byte(0x80)
	self:byte(modrm(3, 0, rm))
	self:byte(imm)
end
function A:test_ax_ax()
	self:byte(0x85)
	self:byte(0xC0)
end
function A:cmp_al_imm(imm)
	self:byte(0x3C)
	self:byte(imm)
end
function A:div_rm16(reg)
	self:byte(0xF7)
	self:byte(modrm(3, 6, reg))
end
function A:jcc(cc, label)
	self:byte(0x70 + cc)
	self:ref("rel8", label)
end
function A:jmp(label)
	self:byte(0xEB)
	self:ref("rel8", label)
end
function A:loop(label)
	self:byte(0xE2)
	self:ref("rel8", label)
end
function A:call(label)
	self:byte(0xE8)
	self:ref("rel16", label)
end
function A:ret()
	self:byte(0xC3)
end
function A:hlt()
	self:byte(0xF4)
end

function A:db(...)
	for _, b in ipairs({ ... }) do
		self:byte(b)
	end
end

function A:asciz(s)
	for i = 1, #s do
		self:byte(string.byte(s, i))
	end
	self:byte(0)
end

function A:dollar(s)
	for i = 1, #s do
		self:byte(string.byte(s, i))
	end
	self:byte(0x24)
end

-- resolve returns (buffer, labels)
function A:resolve(origin)
	origin = origin or 0x100
	local bytes = {}
	local pos = 0
	for _, item in ipairs(self.parts) do
		if type(item) == "number" then
			bytes[#bytes + 1] = item
			pos += 1
		else
			local target = self.labels[item.label]
			assert(target, "undefined label: " .. tostring(item.label))
			if item.kind == "rel8" then
				local d = target - (pos + 1)
				assert(d >= -128 and d <= 127, "rel8 overflow for label " .. item.label)
				bytes[#bytes + 1] = band(d, 0xFF)
				pos += 1
			elseif item.kind == "rel16" then
				local d = target - (pos + 2)
				bytes[#bytes + 1] = band(d, 0xFF)
				bytes[#bytes + 1] = band(rshift(d, 8), 0xFF)
				pos += 2
			else -- abs16
				bytes[#bytes + 1] = band(origin + target, 0xFF)
				bytes[#bytes + 1] = band(rshift(origin + target, 8), 0xFF)
				pos += 2
			end
		end
	end
	local buf = buffer.create(#bytes)
	for i, b in ipairs(bytes) do
		buffer.writeu8(buf, i - 1, b)
	end
	return buf, self.labels
end

return A
