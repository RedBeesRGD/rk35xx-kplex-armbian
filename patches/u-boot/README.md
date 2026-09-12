# u-boot — patches to build the host tools on macOS

Mainline U-Boot v2026.04 plus two patches, applied by `../../build-uboot.sh` to its own clone under
`uboot-build/`. Both are in `scripts/dtc/pylibfdt`, which `binman` needs and which assumes a Linux
host. Neither touches target code: the FIT is the same either way.

| Patch  | Fixes                                                                         |
| ------ | ----------------------------------------------------------------------------- |
| `0001` | two Python 2 calls in `libfdt.i_shipped` that swig 4.3+ no longer papers over |
| `0002` | a hardcoded `-shared`, where Mach-O needs `-bundle -undefined dynamic_lookup` |

`libfdt.i_shipped` guards every other Python 2 call behind `PY_VERSION_HEX`; these two were missed.
swig ≤ 4.2 emitted compatibility defines that hid them, and 4.3 dropped Python 2 along with the
defines, so the generated wrapper calls `PyString_FromString` and `PyInt_AsLong` into a Python 3
header. Debian's swig is 4.1.0, which is why a container build never sees it.

A Python extension resolves its interpreter symbols when loaded. ELF links that with `-shared`;
Mach-O leaves every `Py*` symbol undefined unless told to look them up dynamically. Python reports
the right flags in `sysconfig`, and the Makefile overrides them with a literal `-shared`.

Both are upstream bugs, not local workarounds, and are written to send as-is.
