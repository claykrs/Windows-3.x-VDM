--!nonstrict
-- harness.lua -- shared Lune-side wiring for tools and the test runner.

const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Vfs = require("../core/Vfs")
const Bios = require("../core/Bios")
const Dos = require("../core/Dos")
const TextScreen = require("../core/TextScreen")
const Executables = require("../core/Executables")
const Vga = require("../core/Vga")
const Xms = require("../core/Xms")
const Machine = require("../core/Machine")

const Harness = {}

Harness.deps = {
	Memory = Memory,
	Cpu = Cpu,
	Vfs = Vfs,
	Bios = Bios,
	Dos = Dos,
	TextScreen = TextScreen,
	Executables = Executables,
	Vga = Vga,
	Xms = Xms,
}

function Harness.newMachine(config: any?): any
	return Machine.new(Harness.deps, config)
end

-- load an app fixture by name from fixtures/Apps (COM, MZ or NE)
function Harness.loadBinary(machine: any, name: string)
	const apps = require("../fixtures/Apps")
	const data = apps[name]
	if not data then
		error("no such fixture: " .. name)
	end
	const bytes = buffer.fromstring(data)
	const isMZ = buffer.readu8(bytes, 0) == 0x4D and buffer.readu8(bytes, 1) == 0x5A
	if isMZ then
		const neOff = buffer.readu32(bytes, 0x3C)
		const isNE = neOff + 1 < buffer.len(bytes)
			and buffer.readu8(bytes, neOff) == 0x4E
			and buffer.readu8(bytes, neOff + 1) == 0x45
		if isNE then
			machine:loadNE(bytes)
		else
			machine:loadMZ(bytes)
		end
	else
		machine:loadCOM(bytes)
	end
end

return Harness
