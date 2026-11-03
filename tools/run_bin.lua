--!nonstrict
-- run_bin.lua -- run any fixtures/Apps binary and report output or the failure
-- point. Usage: lune run tools/run_bin.lua [name] [--steps N]

const fs = require("@lune/fs")
const process = require("@lune/process")
const Harness = require("./harness")

const args = process.args
local name = "HELLO.COM"
local steps = 2_000_000
for index, value in args do
	if value == "--steps" then
		steps = tonumber(args[index + 1]) or steps
	elseif not string.find(value, "^%-%-") and not tonumber(args[index - 1]) then
		name = value
	end
end

const machine = Harness.newMachine()
machine.vfs:writeFile("C:\\TEXT.TXT", "seed file\r\n")
machine.vfs:writeFile("C:\\AUTOEXEC.BAT", "@ECHO OFF\r\n")
const ok, err = pcall(function()
	Harness.loadBinary(machine, name)
	machine:run(steps)
end)

print("=== " .. name .. " ===")
print("halted: " .. tostring(machine.cpu.halted) .. "  exit: " .. tostring(machine.exitCode))
print("output: " .. machine:outputText())
if not ok then
	print("STOPPED: " .. tostring(err))
end
for _, line in machine.diagnostics do
	print("[diag] " .. line)
end
print("--- screen ---")
print(machine:screenText())

if not fs.isFile("fixtures/Apps.lua") then
	print("warning: fixtures/Apps.lua is missing; run tools/programs.lua")
end
