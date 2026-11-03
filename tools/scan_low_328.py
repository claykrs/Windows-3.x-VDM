import capstone, struct

d = open(r'media/win31/dump_low.bin', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)

# search for all disp16 = 0x0328 references in low memory
hits = []
start = 0
while True:
    i = d.find(b'\x28\x03', start)
    if i < 0:
        break
    start = i + 1
    lo = max(i - 24, 0)
    insns = list(md.disasm(d[lo:i + 20], lo))
    ref = None
    for insn in insns:
        b0 = insn.address - lo
        if b0 <= i and i + 2 <= b0 + insn.size:
            ref = insn
            break
    if ref is None:
        continue
    op = ref.op_str
    if '0x328' not in op:
        continue
    hits.append((i, ref.mnemonic, op))

print(len(hits), 'total [0x328] references in low memory')
for off, mn, op in hits:
    seg = off >> 4
    print('  seg=%#05x off=%#06x: %s %s' % (seg, off, mn, op))
