import capstone

path = r"media/win31/install/WINDOWS/SYSTEM/KRNL286.EXE"
data = open(path, "rb").read()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
# helper ED1 lives in the same segment as 728C; file offset base 0x1620
base = 0x1620
start = base + 0xEC0
end = base + 0xFA0
for insn in md.disasm(data[start:end], start - base):
    print(f"{insn.address:04X}: {insn.bytes.hex(' '):<22} {insn.mnemonic} {insn.op_str}")