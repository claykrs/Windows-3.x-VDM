--!nonstrict
-- DosTests.lua -- DOS behaviours that apps depend on beyond basic file I/O.
local Dos = require("../core/Dos")

const DosTests = {}

function DosTests.run(mkMachine, expect)
	do
		local m = mkMachine()
		local e = expect("dos_4c_on_kernel_created_psp_returns_to_caller")
		-- KERNEL creates a PSP per task with AH=55h and terminates it with
		-- AH=4Ch to free its memory. PSP:000A is the parent's (WIN.COM's)
		-- return address, so jumping there ended Windows on every app exit.
		m.cpu.dosxResident = true
		const parent = m.pspSeg or 0x1000
		m.mem:write16(parent * 16 + 0x0A, 0x0324)
		m.mem:write16(parent * 16 + 0x0C, 0x1861)
		m.cpu.r[3] = 0x2849
		m.cpu.r[7] = 0x9000
		Dos.FN[0x55](m.dos, m.cpu, m)
		m.cpu.r[4] = 0x2849
		Dos.FN[0x50](m.dos, m.cpu, m)
		m.cpu.cs, m.cpu.ip = 0x0100, 0x0200
		m.cpu.r[1] = 0x4C00
		Dos.FN[0x4C](m.dos, m.cpu, m)
		e(m.exitCode == nil, "machine must keep running")
		e(m.cpu.cs == 0x0100 and m.cpu.ip == 0x0200, "no jump to the parent's INT 22h address")
		e(m.dos.currentPsp == parent, "current PSP is the parent again")
	end

	do
		local m = mkMachine()
		local e = expect("dos_56_rename_file")
		-- Paintbrush renames its temp file on save; AH=56 was an
		-- unsupported-function host error.
		local function put(seg: number, off: number, text: string)
			const base = seg * 16 + off
			for index = 1, #text do
				m.mem:write8(base + index - 1, string.byte(text, index))
			end
			m.mem:write8(base + #text, 0)
		end
		m.vfs:writeFile("C:\\OLD.TMP", "data")
		put(m.cpu.ds, 0x200, "C:\\OLD.TMP")
		put(m.cpu.es, 0x300, "C:\\NEW.BMP")
		m.cpu.r[3] = 0x200
		m.cpu.r[8] = 0x300
		m.cpu.r[1] = 0x5600
		Dos.FN[0x56](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "rename succeeds")
		e(m.vfs:readFile("C:\\NEW.BMP") == "data", "content moved")
		e(m.vfs:readFile("C:\\OLD.TMP") == nil, "source gone")
		Dos.FN[0x56](m.dos, m.cpu, m)
		e(m.cpu:getF(1) and m.cpu.r[1] == 2, "missing source fails with 2")
	end

	do
		local m = mkMachine()
		local e = expect("dos_58_allocation_strategy")
		-- WINOLDAP (MS-DOS Prompt) saves/restores the allocation strategy;
		-- AH=58 was an unsupported-function host error.
		m.cpu.r[1] = 0x5800
		Dos.FN[0x58](m.dos, m.cpu, m)
		e(not m.cpu:getF(1) and m.cpu.r[1] == 0, "default first-fit")
		m.cpu.r[1] = 0x5801
		m.cpu.r[4] = 2
		Dos.FN[0x58](m.dos, m.cpu, m)
		m.cpu.r[1] = 0x5800
		Dos.FN[0x58](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 2, "strategy round trips")
		m.cpu.r[1] = 0x5803
		m.cpu.r[4] = 1
		Dos.FN[0x58](m.dos, m.cpu, m)
		m.cpu.r[1] = 0x5802
		Dos.FN[0x58](m.dos, m.cpu, m)
		e(m.cpu.r[1] % 256 == 1, "umb link round trips")
	end

	do
		local m = mkMachine()
		local e = expect("dos_59_get_extended_error")
		-- KRNL286 calls AH=59h after a failed file operation (Program Manager
		-- Run of CALC.EXE); it was an unsupported-function host error.
		const base = m.cpu.ds * 16 + 0x200
		const path = "C:\\NOPE\\NOFILE.TXT"
		for index = 1, #path do
			m.mem:write8(base + index - 1, string.byte(path, index))
		end
		m.mem:write8(base + #path, 0)
		m.cpu.r[3] = 0x200
		m.cpu.r[1] = 0x3D00
		Dos.FN[0x3D](m.dos, m.cpu, m)
		m.cpu.r[1] = 0x5900
		m.cpu.r[4] = 0
		Dos.FN[0x59](m.dos, m.cpu, m)
		e(
			m.cpu.r[1] == 2 or m.cpu.r[1] == 3,
			string.format("AX=%04X is a not-found code", m.cpu.r[1])
		)
		e(math.floor(m.cpu.r[4] / 256) == 8, "class 8 not found")
	end

	do
		local m = mkMachine()
		local e = expect("dos_4d_returns_child_code_in_al")
		-- WIN.COM calls AH=4Dh after the kernel exits and re-terminates with
		-- the returned AL; the old handler wrote CX instead of AX and left
		-- AL=FFh, which turned a clean Windows exit into exit code 255.
		m.lastChildCode = 0x00
		m.cpu.r[1] = 0x4DFF
		m.cpu.r[2] = 0x1234
		Dos.FN[0x4D](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0x0000, string.format("AX=%04X", m.cpu.r[1]))
		e(m.cpu.r[2] == 0x1234, "CX untouched")
		m.lastChildCode = 0x07
		Dos.FN[0x4D](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0x0007, "AL carries the child's exit code")
	end

	do
		local m = mkMachine()
		local e = expect("dosx_terminate_resumes_parent")
		-- R11: with the DOSX PM handoff done, terminating the RM shell jumps
		-- to the PSP:000A parent resume address instead of ending the machine.
		m.cpu.dosxResident = true
		m.pspSeg = m.pspSeg or 0x1000
		local beforeExit = m.exitCode
		m.mem:write16(m.pspSeg * 16 + 0x0A, 0x1861)
		m.mem:write16(m.pspSeg * 16 + 0x0C, 0x010B)
		Dos.FN[0x00](m.dos, m.cpu, m)
		e(beforeExit == nil and m.exitCode == nil, "machine must keep running")
		e(
			m.cpu.cs == 0x010B and m.cpu.ip == 0x1861,
			string.format("resume at %04X:%04X", m.cpu.cs, m.cpu.ip)
		)
	end

	do
		local m = mkMachine()
		local e = expect("dosx_root_terminate_does_not_loop")
		-- WIN.COM's exit path terminated through its own INT 22h address over
		-- and over after the kernel child exited 0xFF. The first terminate may
		-- resume the recorded address; a second one from the same live-less PSP
		-- is the root and must end the machine with its exit code.
		m.cpu.dosxResident = true
		m.pspSeg = 0x1861
		m.mem:write16(m.pspSeg * 16 + 0x0A, 0x0215)
		m.mem:write16(m.pspSeg * 16 + 0x0C, 0x1861)
		m.cpu.r[1] = 0x4CFF
		Dos.FN[0x4C](m.dos, m.cpu, m)
		e(
			m.exitCode == nil and m.cpu.cs == 0x1861 and m.cpu.ip == 0x0215,
			"first terminate resumes"
		)
		Dos.FN[0x4C](m.dos, m.cpu, m)
		e(m.exitCode == 0xFF, "second terminate from the same PSP exits the machine")
	end

	do
		local m = mkMachine()
		local e = expect("dosx_terminate_default_int22_exits")
		-- a PSP whose INT 22h still points at its own INT 20h has no parent
		m.cpu.dosxResident = true
		m.pspSeg = 0x1234
		m.mem:write16(m.pspSeg * 16 + 0x0A, 0)
		m.mem:write16(m.pspSeg * 16 + 0x0C, m.pspSeg)
		m.cpu.r[1] = 0x4C07
		Dos.FN[0x4C](m.dos, m.cpu, m)
		e(m.exitCode == 7, "default INT 22h exits with the AL code")
	end

	do
		local m = mkMachine()
		local e = expect("dos_plain_terminate_exits")
		-- without the PM handoff, terminate still ends the machine (3.0a path)
		Dos.FN[0x00](m.dos, m.cpu, m)
		e(m.exitCode == 0, "plain terminate exits with code 0")
	end

	do
		local m = mkMachine()
		local e = expect("dosx_terminate_without_resume_exits")
		-- DOSX resident but no parent address recorded: fail safe to exit
		m.cpu.dosxResident = true
		m.pspSeg = m.pspSeg or 0x1000
		m.mem:write16(m.pspSeg * 16 + 0x0A, 0)
		m.mem:write16(m.pspSeg * 16 + 0x0C, 0)
		m.cpu.r[1] = 0x4C
		Dos.FN[0x4C](m.dos, m.cpu, m)
		e(m.exitCode == 0x4C, "missing resume falls back to exit with AL code")
	end

	do
		local m = mkMachine()
		local e = expect("dos_clock_advances")
		m.mem:write16(0x46C, 0)
		Dos.FN[0x2C](m.dos, m.cpu, m)
		e(m.cpu:rb(5) == 12 and m.cpu:rb(1) == 0 and m.cpu:rb(6) == 0, "noon baseline")
		m.mem:write16(0x46C, 19)
		Dos.FN[0x2C](m.dos, m.cpu, m)
		e(m.cpu:rb(5) == 12 and m.cpu:rb(1) == 0 and m.cpu:rb(6) == 1, "clock did not advance")
	end

	do
		local m = mkMachine()
		local e = expect("dos_extended_fcb_and_path")
		m.vfs:ensureDir("C:\\TMP")
		m.vfs:writeFile("C:\\TMP\\A.TXT", "a")
		m.vfs:writeFile("C:\\TMP\\B.TXT", "bb")
		m.vfs:ensureDir("C:\\TMP\\SUB")
		m.dos.cwd = "C:\\TMP\\"
		m.cpu.ds = 0x9000
		m.dos.dtaSeg, m.dos.dtaOff = 0x9000, 0x0300
		local function putPath(text: string)
			for index = 0, 15 do
				m.mem:write8(0x90240 + index, 0)
			end
			m.mem:writeString(0x90240, text)
		end

		-- Extended FCB: FF, five reserved, attribute, drive, name/ext.
		m.mem:write8(0x90200, 0xFF)
		for index = 1, 5 do
			m.mem:write8(0x90200 + index, 0)
		end
		m.mem:write8(0x90206, 0x00)
		m.mem:write8(0x90207, 0)
		m.mem:writeString(0x90208, "???????????")
		m.cpu.r[3] = 0x0200
		Dos.FN[0x11](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0, "extended FCB find failed")
		e(m.mem:read8(0x90301) == string.byte("A"), "extended FCB name")

		-- A volume-label search must not return an ordinary file.
		m.mem:write8(0x90206, 0x08)
		Dos.FN[0x11](m.dos, m.cpu, m)
		e(m.cpu:rb(0) == 0xFF, "volume-label FCB search returned a file")

		-- Path-qualified DTA search must list the named directory with the
		-- real DOS layout: attr 15h, time 16h, date 18h, size 1Ah, name 1Eh.
		m.dos.dtaOff = 0x0400
		m.cpu.r[3] = 0x0240
		m.cpu.r[2] = 0
		putPath("C:\\TMP\\*.TXT")
		Dos.FN[0x4E](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0, "path find failed")
		e(m.mem:read8(0x90415) == 0x20, "DTA attribute offset")
		e(m.mem:read16(0x9041A) == 1, "DTA size low offset")
		e(m.mem:read8(0x9041E) == string.byte("A"), "DTA name offset")
		e(m.mem:read8(0x90423) == 0, "DTA name not NUL-terminated")
		Dos.FN[0x4F](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0 and m.mem:read8(0x9041E) == string.byte("B"), "path find next")

		-- Directories are returned only when the attribute mask asks for them.
		m.cpu.r[3] = 0x0240
		putPath("C:\\TMP\\SUB")
		Dos.FN[0x4E](m.dos, m.cpu, m)
		e(m.cpu.r[1] ~= 0, "directory returned without CX=10h")
		m.cpu.r[2] = 0x10
		Dos.FN[0x4E](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 0, "directory find with CX=10h failed")
		e(m.mem:read8(0x90415) == 0x10, "directory attribute")
		e(m.mem:read8(0x9041E) == string.byte("S"), "directory DTA name")

		-- No volume labels exist in the VFS.
		m.cpu.r[2] = 0x08
		putPath("C:\\TMP\\*.*")
		Dos.FN[0x4E](m.dos, m.cpu, m)
		e(m.cpu.r[1] ~= 0, "volume-label DTA search returned a file")
	end

	do
		local m = mkMachine()
		local e = expect("dos_get_cwd_ax")
		m.dos.cwd = "C:\\WINDOWS"
		m.cpu.ds = 0x9000
		m.cpu.r[7] = 0x0100
		Dos.FN[0x47](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "get-cwd failed")
		e(m.cpu.r[1] == 0x0100, "get-cwd must return AH=1/AL=0")
		e(m.mem:read8(0x90100) == string.byte("W"), "get-cwd buffer")
		e(m.mem:read8(0x90107) == 0, "get-cwd terminator")
	end

	do
		local m = mkMachine()
		local e = expect("dos_handle_owner")
		m.vfs:ensureDir("C:\\TMP")
		m.vfs:writeFile("C:\\TMP\\A.TXT", "a")
		m.cpu.ds = 0x9000
		m.cpu.r[3] = 0x0100
		m.mem:writeString(0x90100, "C:\\TMP\\A.TXT")
		m.dos.currentPsp = 0x1000
		Dos.FN[0x3D](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "open failed")
		const handle = m.cpu.r[1]
		e(m.dos.handles[handle].ownerPsp == 0x1000, "handle owner")
		m.dos.currentPsp = 0x2000
		m.cpu.r[4] = handle
		Dos.FN[0x3E](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "child close failed")
		e(m.dos.handles[handle] ~= nil, "child close freed the parent's handle")
		m.dos.currentPsp = 0x1000
		m.cpu.r[4] = handle
		m.cpu.r[2] = 1
		m.cpu.r[3] = 0x0120
		Dos.FN[0x3F](m.dos, m.cpu, m)
		e(m.cpu.r[1] == 1 and m.mem:read8(0x90120) == string.byte("a"), "parent handle unusable")
		m.cpu.r[4] = handle
		Dos.FN[0x3E](m.dos, m.cpu, m)
		e(m.dos.handles[handle] == nil, "owner close did not free the handle")
	end

	do
		local m = mkMachine()
		local e = expect("dos_allocation_info_1c")
		-- Win 3.1 KRNL286 calls AH=1Ch during startup; it must not be an
		-- unsupported-function error. DS:BX -> media ID byte, CX=bytes/sector.
		m.cpu.r[1] = 0x1C00
		m.cpu.r[3] = 0x0003 -- DL = drive C:
		Dos.FN[0x1C](m.dos, m.cpu, m)
		e(bit32.band(m.cpu.r[1], 0xFF) == 4, "AL sectors per cluster")
		e(m.cpu.r[2] == 512, "CX bytes per sector")
		e(m.cpu.r[3] ~= 0, "DX clusters")
		e(m.mem:read8(bit32.lshift(m.cpu.ds, 4) + m.cpu.r[4]) == 0xF8, "media ID byte")
		m.cpu.r[3] = 0x0019 -- DL = drive Y: (not present)
		Dos.FN[0x1C](m.dos, m.cpu, m)
		e(bit32.band(m.cpu.r[1], 0xFF) == 0xFF, "invalid drive returns AL=FF")
	end

	do
		local m = mkMachine()
		local e = expect("dos_country_info")
		m.cpu.ds = 0x9000
		m.cpu.r[1] = 0x3800 -- get current country
		m.cpu.r[3] = 0x0200
		Dos.FN[0x38](m.dos, m.cpu, m)
		e(not m.cpu:getF(1), "country get failed")
		e(m.cpu.r[4] == 1, "country code BX")
		e(m.mem:read8(0x90201) == 0x24, "currency symbol")
		e(m.mem:read8(0x90206) == 0x2C, "thousands separator")
		e(m.mem:read8(0x90207) == 0x2E, "decimal separator")
		e(m.mem:read8(0x90208) == 0x2F, "date separator")
		e(m.mem:read8(0x90209) == 0x3A, "time separator")
		e(m.mem:read8(0x9020B) == 2, "decimal digits")

		m.cpu.r[1] = 0x3801 -- set country 44 (UK)
		m.cpu.r[4] = 44
		Dos.FN[0x38](m.dos, m.cpu, m)
		e(m.cpu.r[4] == 44, "country set BX")
		m.cpu.r[1] = 0x3800
		Dos.FN[0x38](m.dos, m.cpu, m)
		e(m.cpu.r[4] == 44 and m.cpu.r[1] == 44, "country did not persist")
	end
end

return DosTests
