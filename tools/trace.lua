--!nonstrict
-- trace.lua -- single-step trace of a fixture binary (debug tool).
-- Usage: lune run tools/trace.lua [name] [steps]

const process = require("@lune/process")
const Harness = require("./harness")

const name = process.args[1] or "FIB.COM"
const budget = tonumber(process.args[2]) or 150

const machine = Harness.newMachine()
machine.vfs:writeFile("C:\\TEXT.TXT", "seed\r\n")
Harness.loadBinary(machine, name)
const cpu = machine.cpu

for step = 1, budget do
	if cpu.halted then
		print("HALTED at step " .. step)
		break
	end
	const physical = bit32.lshift(cpu.cs, 4) + cpu.ip
	print(
		("%3d %04X:%04X op=%02X AX=%04X BX=%04X CX=%04X DX=%04X SP=%04X SI=%04X DI=%04X fl=%04X"):format(
			step,
			cpu.cs,
			cpu.ip,
			machine.mem:read8(physical),
			cpu.r[1],
			cpu.r[4],
			cpu.r[2],
			cpu.r[3],
			cpu.r[5],
			cpu.r[7],
			cpu.r[8],
			cpu.flags
		)
	)
	cpu:step()
end
print("output: " .. machine:outputText())
