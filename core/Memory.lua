--!strict
-- Memory.lua -- 1 MiB real-mode address space backed by a Luau buffer.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Memory = {}
Memory.__index = Memory

Memory.SIZE = 1024 * 1024
const MASK_20 = 0xFFFFF
const APERTURE_START = 0xA0000
const APERTURE_END = 0xAFFFF

export type Aperture = {
	read8: (self: any, addr: number) -> number,
	write8: (self: any, addr: number, value: number) -> (),
	read16: (self: any, addr: number) -> number,
	write16: (self: any, addr: number, value: number) -> (),
}

export type Memory = typeof(setmetatable({} :: { buf: buffer, aperture: Aperture? }, Memory))

function Memory.new(): Memory
	return setmetatable({ buf = buffer.create(Memory.SIZE) }, Memory)
end

function Memory:read8(addr: number): number
	addr = band(addr, MASK_20)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr <= APERTURE_END then
		return aperture:read8(addr)
	end
	return buffer.readu8(self.buf, addr)
end

function Memory:read16(addr: number): number
	addr = band(addr, MASK_20)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr < APERTURE_END then
		return aperture:read16(addr)
	end
	if addr < MASK_20 then
		return buffer.readu16(self.buf, addr)
	end
	return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

function Memory:write8(addr: number, value: number)
	addr = band(addr, MASK_20)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr <= APERTURE_END then
		aperture:write8(addr, value)
		return
	end
	buffer.writeu8(self.buf, addr, band(value, 0xFF))
end

function Memory:write16(addr: number, value: number)
	addr = band(addr, MASK_20)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr < APERTURE_END then
		aperture:write16(addr, value)
		return
	end
	if addr < MASK_20 then
		buffer.writeu16(self.buf, addr, band(value, 0xFFFF))
	else
		self:write8(addr, value)
		self:write8(addr + 1, rshift(value, 8))
	end
end

-- Copy a Luau buffer into memory at a physical address.
function Memory:copyFrom(addr: number, src: buffer)
	buffer.copy(self.buf, band(addr, MASK_20), src, 0, buffer.len(src))
end

-- Copy a region of memory out as a new buffer.
function Memory:copyTo(addr: number, length: number): buffer
	local out = buffer.create(length)
	buffer.copy(out, 0, self.buf, band(addr, MASK_20), length)
	return out
end

function Memory:writeString(addr: number, str: string)
	local base = band(addr, MASK_20)
	for index = 1, #str do
		const byte = string.byte(str, index) :: number
		buffer.writeu8(self.buf, base + index - 1, byte)
	end
end

function Memory:readString(addr: number, length: number): string
	const base = band(addr, MASK_20)
	local parts = table.create(length)
	for index = 0, length - 1 do
		parts[index + 1] = string.char(buffer.readu8(self.buf, base + index))
	end
	return table.concat(parts)
end

-- physical segment:offset helper (20-bit wrap like a real 8086)
function Memory.phys(seg: number, off: number): number
	return band(lshift(seg, 4) + off, MASK_20)
end

return Memory
