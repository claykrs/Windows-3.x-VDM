--!nonstrict
-- Kernel16.lua -- Win16 KERNEL stand-in for the bundled demo programs.
-- Registers as the "KERNEL" import module on a Machine. Ordinals follow the
-- real KERNEL export numbers; only what the demo binaries use is implemented.

const band, lshift = bit32.band, bit32.lshift

const Kernel16 = {}

type HeapBlock = {
	seg: number,
}

type Heap = {
	moveable: { [number]: HeapBlock },
	nextHandle: number,
}

export type Machine = any

-- Pascal-convention argument access: the thunk pushed CX, the far call pushed
-- IP and CS, so the first argument sits at SS:SP+6.
local function arg(machine: Machine, cpu: any, index: number): number
	return machine.mem:read16(
		machine.mem.phys(cpu.ss, band(cpu.r[5] + 6 + (index - 1) * 2, 0xFFFF))
	)
end

function Kernel16.register(machine: Machine, extras: any?)
	local heap: Heap = machine.winHeap
	if not heap then
		heap = { moveable = {}, nextHandle = 1 }
		machine.winHeap = heap
	end
	const mem = machine.mem

	local exports = {}

	-- GetVersion: AX = 0x0003 (Windows 3.0), DX = 0
	exports[4] = {
		args = 0,
		fn = function(_machine, cpu)
			cpu:wr(0, 0x0003)
			cpu:wr(2, 0)
		end,
	}

	-- GlobalAlloc(wFlags, dwBytes) -> AX = handle
	exports[5] = {
		args = 6,
		fn = function(host, cpu)
			const flags = arg(host, cpu, 1)
			const bytesHigh = arg(host, cpu, 2)
			const bytesLow = arg(host, cpu, 3)
			const bytes = math.max(bytesHigh * 65536 + bytesLow, 1)
			const paras = math.ceil(bytes / 16) + 1
			const seg = host:dosAlloc(paras)
			if not seg then
				error("KERNEL GlobalAlloc: out of conventional memory")
			end
			local handle = seg
			if band(flags, 0x0002) ~= 0 then -- GMEM_MOVEABLE
				handle = heap.nextHandle
				heap.nextHandle += 1
				heap.moveable[handle] = { seg = seg }
			end
			cpu:wr(0, handle)
		end,
	}

	-- GlobalLock(h) -> DX:AX far pointer
	exports[6] = {
		args = 2,
		fn = function(host, cpu)
			const handle = arg(host, cpu, 1)
			const block = heap.moveable[handle]
			const seg = block and block.seg or handle
			cpu:wr(0, 0) -- offset 0
			cpu:wr(2, seg)
		end,
	}

	-- GlobalFree(h) -> AX = 0 on success, 1 for a stale handle
	exports[7] = {
		args = 2,
		fn = function(host, cpu)
			const handle = arg(host, cpu, 1)
			const block = heap.moveable[handle]
			if block then
				heap.moveable[handle] = nil
				cpu:wr(0, host:dosFree(block.seg) and 0 or 1)
			else
				cpu:wr(0, host:dosFree(handle) and 0 or 1)
			end
		end,
	}

	-- GlobalCompact(dwMaxFree) -> AX = 0 (the arena is already compact)
	exports[8] = {
		args = 4,
		fn = function(_host, cpu)
			cpu:wr(0, 0)
		end,
	}

	-- GlobalUnlock(h) -> AX = 0 (lock counts are not tracked)
	exports[9] = {
		args = 2,
		fn = function(_host, cpu)
			cpu:wr(0, 0)
		end,
	}

	-- GetDOSEnvironment -> AX = environment segment
	const envSeg = 0x6000
	const envText = "PATH=C:\\\0WINDIR=C:\\WINDOWS\0\0"
	mem:writeString(lshift(envSeg, 4), envText)
	exports[10] = {
		args = 0,
		fn = function(_host, cpu)
			cpu:wr(0, envSeg)
		end,
	}

	-- GetCurrentPDB -> AX = PSP segment
	exports[12] = {
		args = 0,
		fn = function(host, cpu)
			cpu:wr(0, host.pspSeg or 0x1000)
		end,
	}

	-- caller extras (test helpers etc): ordinal -> definition
	for ordinal, definition in pairs(extras or {}) do
		exports[ordinal] = definition
	end

	machine:defineWinModule("KERNEL", exports)
	return exports
end

return Kernel16
