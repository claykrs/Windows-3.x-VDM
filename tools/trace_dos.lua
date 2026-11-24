--!nonstrict
-- trace_dos.lua -- boot WIN.COM and record DOS INT 21 calls + arena activity.
-- Prints the last N calls when the guest halts or faults.
-- Usage: lune run tools/trace_dos.lua [--last N] [--steps N] [--filter AH]

const process = require("@lune/process")
const Harness = require("./harness")
const Dos = require("../core/Dos")
const Install = require("./install")

const args = process.args
local last = 40
local budget = 40_000_000
local filter: string? = nil
for index, value in args do
	if value == "--last" then
		last = tonumber(args[index + 1]) or last
	elseif value == "--steps" then
		budget = tonumber(args[index + 1]) or budget
	elseif value == "--filter" then
		filter = string.upper(args[index + 1] or "")
	end
end

const machine = Harness.newMachine()
Install.seed(machine)
Install.writeSystemIni(machine)
const winCom = machine.vfs:readFile("C:\\WINDOWS\\WIN.COM")
machine.dos.cwd = "C:\\WINDOWS"
machine.vfs.cwd = "C:\\WINDOWS"
machine:loadCOM(buffer.fromstring(winCom), nil, "C:\\WINDOWS\\WIN.COM")

type Entry = { text: string }
const trail: { Entry } = {}
local callCount = 0

local function push(text: string)
	trail[#trail + 1] = { text = text }
	if #trail > last then
		table.remove(trail, 1)
	end
end

const realInt21 = Dos.int21
Dos.int21 = function(self)
	const cpu = self.machine.cpu
	const number = bit32.band(bit32.rshift(cpu.r[1], 8), 0xFF)
	-- call site: the INT 21h instruction (2 bytes) that got us here
	const siteCs = cpu.cs
	const siteIp = bit32.band(cpu.ip - 2, 0xFFFF)
	local path = ""
	if number == 0x3C or number == 0x3D or number == 0x41 or number == 0x43 or number == 0x4B then
		const base = bit32.band(bit32.lshift(cpu.ds, 4) + cpu.r[3], 0xFFFFF)
		local chars = {}
		for index = 0, 127 do
			const byte = machine.mem:read8(base + index)
			if byte == 0 then
				break
			end
			chars[#chars + 1] = string.char(byte)
		end
		path = ' "' .. table.concat(chars) .. '"'
	end
	const before = ("AX=%04X BX=%04X CX=%04X DX=%04X DS=%04X%s"):format(
		cpu.r[1],
		cpu.r[4],
		cpu.r[2],
		cpu.r[3],
		cpu.ds,
		path
	)
	realInt21(self)
	callCount += 1
	if filter and ("%02X"):format(number) ~= filter then
		return
	end
	push(
		("%04X:%04X AH=%02X %s -> AX=%04X BX=%04X CF=%s"):format(
			siteCs,
			siteIp,
			number,
			before,
			cpu.r[1],
			cpu.r[4],
			tostring(cpu:getF(1))
		)
	)
end

const realAlloc = machine.dosAlloc
machine.dosAlloc = function(self, paras: number): number?
	const segment = realAlloc(self, paras)
	push(
		("alloc %d paras -> %s (largest %d)"):format(
			paras,
			segment and ("%04X"):format(segment) or "FAIL",
			self:dosLargest()
		)
	)
	return segment
end
const realFree = machine.dosFree
machine.dosFree = function(self, segment: number): boolean
	const freed = realFree(self, segment)
	push(("free %04X -> %s"):format(segment, tostring(freed)))
	return freed
end

local steps = 0
const ok, err = pcall(function()
	while steps < budget and not machine.cpu.halted do
		steps += machine:run(50_000)
	end
end)

print(
	("steps=%d halted=%s exit=%s calls=%d"):format(
		steps,
		tostring(machine.cpu.halted),
		tostring(machine.exitCode),
		callCount
	)
)
print(("final CS:IP=%04X:%04X"):format(machine.cpu.cs, machine.cpu.ip))
if not ok then
	print("ERRORED: " .. tostring(err))
end
for _, entry in trail do
	print("  " .. entry.text)
end
print("output: " .. machine:outputText())
