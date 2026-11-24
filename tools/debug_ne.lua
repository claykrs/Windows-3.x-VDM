--!nonstrict
-- debug_ne.lua -- dump the entry state and first instructions of a NE fixture.
-- Usage: lune run tools/debug_ne.lua [name]

const process = require("@lune/process")
const Harness = require("./harness")
const Kernel16 = require("../fixtures/Kernel16")
const TestApps = require("../fixtures/TestApps")

const name = process.args[1] or "NE4.EXE"
const machine = Harness.newMachine()
Kernel16.register(machine, {})
TestApps.register(machine)
Harness.loadBinary(machine, name)

const cpu = machine.cpu
print(("entry CS=%04X IP=%04X"):format(cpu.cs, cpu.ip))
local bytes: { string } = {}
for index = 0, 47 do
	bytes[#bytes + 1] = ("%02X"):format(machine.mem:read8(machine.mem.phys(cpu.cs, index)))
end
print("code: " .. table.concat(bytes, " "))

for step = 1, 40 do
	if cpu.halted then
		break
	end
	print(
		("%2d %04X:%04X AX=%04X DX=%04X SP=%04X out=%s"):format(
			step,
			cpu.cs,
			cpu.ip,
			cpu.r[1],
			cpu.r[3],
			cpu.r[5],
			(string.gsub(machine:outputText(), "\r\n", "|"))
		)
	)
	cpu:step()
end
