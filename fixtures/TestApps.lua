--!nonstrict
-- TestApps.lua -- Win16 helpers for the bundled test binaries, registered as
-- high ordinals on KERNEL: 300 PrintString(seg:off), 301 PrintWordHex(word).

const band = bit32.band

const TestApps = {}

-- extends the already-registered KERNEL module; imports resolve "KERNEL"#300
function TestApps.register(machine: any)
	const exports = machine.winModules.KERNEL
	assert(exports, "register KERNEL exports before TestApps")

	local function arg(cpu: any, index: number): number
		return machine.mem:read16(
			machine.mem.phys(cpu.ss, band(cpu.r[5] + 6 + (index - 1) * 2, 0xFFFF))
		)
	end

	const definitions = {
		[300] = {
			args = 4,
			fn = function(host, cpu)
				const offset = arg(cpu, 1)
				const segment = arg(cpu, 2)
				local parts: { string } = {}
				for index = 0, 255 do
					const ch = host.mem:read8(host.mem.phys(segment, offset + index))
					if ch == 0x24 then
						break
					end
					parts[#parts + 1] = (ch >= 32 and ch < 127) and string.char(ch) or " "
				end
				host.bios:write(table.concat(parts) .. "\r\n")
				cpu:wr(0, 0)
			end,
		},
		[301] = {
			args = 2,
			fn = function(host, cpu)
				const value = arg(cpu, 1)
				host.bios:write(("%04X\r\n"):format(band(value, 0xFFFF)))
			end,
		},
	}

	for ordinal, definition in pairs(definitions) do
		exports[ordinal] = definition
	end
	machine:defineWinModule("KERNEL", exports)
end

return TestApps
