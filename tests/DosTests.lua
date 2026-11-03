--!nonstrict
-- DosTests.lua -- DOS behaviours that apps depend on beyond basic file I/O.
local Dos = require("../core/Dos")

const DosTests = {}

function DosTests.run(mkMachine, expect)
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
end

return DosTests
