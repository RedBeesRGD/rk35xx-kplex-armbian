#!/usr/bin/env python3
"""Read/write Seekwave firmware memory via the driver's private WEXT ioctls.
   rd <addr> [count]   -> rdaddr=0x...
   wr <addr> <value>   -> addrval=0x...,0x...
"""
import socket, fcntl, struct, ctypes, sys
IFACE = b"wlan0"; SET = 0x8BE1; BUFSZ = 2048

def call(sub: bytes) -> str:
    buf = ctypes.create_string_buffer(BUFSZ); buf.raw = sub + b"\x00" * (BUFSZ - len(sub))
    q = struct.pack("16sQHH", IFACE, ctypes.addressof(buf), len(sub), 0).ljust(56, b"\x00")
    m = ctypes.create_string_buffer(q, len(q))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        fcntl.ioctl(s.fileno(), SET, m)
    except OSError as e:
        return f"ERRNO {e.errno} " + buf.raw.split(b"\x00", 1)[0].decode("latin1", "replace")
    return buf.raw.split(b"\x00", 1)[0].decode("latin1", "replace")

def main(a):
    if len(a) >= 3 and a[1] == "rd":
        base = int(a[2], 0); n = int(a[3], 0) if len(a) > 3 else 1
        for i in range(n):
            addr = base + i * 4
            print(f"0x{addr:08x}: {call(b'rdaddr=' + hex(addr).encode())}")
    elif len(a) == 4 and a[1] == "wr":
        addr, val = int(a[2], 0), int(a[3], 0)
        print(f"write 0x{addr:08x} = 0x{val:08x}: {call(f'addrval={addr:#x},{val:#x}'.encode())}")
    else:
        print(__doc__); return 2
    return 0

sys.exit(main(sys.argv))
