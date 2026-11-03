import capstone

d = open(r'media/win31/dump_low.bin', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)

# Windows 3.1 standard mode DOSX: the reflector status byte is [DS:0x328] of
# the DOSX data segment. In RM the DOSX data lives somewhere in low memory.
# Search strategy: find every byte offset holding a plausible
# "write to [0x328]" instruction and disassemble around it.

# encodings that end with disp16 0x0328: ... 28 03
patterns = [
    (b'\xc6\x06\x28\x03', 'mov byte [0x328], imm8'),
    (b'\xc7\x06\x28\x03', 'mov word [0x328], imm16'),
    (b'\xfe\x06\x28\x03', 'inc byte [0x328]'),
    (b'\xfe\x0e\x28\x03', 'dec byte [0x328]'),
    (b'\x80\x0e\x28\x03', 'or byte [0x328], imm8'),
    (b'\x80\x2e\x28\x03', 'and byte [0x328], imm8'),
    (b'\x80\x16\x28\x03', 'xor byte [0x328], imm8'),
    (b'\x83\x0e\x28\x03', 'or word [0x328], imm8 sign'),
    (b'\x88\x06\x28\x03', 'mov byte [0x328], al'),
    (b'\x88\x1e\x28\x03', 'mov byte [0x328], bl'),
    (b'\x89\x06\x28\x03', 'mov word [0x328], ax'),
    (b'\x89\x1e\x28\x03', 'mov word [0x328], bx'),
]

found = []
for pat, desc in patterns:
    start = 0
    while True:
        i = d.find(pat, start)
        if i < 0:
            break
        found.append((i, desc, pat))
        start = i + 1

print(len(found), 'candidate write sites')
# group by segment (16-byte paragraph of the linear dump address)
seen_segs = {}
for off, desc, pat in found:
    seg = off >> 4
    seen_segs.setdefault(seg, []).append((off, desc))

for seg in sorted(seen_segs):
    print('segment %#05x (linear %#08x): %d sites' % (seg, seg * 16, len(seen_segs[seg])))
    for off, desc in seen_segs[seg][:6]:
        md2 = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
        lo = max(off - 32, 0)
        code = d[lo:off + 24]
        print('  --- site %#x (%s)' % (off, desc))
        for insn in md2.disasm(code, lo):
            if insn.address >= off - 12 and insn.address <= off + 12:
                print('    %04X: %-18s %s %s' % (insn.address, insn.bytes.hex(' '), insn.mnemonic, insn.op_str))
