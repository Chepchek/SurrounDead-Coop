# Minidump reader (no dependencies): exception, faulting module+offset, heuristic stack scan.
# usage: python -I tools/dmpscan.py <file.dmp> [stack_words]
import struct, sys

path = sys.argv[1]
nwords = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
data = open(path, "rb").read()
sig, ver, nstreams, dir_rva = struct.unpack_from("<4sIII", data, 0)
assert sig == b"MDMP", sig
streams = {}
for i in range(nstreams):
    st, size, rva = struct.unpack_from("<III", data, dir_rva + i * 12)
    streams.setdefault(st, []).append((size, rva))


def mdstring(rva):
    n = struct.unpack_from("<I", data, rva)[0]
    return data[rva + 4: rva + 4 + n].decode("utf-16-le", "replace")


mods = []
for size, rva in streams.get(4, []):
    n = struct.unpack_from("<I", data, rva)[0]
    for i in range(n):
        o = rva + 4 + i * 108
        base, msize, _cs, _ts, name_rva = struct.unpack_from("<QIIII", data, o)
        mods.append((base, msize, mdstring(name_rva).split("\\")[-1]))
mods.sort()


def where(a):
    for base, size, name in mods:
        if base <= a < base + size:
            return "%s+0x%x" % (name, a - base)
    return None


# memory ranges
mem = []
for size, rva in streams.get(9, []):  # Memory64List
    n, base_rva = struct.unpack_from("<QQ", data, rva)
    off = base_rva
    for i in range(n):
        start, sz = struct.unpack_from("<QQ", data, rva + 16 + i * 16)
        mem.append((start, sz, off))
        off += sz
for size, rva in streams.get(5, []):  # MemoryList
    n = struct.unpack_from("<I", data, rva)[0]
    for i in range(n):
        start, sz, mrva = struct.unpack_from("<QII", data, rva + 4 + i * 16)
        mem.append((start, sz, mrva))


def read(a, n):
    for start, sz, off in mem:
        if start <= a and a + n <= start + sz:
            return data[off + (a - start): off + (a - start) + n]
    return None


# exception
exc_tid = None
for size, rva in streams.get(6, []):
    tid, _a = struct.unpack_from("<II", data, rva)
    code, flags, rec, addr, nparams = struct.unpack_from("<IIQQI", data, rva + 8)
    params = struct.unpack_from("<15Q", data, rva + 8 + 32)
    ctx_size, ctx_rva = struct.unpack_from("<II", data, rva + 8 + 152)
    exc_tid = tid
    print("exception code=0x%08x thread=%d at %s (0x%x) params=%s" % (code, tid, where(addr), addr,
          [hex(p) for p in params[:nparams]]))
    ctx = data[ctx_rva: ctx_rva + ctx_size]
    regs = {}
    names = ["Rax", "Rcx", "Rdx", "Rbx", "Rsp", "Rbp", "Rsi", "Rdi"] + ["R%d" % i for i in range(8, 16)] + ["Rip"]
    vals = struct.unpack_from("<17Q", ctx, 0x78)
    for n_, v in zip(names, vals):
        regs[n_] = v
    print("regs:", " ".join("%s=%x" % (k, v) for k, v in regs.items()))
    rsp = regs["Rsp"]
    print("stack scan from rsp=%x:" % rsp)
    shown = 0
    for i in range(nwords):
        b = read(rsp + i * 8, 8)
        if b is None:
            print("  (stack memory ends at +0x%x)" % (i * 8))
            break
        v = struct.unpack("<Q", b)[0]
        w = where(v)
        if w and not w.startswith("ntdll") or (w and shown < 3):
            print("  [rsp+0x%04x] %s" % (i * 8, w))
            shown += 1

# threads
for size, rva in streams.get(3, []):
    n = struct.unpack_from("<I", data, rva)[0]
    print("threads:", n)

print("modules (selected):")
for base, size, name in mods:
    if any(k in name.lower() for k in ("ue4ss", "surroundead", "lua", "dwmapi")):
        print("  %x %x %s" % (base, size, name))
