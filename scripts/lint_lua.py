#!/usr/bin/env python3
"""Verificador de sintaxe Lua usando a PRÓPRIA DLL do Cheat Engine.

Por que não usar um linter externo: o Cheat Engine 7.7 embarca Lua 5.3 compilado
em ``lua53-64.dll`` (e ``lua53-32.dll``). Compilar o arquivo com exatamente essa
DLL é a única forma de garantir que o bytecode é válido para o interpretador que
vai realmente executá-lo — sem depender de instalar Lua na máquina.

Uso:
    python scripts/lint_lua.py autorun/ce_agent_bridge.lua
    python scripts/lint_lua.py autorun/*.lua --dll "C:/Program Files/Cheat Engine/lua53-64.dll"

Saída: uma linha por arquivo, com ``OK`` ou ``ERRO: <mensagem>``.
Código de saída: 0 se todos passaram, 1 se algum falhou.
"""

from __future__ import annotations

import argparse
import ctypes
import glob
import sys
from pathlib import Path

CE_DIRS = (
    r"C:\Program Files\Cheat Engine",
    r"C:\Program Files (x86)\Cheat Engine",
)
DLL_NAMES = ("lua53-64.dll", "lua53-32.dll")

LUA_OK = 0
LUA_ERRSYNTAX = 3

# Assinaturas (Lua 5.3). lua_State* é opaco.
luaL_newstate = ("luaL_newstate", ctypes.c_void_p, ())
luaL_loadbufferx = (
    "luaL_loadbufferx",
    ctypes.c_int,
    (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p),
)
lua_tolstring = ("lua_tolstring", ctypes.c_char_p, (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)))
lua_close = ("lua_close", None, (ctypes.c_void_p,))


def find_dll(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.is_file():
            raise SystemExit(f"DLL informada não existe: {p}")
        return p
    for d in CE_DIRS:
        for name in DLL_NAMES:
            p = Path(d) / name
            if p.is_file():
                return p
    raise SystemExit(
        "não encontrei lua53-*.dll. Instale o Cheat Engine ou passe --dll <caminho>."
    )


def bind(dll_path: Path) -> ctypes.CDLL:
    dll = ctypes.CDLL(str(dll_path))
    for name, restype, argtypes in (luaL_newstate, luaL_loadbufferx, lua_tolstring, lua_close):
        fn = getattr(dll, name)
        fn.restype = restype
        fn.argtypes = argtypes
    return dll


def check(dll: ctypes.CDLL, path: Path) -> str | None:
    """Retorna None se compilar, ou a mensagem de erro de sintaxe."""
    source = path.read_bytes()
    state = dll.luaL_newstate()
    if not state:
        raise SystemExit("luaL_newstate falhou (DLL incompatível com esta arquitetura?)")
    try:
        chunkname = f"@{path.name}".encode()
        rc = dll.luaL_loadbufferx(state, source, len(source), chunkname, None)
        if rc == LUA_OK:
            return None
        size = ctypes.c_size_t(0)
        msg = dll.lua_tolstring(state, -1, ctypes.byref(size))
        return msg.decode("utf-8", "replace") if msg else f"erro Lua {rc} (sem mensagem)"
    finally:
        dll.lua_close(state)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Compila arquivos .lua com a DLL do Cheat Engine.")
    ap.add_argument("files", nargs="+", help="arquivos .lua (globs são expandidos pelo shell)")
    ap.add_argument("--dll", default=None, help="caminho explícito para lua53-64.dll / lua53-32.dll")
    args = ap.parse_args(argv)

    dll_path = find_dll(args.dll)
    dll = bind(dll_path)

    targets: list[Path] = []
    for pattern in args.files:
        hits = [Path(p) for p in glob.glob(pattern, recursive=True)]
        targets.extend(hits or [Path(pattern)])
    # Um arquivo sem extensão .lua nunca é Lua: ignoramos em silêncio para que
    # "lint_lua.py autorun/*.lua scripts/*.py" não vire ruído.
    skipped = [p for p in targets if p.is_file() and p.suffix.lower() != ".lua"]
    targets = [p for p in targets if p.is_file() and p.suffix.lower() == ".lua"]
    if not targets:
        detail = f" (ignorados: {', '.join(str(p) for p in skipped)})" if skipped else ""
        print(f"nenhum arquivo .lua encontrado{detail}", file=sys.stderr)
        return 1

    print(f"DLL: {dll_path}")
    failed = 0
    for path in targets:
        err = check(dll, path)
        if err is None:
            print(f"OK    {path}")
        else:
            failed += 1
            print(f"ERRO  {path}\n      {err}")
    print(f"\n{len(targets) - failed}/{len(targets)} compilaram")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
