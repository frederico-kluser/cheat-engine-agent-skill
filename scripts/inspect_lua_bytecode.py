# -*- coding: utf-8 -*-
"""Extrator de constantes de bytecode Lua 5.3 (undump parcial).

Uso: python inspect_lua_bytecode.py <arquivo.bin> [...]

Recebe chunks binarios gerados por string.dump() e imprime as constantes
(strings e numeros) de cada funcao, recursivamente. Serve para descobrir os
nomes REAIS de propriedades/opcoes que a API aceita, sem depender de docs.
"""
import sys
from pathlib import Path

LUA_SIGNATURE = b"\x1bLua"


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.i = 0

    def u8(self) -> int:
        v = self.d[self.i]
        self.i += 1
        return v

    def take(self, n: int) -> bytes:
        v = self.d[self.i:self.i + n]
        self.i += n
        return v

    def integer(self) -> int:
        """Lua 5.3 'integer' (varint com bloco de 7 bits)."""
        v = 0
        while True:
            b = self.u8()
            v = (v << 7) | (b & 0x7F)
            if b & 0x80 == 0:
                return v

    def lua_string(self) -> bytes:
        n = self.integer()
        return self.take(n)

    def size_t_string(self, size_of_size_t: int) -> bytes:
        n = int.from_bytes(self.take(size_of_size_t), "little")
        return self.take(n)


def undump_constants(data: bytes, size_of_size_t: int, depth: int = 0):
    """Devolve (strings, numeros, protos) de um chunk."""
    r = Reader(data)
    strings, numbers = [], []
    kids = []

    r.take(4)                      # signature
    r.u8()                         # version
    r.u8()                         # format
    r.take(6)                      # LUAC_DATA
    r.u8()                         # sizeof(Instruction)
    size_of_int = r.u8()
    size_of_size_t = r.u8()
    r.u8()                         # sizeof(Instruction) == 4 check
    r.u8()                         # sizeof(lua_Integer)
    r.u8()                         # sizeof(lua_Number)
    r.u8()                         # integral flag

    r.u8()                         # source
    r.integer()                    # linedefined
    r.integer()                    # lastlinedefined
    r.u8()                         # numparams
    r.u8()                         # is_vararg
    r.u8()                         # maxstacksize

    n = r.integer()                # code
    r.take(4 * n)

    n = r.integer()                # constants
    for _ in range(n):
        t = r.u8()
        if t == 0:                 # nil
            continue
        if t == 1:                 # boolean
            r.u8()
        elif t == 3:               # float
            numbers.append(("float", r.take(8)))
        elif t == 0x13:            # integer
            numbers.append(("int", r.integer()))
        elif t == 4:               # short string
            strings.append(r.lua_string())
        elif t == 0x14:            # long string
            strings.append(r.size_t_string(size_of_size_t))
        else:
            raise ValueError(f"constante desconhecida tipo {t} em offset {r.i}")

    n = r.integer()                # upvalues
    for _ in range(n):
        r.u8()
        r.u8()

    n = r.integer()                # protos
    for _ in range(n):
        s, num, k = undump_constants(r.d[r.i:], size_of_size_t, depth + 1)
        strings.extend(s)
        numbers.extend(num)
        kids.extend(k)
        # avanca o leitor principal pelo tamanho consumido pelo sub-leitor
        sub = Reader(r.d[r.i:])
        _skip_proto(sub, size_of_size_t)
        r.i += sub.i

    r.integer()                    # lineinfo
    r.integer()                    # locvars
    r.integer()                    # upvalue names
    return strings, numbers, kids


def _skip_proto(r: Reader, size_of_size_t: int):
    """Reproduz exatamente o consumo de undump_constants (para avancar)."""
    r.take(4); r.u8(); r.u8(); r.take(6)
    r.u8(); r.u8(); r.u8(); r.u8(); r.u8(); r.u8(); r.u8()
    r.u8(); r.integer(); r.integer(); r.u8(); r.u8(); r.u8()
    r.take(4 * r.integer())
    n = r.integer()
    for _ in range(n):
        t = r.u8()
        if t == 0:
            continue
        if t == 1:
            r.u8()
        elif t == 3:
            r.take(8)
        elif t == 0x13:
            r.integer()
        elif t == 4:
            r.lua_string()
        elif t == 0x14:
            r.size_t_string(size_of_size_t)
        else:
            raise ValueError(f"constante desconhecida tipo {t}")
    for _ in range(r.integer()):
        r.u8(); r.u8()
    for _ in range(r.integer()):
        _skip_proto(r, size_of_size_t)
    r.integer(); r.integer(); r.integer()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    for arg in sys.argv[1:]:
        p = Path(arg)
        data = p.read_bytes()
        if not data.startswith(LUA_SIGNATURE):
            print(f"{p.name}: nao e um chunk Lua")
            continue
        try:
            strings, numbers, _ = undump_constants(data, 8)
        except Exception as exc:  # noqa: BLE001
            print(f"{p.name}: falha no undump: {exc}")
            continue
        seen, out = set(), []
        for s in strings:
            txt = s.decode("utf-8", "replace")
            if txt not in seen:
                seen.add(txt)
                out.append(txt)
        nums = sorted({str(v) for _, v in numbers})
        print(f"=== {p.name} ({len(data)} bytes) ===")
        print("strings: " + ", ".join(repr(x) for x in out))
        if nums:
            print("numeros: " + ", ".join(nums))
    return 0


if __name__ == "__main__":
    sys.exit(main())
