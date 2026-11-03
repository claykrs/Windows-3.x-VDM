--!nonstrict
-- PmCpuTests.lua -- 286/386 execution level: class probe, ENTER/LEAVE, BOUND,
-- 80186 immediates, string I/O, and the 0F system subset DOSX needs.
-- Each spec may carry `config = { cpu = { cpuLevel = "286" }, ... }`.

const band, bor, rshift = bit32.band, bit32.bor, bit32.rshift

local TESTS = {}

local function T(name, spec)
	TESTS[#TESTS + 1] = {
		name = name,
		setup = spec.setup,
		steps = spec.steps or 200,
		check = spec.check,
		config = spec.config,
	}
end

const LEVEL_286 = { cpu = { cpuLevel = "286" } }
const LEVEL_386 = { cpu = { cpuLevel = "386" } }

local function putCode(m, bytes)
	local full = table.create(#bytes + 1)
	for i = 1, #bytes do
		full[i] = bytes[i]
	end
	full[#bytes + 1] = 0xF4
	local buf = buffer.create(#full)
	for i = 1, #full do
		buffer.writeu8(buf, i - 1, full[i])
	end
	m.mem:copyFrom(0x6000 + 0x100, buf)
end

local function putData(m, addr, bytes)
	local buf = buffer.create(#bytes)
	for i = 1, #bytes do
		buffer.writeu8(buf, i - 1, bytes[i])
	end
	m.mem:copyFrom(0x6000 + addr, buf)
end

local function putBytes(m, addr, bytes)
	local buf = buffer.create(#bytes)
	for i = 1, #bytes do
		buffer.writeu8(buf, i - 1, bytes[i])
	end
	m.mem:copyFrom(addr, buf)
end

local function fresh(m)
	const cpu = m.cpu
	cpu.cs, cpu.ds, cpu.es, cpu.ss = 0x600, 0x600, 0x600, 0x600
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE
end

-- The exact WIN.CNF CPU-class probe at 1000:30D2.
const CLASS_PROBE = {
	0x9C,
	0x33,
	0xC0,
	0x50,
	0x9D,
	0x9C,
	0x58,
	0xA9,
	0x00,
	0x80,
	0xB8,
	0x00,
	0x00,
	0x75,
	0x13,
	0xB8,
	0x00,
	0x70,
	0x50,
	0x9D,
	0xFB,
	0x9C,
	0x58,
	0xA9,
	0x00,
	0x70,
	0xB8,
	0x86,
	0x02,
	0x74,
	0x03,
	0xB8,
	0x86,
	0x03,
	0x9D,
}

T("cpu_class_probe_286", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, CLASS_PROBE)
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x286, "class=" .. string.format("%04X", cpu.r[1]))
		expect(band(cpu.flags, 0xF000) == 0, "286 high flags not zero")
	end,
})

T("cpu_class_probe_386", {
	config = LEVEL_386,
	setup = function(m)
		putCode(m, CLASS_PROBE)
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x386, "class=" .. string.format("%04X", cpu.r[1]))
	end,
})

T("pushf_286_upper_zero", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x9C, 0x58 }) -- PUSHF; POP AX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(band(cpu.r[1], 0xF000) == 0, "flags=" .. string.format("%04X", cpu.r[1]))
		expect(band(cpu.r[1], 0x0002) == 0x0002, "bit 1 always set")
	end,
})

T("enter_leave_frame", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xC8, 0x08, 0x00, 0x00, 0xC9 }) -- ENTER 8,0; LEAVE
		fresh(m)
		m.cpu.r[6] = 0x2222 -- BP
		m.cpu.r[5] = 0x1000
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[6] == 0x2222, "BP=" .. string.format("%04X", cpu.r[6]))
		expect(cpu.r[5] == 0x1000, "SP=" .. string.format("%04X", cpu.r[5]))
	end,
})

T("enter_nested", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xC8, 0x04, 0x00, 0x01, 0xC9 }) -- ENTER 4,1; LEAVE
		fresh(m)
		m.cpu.r[6] = 0x2000
		m.cpu.r[5] = 0x1000
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[6] == 0x2000, "BP restored")
		expect(cpu.r[5] == 0x1000, "SP restored")
	end,
})

T("bound_ok", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x05, 0x00, 0x62, 0x06, 0x00, 0x03 }) -- MOV AX,5; BOUND AX,[0x300]
		fresh(m)
		putData(m, 0x300, { 0x00, 0x00, 0x0A, 0x00 }) -- lower=0 upper=10
	end,
	check = function(_m, cpu, expect)
		expect(cpu.halted, "BOUND did not fall through")
		expect(cpu.r[1] == 5, "AX changed")
	end,
})

T("bound_fault_int5", {
	config = LEVEL_286,
	steps = 50,
	setup = function(m)
		putCode(m, { 0xB8, 0x14, 0x00, 0x62, 0x06, 0x00, 0x03 }) -- index 20
		fresh(m)
		putData(m, 0x300, { 0x00, 0x00, 0x0A, 0x00 })
		m.mem:write16(5 * 4, 0x0010)
		m.mem:write16(5 * 4 + 2, 0x2000)
		const handler = buffer.create(4)
		buffer.writeu8(handler, 0, 0xBB)
		buffer.writeu8(handler, 1, 0x34)
		buffer.writeu8(handler, 2, 0x12)
		buffer.writeu8(handler, 3, 0xCF) -- MOV BX,0x1234; IRET
		m.mem:copyFrom(0x20000 + 0x10, handler)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[4] == 0x1234, "INT 5 not taken: BX=" .. string.format("%04X", cpu.r[4]))
	end,
})

T("push_imm8_sign_extends", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x6A, 0xFF, 0x58 }) -- PUSH -1; POP AX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0xFFFF, "AX=" .. string.format("%04X", cpu.r[1]))
	end,
})

T("push_imm8_positive", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x6A, 0x58, 0x58 }) -- PUSH 0x58; POP AX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x0058, "AX=" .. string.format("%04X", cpu.r[1]))
	end,
})

T("push_imm16", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x68, 0x34, 0x12, 0x58 })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x1234, "AX=" .. string.format("%04X", cpu.r[1]))
	end,
})

T("imul_imm16", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x64, 0x00, 0x69, 0xC0, 0x0A, 0x00 }) -- 100 * 10
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 1000, "AX=" .. cpu.r[1])
		expect(not cpu:getF(1), "CF set for in-range product")
	end,
})

T("imul_imm8_overflows", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x00, 0x10, 0x6B, 0xC0, 0x10 }) -- 0x1000 * 16
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0, "AX=" .. string.format("%04X", cpu.r[1]))
		expect(cpu:getF(1), "CF not set for overflow")
		expect(cpu:getF(2048), "OF not set for overflow")
	end,
})

T("pusha_popa", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x60, 0x61 }) -- PUSHA; POPA
		fresh(m)
		m.cpu.r = { 1, 2, 3, 4, 0x800, 5, 6, 7 }
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 1 and cpu.r[2] == 2 and cpu.r[3] == 3 and cpu.r[4] == 4, "AX-DX")
		expect(cpu.r[5] == 0x800, "SP")
		expect(cpu.r[6] == 5 and cpu.r[7] == 6 and cpu.r[8] == 7, "BP/SI/DI")
	end,
})

T("rep_insb_outsb", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, {
			0xBA,
			0xF0,
			0x03, -- MOV DX,0x3F0
			0xBE,
			0x00,
			0x03, -- MOV SI,0x300
			0xBF,
			0x00,
			0x04, -- MOV DI,0x400
			0xB9,
			0x03,
			0x00, -- MOV CX,3
			0xFC, -- CLD
			0xF3,
			0x6E, -- REP OUTSB
			0xB9,
			0x03,
			0x00, -- MOV CX,3 again (REP consumed it)
			0xF3,
			0x6C, -- REP INSB
		})
		fresh(m)
		putData(m, 0x300, { 0x11, 0x22, 0x33 })
		const written = {}
		m.cpu.io = {
			in8 = function()
				return 0x5A
			end,
			out8 = function(_port, value)
				written[#written + 1] = value
			end,
		}
		m.outBytes = written
	end,
	check = function(m, cpu, expect)
		expect(table.concat(m.outBytes, ",") == "17,34,51", "OUTSB data")
		expect(m.mem:read8(0x6000 + 0x400) == 0x5A, "INSB byte 1")
		expect(m.mem:read8(0x6000 + 0x401) == 0x5A, "INSB byte 2")
		expect(cpu.r[7] == 0x303 and cpu.r[8] == 0x403, "SI/DI advanced")
	end,
})

T("lmsW_smsw", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x05, 0x00, 0x0F, 0x01, 0xF0, 0x0F, 0x01, 0xE0 })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.cr0 == 5, "CR0=" .. string.format("%X", cpu.cr0))
		expect(cpu.r[1] == 5, "SMSW AX=" .. string.format("%04X", cpu.r[1]))
	end,
})

T("lgdt_lidt_286", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x0F, 0x01, 0x16, 0x00, 0x03, 0x0F, 0x01, 0x1E, 0x00, 0x03 })
		fresh(m)
		-- 286 form: limit word, 24-bit base, reserved byte
		putData(m, 0x300, { 0xFF, 0x0F, 0x56, 0x34, 0x12, 0x00 })
	end,
	check = function(_m, cpu, expect)
		expect(cpu.gdtr.limit == 0x0FFF, "GDTR limit")
		expect(cpu.gdtr.base == 0x123456, "GDTR base=" .. string.format("%X", cpu.gdtr.base))
		expect(cpu.idtr.base == 0x123456, "IDTR base")
	end,
})

T("sgdt_sidt_286", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0x0F, 0x01, 0x06, 0x00, 0x03, 0x0F, 0x01, 0x0E, 0x20, 0x03 })
		fresh(m)
		m.cpu.gdtr = { base = 0x123456, limit = 0x0FFF }
		m.cpu.idtr = { base = 0x654321, limit = 0x00FF }
	end,
	check = function(m, _cpu, expect)
		expect(m.mem:read16(0x6000 + 0x300) == 0x0FFF, "SGDT limit")
		expect(m.mem:read8(0x6000 + 0x304) == 0x12, "SGDT base high")
		expect(m.mem:read16(0x6000 + 0x320) == 0x00FF, "SIDT limit")
		expect(m.mem:read8(0x6000 + 0x324) == 0x65, "SIDT base high")
	end,
})

T("lar_lsl_gdt", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, {
			0x0F,
			0x01,
			0x16,
			0x00,
			0x03, -- LGDT [0x300]
			0xBB,
			0x08,
			0x00, -- MOV BX,8
			0x0F,
			0x02,
			0xC3, -- LAR AX,BX
			0x0F,
			0x03,
			0xCB, -- LSL CX,BX
		})
		fresh(m)
		-- GDTR: limit 0x1F, base 0x7000
		putData(m, 0x300, { 0x1F, 0x00, 0x00, 0x70, 0x00, 0x00 })
		-- descriptor 1 (selector 0008h): limit FFFF, access 9A, flags 40
		m.mem:write16(0x7008, 0xFFFF)
		m.mem:write16(0x700A, 0)
		m.mem:write8(0x700C, 0)
		m.mem:write8(0x700D, 0x9A)
		m.mem:write8(0x700E, 0x40)
		m.mem:write8(0x700F, 0)
	end,
	check = function(_m, cpu, expect)
		expect(not cpu:getF(64), "LAR did not find descriptor")
		expect(cpu.r[1] == 0x9A40, "LAR rights=" .. string.format("%04X", cpu.r[1]))
		expect(cpu.r[2] == 0xFFFF, "LSL limit=" .. string.format("%04X", cpu.r[2]))
	end,
})

local function writeDescriptor(m, addr, limit, base, access, flags)
	m.mem:write16(addr, band(limit, 0xFFFF))
	m.mem:write16(addr + 2, band(base, 0xFFFF))
	m.mem:write8(addr + 4, band(rshift(base, 16), 0xFF))
	m.mem:write8(addr + 5, access)
	m.mem:write8(addr + 6, flags)
	m.mem:write8(addr + 7, band(rshift(base, 24), 0xFF))
end

T("verr_verw_gdt", {
	config = LEVEL_286,
	steps = 40,
	setup = function(m)
		const code = {
			0xB8,
			0x08,
			0x00, -- MOV AX,0008 (readable code)
			0x0F,
			0x00,
			0xE0, -- VERR AX
			0x9C,
			0x58, -- PUSHF; POP AX
			0xA2,
			0x00,
			0x03, -- MOV [0x300],AL
			0xB8,
			0x10,
			0x00, -- MOV AX,0010 (execute-only code)
			0x0F,
			0x00,
			0xE0, -- VERR AX
			0x9C,
			0x58,
			0xA2,
			0x01,
			0x03,
			0xB8,
			0x18,
			0x00, -- MOV AX,0018 (writable data)
			0x0F,
			0x00,
			0xE8, -- VERW AX
			0x9C,
			0x58,
			0xA2,
			0x02,
			0x03,
			0xB8,
			0x08,
			0x00, -- MOV AX,0008 (code is not writable)
			0x0F,
			0x00,
			0xE8, -- VERW AX
			0x9C,
			0x58,
			0xA2,
			0x03,
			0x03,
			0xB8,
			0x28,
			0x00, -- MOV AX,0028 (absent descriptor)
			0x0F,
			0x00,
			0xE0, -- VERR AX
			0x9C,
			0x58,
			0xA2,
			0x04,
			0x03,
			0xB8,
			0x00,
			0x00, -- MOV AX,0 (null selector)
			0x0F,
			0x00,
			0xE0, -- VERR AX
			0x9C,
			0x58,
			0xA2,
			0x05,
			0x03,
			0xF4,
		}
		local buf = buffer.create(#code)
		for index = 1, #code do
			buffer.writeu8(buf, index - 1, code[index])
		end
		m.mem:copyFrom(0x8100, buf)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		writeDescriptor(m, 0x7008, 0xFFFF, 0x8000, 0x9A, 0) -- code, readable
		writeDescriptor(m, 0x7010, 0xFFFF, 0x8000, 0x98, 0) -- code, execute-only
		writeDescriptor(m, 0x7018, 0xFFFF, 0x9000, 0x92, 0) -- data, writable
		writeDescriptor(m, 0x7020, 0xFFFF, 0x9000, 0x90, 0) -- data, read-only
		m.cpu:loadSeg("cs", 0x08)
		m.cpu:loadSeg("ds", 0x18)
		m.cpu:loadSeg("ss", 0x18)
		m.cpu.ip = 0x100
		m.cpu.r[5] = 0xFFFE
	end,
	check = function(m, _cpu, expect)
		local function zf(index)
			return band(m.mem:read8(0x9300 + index), 0x40) ~= 0
		end
		expect(zf(0), "VERR readable code cleared ZF")
		expect(not zf(1), "VERR execute-only code set ZF")
		expect(zf(2), "VERW writable data cleared ZF")
		expect(not zf(3), "VERW code segment set ZF")
		expect(not zf(4), "VERR absent descriptor set ZF")
		expect(not zf(5), "VERR null selector set ZF")
	end,
})

T("pm_descriptor_base_limit", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x1F }
		writeDescriptor(m, 0x7008, 0x0FFF, 0x12340, 0x92, 0)
		m.cpu.cr0 = 1
	end,
	check = function(_m, cpu, expect)
		cpu:loadSeg("ds", 0x08)
		expect(cpu.ds == 0x08, "DS selector")
		expect(cpu.segBase.ds == 0x12340, "DS base=" .. string.format("%X", cpu.segBase.ds))
		expect(cpu.segLimit.ds == 0x0FFF, "DS limit=" .. string.format("%X", cpu.segLimit.ds))
		expect(cpu.segAccess.ds == 0x92, "DS access=" .. string.format("%02X", cpu.segAccess.ds))
		expect(cpu:linear("ds", 0x0FFF, 1) == 0x1333F, "linear end")
		local ok, err = pcall(function()
			cpu:linear("ds", 0x1000, 1)
		end)
		expect(
			not ok and string.find(tostring(err), "exceeds limit", 1, true) ~= nil,
			"limit fault"
		)
	end,
})

T("pm_null_data_selector", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.cr0 = 1
	end,
	check = function(_m, cpu, expect)
		cpu:loadSeg("ds", 0)
		expect(cpu.ds == 0 and cpu.segBase.ds == 0 and cpu.segLimit.ds == 0, "null DS cache")
		local ok, err = pcall(function()
			cpu:linear("ds", 0x246, 2)
		end)
		expect(
			not ok and string.find(tostring(err), "exceeds limit", 1, true) ~= nil,
			"null DS access did not fault"
		)
	end,
})

T("pm_far_jump_selector", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xEA, 0x0E, 0x0B, 0x78, 0x00 }) -- LJMP 0078:0B0E
		fresh(m)
		m.cpu:loadSeg("cs", 0x600) -- populate the real-mode cache first
		m.cpu.gdtr = { base = 0x7000, limit = 0x7F }
		writeDescriptor(m, 0x7000 + 0x78, 0xFFFF, 0x7000, 0x9A, 0)
		m.mem:write8(0x7000 + 0xB0E, 0xF4) -- HLT at the PM target
		m.cpu.cr0 = 1
	end,
	check = function(_m, cpu, expect)
		expect(cpu.cs == 0x78, "CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.segBase.cs == 0x7000, "CS base=" .. string.format("%X", cpu.segBase.cs))
		expect(cpu.halted, "PM target did not execute")
	end,
})

T("pm_far_jump_limit_fault", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		putCode(m, { 0xEA, 0x00, 0x02, 0x78, 0x00 }) -- LJMP 0078:0200
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x7F }
		writeDescriptor(m, 0x7000 + 0x78, 0x0100, 0x7000, 0x9A, 0)
		m.cpu.cr0 = 1
	end,
	check = function(m, _cpu, expect)
		local ok, err = pcall(function()
			m:run(2)
		end)
		expect(not ok, "limit violation did not fault")
		expect(
			string.find(tostring(err), "exceeds limit", 1, true) ~= nil,
			"fault text=" .. tostring(err)
		)
		expect(
			string.find(tostring(err), "0078", 1, true) ~= nil,
			"fault did not name selector 0078"
		)
	end,
})

T("pm_call_gate_named_fault", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x1F }
		writeDescriptor(m, 0x7008, 0x0000, 0x0000, 0xE4, 0) -- 286 call gate
		m.cpu.cr0 = 1
	end,
	check = function(_m, cpu, expect)
		local ok, err = pcall(function()
			cpu:loadSeg("cs", 0x08)
		end)
		expect(not ok, "call gate loaded as a code segment")
		expect(
			string.find(tostring(err), "not a code segment", 1, true) ~= nil,
			"fault text=" .. tostring(err)
		)
		expect(string.find(tostring(err), "0008", 1, true) ~= nil, "fault did not name 0008")
	end,
})

T("ltr_tss_cache", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		putCode(m, { 0xB8, 0x28, 0x00, 0x0F, 0x00, 0xD8 }) -- MOV AX,28h; LTR AX
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		writeDescriptor(m, 0x7000 + 0x28, 0x002B, 0x7100, 0x81, 0) -- available 286 TSS
		m.cpu.cr0 = 1
	end,
	check = function(m, cpu, expect)
		m:run(2)
		expect(cpu.tr == 0x28, "TR=" .. string.format("%04X", cpu.tr))
		expect(cpu.trBase == 0x7100, "TR base=" .. string.format("%X", cpu.trBase))
		expect(cpu.trLimit == 0x002B, "TR limit=" .. string.format("%X", cpu.trLimit))
		expect(m.mem:read8(0x7028 + 5) == 0x83, "TSS busy bit not set")
	end,
})

T("call_gate_ring3_to_ring0_frame", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		-- selector 08: ring0 code at 8000
		writeDescriptor(m, 0x7008, 0xFFFF, 0x8000, 0x9A, 0)
		-- selector 10: ring0 writable stack at 9000
		writeDescriptor(m, 0x7010, 0xFFFF, 0x9000, 0x92, 0)
		-- selector 18: ring3 code at 6000
		writeDescriptor(m, 0x7018, 0xFFFF, 0x6000, 0xFA, 0)
		-- selector 20: ring3 writable stack at C000
		writeDescriptor(m, 0x7020, 0xFFFF, 0xC000, 0xF2, 0)
		-- selector 28: TSS at 7100, SP0=0FF0 SS0=10h
		writeDescriptor(m, 0x7028, 0x002B, 0x7100, 0x81, 0)
		-- selector 30: call gate DPL3, target 08:0100, 2 params
		writeDescriptor(m, 0x7030, 0x0100, 0x0008, 0xE4, 0)
		m.mem:write8(0x7034, 2) -- parameter count
		m.mem:write16(0x7102, 0x0FF0) -- TSS SP0
		m.mem:write16(0x7104, 0x0010) -- TSS SS0
		m.cpu:loadSeg("cs", 0x1B) -- ring 3 (RPL 3)
		m.cpu:loadSeg("ss", 0x23)
		m.cpu:loadSeg("ds", 0x23)
		m.cpu:loadSeg("es", 0x23)
		m.cpu.tr = 0x28
		m.cpu.trBase = 0x7100
		m.cpu.trLimit = 0x002B
		m.cpu.r[5] = 0x0F00
		m.cpu.ip = 0x0500
		m.mem:write16(0xC000 + 0x0F00, 0x1111)
		m.mem:write16(0xC000 + 0x0F02, 0x2222)
		m.mem:write8(0x8000 + 0x0100, 0xCF) -- IRET at ring0 target
	end,
	check = function(m, cpu, expect)
		cpu:farCall(0x30, 0x0100, true)
		expect(cpu.cs == 0x08, "target CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.segBase.cs == 0x8000, "target CS base")
		expect(cpu.ss == 0x10, "ring0 SS=" .. string.format("%04X", cpu.ss))
		expect(cpu.segBase.ss == 0x9000, "ring0 SS base")
		-- A call gate pushes IP, CS, old SP, old SS and the parameters; FLAGS
		-- is interrupt-gate state and must not be in this frame.
		expect(cpu.r[5] == 0x0FE4, "ring0 SP=" .. string.format("%04X", cpu.r[5]))
		expect(m.mem:read16(0x9000 + 0x0FE4) == 0x0500, "return IP")
		expect(m.mem:read16(0x9000 + 0x0FE6) == 0x001B, "return CS")
		expect(m.mem:read16(0x9000 + 0x0FE8) == 0x0F00, "old SP")
		expect(m.mem:read16(0x9000 + 0x0FEA) == 0x0023, "old SS")
		expect(m.mem:read16(0x9000 + 0x0FEC) == 0x1111, "param 1")
		expect(m.mem:read16(0x9000 + 0x0FEE) == 0x2222, "param 2")
	end,
})

T("retf_ring0_to_ring3_frame", {
	config = LEVEL_286,
	steps = 1,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		writeDescriptor(m, 0x7008, 0xFFFF, 0x8000, 0x9A, 0) -- ring0 code
		writeDescriptor(m, 0x7010, 0xFFFF, 0x9000, 0x92, 0) -- ring0 stack
		writeDescriptor(m, 0x7018, 0xFFFF, 0x6000, 0xFA, 0) -- ring3 code
		writeDescriptor(m, 0x7020, 0xFFFF, 0xC000, 0xF2, 0) -- ring3 stack
		m.cpu:loadSeg("cs", 0x08)
		m.cpu:loadSeg("ss", 0x10)
		m.cpu:loadSeg("ds", 0x10)
		m.cpu.r[5] = 0x0F00
		m.cpu.ip = 0x0100
		m.mem:write8(0x8100, 0xCB) -- RETF
		-- Outer-privilege return frame: IP, CS, SP, SS.
		m.cpu:push16(0x0023)
		m.cpu:push16(0x0F00)
		m.cpu:push16(0x001B)
		m.cpu:push16(0x0500)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.cs == 0x1B, "CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.ip == 0x0500, "IP=" .. string.format("%04X", cpu.ip))
		expect(cpu.ss == 0x23, "SS=" .. string.format("%04X", cpu.ss))
		expect(cpu.r[5] == 0x0F00, "SP=" .. string.format("%04X", cpu.r[5]))
	end,
})

T("call_gate_bad_target_named", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		writeDescriptor(m, 0x7008, 0xFFFF, 0x8000, 0x9A, 0)
		writeDescriptor(m, 0x7030, 0x0100, 0x0040, 0xE4, 0) -- absent target 0040
		m.cpu:loadSeg("cs", 0x08)
		m.cpu.r[5] = 0x0F00
		m.cpu.ip = 0x0100
	end,
	check = function(_m, cpu, expect)
		local ok, err = pcall(function()
			cpu:farCall(0x30, 0x0100, true)
		end)
		expect(not ok, "bad gate target did not fault")
		expect(
			string.find(tostring(err), "target selector 0040", 1, true) ~= nil,
			"fault text=" .. tostring(err)
		)
	end,
})

local function writeGate(m, addr, offset, selector, access)
	m.mem:write16(addr, band(offset, 0xFFFF))
	m.mem:write16(addr + 2, selector)
	m.mem:write8(addr + 4, 0)
	m.mem:write8(addr + 5, access)
	m.mem:write16(addr + 6, band(rshift(offset, 16), 0xFFFF))
end

T("pm_int3_ring3_to_ring0_iret", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		m.cpu.idtr = { base = 0x7200, limit = 0x07FF }
		writeDescriptor(m, 0x7008, 0xFFFF, 0x8000, 0x9A, 0)
		writeDescriptor(m, 0x7010, 0xFFFF, 0x9000, 0x92, 0)
		writeDescriptor(m, 0x7018, 0xFFFF, 0x6000, 0xFA, 0)
		writeDescriptor(m, 0x7020, 0xFFFF, 0xC000, 0xF2, 0)
		writeDescriptor(m, 0x7028, 0x002B, 0x7100, 0x81, 0)
		m.mem:write16(0x7102, 0x0FF0) -- TSS SP0
		m.mem:write16(0x7104, 0x0010) -- TSS SS0
		writeGate(m, 0x7200 + 3 * 8, 0x0200, 0x0008, 0xEE) -- DPL3 interrupt gate
		m.cpu:loadSeg("cs", 0x1B)
		m.cpu:loadSeg("ss", 0x23)
		m.cpu:loadSeg("ds", 0x23)
		m.cpu:loadSeg("es", 0x23)
		m.cpu.tr = 0x28
		m.cpu.trBase = 0x7100
		m.cpu.trLimit = 0x002B
		m.cpu.r[5] = 0x0F00
		m.cpu.ip = 0x0500
		m.cpu.flags = bor(m.cpu.flags, 512) -- IF
		m.mem:write8(0x8200, 0xCF) -- IRET at ring0 target
	end,
	check = function(m, cpu, expect)
		cpu:interrupt(3, nil, true)
		expect(cpu.cs == 0x08, "target CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.ss == 0x10, "ring0 SS=" .. string.format("%04X", cpu.ss))
		expect(cpu.r[5] == 0x0FE6, "ring0 SP=" .. string.format("%04X", cpu.r[5]))
		expect(m.mem:read16(0x9000 + 0x0FE6) == 0x0500, "frame IP")
		expect(m.mem:read16(0x9000 + 0x0FE8) == 0x001B, "frame CS")
		expect(m.mem:read16(0x9000 + 0x0FEC) == 0x0F00, "frame old SP")
		expect(m.mem:read16(0x9000 + 0x0FEE) == 0x0023, "frame old SS")
		expect(not cpu:getF(512), "interrupt gate did not clear IF")
		m:run(1) -- IRET back to ring 3
		expect(cpu.cs == 0x1B, "IRET CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.ss == 0x23, "IRET SS=" .. string.format("%04X", cpu.ss))
		expect(cpu.ip == 0x0500, "IRET IP=" .. string.format("%04X", cpu.ip))
		expect(cpu.r[5] == 0x0F00, "IRET SP=" .. string.format("%04X", cpu.r[5]))
		expect(cpu:getF(512), "IRET did not restore IF")
	end,
})

T("pm_int_bad_idt_limit_triple_fault", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.cr0 = 1
		m.cpu.idtr = { base = 0x7200, limit = 0 } -- vector 3 outside limit
	end,
	check = function(_m, cpu, expect)
		cpu:interrupt(3, nil, true)
		expect(cpu.tripleFaults == 1, "triple faults=" .. tostring(cpu.tripleFaults))
		expect(cpu.cr0 == 0, "CR0 after reset=" .. string.format("%X", cpu.cr0))
		expect(cpu.cs == 0xF000 and cpu.ip == 0xFFF0, "reset vector")
	end,
})

T("pm_int_bad_gate_target_named", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		m.cpu.idtr = { base = 0x7200, limit = 0x07FF }
		writeGate(m, 0x7200 + 3 * 8, 0x0200, 0x0040, 0x8E) -- absent target 0040
	end,
	check = function(_m, cpu, expect)
		local ok, err = pcall(function()
			cpu:interrupt(3, nil, true)
		end)
		expect(not ok, "bad gate target did not fault")
		expect(
			string.find(tostring(err), "target selector 0040", 1, true) ~= nil,
			"fault text=" .. tostring(err)
		)
	end,
})

T("pm_zero_lidt_selects_compact_idt", {
	config = LEVEL_386,
	steps = 1,
	setup = function(m)
		putCode(m, { 0x0F, 0x01, 0x1E, 0x00, 0x03 }) -- LIDT [0x300]
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu:loadSeg("ds", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		m.cpu.idtr = { base = 0x110000, limit = 0x07FF }
		m.cpu.cr0 = 1
		putData(m, 0x300, { 0, 0, 0, 0, 0, 0 })
		-- compact 8-entry table at live base+0x470; vector 3 default stub
		m.mem:write16(0x110488, 0x0C63)
		m.mem:write16(0x11048A, 0x0053)
		m.mem:write8(0x11048C, 0)
		m.mem:write8(0x11048D, 0xE6)
		m.mem:write16(0x11048E, 0)
	end,
	check = function(m, cpu, expect)
		expect(cpu.idtr.base == 0x110470, "IDTR base=" .. string.format("%X", cpu.idtr.base))
		expect(cpu.idtr.limit == 0x3F, "IDTR limit=" .. string.format("%X", cpu.idtr.limit))
		expect(m.mem:read16(0x110488) == 0x0C63, "compact vector offset")
		expect(m.mem:read16(0x11048A) == 0x0078, "compact vector selector")
		expect(m.mem:read8(0x11048D) == 0xE6, "compact vector access")
	end,
})

T("pm_zero_lidt_286_triple_fault", {
	config = LEVEL_286,
	steps = 2,
	setup = function(m)
		putCode(m, { 0x0F, 0x01, 0x1E, 0x00, 0x03, 0xCC }) -- LIDT [0x300]; INT3
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu:loadSeg("ds", 0x600)
		m.cpu.gdtr = { base = 0x7000, limit = 0x3F }
		m.cpu.idtr = { base = 0x110000, limit = 0x07FF }
		m.cpu.cr0 = 1
		putData(m, 0x300, { 0, 0, 0, 0, 0, 0 })
	end,
	check = function(_m, cpu, expect)
		expect(cpu.tripleFaults == 1, "triple faults=" .. tostring(cpu.tripleFaults))
		expect(cpu.cr0 == 0, "CR0 after reset=" .. string.format("%X", cpu.cr0))
		expect(cpu.idtr.base == 0 and cpu.idtr.limit == 0, "IDTR after reset")
		expect(cpu.cs == 0xF000 and cpu.ip == 0xFFF0, "reset vector")
	end,
})

T("pm_clear_pe_real_segment_load", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu:loadSeg("ds", 0x600)
		m.cpu.cr0 = 1
	end,
	check = function(m, cpu, expect)
		cpu:setPE(false)
		expect(band(cpu.cr0, 1) == 0, "PE still set")
		cpu:loadSeg("es", 0x3838)
		expect(cpu.es == 0x3838, "ES selector")
		expect(cpu.segBase.es == 0x38380, "ES base=" .. string.format("%X", cpu.segBase.es))
		expect(cpu.segLimit.es == 0xFFFF, "ES limit")
		cpu:loadSeg("cs", 0x3838)
		expect(cpu.segBase.cs == 0x38380, "CS base after real reload")
		m.mem:write8(0x38380, 0xF4)
		cpu.ip = 0
		m:run(1)
		expect(cpu.halted, "real-mode fetch after CS reload did not run")
	end,
})

T("pm_switch_helper_clears_pe_and_reloads_real_cs", {
	config = LEVEL_386,
	steps = 15,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x7F }
		writeDescriptor(m, 0x7000 + 0x78, 0xFFFF, 0x38380, 0x9A, 0) -- CS 0078
		writeDescriptor(m, 0x7000 + 0x48, 0xFFFF, 0x340D0, 0xF2, 0) -- DS 004B
		writeDescriptor(m, 0x7000 + 0x68, 0xFFFF, 0x340D0, 0xF2, 0) -- SS 0068
		m.cpu:loadSeg("cs", 0x78)
		m.cpu:loadSeg("ds", 0x4B)
		m.cpu:loadSeg("ss", 0x68)
		m.cpu.ip = 0x0C63
		m.cpu.r[5] = 0xFFF8
		m.cpu.r[1] = 0x34FF -- EAX saved by the helper
		m.cpu.r[3] = 0x0003 -- DX saved by the helper
		m.cpu.idtr = { base = 0x110470, limit = 0x3F }
		m.mem:write16(0x38380, 0x340D) -- CS:[0] real-mode paragraph
		m.mem:write16(0x440C8, 0x0C90) -- RET target (SS:0xFFF8)
		putBytes(m, 0x341F2, { 0, 0, 0, 0, 0, 0 }) -- zero LIDT [DS:0x122]
		putBytes(m, 0x38FE3, {
			0x52, -- PUSH DX
			0x66,
			0x50, -- PUSH EAX
			0x2E,
			0x8B,
			0x16,
			0x00,
			0x00, -- MOV DX,CS:[0]
			0x0F,
			0x20,
			0xC0, -- MOV EAX,CR0
			0x24,
			0xFE, -- AND AL,FE
			0x0F,
			0x01,
			0x1E,
			0x22,
			0x01, -- LIDT [0x122]
			0x0F,
			0x22,
			0xC0, -- MOV CR0,EAX
			0xEA,
			0x7D,
			0x0C,
			0x38,
			0x38, -- LJMP 3838:0C7D
			0x8E,
			0xD2, -- MOV SS,DX
			0x8E,
			0xDA, -- MOV DS,DX
			0x8E,
			0xC2, -- MOV ES,DX
			0x66,
			0x58, -- POP EAX
			0x5A, -- POP DX
			0xC3, -- RET
		})
		m.mem:write8(0x39010, 0xF4) -- HLT at 3838:0C90
	end,
	check = function(_m, cpu, expect)
		expect(band(cpu.cr0, 1) == 0, "CR0=" .. string.format("%X", cpu.cr0))
		expect(cpu.cs == 0x3838, "CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.segBase.cs == 0x38380, "CS base=" .. string.format("%X", cpu.segBase.cs))
		expect(cpu.ds == 0x340D and cpu.es == 0x340D and cpu.ss == 0x340D, "real DS/ES/SS")
		expect(cpu.segBase.ds == 0x340D0, "DS base=" .. string.format("%X", cpu.segBase.ds))
		expect(cpu:rr32(0) == 0x34FF, "EAX=" .. string.format("%X", cpu:rr32(0)))
		expect(cpu.r[3] == 0x0003, "DX=" .. string.format("%04X", cpu.r[3]))
		expect(cpu.r[5] == 0xFFFA, "SP=" .. string.format("%04X", cpu.r[5]))
		expect(cpu.idtr.base == 0x110470 and cpu.idtr.limit == 0x3F, "zero LIDT kept compact IDT")
		expect(cpu.halted, "RET target did not run")
	end,
})

T("pm_int3_near_ret_pops_saved_cs", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cpu.gdtr = { base = 0x7000, limit = 0x1F }
		writeDescriptor(m, 0x7008, 0xFFFF, 0x6000, 0x9A, 0)
		writeDescriptor(m, 0x7010, 0xFFFF, 0x9000, 0x92, 0)
		m.cpu.idtr = { base = 0x7200, limit = 0x07FF }
		writeGate(m, 0x7200 + 3 * 8, 0x0101, 0x0008, 0x8E)
		m.cpu:loadSeg("cs", 0x08)
		m.cpu:loadSeg("ss", 0x10)
		m.cpu.r[5] = 0x1000
		m.mem:write8(0x6100, 0xCC) -- INT3
		m.mem:write8(0x6101, 0xC3) -- RET, same address as the saved IP
		m.cpu.ip = 0x0100
	end,
	check = function(m, cpu, expect)
		m:run(1) -- INT3 pushes FLAGS, CS, IP
		expect(cpu.ip == 0x0101, "INT3 target IP=" .. string.format("%04X", cpu.ip))
		expect(cpu.r[5] == 0x0FFA, "INT3 SP=" .. string.format("%04X", cpu.r[5]))
		expect(m.mem:read16(0x9000 + 0x0FFA) == 0x0101, "saved IP")
		expect(m.mem:read16(0x9000 + 0x0FFC) == 0x0008, "saved CS")
		m:run(1) -- near RET pops the saved IP; CS remains
		expect(cpu.ip == 0x0101 and cpu.cs == 0x0008, "near RET self-return")
		expect(cpu.r[5] == 0x0FFC, "near RET SP=" .. string.format("%04X", cpu.r[5]))
		m:run(1) -- next near RET pops the saved CS as IP
		expect(cpu.ip == 0x0008, "second near RET IP=" .. string.format("%04X", cpu.ip))
		expect(cpu.cs == 0x0008, "second near RET CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.r[5] == 0x0FFE, "second near RET SP=" .. string.format("%04X", cpu.r[5]))
	end,
})

T("mov_cr0_clear_pe", {
	config = LEVEL_386,
	setup = function(m)
		putCode(m, { 0x66, 0x0F, 0x22, 0xC0 }) -- MOV CR0,EAX (EAX=0)
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu:wr32(0, 0)
		m.cpu.cr0 = 1
	end,
	check = function(m, cpu, expect)
		m:run(1)
		expect(band(cpu.cr0, 1) == 0, "CR0=" .. string.format("%X", cpu.cr0))
		cpu:loadSeg("es", 0x3838)
		expect(cpu.segBase.es == 0x38380, "ES base after MOV CR0 clear")
	end,
})

T("lmsW_clear_pe", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x00, 0x00, 0x0F, 0x01, 0xF0 }) -- MOV AX,0; LMSW AX
		fresh(m)
		m.cpu:loadSeg("cs", 0x600)
		m.cpu.cr0 = 1
	end,
	check = function(m, cpu, expect)
		m:run(2)
		expect(band(cpu.cr0, 1) == 0, "CR0=" .. string.format("%X", cpu.cr0))
		cpu:loadSeg("ds", 0x3838)
		expect(cpu.segBase.ds == 0x38380, "DS base after LMSW clear")
	end,
})

T("mov_cr0_386", {
	config = LEVEL_386,
	setup = function(m)
		putCode(m, { 0x66, 0x0F, 0x20, 0xC0, 0x66, 0x0F, 0x22, 0xC0 })
		fresh(m)
		m.cpu.cr0 = 0x00000010
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rr32(0) == 0x10, "EAX=" .. string.format("%X", cpu:rr32(0)))
		expect(cpu.cr0 == 0x10, "CR0=" .. string.format("%X", cpu.cr0))
	end,
})

T("movzx_movsx_386", {
	config = LEVEL_386,
	setup = function(m)
		putCode(m, { 0xB3, 0xFF, 0x0F, 0xB6, 0xC3, 0x66, 0x0F, 0xBE, 0xC3 })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rr32(0) == 0xFFFFFFFF, "EAX=" .. string.format("%X", cpu:rr32(0)))
	end,
})

T("pm_shutdown_09_restores_frame", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cmos[0x0F] = 0x09
		m.mem.a20 = true
		m.xms.a20 = true
		m.mem:write16(0x467, 0x00DE)
		m.mem:write16(0x469, 0x340D)
		m.mem:write16(0x341AE, 0x340D) -- saved DS
		m.mem:write16(0x341B0, 0x340D) -- saved ES
		for index = 0, 7 do -- PUSHAW frame
			m.mem:write16(0x341B2 + index * 2, 0)
		end
		m.mem:write16(0x341C2, 0x0C13)
		m.mem:write16(0x341C4, 0x3838)
		m.mem:write16(0x341C6, 0x0046)
	end,
	check = function(m, cpu, expect)
		m:shutdownResume(cpu)
		expect(cpu.cs == 0x3838, "CS=" .. string.format("%04X", cpu.cs))
		expect(cpu.ip == 0x0C13, "IP=" .. string.format("%04X", cpu.ip))
		expect(cpu.ss == 0x340D, "SS=" .. string.format("%04X", cpu.ss))
		expect(cpu.r[5] == 0x00F8, "SP=" .. string.format("%04X", cpu.r[5]))
		expect(cpu.ds == 0x340D and cpu.es == 0x340D, "DS/ES restored")
		expect(not m.mem.a20 and not m.xms.a20, "09h must disable A20")
		expect(m.cmos[0x0F] == 0, "shutdown status cleared")
	end,
})

T("pm_shutdown_0a_preserves_a20", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		fresh(m)
		m.cpu.cr0 = 1
		m.cmos[0x0F] = 0x0A
		m.mem.a20 = true
		m.xms.a20 = true
		m.mem:write16(0x467, 0x0C05)
		m.mem:write16(0x469, 0x3838)
	end,
	check = function(m, cpu, expect)
		m:shutdownResume(cpu)
		expect(cpu.cs == 0x3838 and cpu.ip == 0x0C05, "SHUTA CS:IP")
		expect(m.mem.a20 and m.xms.a20, "0Ah must preserve A20")
	end,
})

T("mov_cr0_286_invalid", {
	config = LEVEL_286,
	steps = 0,
	setup = function(m)
		putCode(m, { 0x0F, 0x20, 0xC0 }) -- MOV EAX,CR0 (386 only)
		fresh(m)
	end,
	check = function(m, _cpu, expect)
		local ok, err = pcall(function()
			m:run(1)
		end)
		expect(not ok, "286 MOV CR0 did not fault")
		expect(string.find(tostring(err), "#UD", 1, true) ~= nil, "fault=" .. tostring(err))
	end,
})

return TESTS
