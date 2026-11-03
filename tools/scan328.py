import capstone

d = open(r'media/win31/dump_low.bin', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)

# every occurrence of disp16 0x0328 in low memory
hits = []
start = 0
while True:
    i = d.find(b'\x28\x03', start)
    if i < 0:
        break
    hits.append(i)
    start = i + 1

print(len(hits), 'raw 28 03 sequences')

results = {}
for off in hits:
    lo = max(off - 24, 0)
    code = d[lo:off + 20]
    insns = list(md.disasm(code, lo))
    # find the instruction whose operand bytes END at off+2 (i.e. contains disp 28 03)
    ref = None
    for insn in insns:
        b0 = insn.address - lo
        b1 = b0 + insn.size
        if b0 <= off and off + 2 <= b1:
            ref = insn
            break
    if ref is None:
        continue
    if '0x328' not in ref.op_str and '0x327' not in ref.op_str and '0x324' not in ref.op_str:
        continue
    seg = (off + 1) >> 4  # rough: the instruction likely lives in the para containing it
    key = ref.mnemonic + ' | ' + ref.op_str
    results.setdefault(key, []).append((off, ref.address))

for key in sorted(results):
    sites = results[key]
    print('%3d sites | %s' % (len(sites), key))
    segs = sorted(set((o >> 4) for o, a in sites))
    print('      segs:', ', '.join('%#x' % s for s in segs[:12]))
