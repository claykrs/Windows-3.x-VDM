-- run.lua -- Lune test runner: CPU unit tests, app tests, throughput.

local process = require("@lune/process")

local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vfs = require("../core/Vfs")
local Bios = require("../core/Bios")
local Dos = require("../core/Dos")
local TextScreen = require("../core/TextScreen")
local Executables = require("../core/Executables")
local Vga = require("../core/Vga")
local Xms = require("../core/Xms")
local Machine = require("../core/Machine")
local cpuTests = require("../tests/CpuTests")
local pmCpuTests = require("../tests/PmCpuTests")
local xmsTests = require("../tests/XmsTests")
local machineTests = require("../tests/MachineTests")
local dosTests = require("../tests/DosTests")
local groupFileTests = require("../tests/GroupFileTests")
local apps = require("../fixtures/Apps")
local Kernel16 = require("../fixtures/Kernel16")
local TestApps = require("../fixtures/TestApps")

local deps = {
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

local passed, failures = 0, {}

local function expect(name)
	return function(cond, detail)
		if cond then
			passed += 1
		else
			failures[#failures + 1] = name .. (detail and (" -- " .. detail) or "")
		end
	end
end

local function mkMachine(config)
	local m = Machine.new(deps, config)
	m.vfs:writeFile("C:\\TEXT.TXT", "The quick brown fox jumps over the lazy dog.\r\n")
	return m
end

local function runCpuSuite(tests)
	for _, t in ipairs(tests) do
		local ok, err = pcall(function()
			local m = mkMachine(t.config)
			if t.setup then
				t.setup(m)
			end
			m:run(t.steps)
			t.check(m, m.cpu, expect(t.name))
		end)
		if not ok then
			failures[#failures + 1] = t.name .. " -- ERRORED: " .. tostring(err)
		end
	end
end

-- ============ CPU unit tests ============
runCpuSuite(cpuTests)
-- ============ 286/386 execution level ============
runCpuSuite(pmCpuTests)
-- ============ XMS/HIMEM ============
runCpuSuite(xmsTests)

-- ============ machine / DOS environment tests ============
do
	local ok, err = pcall(function()
		machineTests.run(mkMachine, expect)
	end)
	if not ok then
		failures[#failures + 1] = "machine tests -- ERRORED: " .. tostring(err)
	end
end

-- ============ DOS clock and handle ownership ============
do
	local ok, err = pcall(function()
		dosTests.run(mkMachine, expect)
	end)
	if not ok then
		failures[#failures + 1] = "dos tests -- ERRORED: " .. tostring(err)
	end
end

-- ============ Program Manager group file format ============
do
	local ok, err = pcall(function()
		groupFileTests.run(expect)
	end)
	if not ok then
		failures[#failures + 1] = "group file tests -- ERRORED: " .. tostring(err)
	end
end

-- ============ app-level tests ============
local function runApp(name, keys, budget)
	local m = mkMachine()
	if keys then
		m:pushKeys(keys)
	end
	m:loadCOM(buffer.fromstring(apps[name]))
	local total = 0
	while not m.cpu.halted and total < (budget or 5_000_000) do
		total += m:run(100_000)
	end
	return m, total
end

do
	local m = runApp("HELLO.COM")
	local e = expect("app_hello")
	e(m:outputText() == "Hello from a real 8086 inside Roblox Luau!", m:outputText())
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

do
	local m = runApp("FIB.COM")
	local e = expect("app_fib")
	local want = "0 1 1 2 3 5 8 13 21 34 55 89 "
	e(m:outputText() == want, "output=" .. m:outputText())
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

do
	local m = runApp("ECHO.COM", "hi\r")
	local e = expect("app_echo")
	e(m:outputText() == "hi\r\n", "output=" .. m:outputText())
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

do
	local m = runApp("CAT.COM")
	local e = expect("app_cat")
	e(
		m:outputText() == "The quick brown fox jumps over the lazy dog.\r\n",
		"output=" .. m:outputText()
	)
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

do
	-- MZ loader + relocation proof: patched word = load segment 0x1010 = 4112
	local m = mkMachine()
	local e = expect("app_mzdemo")
	m:loadMZ(buffer.fromstring(apps["MZDEMO.EXE"]))
	local total = 0
	while not m.cpu.halted and total < 1_000_000 do
		total += m:run(100_000)
	end
	e(m:outputText() == "4112", "output=" .. m:outputText())
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

-- NE: two-segment NE with entry-table entry, prints from segment 0
do
	local m = mkMachine()
	local e = expect("app_ne2")
	m:loadNE(buffer.fromstring(apps["NE2.EXE"]))
	local total = 0
	while not m.cpu.halted and total < 1_000_000 do
		total += m:run(100_000)
	end
	e(m:outputText() == "NE2 OK", "output=" .. m:outputText())
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

-- NE3: Win16 imports — KERNEL.#1 (PrintString) via an import-thunk far call
do
	local m = mkMachine()
	local e = expect("app_ne3")
	Kernel16.register(m, {})
	TestApps.register(m) -- PrintString lands at KERNEL#300
	m:loadNE(buffer.fromstring(apps["NE3.EXE"]))
	local total = 0
	while not m.cpu.halted and total < 1_000_000 do
		total += m:run(100_000)
	end
	local out = m:outputText()
	e(string.find(out, "KERNEL #300 called!", 1, true) ~= nil, "output=" .. out)
	e(string.find(out, "back in NE3, exit ok", 1, true) ~= nil, "no return path: " .. out)
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

-- NE4: real KERNEL ordinals — GetVersion, GlobalAlloc/Lock/Unlock/Free,
-- PrintString through the Win16 import-thunk machinery
do
	local m = mkMachine()
	local e = expect("app_ne4")
	Kernel16.register(m, {})
	TestApps.register(m)
	m:loadNE(buffer.fromstring(apps["NE4.EXE"]))
	local total = 0
	while not m.cpu.halted and total < 2_000_000 do
		total += m:run(100_000)
	end
	local out = m:outputText()
	-- handle value varies with the unified allocator; verify shape instead
	local handle = string.match(out, "\r\n(%x%x%x%x)\r\n")
	e(handle ~= nil, "no GlobalAlloc handle line in: " .. out)
	for _, want in ipairs({ "NE4 KERNEL test", "0003", "0000", "Hi from alloc", "done" }) do
		e(string.find(out, want, 1, true) ~= nil, "missing [" .. want .. "] in: " .. out)
	end
	e(m.exitCode == 0, "exitCode=" .. tostring(m.exitCode))
end

-- keyboard blocking: echo waits, pushKeys resumes mid-run, waits again for CR
do
	local m = mkMachine()
	m:loadCOM(buffer.fromstring(apps["ECHO.COM"]))
	local e = expect("app_echo_blocking")
	m:run(50_000)
	e(m.cpu.halted and m.waiting == "keyboard", "did not block on keyboard")
	m:pushKeys("ok")
	m:run(100_000)
	e(m.cpu.halted and m.waiting == "keyboard", "did not block again for CR")
	m:pushKeys("\r")
	m:run(100_000)
	e(m:outputText() == "ok\r\n", "output=" .. m:outputText())
end

-- ============ throughput ============
local m = mkMachine()
m:loadCOM(buffer.fromstring(apps["FIB.COM"]))
local bench = os.clock()
local benchSteps = m:run(2_000_000)
local elapsed = os.clock() - bench
local opsPerSec = math.floor(benchSteps / elapsed)

-- ============ summary ============
print(("passed assertions: %d"):format(passed))
if #failures > 0 then
	print(("FAILURES (%d):"):format(#failures))
	for _, f in ipairs(failures) do
		print("  " .. f)
	end
else
	print("ALL TESTS PASSED")
end
print(("throughput: %d emulated instr/sec (fib workload, Lune/JIT)"):format(opsPerSec))

-- show the emulated screen after hello ran
do
	local m = runApp("HELLO.COM")
	local screen = m:screenText()
	print("--- emulated screen (after HELLO.COM) ---")
	print(screen)
end

process.exit(#failures > 0 and 1 or 0)
