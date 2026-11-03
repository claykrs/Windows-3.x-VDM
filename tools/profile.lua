--!nonstrict
-- profile.lua -- run the WIN.COM boot and sample CS:IP to find hot spots
-- (polling loops show up immediately). Usage: lune run tools/profile.lua [steps]

const process = require("@lune/process")
const Harness = require("./harness")
const Install = require("./install")

const machine = Harness.newMachine()
Install.seed(machine)
Install.writeSystemIni(machine)
const winCom = machine.vfs:readFile("C:\\WINDOWS\\WIN.COM")
machine.dos.cwd = "C:\\WINDOWS"
machine.vfs.cwd = "C:\\WINDOWS"
machine:loadCOM(buffer.fromstring(winCom), nil, "C:\\WINDOWS\\WIN.COM")

const budget = tonumber(process.args[1]) or 20_000_000
const samples: { [string]: number } = {}
local total = 0
const ok, err = pcall(function()
	while total < budget and not machine.cpu.halted do
		const count = machine:run(50_000)
		total += count
		const key = ("%04X:%04X"):format(machine.cpu.cs, machine.cpu.ip)
		samples[key] = (samples[key] or 0) + count
	end
end)
if not ok then
	print("STOPPED: " .. tostring(err))
end

type Sample = { key: string, count: number }
const list: { Sample } = {}
for key, value in samples do
	list[#list + 1] = { key = key, count = value }
end
table.sort(list, function(a, b)
	return a.count > b.count
end)
print(("total steps %d, hot spots (cs:ip -> steps):"):format(total))
for index = 1, math.min(12, #list) do
	print(
		("  %s  %d (%.1f%%)"):format(
			list[index].key,
			list[index].count,
			100 * list[index].count / total
		)
	)
end
print("output: " .. machine:outputText())
