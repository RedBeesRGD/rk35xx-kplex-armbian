#!/usr/bin/env python3
"""
Send Seekwave SWT6621S rate-control MIB sub-commands to firmware from userspace.

Mechanism (verified against swt6621s_wifi.ko):
  ioctl SIOCIWFIRSTPRIV+1 (0x8BE1, priv name "set") on wlan0
     -> skw_iwpriv_set  (splits "name=args", dispatches via skw_iwpriv_set_cmds)
        -> rcminrate=<v>            -> skw_set_mib(dev,iface, MIB 0x50, 1 byte)  == firmware "cmd 0x50" (rebuild)
        -> rcratechg=<v1..v5>       -> skw_set_mib(dev,iface, MIB 0x51, 5 bytes) == firmware "cmd 0x51" (tuning)
     skw_set_mib builds TLV{u16 type=MIB_id; u16 len; u8 val[len]} and sends
     SKW_CMD_SET_MIB (top-level opcode 0x28) via skw_msg_xmit_timeout.

The MIB id IS the firmware "cmd" number the firmware handler dispatches on.

Usage:
  sudo python3 skw_ratectl.py rebuild <rateidx>          # firmware cmd 0x50 (recovery)
  sudo python3 skw_ratectl.py tune <v1> <v2> <v3> <v4> <v5>   # firmware cmd 0x51
Values may be decimal or 0x-hex.  <rateidx> must pass the driver's rate-enum
check; 0x30..0x37 and 0xc0..0xcf are always accepted.
"""
import socket, fcntl, struct, ctypes, sys

IFACE = b"wlan0"
CMD_SET = 0x8BE0 + 1          # SIOCIWFIRSTPRIV+1, priv name "set"
BUFSZ = 2048                  # >= get_args (1024) so the usage/result copy-back fits

def send(subcmd: bytes) -> str:
    buf = ctypes.create_string_buffer(BUFSZ)
    buf.raw = subcmd + b"\x00" * (BUFSZ - len(subcmd))
    # struct iwreq { char ifr_name[16]; struct iw_point{ void* pointer; u16 length; u16 flags; } }
    iwreq = struct.pack("16sQHH", IFACE, ctypes.addressof(buf), len(subcmd), 0)
    iwreq = iwreq.ljust(16 + 40, b"\x00")
    mbuf = ctypes.create_string_buffer(iwreq, len(iwreq))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fcntl.ioctl(s.fileno(), CMD_SET, mbuf)          # raises OSError on failure
    return buf.raw.split(b"\x00", 1)[0].decode("latin1", "replace")

def main(argv):
    if len(argv) >= 3 and argv[1] == "rebuild":
        sub = b"rcminrate=" + argv[2].encode()               # -> MIB 0x50
    elif len(argv) == 7 and argv[1] == "tune":
        sub = b"rcratechg=" + ",".join(argv[2:7]).encode()   # -> MIB 0x51
    else:
        print(__doc__); return 2
    print("SENDING:", sub.decode())
    print("DRIVER REPLY:", send(sub))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
