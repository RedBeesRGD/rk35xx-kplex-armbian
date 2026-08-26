import sys, capstone
BASE = 0x00100000
data = open("iram.bin","rb").read()
start = int(sys.argv[1],0); end = int(sys.argv[2],0)
md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB)
md.detail = False
off = start - BASE
for i in md.disasm(data[off:end-BASE], start):
    print(f"{i.address:08x}  {i.bytes.hex():<12} {i.mnemonic:<8} {i.op_str}")
