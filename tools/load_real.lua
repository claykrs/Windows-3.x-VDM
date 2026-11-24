--!nonstrict
-- load_real.lua -- load the genuine Windows 3.0a core through the NE loader:
-- KERNEL, the six drivers from SYSTEM.INI, GDI and USER, with recursive import
-- resolution. This is the R2 validation that the real Windows core sits in
-- emulated memory with every import resolved.

const fs = require("@lune/fs")
const Harness = require("./harness")
const Executables = require("../core/Executables")

const STAGED = "media/win30/staged"

-- module name -> staged file (DISPLAY maps to the VGA driver per SYSTEM.INI)
const ALIASES: { [string]: string } = { DISPLAY = "VGA.DRV" }

local function fileFor(name: string): string?
	const direct = STAGED .. "/" .. name
	if fs.isFile(direct) then
		return direct
	end
	for _, extension in { ".EXE", ".DRV", ".DLL" } do
		const path = STAGED .. "/" .. name .. extension
		if fs.isFile(path) then
			return path
		end
	end
	return nil
end

type Loaded = { name: string, module: any }

const machine = Harness.newMachine()
const loaded: { Loaded } = {}

local function loadModule(name: string): any
	const key = string.upper(name)
	if machine.winImages[key] then
		return machine.winImages[key]
	end
	const file = fileFor(ALIASES[key] or name)
	if not file then
		error("no staged file for module " .. name)
	end
	const data = fs.readFile(file)
	const module = Executables.loadNEImage(machine, buffer.fromstring(data), key)
	loaded[#loaded + 1] = { name = key, module = module }
	for _, imported in module.importedNames or {} do
		loadModule(imported)
	end
	return module
end

const ok, err = pcall(function()
	loadModule("KERNEL")
	-- drivers before GDI/USER: their imports resolve when each image loads
	for _, driver in
		{ "KEYBOARD.DRV", "MOUSE.DRV", "SOUND.DRV", "SYSTEM.DRV", "COMM.DRV", "VGA.DRV" }
	do
		loadModule(driver)
	end
	loadModule("GDI")
	loadModule("USER")
end)

for _, record in loaded do
	const module = record.module
	local exports = 0
	for _ in pairs(module.entries) do
		exports += 1
	end
	print(
		("%-14s %2d segs  entry=%d:%04X  DGROUP=%s  %3d ordinals"):format(
			record.name,
			#module.segBases,
			module.entrySeg,
			module.entryOff,
			module.dgroup and ("%#x"):format(module.dgroup) or "none",
			exports
		)
	)
end
if ok then
	print(("Windows 3.0a core modules fully loaded (%d modules)"):format(#loaded))
else
	print("FAILED: " .. tostring(err))
end
