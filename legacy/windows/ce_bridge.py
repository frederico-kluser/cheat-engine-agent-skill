"""Cliente do bridge do Cheat Engine - controle total do CE por terminal.

Como funciona (medido, nao suposto)
-----------------------------------
O Cheat Engine 7.7 tem o caminho de ESCRITA de pipe/TCP quebrado: todo write*
retorna sucesso e transfere ZERO bytes. Ja a LEITURA de um named pipe entregue
por acceptConnection funciona. Entao o bridge usa um transporte assimetrico:

    pedido   : este cliente --(named pipe)-->  CE      [funciona]
    resposta : CE --(arquivo em disco)-->  este cliente [funciona]

O pedido e JSON-RPC 2.0 terminado por 0x1E (ASCII Record Separator).
A resposta chega em  %TEMP%\\ce_bridge_spool\\resp_<id>.json

Uso como biblioteca
-------------------
    from ce_bridge import CE
    with CE() as ce:
        print(ce.call("info"))
        ce.attach(name="notepad.exe")
        print(ce.read("notepad.exe+1000", "integer"))

Uso pelo terminal
-----------------
    python scripts/ce_bridge.py ping
    python scripts/ce_bridge.py info
    python scripts/ce_bridge.py attach --name notepad.exe
    python scripts/ce_bridge.py read 0x140001000 integer
    python scripts/ce_bridge.py write 0x140001000 integer 999
    python scripts/ce_bridge.py methods
    python scripts/ce_bridge.py doctor
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import sys
import time
from ctypes import wintypes

# --------------------------------------------------------------------------
# Win32: named pipes
# --------------------------------------------------------------------------
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
ERROR_PIPE_BUSY = 231
ERROR_FILE_NOT_FOUND = 2
DELIM = 0x1E

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

kernel32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
kernel32.WaitNamedPipeW.restype = wintypes.BOOL

kernel32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
    wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
]
kernel32.CreateFileW.restype = wintypes.HANDLE

kernel32.WriteFile.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
]
kernel32.WriteFile.restype = wintypes.BOOL

kernel32.ReadFile.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
]
kernel32.ReadFile.restype = wintypes.BOOL

kernel32.PeekNamedPipe.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
    ctypes.POINTER(wintypes.DWORD),
]
kernel32.PeekNamedPipe.restype = wintypes.BOOL

kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


class BridgeError(RuntimeError):
    """Falha de transporte ou erro devolvido pelo CE."""


# --------------------------------------------------------------------------
# Descoberta do pipe
# --------------------------------------------------------------------------
def list_pipes(prefixo: str = "CE_AGENT_BRIDGE") -> list[str]:
    """Lista os nomes de pipe do CE disponiveis nesta maquina."""
    try:
        nomes = os.listdir("\\\\.\\pipe\\")
    except OSError:
        # Fallback: alguns ambientes nao listam o pseudo-diretorio.
        try:
            import subprocess
            saida = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "[System.IO.Directory]::GetFiles('\\\\.\\pipe\\') | ForEach-Object { $_ }"],
                capture_output=True, text=True, timeout=15,
            ).stdout
            nomes = [os.path.basename(l.strip()) for l in saida.splitlines() if l.strip()]
        except Exception:  # noqa: BLE001
            nomes = []
    return sorted({n for n in nomes if n.upper().startswith(prefixo.upper())})


def find_pipe(prefixo: str = "CE_AGENT_BRIDGE", timeout: float = 10.0) -> str:
    """Espera aparecer um pipe do bridge e devolve o nome completo."""
    prazo = time.monotonic() + timeout
    while True:
        achados = list_pipes(prefixo)
        if achados:
            return achados[0]
        if time.monotonic() >= prazo:
            raise BridgeError(
                f"nenhum pipe '{prefixo}*' encontrado. "
                "O Cheat Engine esta aberto? O autorun\\ce_agent_bridge.lua esta instalado?"
            )
        time.sleep(0.2)


# --------------------------------------------------------------------------
# Cliente
# --------------------------------------------------------------------------
def as_int(valor):
    """Converte para int o que o CE devolve como numero ou string hexadecimal.

    O enumModules() do 7.7 entrega Address como texto ("0x7ff805f80000")
    quando o valor nao cabe exatamente num double. O bridge ja normaliza os
    modulos, mas esta funcao protege codigo de cliente escrito a mao.
    """
    if isinstance(valor, bool) or valor is None:
        return None
    if isinstance(valor, int):
        return valor
    if isinstance(valor, float):
        return int(valor)
    if isinstance(valor, str):
        t = valor.strip()
        try:
            return int(t, 16) if t[:2].lower() == "0x" else int(t, 10)
        except ValueError:
            return None
    return None


class CE:
    """Cliente do bridge: um pedido por conexao, resposta por arquivo."""

    def __init__(self, pipe: str | None = None, spool: str | None = None,
                 connect_timeout_ms: int = 8000, reply_timeout: float = 30.0):
        self.pipe_name = pipe or find_pipe()
        self.pipe_path = "\\\\.\\pipe\\" + self.pipe_name
        self.spool = spool or os.path.join(os.environ.get("TEMP", "."), "ce_bridge_spool")
        self.connect_timeout_ms = connect_timeout_ms
        self.reply_timeout = reply_timeout
        self._next_id = 1

    # -- infra ------------------------------------------------------------
    def _reply_path(self, req_id) -> str:
        return os.path.join(self.spool, f"resp_{req_id}.json")

    def _connect(self):
        """Abre a instancia do pipe, tolerando a janela de reciclagem do CE.

        O listener em Lua nao mantem varias instancias: ao atender um cliente
        ele roda um novo createPipe. Nessa janela o nome do pipe desaparece do
        namespace por poucos milissegundos (erro 2) ou fica ocupado (erro 231).
        Os dois casos sao transitorios, entao insistimos ate o prazo.
        """
        prazo = time.monotonic() + self.connect_timeout_ms / 1000.0
        ultimo = None
        while True:
            restante = int((prazo - time.monotonic()) * 1000)
            if not kernel32.WaitNamedPipeW(self.pipe_path, max(restante, 1)):
                ultimo = ctypes.get_last_error()
                if ultimo not in (ERROR_PIPE_BUSY, ERROR_FILE_NOT_FOUND):
                    raise BridgeError(
                        f"WaitNamedPipe falhou (erro {ultimo}) em {self.pipe_path}"
                    )
            else:
                handle = kernel32.CreateFileW(
                    self.pipe_path, GENERIC_READ | GENERIC_WRITE, 0, None,
                    OPEN_EXISTING, 0, None,
                )
                if handle != INVALID_HANDLE_VALUE:
                    return handle
                ultimo = ctypes.get_last_error()
                if ultimo not in (ERROR_PIPE_BUSY, ERROR_FILE_NOT_FOUND):
                    raise BridgeError(
                        f"CreateFileW falhou (erro {ultimo}) em {self.pipe_path}"
                    )
            if time.monotonic() >= prazo:
                raise BridgeError(
                    f"nao consegui conectar em {self.pipe_path} em "
                    f"{self.connect_timeout_ms} ms (ultimo erro {ultimo})"
                )
            time.sleep(0.02)

    def _write(self, handle, dados: bytes) -> int:
        buf = ctypes.create_string_buffer(dados, len(dados))
        escritos = wintypes.DWORD(0)
        ok = kernel32.WriteFile(handle, buf, len(dados), ctypes.byref(escritos), None)
        if not ok:
            raise BridgeError(f"WriteFile falhou (erro {ctypes.get_last_error()})")
        return escritos.value

    # -- API --------------------------------------------------------------
    def call(self, method: str, params=None, req_id=None, timeout=None):
        """Envia um pedido e espera a resposta em arquivo. Devolve o campo 'result'."""
        if req_id is None:
            req_id = self._next_id
            self._next_id += 1
        timeout = self.reply_timeout if timeout is None else timeout

        destino = self._reply_path(req_id)
        # Resposta antiga com o mesmo id invalidaria a leitura: apagar antes.
        for velho in (destino, destino + ".tmp"):
            try:
                os.remove(velho)
            except OSError:
                pass

        pedido = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            pedido["params"] = params
        corpo = json.dumps(pedido, ensure_ascii=False).encode("utf-8") + bytes([DELIM])

        handle = self._connect()
        try:
            self._write(handle, corpo)
        finally:
            # Fechar avisa o CE que a mensagem acabou (readByte devolvera nil).
            kernel32.CloseHandle(handle)

        prazo = time.monotonic() + timeout
        while time.monotonic() < prazo:
            if os.path.exists(destino):
                try:
                    with open(destino, "rb") as fh:
                        bruto = fh.read()
                except OSError:
                    time.sleep(0.01)
                    continue
                if not bruto:
                    time.sleep(0.01)
                    continue
                try:
                    envelope = json.loads(bruto.decode("utf-8", "replace"))
                except ValueError:
                    time.sleep(0.02)
                    continue
                if "error" in envelope:
                    err = envelope["error"]
                    raise BridgeError(
                        f"{err.get('message', 'erro desconhecido')} "
                        f"(code {err.get('code')}, metodo {method})"
                    )
                return envelope.get("result")
            time.sleep(0.01)

        raise BridgeError(
            f"timeout de {timeout:.0f}s esperando {destino}. "
            "O CE recebeu o pedido? Veja o console Lua do Cheat Engine."
        )

    def raw(self, method: str, params=None, **kw):
        """Como call(), mas devolve o envelope inteiro (inclui 'ms')."""
        return self.call(method, params, **kw)

    # -- acucar -----------------------------------------------------------
    def ping(self):
        return self.call("ping")

    def info(self):
        return self.call("info")

    def methods(self):
        """Lista os nomes dos metodos RPC.

        O bridge responde {'count': N, 'methods': [...], 'bridge': ..., 'protocol': ...}.
        Devolvemos so a lista para que len(ce.methods()) seja o numero real.
        """
        r = self.call("rpc_methods")
        if isinstance(r, dict):
            return list(r.get("methods") or ())
        return list(r)

    def methods_info(self):
        """Resposta crua do rpc_methods (com bridge, protocol e count)."""
        return self.call("rpc_methods")

    def attach(self, pid=None, name=None):
        return self.call("attach", {"pid": pid, "name": name})

    def read(self, address, tipo="integer", maxlen=None):
        return self.call("read", {"address": address, "type": tipo, "maxlen": maxlen})

    def modules(self):
        """Lista os modulos do processo aberto, com base/size ja em inteiro."""
        r = self.call("modules")
        for m in r.get("modules", ()):
            m["base"] = as_int(m.get("base"))
            m["address"] = as_int(m.get("address"))
            m["size"] = as_int(m.get("size")) or 0
        return r

    def write(self, address, value, tipo="integer", transactional=True):
        return self.call("write", {"address": address, "value": value,
                                   "type": tipo, "transactional": transactional})

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _imprimir(obj) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="ce_bridge",
        description="Controla o Cheat Engine por terminal (named pipe + caixa de correio).",
    )
    ap.add_argument("--pipe", help="nome do pipe (padrao: descobre sozinho)")
    ap.add_argument("--timeout", type=float, default=30.0, help="segundos esperando a resposta")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("ping", help="testa a conexao")
    sub.add_parser("info", help="processo aberto no CE")
    sub.add_parser("methods", help="lista os metodos RPC do bridge")
    sub.add_parser("pipes", help="lista os pipes do bridge disponiveis")
    sub.add_parser("doctor", help="diagnostico completo do bridge")

    p = sub.add_parser("attach", help="abre um processo")
    p.add_argument("--pid", type=int)
    p.add_argument("--name")

    p = sub.add_parser("read", help="le memoria")
    p.add_argument("address")
    p.add_argument("type", nargs="?", default="integer")
    p.add_argument("--maxlen", type=int)

    p = sub.add_parser("write", help="escreve memoria")
    p.add_argument("address")
    p.add_argument("type")
    p.add_argument("value")
    p.add_argument("--no-txn", action="store_true")

    p = sub.add_parser("eval", help="executa codigo Lua dentro do CE")
    p.add_argument("code")

    args = ap.parse_args(argv)

    if args.cmd == "pipes":
        _imprimir(list_pipes())
        return 0

    if args.cmd == "doctor":
        return _doctor(args)

    if not args.cmd:
        ap.print_help()
        return 2

    with CE(pipe=args.pipe, reply_timeout=args.timeout) as ce:
        if args.cmd == "ping":
            _imprimir(ce.ping())
        elif args.cmd == "info":
            _imprimir(ce.info())
        elif args.cmd == "methods":
            _imprimir(ce.methods())
        elif args.cmd == "attach":
            if not args.pid and not args.name:
                print("informe --pid ou --name", file=sys.stderr)
                return 2
            _imprimir(ce.attach(pid=args.pid, name=args.name))
        elif args.cmd == "read":
            _imprimir(ce.read(args.address, args.type, args.maxlen))
        elif args.cmd == "write":
            valor = args.value
            if args.type not in ("string", "widestring", "bytes"):
                try:
                    valor = int(args.value, 0)
                except ValueError:
                    valor = float(args.value)
            _imprimir(ce.write(args.address, valor, args.type,
                               transactional=not args.no_txn))
        elif args.cmd == "eval":
            _imprimir(ce.call("eval", {"code": args.code}))
    return 0


def _doctor(args) -> int:
    print("== doctor do ce-agent-bridge ==")
    achados = list_pipes()
    print(f"pipes encontrados : {achados or 'NENHUM'}")
    if not achados:
        print("\nO Cheat Engine nao esta escutando.")
        print("  1. O Cheat Engine esta aberto?")
        print(r"  2. autorun\ce_agent_bridge.lua esta em <Cheat Engine>\autorun\ ?")
        print("  3. O Cheat Engine foi reiniciado DEPOIS de copiar o arquivo?")
        return 1

    spool = os.path.join(os.environ.get("TEMP", "."), "ce_bridge_spool")
    print(f"caixa de correio  : {spool} {'(existe)' if os.path.isdir(spool) else '(AUSENTE)'}")

    try:
        with CE(pipe=args.pipe, reply_timeout=args.timeout) as ce:
            print(f"pipe              : {ce.pipe_path}")
            t0 = time.monotonic()
            pong = ce.ping()
            dt = (time.monotonic() - t0) * 1000
            print(f"ping              : ok em {dt:.0f} ms")
            _imprimir(pong)
            info = ce.info()
            print("info              :")
            _imprimir(info)
            m = ce.methods()
            print(f"metodos expostos  : {len(m)} (bridge {ce.methods_info().get('bridge')})")
            faltando = {"ping", "version", "eval", "info", "attach", "detach",
                        "modules", "regions", "resolve", "read", "read_many",
                        "write", "alloc", "dealloc", "scan_create", "scan_refine",
                        "scan_results", "scan_free", "aa_check", "aa_apply",
                        "aa_revert", "cleanup", "disassemble",
                        "instruction_size"} - set(m)
            print(f"metodos essenciais: {'todos presentes' if not faltando else 'FALTANDO ' + str(sorted(faltando))}")
            print("\nBRIDGE OK")
            return 0
    except BridgeError as exc:
        print(f"\nFALHA: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
