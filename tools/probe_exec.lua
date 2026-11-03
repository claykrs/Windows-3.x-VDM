local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vfs = require("../core/Vfs")
local Bios = require("../core/Bios")
local Dos = require("../core/Dos")
local TextScreen = require("../core/TextScreen")
local Executables = require("../core/Executables")
local Machine = require("../core/Machine")

local deps = {
	Memory = Memory,
	Cpu = Cpu,
	Vfs = Vfs,
	Bios = Bios,
	Dos = Dos,
	TextScreen = TextScreen,
	Executables = Executables,
}
local m = Machine.new(deps)
m.vfs:writeFile("C:\\X.COM", "\205\32")
m.dos.cwd = "C:\\"
local paramBase = 0x50000
m.mem:write16(paramBase + 0, 0)
m.mem:write16(paramBase + 2, 0x0100)
m.mem:write16(paramBase + 4, 0x6000)
m.mem:write8(0x60000 + 0x0100, 5)
m.mem:writeString(0x60000 + 0x0101, " A B ")
m.cpu.ds = 0x7000
m.cpu.r[3] = 0
m.mem:writeString(0x70000, "C:\\X.COM")
m.mem:write8(0x70008, 0)
m.cpu.es = 0x5000
m.cpu.r[4] = 0
print("read path", m.vfs:readFile("C:\\X.COM") ~= nil)
print("mem path", m.mem:readString(0x70000, 8))
Dos.FN[0x4B](m.dos, m.cpu, m)
print("CF", m.cpu:getF(1), "AX", m.cpu.r[1])
print("psp", m.pspSeg)
print("tail len at 1080", m.mem:read8(0x1080))
print("tail", m.mem:readString(0x1081, 6))
print("diag", m.diagnostics[#m.diagnostics])
