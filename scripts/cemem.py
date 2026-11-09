#!/usr/bin/env python3
"""cemem — motor de memória NATIVO (sem Cheat Engine): /proc/PID/mem + numpy.

Plano B da skill e ferramenta de conferência: lê, escreve, escaneia (first/next,
inclusive valor desconhecido), segue e PROCURA cadeias de ponteiros (pointer
scan), acha padrões de bytes, congela valores em segundo plano e (des)monta
instruções — em qualquer processo do usuário: nativo Linux, Wine ou Proton.
Requer kernel.yama.ptrace_scope=0 (o install.sh configura) ou root.

    cemem scan alvo 100                 # first scan (dword) -> sessão "default"
    cemem next 93                       # next scan
    cemem next decreased                # ...ou increased/changed/unchanged
    cemem write alvo 0x55d0c0a1b2c4 999
    cemem ptrscan alvo 0x55d0c0a1b2c4   # cadeias estáveis "modulo+off -> [..]+o"
    cemem freeze alvo 0x55d0c0a1b2c4 999 --background
    cemem aob alvo "48 8B 05 ?? ?? ?? ??" -m jogo

Saída JSON. Endereços HEX (como no CE), aceitam "modulo+offset".
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ce import BridgeError, best_process, list_processes, proc_info  # noqa: E402

try:
    import numpy as np
    np.seterr(all="ignore")  # memória tem NaN/inf em floats: comparar sem avisos
except ImportError:  # pragma: no cover
    np = None

CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "ce-agent" / "cemem"
CHUNK = 64 * 1024 * 1024

TYPES = {  # nome -> (struct, numpy dtype, tamanho)
    "byte": ("<B", "u1", 1), "word": ("<H", "<u2", 2), "dword": ("<I", "<u4", 4),
    "qword": ("<Q", "<u8", 8), "float": ("<f", "<f4", 4), "double": ("<d", "<f8", 8),
    "int8": ("<b", "i1", 1), "int16": ("<h", "<i2", 2), "int32": ("<i", "<i4", 4),
    "int64": ("<q", "<i8", 8), "pointer": ("<Q", "<u8", 8),
}
ALIAS = {"u8": "byte", "u16": "word", "short": "word", "2": "word", "u32": "dword", "int": "int32",
         "integer": "int32", "4": "dword", "u64": "qword", "8": "qword", "long": "int64", "single": "float",
         "f32": "float", "f64": "double", "ptr": "pointer", "1": "byte", "i8": "int8", "i16": "int16",
         "i32": "int32", "i64": "int64"}


class Erro(RuntimeError):
    pass


def canon(t: str) -> str:
    t = (t or "dword").lower()
    t = ALIAS.get(t, t)
    if t not in TYPES and t not in ("string", "widestring", "bytes"):
        raise Erro(f"tipo desconhecido: {t}")
    return t


def need_numpy():
    if np is None:
        raise Erro("numpy não instalado: sudo pacman -S python-numpy")


# ---------------------------------------------------------------------------
# Processo, mapas e acesso à memória
# ---------------------------------------------------------------------------
MAPS_RE = re.compile(r"^([0-9a-f]+)-([0-9a-f]+) (\S{4}) ([0-9a-f]+) \S+ (\d+)\s*(.*)$")


def parse_maps(pid: int) -> list[dict]:
    out = []
    try:
        with open(f"/proc/{pid}/maps") as f:
            for line in f:
                m = MAPS_RE.match(line.rstrip("\n"))
                if not m:
                    continue
                start, end, perms, off, inode, path = m.groups()
                out.append({"start": int(start, 16), "end": int(end, 16), "perms": perms,
                            "offset": int(off, 16), "inode": int(inode), "path": path})
    except PermissionError:
        raise Erro(f"sem permissão para /proc/{pid}/maps")
    except FileNotFoundError:
        raise Erro(f"processo {pid} não existe")
    return out


def modules(pid: int, maps: list[dict] | None = None) -> list[dict]:
    """Módulos = arquivos mapeados (ELF .so/exe e, no Wine/Proton, .exe/.dll PE)."""
    maps = maps or parse_maps(pid)
    mods: dict[str, dict] = {}
    for r in maps:
        p = r["path"]
        if not p or p.startswith("[") or r["inode"] == 0 or p.startswith("/memfd:") or p.startswith("/dev/"):
            continue
        m = mods.get(p)
        if m is None:
            mods[p] = {"name": os.path.basename(p), "path": p, "base": r["start"] - r["offset"]
                       if r["offset"] <= r["start"] else r["start"], "end": r["end"], "first": r["start"]}
        else:
            m["end"] = max(m["end"], r["end"])
            m["first"] = min(m["first"], r["start"])
    out = []
    for m in mods.values():
        base = min(m["first"], m["base"])
        out.append({"name": m["name"], "path": m["path"], "base": base, "size": m["end"] - base})
    out.sort(key=lambda m: m["base"])
    return out


def find_module(pid: int, name: str, maps=None) -> dict:
    alvo = name.strip('"').lower()
    mods = modules(pid, maps)
    for m in mods:
        if m["name"].lower() == alvo:
            return m
    for m in mods:
        stem = m["name"].lower().rsplit(".", 1)[0]
        if stem == alvo:
            return m
    for m in mods:
        if alvo in m["name"].lower():
            return m
    raise Erro(f"módulo não encontrado: {name}")


def resolve_pid(alvo: str) -> int:
    try:
        return best_process(alvo)[0]["pid"]
    except BridgeError as e:
        raise Erro(str(e))


def parse_addr(pid: int, s: str | int) -> int:
    if isinstance(s, int):
        return s
    s = s.strip()
    m = re.match(r'^"?([^"+\[\]]+?)"?\s*\+\s*(?:0x)?([0-9a-fA-F]+)$', s)
    if m and not re.fullmatch(r"(0x)?[0-9a-fA-F]+", m.group(1)):
        return find_module(pid, m.group(1))["base"] + int(m.group(2), 16)
    if re.fullmatch(r"(0x)?[0-9a-fA-F]+", s):
        return int(s, 16)
    try:
        return find_module(pid, s)["base"]
    except Erro:
        raise Erro(f"endereço inválido: {s} (use hex, 'modulo+offset' ou nome de módulo)")


class Mem:
    def __init__(self, pid: int, write: bool = False):
        self.pid = pid
        try:
            self.fd = os.open(f"/proc/{pid}/mem", os.O_RDWR if write else os.O_RDONLY)
        except PermissionError:
            scope = Path("/proc/sys/kernel/yama/ptrace_scope").read_text().strip()
            raise Erro(f"sem permissão para ler o PID {pid} (ptrace_scope={scope}). "
                       "Rode o install.sh da skill ou use sudo.")
        except FileNotFoundError:
            raise Erro(f"processo {pid} não existe")

    def read(self, addr: int, n: int) -> bytes:
        try:
            data = os.pread(self.fd, n, addr)
        except OSError as e:
            raise Erro(f"leitura falhou em {addr:#x}: {e.strerror}")
        if len(data) < n:
            raise Erro(f"leitura curta em {addr:#x} ({len(data)}/{n})")
        return data

    def try_read(self, addr: int, n: int) -> bytes | None:
        try:
            return os.pread(self.fd, n, addr)
        except OSError:
            return None

    def write(self, addr: int, data: bytes):
        try:
            n = os.pwrite(self.fd, data, addr)
        except OSError as e:
            raise Erro(f"escrita falhou em {addr:#x}: {e.strerror}")
        if n != len(data):
            raise Erro(f"escrita curta em {addr:#x}")

    def close(self):
        os.close(self.fd)


def scan_regions(maps: list[dict], writable=True, module: dict | None = None) -> list[dict]:
    out = []
    for r in maps:
        if r["perms"][0] != "r":
            continue
        if writable and r["perms"][1] != "w":
            continue
        if r["path"] in ("[vvar]", "[vsyscall]", "[vvar_vclock]") or r["path"].startswith("/dev/"):
            continue
        if module and not (module["base"] <= r["start"] < module["base"] + module["size"]):
            continue
        out.append(r)
    return out


def ptr_size(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/exe", "rb") as f:
            return 8 if f.read(5)[4] == 2 else 4
    except OSError:
        return 8


# ---------------------------------------------------------------------------
# Valores
# ---------------------------------------------------------------------------
def pack(t: str, v: str) -> bytes:
    if t == "string":
        return v.encode() + b"\0"
    if t == "widestring":
        return v.encode("utf-16-le") + b"\0\0"
    if t == "bytes":
        return bytes.fromhex(v.replace(" ", ""))
    fmt = TYPES[t][0]
    if t in ("float", "double"):
        return struct.pack(fmt, float(v))
    n = int(v, 0) if isinstance(v, str) else int(v)
    bits = TYPES[t][2] * 8
    if n < 0 and fmt[1].isupper():
        n &= (1 << bits) - 1
    return struct.pack(fmt, n)


def unpack(t: str, b: bytes):
    return struct.unpack(TYPES[t][0], b[: TYPES[t][2]])[0]


def decimals(v: str) -> int:
    v = str(v)
    return len(v.split(".", 1)[1]) if "." in v else 0


# ---------------------------------------------------------------------------
# Sessões de scan (disco: ~/.cache/ce-agent/cemem/<sessão>)
# ---------------------------------------------------------------------------
def sess_dir(name: str) -> Path:
    return CACHE / "sessions" / re.sub(r"[^\w.-]", "_", name)


def save_session(name: str, meta: dict, addrs, vals=None):
    d = sess_dir(name)
    if d.exists():
        for f in d.rglob("*"):
            if f.is_file():
                f.unlink()
    d.mkdir(parents=True, exist_ok=True)
    np.save(d / "addrs.npy", addrs)
    if vals is not None:
        np.save(d / "vals.npy", vals)
    meta["count"] = int(len(addrs))
    (d / "meta.json").write_text(json.dumps(meta))


def load_session(name: str):
    d = sess_dir(name)
    try:
        meta = json.loads((d / "meta.json").read_text())
    except OSError:
        raise Erro(f"sessão {name!r} não existe (faça: cemem scan ...)")
    return meta, d


def read_at(mem: Mem, maps: list[dict], addrs, dtype, size: int):
    """Lê `size` bytes em cada endereço (vetorizado por região). Devolve (vals, ok_mask)."""
    vals = np.zeros(len(addrs), dtype=dtype)
    ok = np.zeros(len(addrs), dtype=bool)
    if len(addrs) == 0:
        return vals, ok
    order = np.argsort(addrs)
    sa = addrs[order]
    for r in maps:
        lo, hi = np.searchsorted(sa, r["start"]), np.searchsorted(sa, r["end"] - size, side="right")
        if lo >= hi:
            continue
        span_lo, span_hi = int(sa[lo]), int(sa[hi - 1]) + size
        data = mem.try_read(span_lo, span_hi - span_lo)
        if not data or len(data) < span_hi - span_lo:
            continue
        buf = np.frombuffer(data, dtype=np.uint8)
        rel = (sa[lo:hi] - span_lo).astype(np.int64)
        idx = rel[:, None] + np.arange(size)[None, :]
        raw = buf[idx].copy().view(dtype).reshape(-1)
        vals[order[lo:hi]] = raw
        ok[order[lo:hi]] = True
    return vals, ok


def compare(op: str, cur, old, v=None, v2=None, tol=0.0):
    if op == "exact":
        return np.abs(cur - v) <= tol if tol else cur == v
    if op == "between":
        return (cur >= v) & (cur <= v2)
    if op == "bigger":
        return cur > v
    if op == "smaller":
        return cur < v
    if op == "increased":
        return cur > old
    if op == "decreased":
        return cur < old
    if op == "increased_by":
        return np.abs((cur - old) - v) <= tol if tol else (cur - old) == v
    if op == "decreased_by":
        return np.abs((old - cur) - v) <= tol if tol else (old - cur) == v
    if op == "changed":
        return cur != old
    if op == "unchanged":
        return cur == old
    raise Erro(f"operação inválida: {op}")


def cmd_scan(a):
    need_numpy()
    pid = resolve_pid(a.alvo)
    t = canon(a.type)
    maps = parse_maps(pid)
    mod = find_module(pid, a.module, maps) if a.module else None
    regs = scan_regions(maps, writable=not a.all_regions, module=mod)
    mem = Mem(pid)
    t0 = time.time()
    meta = {"pid": pid, "type": t, "created": t0, "scans": 1}
    if t in ("string", "widestring", "bytes"):
        pat = pack(t, a.value)[:-1 if t == "string" else (-2 if t == "widestring" else None)]
        hits = []
        for r in regs:
            for base in range(r["start"], r["end"], CHUNK):
                data = mem.try_read(base, min(CHUNK + len(pat), r["end"] - base))
                if not data:
                    continue
                i = data.find(pat)
                while i != -1:
                    hits.append(base + i)
                    i = data.find(pat, i + 1)
        addrs = np.unique(np.array(hits, dtype=np.uint64))
        meta["pattern"] = pat.hex()
        save_session(a.session, meta, addrs)
        return summary(a.session, addrs, None, t, time.time() - t0)
    _, dt, size = TYPES[t]
    dtype = np.dtype(dt)
    align = 1 if a.unaligned else size
    unknown = a.value is None
    if unknown:  # snapshot completo para comparar depois
        d = sess_dir(a.session)
        save_session(a.session, dict(meta, unknown=True, align=align), np.zeros(0, dtype=np.uint64))
        snap = d / "snap"
        snap.mkdir(exist_ok=True)
        total = 0
        for r in regs:
            data = mem.try_read(r["start"], r["end"] - r["start"])
            if data:
                (snap / f"{r['start']:x}.bin").write_bytes(data)
                total += len(data) // align
        meta.update(unknown=True, align=align, count=total)
        (d / "meta.json").write_text(json.dumps(meta))
        return {"session": a.session, "pid": pid, "type": t, "unknown": True, "candidates": total,
                "seconds": round(time.time() - t0, 2),
                "next": "cemem next increased|decreased|changed|unchanged|<valor>"}
    v = float(a.value) if t in ("float", "double") else int(a.value, 0)
    tol = 0.5 * 10 ** -decimals(a.value) if t in ("float", "double") else 0
    v2 = (float(a.value2) if t in ("float", "double") else int(a.value2, 0)) if a.value2 else None
    hits_a, hits_v = [], []
    for r in regs:
        for base in range(r["start"], r["end"], CHUNK):
            n = min(CHUNK, r["end"] - base)
            data = mem.try_read(base, n)
            if not data:
                continue
            for shift in range(0, size, align):
                usable = (len(data) - shift) // size * size
                if usable <= 0:
                    continue
                arr = np.frombuffer(data, dtype=dtype, count=usable // size, offset=shift)
                m = compare(a.op, arr, None, v, v2, tol)
                idx = np.flatnonzero(m)
                if idx.size:
                    hits_a.append(base + shift + idx.astype(np.uint64) * size)
                    hits_v.append(arr[idx])
    addrs = np.concatenate(hits_a) if hits_a else np.zeros(0, dtype=np.uint64)
    vals = np.concatenate(hits_v) if hits_v else np.zeros(0, dtype=dtype)
    order = np.argsort(addrs)
    save_session(a.session, meta, addrs[order], vals[order])
    return summary(a.session, addrs[order], vals[order], t, time.time() - t0)


def summary(sess, addrs, vals, t, secs, preview=20):
    r = {"session": sess, "type": t, "found": int(len(addrs)), "seconds": round(secs, 2)}
    if len(addrs):
        r["results"] = [{"address": f"{int(x):#x}", **({"value": vals[i].item()} if vals is not None else {})}
                        for i, x in enumerate(addrs[:preview])]
        r["truncated"] = len(addrs) > preview
    return r


def cmd_next(a):
    need_numpy()
    meta, d = load_session(a.session)
    pid, t = meta["pid"], meta["type"]
    if t in ("string", "widestring", "bytes"):
        raise Erro("next scan não suportado para string/bytes (refaça o scan)")
    _, dt, size = TYPES[t]
    dtype = np.dtype(dt)
    w = a.op_or_value.lower()
    ops = {"increased", "decreased", "changed", "unchanged", "bigger", "smaller", "between", "exact"}
    if w in ops:
        op, val = w, a.value
        if op in ("increased", "decreased") and val is not None:
            op += "_by"
    else:
        op, val = "exact", a.op_or_value
    v = (float(val) if t in ("float", "double") else int(val, 0)) if val is not None else None
    v2 = (float(a.value2) if t in ("float", "double") else int(a.value2, 0)) if a.value2 else None
    tol = 0.5 * 10 ** -decimals(val) if (val is not None and t in ("float", "double")) else 0
    mem = Mem(pid)
    maps = parse_maps(pid)
    t0 = time.time()
    if meta.get("unknown") and (d / "snap").exists():
        align = meta.get("align", size)
        hits_a, hits_v = [], []
        for f in sorted((d / "snap").glob("*.bin")):
            base = int(f.stem, 16)
            old_b = f.read_bytes()
            cur_b = mem.try_read(base, len(old_b))
            if not cur_b or len(cur_b) != len(old_b):
                continue
            for shift in range(0, size, align):
                usable = (len(old_b) - shift) // size
                if usable <= 0:
                    continue
                old = np.frombuffer(old_b, dtype=dtype, count=usable, offset=shift)
                cur = np.frombuffer(cur_b, dtype=dtype, count=usable, offset=shift)
                m = compare(op, cur, old, v, v2, tol)
                idx = np.flatnonzero(m)
                if idx.size:
                    hits_a.append(base + shift + idx.astype(np.uint64) * size)
                    hits_v.append(cur[idx])
        addrs = np.concatenate(hits_a) if hits_a else np.zeros(0, dtype=np.uint64)
        vals = np.concatenate(hits_v) if hits_v else np.zeros(0, dtype=dtype)
        order = np.argsort(addrs)
        addrs, vals = addrs[order], vals[order]
    else:
        addrs = np.load(d / "addrs.npy")
        old = np.load(d / "vals.npy") if (d / "vals.npy").exists() else None
        cur, ok = read_at(mem, maps, addrs, dtype, size)
        if old is None:
            old = cur
        m = compare(op, cur, old, v, v2, tol) & ok
        addrs, vals = addrs[m], cur[m]
    meta["scans"] = meta.get("scans", 1) + 1
    meta.pop("unknown", None)
    save_session(a.session, meta, addrs, vals)
    return summary(a.session, addrs, vals, t, time.time() - t0)


def cmd_results(a):
    need_numpy()
    meta, d = load_session(a.session)
    addrs = np.load(d / "addrs.npy")
    vals = np.load(d / "vals.npy") if (d / "vals.npy").exists() else None
    if a.refresh and meta["type"] in TYPES:
        _, dt, size = TYPES[meta["type"]]
        vals, _ = read_at(Mem(meta["pid"]), parse_maps(meta["pid"]), addrs, np.dtype(dt), size)
    sl = slice(a.offset, a.offset + a.limit)
    return {"session": a.session, "pid": meta["pid"], "type": meta["type"], "total": int(len(addrs)),
            "results": [{"address": f"{int(x):#x}", **({"value": vals[a.offset + i].item()} if vals is not None else {})}
                        for i, x in enumerate(addrs[sl])]}


# ---------------------------------------------------------------------------
# Leitura/escrita/ponteiros/AOB
# ---------------------------------------------------------------------------
def read_value(mem: Mem, addr: int, t: str, maxlen=256):
    if t == "string":
        return mem.read(addr, maxlen).split(b"\0", 1)[0].decode("utf-8", "replace")
    if t == "widestring":
        raw = mem.read(addr, maxlen * 2)
        end = next((i for i in range(0, len(raw) - 1, 2) if raw[i:i + 2] == b"\0\0"), len(raw))
        return raw[:end].decode("utf-16-le", "replace")
    if t == "bytes":
        return mem.read(addr, maxlen).hex(" ").upper()
    return unpack(t, mem.read(addr, TYPES[t][2]))


def cmd_read(a):
    pid = resolve_pid(a.alvo)
    t = canon(a.type)
    addr = parse_addr(pid, a.endereco)
    mem = Mem(pid)
    if t in TYPES and a.count > 1:
        sz = TYPES[t][2]
        raw = mem.read(addr, sz * a.count)
        return {"address": f"{addr:#x}", "type": t, "values": [unpack(t, raw[i * sz:]) for i in range(a.count)]}
    return {"address": f"{addr:#x}", "type": t,
            "value": read_value(mem, addr, t, a.count if t == "bytes" and a.count > 1 else a.maxlen)}


def cmd_write(a):
    pid = resolve_pid(a.alvo)
    t = canon(a.type)
    addr = parse_addr(pid, a.endereco)
    data = pack(t, a.valor)
    if t == "string" and a.no_terminator:
        data = data[:-1]
    mem = Mem(pid, write=True)
    before = mem.read(addr, len(data))
    mem.write(addr, data)
    after = mem.read(addr, len(data))
    return {"address": f"{addr:#x}", "type": t, "before": before.hex(" ").upper(),
            "after": after.hex(" ").upper(), "changed": before != after}


def walk(mem: Mem, pid: int, base: int, offsets: list[int], psize: int):
    a, chain = base, [{"step": "base", "address": f"{base:#x}"}]
    for i, off in enumerate(offsets, 1):
        raw = mem.try_read(a, psize)
        if not raw or len(raw) < psize:
            chain.append({"step": i, "error": f"ilegível em {a:#x}"})
            return None, chain
        ptr = int.from_bytes(raw, "little")
        a = ptr + off
        chain.append({"step": i, "pointer": f"{ptr:#x}", "offset": f"{off:#x}", "address": f"{a:#x}"})
    return a, chain


def parse_offsets(vals):
    out = []
    for v in vals or []:
        neg = v.startswith("-")
        out.append((-1 if neg else 1) * int(v.lstrip("+-"), 16))
    return out


def cmd_ptr(a):
    pid = resolve_pid(a.alvo)
    mem = Mem(pid)
    final, chain = walk(mem, pid, parse_addr(pid, a.base), parse_offsets(a.offsets), ptr_size(pid))
    r = {"chain": chain, "valid": final is not None, "address": f"{final:#x}" if final is not None else None}
    if final is not None and a.type:
        try:
            r["value"] = read_value(mem, final, canon(a.type))
        except Erro as e:
            r["error"] = str(e)
    return r


def aob_regex(pattern: str) -> re.Pattern:
    parts = []
    for tok in pattern.replace(",", " ").split():
        if tok in ("?", "??", "*", "**"):
            parts.append(b".")
        else:
            parts.append(re.escape(bytes([int(tok, 16)])))
    return re.compile(b"".join(parts), re.DOTALL)


def cmd_aob(a):
    pid = resolve_pid(a.alvo)
    maps = parse_maps(pid)
    mod = find_module(pid, a.module, maps) if a.module else None
    rx = aob_regex(a.padrao)
    mem = Mem(pid)
    hits = []
    for r in scan_regions(maps, writable=False, module=mod):
        if not a.module and "x" not in r["perms"] and not a.all_regions:
            continue
        for base in range(r["start"], r["end"], CHUNK):
            data = mem.try_read(base, min(CHUNK + 64, r["end"] - base))
            if not data:
                continue
            for m in rx.finditer(data):
                if len(hits) < a.limit:
                    hits.append(base + m.start())
    hits = sorted(set(hits))
    mods = modules(pid, maps)

    def rel(x):
        for m in mods:
            if m["base"] <= x < m["base"] + m["size"]:
                return f'{m["name"]}+{x - m["base"]:x}'
        return None
    return {"pattern": a.padrao, "count": len(hits),
            "results": [{"address": f"{h:#x}", "module_offset": rel(h)} for h in hits]}


def cmd_dump(a):
    pid = resolve_pid(a.alvo)
    addr = parse_addr(pid, a.endereco)
    data = Mem(pid).read(addr, a.size)
    lines = []
    for i in range(0, len(data), 16):
        row = data[i:i + 16]
        lines.append(f"{addr + i:#x}  {row.hex(' ').upper():<47}  " +
                     "".join(chr(c) if 32 <= c < 127 else "." for c in row))
    return {"address": f"{addr:#x}", "lines": lines}


# ---------------------------------------------------------------------------
# Pointer scan (mapa reverso de ponteiros, BFS do alvo até módulos estáticos)
# ---------------------------------------------------------------------------
def cmd_ptrscan(a):
    need_numpy()
    pid = resolve_pid(a.alvo)
    maps = parse_maps(pid)
    psize = ptr_size(pid)
    dt = np.dtype("<u8" if psize == 8 else "<u4")
    target = parse_addr(pid, a.endereco)
    maxoff = int(a.max_offset, 16) if isinstance(a.max_offset, str) else a.max_offset
    mem = Mem(pid)
    t0 = time.time()
    rw = scan_regions(maps, writable=True)
    readable = [(r["start"], r["end"]) for r in maps if r["perms"][0] == "r"]
    lo_all = min(s for s, _ in readable)
    hi_all = max(e for _, e in readable)
    mods = modules(pid, maps)
    if a.module:
        statics = [find_module(pid, m, maps) for m in a.module]
    else:
        statics = [m for m in mods if not m["path"].startswith("/usr/lib") and not m["path"].startswith("/lib")] \
            if a.main_only else mods

    def static_of(x: int):
        for m in statics:
            if m["base"] <= x < m["base"] + m["size"]:
                return m
        return None

    # 1) mapa de ponteiros: (valor, local) para todo valor alinhado que aponta para memória legível
    vals_l, locs_l = [], []
    starts = np.array([s for s, _ in readable], dtype=np.uint64)
    ends = np.array([e for _, e in readable], dtype=np.uint64)
    for r in rw:
        for base in range(r["start"], r["end"], CHUNK):
            data = mem.try_read(base, min(CHUNK, r["end"] - base))
            if not data:
                continue
            arr = np.frombuffer(data, dtype=dt, count=len(data) // psize).astype(np.uint64)
            m = (arr >= lo_all) & (arr < hi_all)
            idx = np.flatnonzero(m)
            if not idx.size:
                continue
            v = arr[idx]
            k = np.searchsorted(starts, v, side="right") - 1
            ok = (k >= 0) & (v < ends[np.clip(k, 0, len(ends) - 1)])
            vals_l.append(v[ok])
            locs_l.append(base + idx[ok].astype(np.uint64) * psize)
    if not vals_l:
        return {"target": f"{target:#x}", "paths": [], "note": "nenhum ponteiro encontrado"}
    pv = np.concatenate(vals_l)
    pl = np.concatenate(locs_l)
    order = np.argsort(pv, kind="stable")
    pv, pl = pv[order], pl[order]
    built = time.time() - t0

    # 2) BFS reversa (coleta folgada; ordena e corta no fim)
    teto = max(a.limit * 10, 500)
    results = []
    frontier = [(target, [])]  # (endereço a alcançar, offsets do fim para o começo)
    seen = {target}
    for depth in range(1, a.depth + 1):
        nxt = []
        for addr, offs in frontier:
            lo = np.searchsorted(pv, max(0, addr - maxoff))
            hi = np.searchsorted(pv, addr, side="right")
            for j in range(lo, hi):
                loc = int(pl[j])
                off = addr - int(pv[j])
                path = [off] + offs
                m = static_of(loc)
                if m is not None:
                    results.append({"base": f'{m["name"]}+{loc - m["base"]:x}', "offsets": [f"{o:x}" for o in path],
                                    "depth": depth})
                    if len(results) >= teto:
                        break
                elif depth < a.depth and loc not in seen and len(nxt) < a.max_nodes:
                    seen.add(loc)
                    nxt.append((loc, path))
            if len(results) >= teto:
                break
        if len(results) >= teto:
            break
        frontier = nxt
        if not frontier:
            break
    sistema = {m["name"] for m in mods if m["path"].startswith(("/usr/", "/lib", "/opt/"))
               or "/lib/wine/" in m["path"] or "/system32/" in m["path"].lower()
               or "/syswow64/" in m["path"].lower()}
    # primeiro: módulos do próprio programa; depois menos níveis; depois offsets menores
    results.sort(key=lambda r: (r["base"].rsplit("+", 1)[0] in sistema, r["depth"],
                                [int(o, 16) for o in r["offsets"]]))
    # 3) validação: cada caminho precisa chegar no alvo agora
    valid = []
    for r in results:
        if len(valid) >= a.limit:
            break
        mod, off = r["base"].rsplit("+", 1)
        m = next(x for x in statics if x["name"] == mod)
        final, _ = walk(mem, pid, m["base"] + int(off, 16), [int(o, 16) for o in r["offsets"]], psize)
        if final == target:
            r["ce_address"] = f'"{mod}"+{off}'
            valid.append(r)
    return {"target": f"{target:#x}", "pointers_mapped": int(len(pv)), "map_seconds": round(built, 2),
            "seconds": round(time.time() - t0, 2), "count": len(valid), "paths": valid,
            "tip": "confirme reiniciando o alvo: cemem ptr <alvo> <base> <offsets...>"}


# ---------------------------------------------------------------------------
# Freeze em segundo plano
# ---------------------------------------------------------------------------
def cmd_freeze(a):
    pid = resolve_pid(a.alvo)
    t = canon(a.type)
    addr = parse_addr(pid, a.endereco)
    offs = parse_offsets(a.offsets)
    data = pack(t, a.valor)
    if a.background:
        fdir = CACHE / "freezes"
        fdir.mkdir(parents=True, exist_ok=True)
        cmd = [sys.executable, os.path.abspath(__file__), "freeze", str(pid), a.endereco, a.valor,
               "-t", t, "--interval", str(a.interval)] + (["--offsets", *a.offsets] if a.offsets else [])
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        fid = f"f{p.pid}"
        (fdir / f"{fid}.json").write_text(json.dumps({"id": fid, "pid": p.pid, "target_pid": pid,
                                                       "address": a.endereco, "offsets": a.offsets,
                                                       "value": a.valor, "type": t}))
        return {"freeze_id": fid, "background_pid": p.pid, "target_pid": pid, "address": a.endereco,
                "value": a.valor, "stop": f"cemem unfreeze {fid}"}
    mem = Mem(pid, write=True)
    psize = ptr_size(pid)
    t_end = time.time() + a.seconds if a.seconds else None
    n = 0
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while t_end is None or time.time() < t_end:
        if not Path(f"/proc/{pid}").exists():
            break
        dst = addr if not offs else walk(mem, pid, addr, offs, psize)[0]
        if dst is not None:
            try:
                mem.write(dst, data)
                n += 1
            except Erro:
                pass
        time.sleep(a.interval)
    return {"writes": n, "address": a.endereco}


def cmd_unfreeze(a):
    fdir = CACHE / "freezes"
    alvos = list(fdir.glob("*.json")) if a.all or not a.id else [fdir / f"{a.id}.json"]
    out = []
    for f in alvos:
        try:
            info = json.loads(f.read_text())
            os.kill(info["pid"], signal.SIGTERM)
            out.append(info["id"])
        except (OSError, ValueError, KeyError):
            pass
        f.unlink(missing_ok=True)
    return {"stopped": out}


def cmd_freezes(_a):
    fdir = CACHE / "freezes"
    out = []
    for f in fdir.glob("*.json") if fdir.exists() else []:
        info = json.loads(f.read_text())
        info["alive"] = Path(f"/proc/{info['pid']}").exists()
        out.append(info)
    return {"count": len(out), "freezes": out}


# ---------------------------------------------------------------------------
# Disasm / asm
# ---------------------------------------------------------------------------
def cmd_disasm(a):
    try:
        import capstone
    except ImportError:
        raise Erro("capstone não instalado: sudo pacman -S python-capstone")
    pid = resolve_pid(a.alvo)
    addr = parse_addr(pid, a.endereco)
    bits = a.bits or (64 if ptr_size(pid) == 8 else 32)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64 if bits == 64 else capstone.CS_MODE_32)
    code = Mem(pid).read(addr, a.count * 15)
    out = []
    for ins in md.disasm(code, addr):
        out.append({"address": f"{ins.address:#x}", "bytes": ins.bytes.hex(" ").upper(),
                    "opcode": f"{ins.mnemonic} {ins.op_str}".strip()})
        if len(out) >= a.count:
            break
    return {"bits": bits, "count": len(out), "instructions": out}


def cmd_asm(a):
    try:
        import keystone
    except ImportError:
        raise Erro("keystone não instalado: sudo pacman -S python-keystone")
    ks = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_64 if a.bits == 64 else keystone.KS_MODE_32)
    at = int(a.at, 16) if a.at else 0
    enc, _ = ks.asm(a.linha, at)
    return {"line": a.linha, "address": f"{at:#x}", "bytes": bytes(enc or []).hex(" ").upper(),
            "size": len(enc or [])}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="cemem", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True, metavar="comando")

    def add(n, h):
        return sp.add_parser(n, help=h, description=h)

    p = add("ps", "processos (nativo/Wine/Proton)")
    p.add_argument("filtro", nargs="?")
    p = add("maps", "mapa de memória (/proc/PID/maps)")
    p.add_argument("alvo")
    p.add_argument("filtro", nargs="?")
    p.add_argument("--writable", action="store_true")
    p = add("modules", "módulos e bases (ELF e PE/Wine)")
    p.add_argument("alvo")
    p.add_argument("filtro", nargs="?")
    p = add("read", "lê memória")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("-n", "--count", type=int, default=1)
    p.add_argument("--maxlen", type=int, default=256)
    p = add("write", "escreve memória")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("valor")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("--no-terminator", action="store_true")
    p = add("scan", "first scan (sem valor = valor desconhecido)")
    p.add_argument("alvo")
    p.add_argument("value", nargs="?")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("--op", default="exact", choices=["exact", "between", "bigger", "smaller"])
    p.add_argument("--value2")
    p.add_argument("-m", "--module")
    p.add_argument("--unaligned", action="store_true")
    p.add_argument("--all-regions", action="store_true", help="inclui regiões só-leitura")
    p.add_argument("-s", "--session", default="default")
    p = add("next", "next scan: valor | increased | decreased | changed | unchanged | bigger N ...")
    p.add_argument("op_or_value")
    p.add_argument("value", nargs="?")
    p.add_argument("--value2")
    p.add_argument("-s", "--session", default="default")
    p = add("results", "resultados da sessão")
    p.add_argument("-s", "--session", default="default")
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--refresh", action="store_true", help="relê os valores atuais")
    p = add("ptr", "segue cadeia: cemem ptr <alvo> <base> <off1> <off2>...")
    p.add_argument("alvo")
    p.add_argument("base")
    p.add_argument("offsets", nargs="*")
    p.add_argument("-t", "--type", default="dword")
    p = add("ptrscan", "procura cadeias de ponteiros estáveis até um endereço")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("--depth", type=int, default=3)
    p.add_argument("--max-offset", default="1000", help="hex (padrão 0x1000)")
    p.add_argument("-m", "--module", action="append", help="só bases neste(s) módulo(s)")
    p.add_argument("--main-only", action="store_true", help="ignora libs do sistema (/usr/lib)")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--max-nodes", type=int, default=5000)
    p = add("aob", "procura padrão de bytes (?? = coringa)")
    p.add_argument("alvo")
    p.add_argument("padrao")
    p.add_argument("-m", "--module")
    p.add_argument("--all-regions", action="store_true")
    p.add_argument("--limit", type=int, default=100)
    p = add("dump", "hexdump")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("-s", "--size", type=int, default=256)
    p = add("freeze", "congela valor (loop; --background para segundo plano)")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("valor")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("--offsets", nargs="*")
    p.add_argument("--interval", type=float, default=0.05)
    p.add_argument("--seconds", type=float)
    p.add_argument("--background", action="store_true")
    p = add("unfreeze", "para freeze(s) em segundo plano")
    p.add_argument("id", nargs="?")
    p.add_argument("--all", action="store_true")
    add("freezes", "lista freezes em segundo plano")
    p = add("disasm", "desmonta (capstone)")
    p.add_argument("alvo")
    p.add_argument("endereco")
    p.add_argument("-n", "--count", type=int, default=20)
    p.add_argument("--bits", type=int, choices=[32, 64])
    p = add("asm", "monta instruções (keystone): 'mov eax,1; ret'")
    p.add_argument("linha")
    p.add_argument("--at")
    p.add_argument("--bits", type=int, default=64, choices=[32, 64])
    return ap


def main(argv=None):
    a = build().parse_args(argv)
    try:
        if a.cmd == "ps":
            procs = [p for p in list_processes(a.filtro) if p["uid"] == os.getuid()]
            r = {"count": len(procs), "processes": procs[:200]}
        elif a.cmd == "maps":
            pid = resolve_pid(a.alvo)
            regs = [x for x in parse_maps(pid) if (not a.filtro or a.filtro.lower() in x["path"].lower())
                    and (not a.writable or x["perms"][1] == "w")]
            r = {"pid": pid, "count": len(regs), "regions": [
                {"start": f"{x['start']:#x}", "end": f"{x['end']:#x}", "size": x["end"] - x["start"],
                 "perms": x["perms"], "path": x["path"]} for x in regs[:2000]]}
        elif a.cmd == "modules":
            pid = resolve_pid(a.alvo)
            mods = [m for m in modules(pid) if not a.filtro or a.filtro.lower() in m["name"].lower()]
            r = {"pid": pid, "process": proc_info(pid), "count": len(mods), "modules": [
                {"name": m["name"], "base": f"{m['base']:#x}", "size": m["size"], "path": m["path"]} for m in mods]}
        else:
            r = globals()[f"cmd_{a.cmd}"](a)
    except (Erro, BridgeError) as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False, indent=2))
        return 1
    print(json.dumps(r, ensure_ascii=False, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
