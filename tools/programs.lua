-- programs.lua -- builds the demo binaries into apps/ + src/Apps.lua.

local fs = require("@lune/fs")
local A = require("./asm")

local bor, lshift = bit32.bor, bit32.lshift

-- shared decimal print routine: prints AX, clobbers AX BX CX DX
local function addPrintAX(a)
	a:label("printAX")
	a:mov_r16_imm(3, 10) -- MOV BX, 10
	a:xor_r_r(1, 1) -- XOR CX, CX
	a:label("dloop")
	a:xor_r_r(2, 2) -- XOR DX, DX
	a:div_rm16(3) -- DIV BX
	a:push_r(2) -- PUSH DX (remainder)
	a:inc_r(1) -- INC CX
	a:test_ax_ax()
	a:jcc(5, "dloop") -- JNZ
	a:label("ploop")
	a:pop_r(2) -- POP DX
	a:add_rm8_imm(2, 0x30) -- ADD DL, '0'
	a:mov_r8_imm(4, 0x02) -- MOV AH, 2
	a:push_r(1)
	a:int(0x21)
	a:pop_r(1)
	a:loop("ploop")
	a:ret()
end

local function exitDOS(a, code)
	a:mov_r16_imm(0, bor(lshift(code, 8), 0))
	a:int(0x21)
end

local function buildHello()
	local a = A.new()
	a:mov_r16_label(2, "msg") -- MOV DX, msg
	a:mov_r8_imm(4, 0x09) -- MOV AH, 9
	a:int(0x21)
	exitDOS(a, 0)
	a:label("msg")
	a:dollar("Hello from a real 8086 inside Roblox Luau!$")
	return a:resolve(0x100)
end

local function buildFib()
	local a = A.new()
	a:mov_r16_imm(6, 0) -- SI = a = 0
	a:mov_r16_imm(7, 1) -- DI = b = 1
	a:mov_r16_imm(1, 12) -- CX = 12 numbers
	a:label("next")
	a:push_r(1) -- CX
	a:push_r(7) -- DI
	a:push_r(6) -- SI
	a:mov_r_r(0, 6) -- MOV AX, SI
	a:call("printAX")
	a:mov_r8_imm(2, 0x20) -- MOV DL, ' '
	a:mov_r8_imm(4, 0x02) -- MOV AH, 2
	a:int(0x21)
	a:pop_r(6) -- SI (old a)
	a:pop_r(7) -- DI (old b)
	a:pop_r(1) -- CX
	a:mov_r_r(0, 6) -- AX = old a
	a:mov_r_r(6, 7) -- SI = old b
	a:add_r_r(7, 0) -- DI = old a + old b
	a:loop("next")
	exitDOS(a, 0)
	addPrintAX(a)
	return a:resolve(0x100)
end

local function buildEcho()
	local a = A.new()
	a:label("loop")
	a:mov_r8_imm(4, 0x00) -- MOV AH, 0 (read key)
	a:int(0x16)
	a:cmp_al_imm(13) -- CR?
	a:jcc(4, "done") -- JE
	a:mov_rm8_r8(2, 0) -- MOV DL, AL
	a:mov_r8_imm(4, 0x02) -- MOV AH, 2
	a:int(0x21)
	a:jmp("loop")
	a:label("done")
	a:mov_r8_imm(2, 13)
	a:mov_r8_imm(4, 0x02)
	a:int(0x21)
	a:mov_r8_imm(2, 10)
	a:int(0x21)
	exitDOS(a, 0)
	return a:resolve(0x100)
end

local function buildCat()
	local a = A.new()
	a:mov_r16_label(2, "fname") -- MOV DX, fname
	a:mov_r16_imm(0, 0x3D00) -- MOV AX, 3D00h (open read)
	a:int(0x21)
	a:jcc(2, "err") -- JC
	a:mov_r_r(3, 0) -- MOV BX, AX (handle)
	a:mov_r16_imm(2, 0x0500) -- MOV DX, buffer
	a:mov_r16_imm(1, 0x0800) -- MOV CX, 2048
	a:mov_r8_imm(4, 0x3F) -- MOV AH, 3Fh (read)
	a:int(0x21)
	a:jcc(2, "err") -- JC
	a:mov_r_r(1, 0) -- MOV CX, AX (bytes read)
	a:mov_r16_imm(2, 0x0500) -- MOV DX, buffer
	a:mov_r16_imm(3, 1) -- MOV BX, 1 (stdout)
	a:mov_r8_imm(4, 0x40) -- MOV AH, 40h (write)
	a:int(0x21)
	exitDOS(a, 0)
	a:label("err")
	a:mov_r16_label(2, "emsg")
	a:mov_r8_imm(4, 0x09)
	a:int(0x21)
	exitDOS(a, 1)
	a:label("fname")
	a:asciz("C:\\TEXT.TXT")
	a:label("emsg")
	a:dollar("ERROR!$")
	return a:resolve(0x100)
end

-- builds a real MZ .exe: prints the relocation-patched word (proves relocs applied)
local function buildMzDemo()
	local a = A.new()
	a:mov_r16_sreg(0, 1) -- MOV AX, CS
	a:mov_sreg_r16(3, 0) -- MOV DS, AX
	a:mov_ax_label("patched") -- MOV AX, [patched]
	a:call("printAX")
	exitDOS(a, 0)
	a:label("patched")
	a:word(0) -- relocated += loadSeg -> prints 4112 (0x1010)
	addPrintAX(a)
	local buf, labels = a:resolve(0)

	-- wrap in an MZ header with one relocation entry pointing at "patched"
	-- file = 32-byte MZ stub + image; cp/cblp describe the whole file
	local imgLen = buffer.len(buf)
	local fileLen = 32 + imgLen
	local cp = math.ceil(fileLen / 512)
	local cblp = fileLen - (cp - 1) * 512
	local relocOff = labels["patched"]

	local hdr = buffer.create(32) -- 14 header words + one reloc entry (off, seg)
	local function w16(off, v)
		buffer.writeu8(hdr, off, bit32.band(v, 0xFF))
		buffer.writeu8(hdr, off + 1, bit32.band(bit32.rshift(v, 8), 0xFF))
	end
	w16(0, 0x5A4D) -- MZ
	w16(2, cblp)
	w16(4, cp)
	w16(6, 1) -- crlc: one relocation
	w16(8, 2) -- header = 2 paragraphs (32 bytes)
	w16(10, 0) -- minalloc
	w16(12, 0xFFFF) -- maxalloc
	w16(14, 0) -- ss (relative to load module)
	w16(16, 0x0100) -- sp
	w16(18, 0) -- checksum
	w16(20, 0) -- ip
	w16(22, 0) -- cs
	w16(24, 28) -- lfarlc: reloc table right after the 14 header words
	w16(26, 0) -- overlay number
	w16(28, relocOff) -- reloc entry: offset within load module
	w16(30, 0) -- reloc entry: segment 0

	local out = buffer.create(32 + imgLen)
	buffer.copy(out, 0, hdr, 0, 32)
	buffer.copy(out, 32, buf, 0, imgLen)
	return out
end

-- builders for real-format NE test binaries (replaces buildNE2/3/4)

-- assembleNE(spec) -> buffer, real NE inside a 1-paragraph MZ stub.
-- spec = {
--   segments = { { code = luauBuffer, data = true/false, minAlloc = n, relocs = {
--       { kind="import", off=n, mod=name, ord=n } or { kind="internal", off=n, seg=n, off2=n } } } ... },
--   entry = { seg = 1-based seg index, off = offset },   -- goes in NE csip
--   autodata = 1-based seg index or nil,
--   imports = { "KERNEL", ... },
-- }
-- Layout: 0x00 MZ stub (0x40), NE header (0x40), entry table, seg table,
-- imported names + module refs, then segment data paragraph-aligned.
local band, rshift = bit32.band, bit32.rshift
local function assembleNE(spec)
	local W = {}
	local function w8(b)
		W[#W + 1] = string.char(band(b, 0xFF))
	end
	local function w16(v)
		w8(band(v, 0xFF))
		w8(band(rshift(v, 8), 0xFF))
	end

	local imports = spec.imports or {}
	local modRefs = #imports

	-- entry table: single fixed bundle per segment group is overkill; emit one
	-- bundle per segment holding that segment's exported entries (none for tests
	-- except the auto entry). Real format: [count][segIdx] then entries.
	local exported = spec.exports or {}
	local bySeg = {}
	for _, e in ipairs(exported) do
		bySeg[e.seg] = bySeg[e.seg] or {}
		table.insert(bySeg[e.seg], e.off)
	end
	for seg, offs in pairs(bySeg) do
		w8(#offs)
		w8(seg)
		for _, off in ipairs(offs) do
			w8(0x01) -- flags: fixed entry
			w16(off)
		end
	end
	w8(0) -- bundle terminator
	while #W % 16 ~= 0 do
		w8(0)
	end
	local etabLen = #W

	-- segment table (after entry table); compute file offsets as we go
	local segCount = #spec.segments
	local segTabAbs = 0x40 + 0x40 + etabLen
	local namesAbs = segTabAbs + segCount * 8
	local impBlob = {}
	for _, nm in ipairs(imports) do
		impBlob[#impBlob + 1] = string.char(#nm) .. string.upper(nm)
	end
	local impBlobStr = table.concat(impBlob)
	local modRefAbs = namesAbs + #impBlobStr
	local modRefWords = {}
	local cursor = 0
	for _, nm in ipairs(imports) do
		modRefWords[#modRefWords + 1] = cursor
		cursor += #nm + 1
	end
	local dataStart = modRefAbs + modRefs * 2
	while dataStart % 16 ~= 0 do
		dataStart += 1
	end

	-- NE header
	local H = {}
	local function hw8(b)
		H[#H + 1] = string.char(band(b, 0xFF))
	end
	local function hw16(v)
		hw8(band(v, 0xFF))
		hw8(band(rshift(v, 8), 0xFF))
	end
	local function hw32(v)
		hw16(band(v, 0xFFFF))
		hw16(band(rshift(v, 16), 0xFFFF))
	end
	hw16(0x454E) -- NE
	hw8(5)
	hw8(1) -- linker 5.1
	hw16(0x40) -- enttab (rel to NE): entry table right after NE header
	hw16(etabLen)
	hw16(0)
	hw16(0) -- checksum
	hw16(0x0302) -- flags: GUI, multiple data
	hw16(spec.autodata or 0xFFFF) -- autodata
	hw16(0)
	hw16(0) -- heap, stack
	local csip = bor(spec.entry.off, bit32.lshift(spec.entry.seg, 16))
	hw32(csip)
	hw32(0) -- sssp: loader assigns PSP stack
	hw16(segCount)
	hw16(modRefs)
	hw16(0) -- cbnrestab
	hw16(segTabAbs - 0x40) -- segtab rel
	hw16(0) -- rsrctab (none)
	hw16(0) -- restab (none)
	hw16(modRefAbs - 0x40) -- modtab rel (words into imptab)
	hw16(namesAbs - 0x40) -- imptab rel (length-prefixed names)
	hw32(0) -- nrestab
	hw16(0) -- cmovent
	hw16(4) -- align: 16-byte sectors
	hw16(0) -- cres
	hw8(2)
	hw8(0) -- exetyp Windows, flagsothers
	hw16(0)
	hw16(0)
	hw16(0) -- pretthunks, psegrefbytes, swaparea
	hw16(0x0300) -- expected Windows version 3.0
	assert(#H == 0x40, "NE header size " .. #H)

	local out = {}
	out[#out + 1] = "MZ"
	out[#out + 1] = string.rep("\0", 0x3A - 2)
	-- e_lfanew dword at 0x3C = 0x40
	out[#out + 1] = string.char(0x40, 0, 0, 0)
	out[#out + 1] = table.concat(H)
	out[#out + 1] = table.concat(W)

	-- segment table + relocation blobs; data placement is computed, not written
	local segEntries = {}
	local relocBlobs = {}
	local dataOff = dataStart
	for i, seg in ipairs(spec.segments) do
		seg.code = (typeof(seg.code) == "string") and seg.code or buffer.tostring(seg.code)
		local codeLen = #seg.code
		local hasRelocs = seg.relocs and #seg.relocs > 0
		local flags = 0x0040 -- preload
		if seg.data then
			flags = bor(flags, 0x0001)
		end
		if hasRelocs then
			flags = bor(flags, 0x0100)
		end
		segEntries[i] = {
			sector = math.floor(dataOff / 16),
			len = codeLen,
			flags = flags,
			minAlloc = seg.minAlloc or 0,
		}
		if hasRelocs then
			local rb = { string.char(band(#seg.relocs, 0xFF), rshift(#seg.relocs, 8)) }
			for _, fx in ipairs(seg.relocs) do
				if fx.kind == "import" then
					local modIdx = 0
					for mi, nm in ipairs(imports) do
						if string.upper(nm) == string.upper(fx.mod) then
							modIdx = mi
						end
					end
					assert(modIdx > 0, "import not in imports list: " .. fx.mod)
					rb[#rb + 1] = string.char(3, 1) -- POINTER32, import-by-ordinal
					rb[#rb + 1] = string.char(band(fx.off, 0xFF), band(rshift(fx.off, 8), 0xFF))
					rb[#rb + 1] = string.char(band(modIdx, 0xFF), band(rshift(modIdx, 8), 0xFF))
					rb[#rb + 1] = string.char(band(fx.ord, 0xFF), band(rshift(fx.ord, 8), 0xFF))
				else -- internal pointer fixup
					rb[#rb + 1] = string.char(3, 0)
					rb[#rb + 1] = string.char(band(fx.off, 0xFF), band(rshift(fx.off, 8), 0xFF))
					rb[#rb + 1] = string.char(band(fx.seg, 0xFF), 0)
					rb[#rb + 1] = string.char(band(fx.off2, 0xFF), band(rshift(fx.off2, 8), 0xFF))
				end
			end
			relocBlobs[i] = table.concat(rb)
		end
		dataOff = dataOff + codeLen + (relocBlobs[i] and #relocBlobs[i] or 0)
		while dataOff % 16 ~= 0 do
			dataOff += 1
		end
	end

	-- final assembly: MZ stub + NE header + entry table + seg table + names + data
	local body = {}
	body[1] = "MZ"
		.. string.rep("\0", 0x3A)
		.. string.char(0x40, 0, 0, 0) -- e_lfanew = 0x40
		.. table.concat(H)

	local function emitAt(abs, s)
		local cur = #body[1]
		if cur < abs then
			body[1] = body[1] .. string.rep("\0", abs - cur)
		end
		body[1] = body[1] .. s
	end

	emitAt(0x80, table.concat(W)) -- entry table
	local segTableStr = {}
	for _, se in segEntries do
		local function sw16(v)
			segTableStr[#segTableStr + 1] = string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
		end
		sw16(se.sector)
		sw16(se.len)
		sw16(se.flags)
		sw16(se.minAlloc)
	end
	emitAt(segTabAbs, table.concat(segTableStr))
	local namesStr = impBlobStr
	for _, wv in ipairs(modRefWords) do
		namesStr = namesStr .. string.char(band(wv, 0xFF), band(rshift(wv, 8), 0xFF))
	end
	emitAt(namesAbs, namesStr)

	local off2 = dataStart
	for i, seg in ipairs(spec.segments) do
		local cur = #body[1]
		if cur < off2 then
			body[1] = body[1] .. string.rep("\0", off2 - cur)
		end
		body[1] = body[1] .. seg.code
		if relocBlobs[i] then
			body[1] = body[1] .. relocBlobs[i]
		end
		off2 = #body[1]
		while off2 % 16 ~= 0 do
			body[1] = body[1] .. "\0"
			off2 += 1
		end
	end

	return buffer.fromstring(table.concat(body))
end

-- NE2: two segments, no imports; prints from its own segment
local function buildNE2()
	local a = A.new()
	a:mov_r16_sreg(0, 1) -- MOV AX, CS
	a:mov_sreg_r16(3, 0) -- MOV DS, AX
	a:mov_r16_label(2, "msg")
	a:mov_r8_imm(4, 0x09)
	a:int(0x21)
	exitDOS(a, 0)
	a:label("msg")
	a:dollar("NE2 OK$")
	local code = a:resolve(0)

	return assembleNE({
		segments = {
			{ code = code, minAlloc = 0, relocs = nil },
			{ code = string.rep("\0", 16), data = true, minAlloc = 16, relocs = nil },
		},
		entry = { seg = 1, off = 0 },
		autodata = 2,
		imports = {},
		exports = {},
	})
end

-- NE3: imports KERNEL#300 (PrintString) via an import-by-ordinal fixup
local function buildNE3()
	local a = A.new()
	a:mov_r16_sreg(0, 1) -- MOV AX, CS
	a:mov_sreg_r16(3, 0) -- MOV DS, AX
	a:mov_r16_label(2, "msg")
	a:push_r(0)
	a:push_r(2)
	a:db(0x9A, 0xFF, 0xFF, 0xFF, 0xFF) -- CALL FAR (patched; FFFF = chain end)
	a:mov_r16_label(2, "msg2")
	a:mov_r8_imm(4, 0x09)
	a:int(0x21)
	exitDOS(a, 0)
	a:label("msg")
	a:dollar("KERNEL #300 called!$")
	a:label("msg2")
	a:dollar("back in NE3, exit ok$")
	local code = a:resolve(0)

	return assembleNE({
		segments = {
			{
				code = code,
				minAlloc = 0,
				relocs = { { kind = "import", off = 10, mod = "KERNEL", ord = 300 } },
			},
			{ code = string.rep("\0", 16), data = true, minAlloc = 16, relocs = nil },
		},
		entry = { seg = 1, off = 0 },
		autodata = 2,
		imports = { "KERNEL" },
		exports = {},
	})
end

-- NE4: full KERNEL exercise — GetVersion, GlobalAlloc/Lock/Unlock/Free + prints
local function buildNE4()
	local a = A.new()
	local fixups = {}
	local function impCall(ordinal)
		local operandOff = a.cur + 1
		a:db(0x9A, 0xFF, 0xFF, 0xFF, 0xFF) -- FFFF operands = chain end
		fixups[#fixups + 1] = { off = operandOff, ord = ordinal }
	end

	a:mov_r16_sreg(0, 1)
	a:mov_sreg_r16(3, 0)
	a:mov_r16_label(2, "banner")
	a:push_r(0)
	a:push_r(2)
	impCall(300)
	impCall(4)
	a:push_r(0)
	impCall(301)
	a:mov_r16_imm(0, 0x0040)
	a:push_r(0)
	a:mov_r16_imm(0, 0)
	a:push_r(0)
	a:mov_r16_imm(0, 32)
	a:push_r(0)
	impCall(5)
	a:mov_r_r(6, 0)
	a:push_r(0)
	impCall(301)
	a:push_r(6)
	impCall(6)
	a:push_r(2)
	impCall(301)
	a:push_r(0)
	impCall(301)
	a:push_sreg(3)
	a:mov_sreg_r16(3, 2)
	a:mov_r16_imm(0, 0x6948)
	a:mov_moffs_ax(0)
	a:mov_r16_imm(0, 0x6620)
	a:mov_moffs_ax(2)
	a:mov_r16_imm(0, 0x6F72)
	a:mov_moffs_ax(4)
	a:mov_r16_imm(0, 0x206D)
	a:mov_moffs_ax(6)
	a:mov_r16_imm(0, 0x6C61)
	a:mov_moffs_ax(8)
	a:mov_r16_imm(0, 0x6F6C)
	a:mov_moffs_ax(10)
	a:mov_r16_imm(0, 0x2463)
	a:mov_moffs_ax(12)
	a:xor_r_r(2, 2)
	a:push_r(6)
	a:push_r(2)
	impCall(300)
	a:pop_sreg(3)
	a:push_r(6)
	impCall(9)
	a:push_r(6)
	impCall(7)
	a:mov_r16_sreg(0, 3)
	a:mov_r16_label(2, "done")
	a:push_r(0)
	a:push_r(2)
	impCall(300)
	exitDOS(a, 0)
	a:label("banner")
	a:dollar("NE4 KERNEL test$")
	a:label("done")
	a:dollar("done$")
	local code = a:resolve(0)

	local relocs = {}
	for _, f in ipairs(fixups) do
		relocs[#relocs + 1] = { kind = "import", off = f.off, mod = "KERNEL", ord = f.ord }
	end

	return assembleNE({
		segments = {
			{ code = code, minAlloc = 0, relocs = relocs },
			{ code = string.rep("\0", 16), data = true, minAlloc = 16, relocs = nil },
		},
		entry = { seg = 1, off = 0 },
		autodata = 2,
		imports = { "KERNEL" },
		exports = {},
	})
end

local function toEscapedLuau(name, buf)
	local parts = {}
	for i = 0, buffer.len(buf) - 1 do
		local b = buffer.readu8(buf, i)
		if b == 34 then
			parts[#parts + 1] = '\\"'
		elseif b == 92 then
			parts[#parts + 1] = "\\\\"
		elseif b >= 32 and b < 127 then
			parts[#parts + 1] = string.char(b)
		else
			parts[#parts + 1] = string.format("\\%03d", b)
		end
	end
	return string.format('\t["%s"] = "%s",', name, table.concat(parts))
end

local programs = {
	{ name = "HELLO.COM", data = buildHello() },
	{ name = "FIB.COM", data = buildFib() },
	{ name = "ECHO.COM", data = buildEcho() },
	{ name = "CAT.COM", data = buildCat() },
	{ name = "MZDEMO.EXE", data = buildMzDemo() },
	{ name = "NE2.EXE", data = buildNE2() },
	{ name = "NE3.EXE", data = buildNE3() },
	{ name = "NE4.EXE", data = buildNE4() },
}

if not fs.isDir("apps") then
	fs.writeDir("apps")
end
local lines = {
	"-- GENERATED by tools/programs.lua -- do not edit by hand.",
	"-- The same binaries as apps/, embedded so Roblox needs no filesystem.",
	"return {",
}
for _, p in ipairs(programs) do
	fs.writeFile("apps/" .. p.name, p.data)
	lines[#lines + 1] = toEscapedLuau(p.name, p.data)
	print(("built apps/%s (%d bytes)"):format(p.name, buffer.len(p.data)))
end
lines[#lines + 1] = "}"
fs.writeFile("fixtures/Apps.lua", table.concat(lines, "\n") .. "\n")
print("wrote fixtures/Apps.lua")
