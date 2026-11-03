import capstone

d = open(r'media/win31/dump_krnl.bin', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)

results = {}
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
    key = '%s %s' % (ref.mnemonic, op)
    results.setdefault(key, []).append(i)

for key in sorted(results):
    sites = results[key]
    print('%2d sites | %s' % (len(sites), key))
    print('      offsets:', ', '.join('%#x' % o for o in sites[:16]))
