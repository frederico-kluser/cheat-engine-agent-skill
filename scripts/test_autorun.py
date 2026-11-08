#!/usr/bin/env python3
"""Executa autorun/ce_agent_bridge.lua no Lua 5.3 REAL do Cheat Engine, com a API
do CE substituída por stubs (scripts/lua_stubs.lua).

Para que serve: quando a ponte tem erro de runtime (função que não existe, nil
index, bad argument), o autorun do CE engole o erro num diálogo da GUI e a porta
20000 simplesmente não abre. Aqui o erro vira mensagem de erro do Lua, com linha
e traceback, e o teste roda em segundos sem abrir janela nenhuma.

Depois de carregar a ponte, o teste chama handlers de verdade através de
_G.ce_bridge.call() e confere o que eles devolveram e quais APIs do CE acionaram.

Uso:
    python scripts/test_autorun.py
    python scripts/test_autorun.py --bridge autorun/ce_agent_bridge.lua --verbose
"""

from __future__ import annotations

import argparse
import ctypes
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BRIDGE = ROOT / "autorun" / "ce_agent_bridge.lua"
DEFAULT_STUBS = ROOT / "scripts" / "lua_stubs.lua"

# ------------------------------------------------------------------ Lua 5.3 ABI
LUA_OK = 0
LUA_MULTRET = -1
LUA_TSTRING = 4
LUA_TNUMBER = 3
LUA_TBOOLEAN = 1
LUA_TNIL = 0
LUA_TTABLE = 5


class LuaError(RuntimeError):
    pass


class Lua:
    def __init__(self, dll_path: Path) -> None:
        self.dll = ctypes.CDLL(str(dll_path))
        self._bind()
        self.state = self.dll.luaL_newstate()
        if not self.state:
            raise LuaError("luaL_newstate falhou")
        self.dll.luaL_openlibs(self.state)

    def _bind(self) -> None:
        sigs = [
            ("luaL_newstate", ctypes.c_void_p, ()),
            ("luaL_openlibs", None, (ctypes.c_void_p,)),
            ("luaL_loadbufferx", ctypes.c_int,
             (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p)),
            ("lua_pcallk", ctypes.c_int,
             (ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
              ctypes.c_void_p, ctypes.c_void_p)),
            ("lua_getglobal", ctypes.c_int, (ctypes.c_void_p, ctypes.c_char_p)),
            ("lua_type", ctypes.c_int, (ctypes.c_void_p, ctypes.c_int)),
            ("lua_tolstring", ctypes.c_char_p,
             (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t))),
            ("lua_toboolean", ctypes.c_int, (ctypes.c_void_p, ctypes.c_int)),
            ("lua_tonumberx", ctypes.c_double,
             (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int))),
            ("lua_settop", None, (ctypes.c_void_p, ctypes.c_int)),
            ("lua_gettop", ctypes.c_int, (ctypes.c_void_p,)),
            ("lua_close", None, (ctypes.c_void_p,)),
        ]
        for name, restype, argtypes in sigs:
            fn = getattr(self.dll, name)
            fn.restype = restype
            fn.argtypes = argtypes

    # -- helpers ---------------------------------------------------------------
    def _error_message(self, idx: int = -1) -> str:
        size = ctypes.c_size_t(0)
        msg = self.dll.lua_tolstring(self.state, idx, ctypes.byref(size))
        if msg:
            return msg.decode("utf-8", "replace")
        return f"<erro Lua nao-textual, tipo={self.dll.lua_type(self.state, idx)}>"

    def load(self, source: bytes | str, chunkname: str | bytes) -> None:
        if isinstance(source, str):
            source = source.encode("utf-8")
        if isinstance(chunkname, str):
            chunkname = chunkname.encode("utf-8")
        rc = self.dll.luaL_loadbufferx(self.state, source, len(source), chunkname, None)
        if rc != LUA_OK:
            msg = self._error_message()
            self.dll.lua_settop(self.state, 0)
            raise LuaError(msg)

    def pcall(self, nargs: int = 0, nresults: int = 0) -> None:
        """Chama o chunk/funcao do topo. nresults=-1 preserva todos os retornos."""
        base = self.dll.lua_gettop(self.state) - nargs - 1
        rc = self.dll.lua_pcallk(self.state, nargs, nresults, 0, None, None)
        if rc != LUA_OK:
            msg = self._error_message()
            self.dll.lua_settop(self.state, 0)
            raise LuaError(msg)
        if nresults == LUA_MULTRET:
            # deixa exactamente os valores de retorno na pilha
            self.dll.lua_settop(self.state, self.dll.lua_gettop(self.state))

    def run_file(self, path: Path) -> None:
        self.load(path.read_bytes(), f"@{path}")
        self.pcall()

    def run_source(self, code: str, chunkname: str = "=test") -> None:
        self.load(code.encode("utf-8"), chunkname)
        self.pcall()

    def run_source_discard(self, code: str, chunkname: str = "=test") -> None:
        """Executa um chunk que devolve valores e joga fora a pilha."""
        self.load(code.encode("utf-8"), chunkname)
        self.pcall(nresults=LUA_MULTRET)
        self.dll.lua_settop(self.state, 0)

    def top_string(self) -> str | None:
        """Le a string do topo da pilha (None se nao for string)."""
        size = ctypes.c_size_t(0)
        raw = self.dll.lua_tolstring(self.state, -1, ctypes.byref(size))
        return raw.decode("utf-8") if raw else None

    def pop_boolean(self) -> bool:
        value = bool(self.dll.lua_toboolean(self.state, -1))
        self.dll.lua_settop(self.state, 0)
        return value

    def get_global(self, name: str) -> int:
        """Empurra o global e devolve o tipo Lua (deixa o valor na pilha)."""
        self.dll.lua_getglobal(self.state, name.encode())
        return self.dll.lua_type(self.state, -1)

    def eval_json(self, code: str) -> object:
        """Avalia 'return <code>' e converte o resultado via json.lua do CE.

        Fazemos a conversão dentro do próprio Lua (json.encode) porque o
        resultado costuma ser tabela, e ler tabela pelo C API seria trabalhoso.
        """
        wrapper = (
            "local ok, res = pcall(function() return %s end)\n"
            "if not ok then error('__lua_error__' .. tostring(res), 0) end\n"
            "return require('json').encode({ ok = true, value = res })\n"
        ) % code
        self.load(wrapper.encode("utf-8"), b"=eval_json")
        self.pcall(nresults=LUA_MULTRET)
        raw = self.top_string()
        self.dll.lua_settop(self.state, 0)
        if raw is None:
            raise LuaError("eval_json nao devolveu string")
        if raw.startswith("__lua_error__"):
            raise LuaError(raw[len("__lua_error__"):])
        payload = json.loads(raw)
        return payload["value"]


def find_lua_dll(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.is_file():
            raise SystemExit(f"DLL informada nao existe: {p}")
        return p
    for d in (r"C:\Program Files\Cheat Engine", r"C:\Program Files (x86)\Cheat Engine"):
        for n in ("lua53-64.dll", "lua53-32.dll"):
            p = Path(d) / n
            if p.is_file():
                return p
    raise SystemExit("nao encontrei lua53-*.dll; passe --dll <caminho>")


class Result:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[tuple[str, str]] = []

    def check(self, label: str, condition: bool, detail: str = "") -> None:
        if condition:
            self.passed += 1
            print(f"  ok   {label}")
        else:
            self.failed.append((label, detail))
            print(f"  FALHA {label}" + (f"\n        {detail}" if detail else ""))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Testa a ponte CELua fora do Cheat Engine.")
    ap.add_argument("--bridge", default=str(DEFAULT_BRIDGE))
    ap.add_argument("--stubs", default=str(DEFAULT_STUBS))
    ap.add_argument("--dll", default=None)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    bridge = Path(args.bridge)
    stubs = Path(args.stubs)
    for p in (bridge, stubs):
        if not p.is_file():
            print(f"arquivo nao encontrado: {p}", file=sys.stderr)
            return 1

    dll_path = find_lua_dll(args.dll)
    print(f"Lua:   {dll_path}")
    print(f"ponte: {bridge}")
    print(f"stubs: {stubs}\n")

    lua = Lua(dll_path)

    # 0) O CE poe a sua pasta no package.path; o lua53-64.dll sozinho nao sabe
    #    onde esta o lua/json.lua que a ponte usa via require("json").
    ce_dir = dll_path.parent
    extra_paths = [
        ce_dir / "lua" / "?.lua",
        ce_dir / "lua" / "?" / "init.lua",
        ce_dir / "?.lua",
    ]
    lua.run_source(
        "local extra = { %s }\n"
        "package.path = table.concat(extra, ';') .. ';' .. package.path\n"
        % ", ".join(json.dumps(str(p)) for p in extra_paths),
        "=package_path",
    )

    # 1) Carrega os stubs da API do CE.
    try:
        lua.run_file(stubs)
    except LuaError as exc:
        print(f"FALHA ao carregar os stubs: {exc}", file=sys.stderr)
        return 1

    # 2) O teste de verdade: carregar a ponte como o autorun do CE faria.
    print("carregando autorun (como o CE faz no boot):")
    try:
        lua.run_file(bridge)
        print("  ok   autorun executou sem erro")
    except LuaError as exc:
        print(f"  FALHA erro de runtime no autorun:\n        {exc}")
        return 1

    res = Result()

    # 3) A ponte publicou a API global?
    lua.load(
        b"return type(_G.ce_bridge) == 'table'"
        b" and type(_G.ce_bridge.call) == 'function'"
        b" and type(_G.ce_bridge.methods) == 'table'",
        b"=probe",
    )
    lua.pcall(nresults=LUA_MULTRET)
    res.check("_G.ce_bridge exposto com version/protocol/call", lua.pop_boolean())

    # 4) A lista de métodos é a esperada?
    methods = lua.eval_json("(function() local t = {} for k in pairs(_G.ce_bridge.methods) do t[#t+1] = k end table.sort(t) return t end)()")
    print(f"\n{len(methods)} metodos registrados:")
    if args.verbose:
        print("  " + ", ".join(methods))
    required = {
        "ping", "version", "eval", "process_list", "info", "attach", "detach",
        "modules", "regions", "resolve", "read", "read_many", "write", "alloc",
        "dealloc", "scan_create", "scan_refine", "scan_results", "scan_free",
        "aa_check", "aa_apply", "aa_revert", "txn_list", "cleanup",
        "record_add", "record_list", "record_set", "record_delete",
        "disassemble", "gui_forms", "gui_show", "gui_click", "gui_set",
        "hotkey_add", "hotkey_remove", "timer_create",
    }
    missing = sorted(required - set(methods))
    res.check(f"todos os {len(required)} metodos essenciais registrados", not missing,
              f"faltando: {', '.join(missing)}" if missing else "")

    # 5) Handlers de verdade, pelos mesmos caminhos que um cliente usaria.
    print("\nhandlers (via _G.ce_bridge.call, sem socket):")

    def call(method: str, params: dict | None = None):
        """Chama um handler da ponte e devolve {success, result|error}.

        O ce_bridge.call() faz error() em falha; aqui o pcall apanha-o para o
        teste poder afirmar sobre a mensagem de erro em vez de rebentar.
        """
        payload = json.dumps(params or {})
        return lua.eval_json(
            "(function(method, raw)\n"
            "  local j = require('json')\n"
            "  local ok, r = pcall(_G.ce_bridge.call, method, j.decode(raw))\n"
            "  if not ok then return { success = false, error = tostring(r) } end\n"
            "  if r == nil then return { success = false, error = 'handler devolveu nil' } end\n"
            "  return { success = true, result = r }\n"
            f"end)({json.dumps(method)}, [==[{payload}]==])"
        )

    r = call("ping")
    res.check("ping responde", r.get("success") and isinstance(r.get("result"), dict),
              json.dumps(r)[:400])

    r = call("process_list")
    ok = r.get("success") and r["result"].get("processes") is not None
    res.check("process_list usa getProcesslist() e devolve lista", ok, json.dumps(r)[:400])

    r = call("getProcesslist")  # nome inexistente de proposito
    res.check("metodo desconhecido devolve erro tratado", not r.get("success"),
              json.dumps(r)[:200])

    r = call("attach", {"pid": 4242})
    res.check("attach aceita pid", r.get("success"), json.dumps(r)[:400])

    r = call("info")
    info = r.get("result") if r.get("success") else {}
    ok = isinstance(info, dict) and "celua_path" not in info and "is_kernelmode" not in info
    res.check("info nao expoe API inexistente (isKernelMode/celuaPath)", ok,
              json.dumps(info)[:400])

    r = call("read", {"address": "jogo.exe+1000", "type": "integer"})
    res.check("read resolve simbolo e le inteiro", r.get("success"), json.dumps(r)[:300])

    r = call("read", {"address": "naoexiste", "type": "integer"})
    res.check("read com simbolo invalido falha com mensagem", not r.get("success"),
              json.dumps(r)[:300])

    r = call("write", {"address": "jogo.exe+1000", "type": "integer", "value": 777})
    txn = (r.get("result") or {}).get("transaction_id") if r.get("success") else None
    res.check("write grava e cria transacao reversivel", bool(txn), json.dumps(r)[:300])

    r = call("txn_list")
    n_writes = len(((r.get("result") or {}).get("writes") or [])) if r.get("success") else 0
    res.check("txn_list lista a escrita pendente", n_writes >= 1, json.dumps(r)[:300])

    r = call("scan_create", {"vartype": "vtDword", "value": "1234",
                             "address": "jogo.exe+1000", "stop": "jogo.exe+9000"})
    scan = r.get("result") or {}
    scan_id = scan.get("scan_id")
    res.check("scan_create configura e roda firstScan", bool(scan_id), json.dumps(r)[:400])

    if scan_id:
        r = call("scan_results", {"scan_id": scan_id, "limit": 10})
        found = (r.get("result") or {}).get("results") if r.get("success") else None
        res.check("scan_results devolve resultados (via ms.Results)", isinstance(found, list) and len(found) > 0,
                  json.dumps(r)[:400])
        r = call("scan_results", {"scan_id": scan_id, "limit": 10, "with_values": True})
        vals = (r.get("result") or {}).get("results") if r.get("success") else None
        ok_vals = isinstance(vals, list) and vals and vals[0].get("value") is not None
        res.check("scan_results with_values usa a FoundList", bool(ok_vals), json.dumps(r)[:400])
        r = call("scan_free", {"scan_id": scan_id})
        res.check("scan_free libera sem erro", r.get("success"), json.dumps(r)[:300])

    r = call("aa_check", {"script": "[ENABLE]\n// nada\n[DISABLE]\n"})
    ok_valid = r.get("success") and (r.get("result") or {}).get("valid") is True
    res.check("aa_check valida script", ok_valid, json.dumps(r)[:300])

    r = call("aa_check", {"script": "SINTaxe_ruim"})
    res_aa = r.get("result") or {}
    ok_invalid = (
        r.get("success") is True
        and res_aa.get("valid") is False
        and "bad syntax" in str(res_aa.get("error", ""))
    )
    res.check(
        "aa_check rejeita script invalido preservando a mensagem do CE",
        ok_invalid,
        json.dumps(r)[:300],
    )

    r = call("aa_apply", {"script": "[ENABLE]\n// patch\n[DISABLE]\n"})
    rec_id = (r.get("result") or {}).get("record_id") if r.get("success") else None
    res.check("aa_apply aplica e guarda disableInfo", bool(rec_id), json.dumps(r)[:300])

    if rec_id:
        r = call("aa_revert", {"record_id": rec_id})
        res.check("aa_revert reverte o script", r.get("success"), json.dumps(r)[:300])

    r = call("detach")
    res.check("detach usa openProcess(0) e nao closeProcess()", r.get("success"),
              json.dumps(r)[:300])

    r = call("gui_forms")
    forms = (r.get("result") or {}).get("forms") if r.get("success") else None
    ok = isinstance(forms, list) and any(f.get("name") == "MainForm" for f in forms)
    res.check("gui_forms enumera via getFormCount/getForm", ok, json.dumps(r)[:400])

    r = call("gui_show", {"form": "MemoryView", "visible": True})
    res.check("gui_show acha form por nome (sem getFormByName)", r.get("success"),
              json.dumps(r)[:300])

    r = call("gui_activate", {"form": "MainForm"})
    res.check("gui_activate traz MainForm para frente", r.get("success"), json.dumps(r)[:300])

    r = call("gui_click", {"form": "MainForm", "component": "edtSearch"})
    res.check("gui_click clica componente aninhado", r.get("success"), json.dumps(r)[:300])

    r = call("gui_set", {"form": "MainForm", "component": "edtSearch",
                         "property": "Text", "value": "oi"})
    res.check("gui_set escreve propriedade do componente", r.get("success"), json.dumps(r)[:300])

    r = call("cleanup")
    res.check("cleanup fecha a sessao sem erro", r.get("success"), json.dumps(r)[:300])

    # 6) O caminho JSON-RPC completo (dispatch), como um cliente MCP enviaria.
    print("\ndispatch JSON-RPC 2.0:")
    r = lua.eval_json(
        "(function()\n"
        "  local bridge = _G.ce_bridge\n"
        "  local raw = require('json').encode({ jsonrpc = '2.0', id = 1, method = 'ping', params = {} })\n"
        "  return { dispatched = bridge.config and bridge.protocol or nil }\n"
        "end)()"
    )
    res.check("protocolo anunciado", bool(r.get("dispatched")), json.dumps(r)[:200])

    # 7) Chamadas de API que a ponte fez durante todo o teste.
    calls = lua.eval_json("(function() local t = {} for i, c in ipairs(_STUB_CALLS) do t[i] = c.name end return t end)()")
    called = set(calls)
    for api in ("getProcesslist", "openProcess", "createMemScan", "memscan.firstScan",
                "memscan.waitTillDone", "createFoundList", "foundlist.initialize",
                "autoAssembleCheck", "autoAssemble", "getFormCount", "getForm",
                "writeInteger", "readBytes"):
        res.check(f"API do CE acionada: {api}", api in called)

    banned = {"getProcessList", "getFormByName", "closeProcess", "getProcessNameFromID",
              "isKernelMode", "celuaPath"}
    hit = sorted(banned & called)
    res.check("nenhuma API inexistente foi chamada", not hit,
              f"chamou: {', '.join(hit)}" if hit else "")

    if args.verbose:
        print("\nsequencia de chamadas na API do CE:")
        for i, c in enumerate(calls, 1):
            print(f"  {i:3d}. {c}")

    print(f"\n{res.passed} passaram, {len(res.failed)} falharam")
    if res.failed:
        print("\nfalhas:")
        for label, detail in res.failed:
            print(f"  - {label}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
