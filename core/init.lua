--!strict
-- init.lua -- the Vdm emulator as one Roblox ModuleScript tree.
-- Loaded through `require(ReplicatedStorage:WaitForChild("Vdm"))`; every
-- consumer uses this index instead of deep script.Parent chains.

const Vdm = {}

Vdm.Memory = require(script.Memory)
Vdm.Cpu = require(script.Cpu)
Vdm.Vfs = require(script.Vfs)
Vdm.Bios = require(script.Bios)
Vdm.Dos = require(script.Dos)
Vdm.TextScreen = require(script.TextScreen)
Vdm.Vga = require(script.Vga)
Vdm.Executables = require(script.Executables)
Vdm.Machine = require(script.Machine)

return Vdm
