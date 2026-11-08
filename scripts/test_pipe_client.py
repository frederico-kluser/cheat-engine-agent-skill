# -*- coding: utf-8 -*-
"""Cliente de teste e diagnostico do named pipe do CE.

Uso:
    python test_pipe_client.py [nome] [mensagem] [mensagem2]

O protocolo do `ce_agent_bridge` termina cada mensagem com o byte 0x1E
(Record Separator). O CE le byte-a-byte via `readByte()` porque a API
`readBytes(size)` do CELua so retorna quando le EXATAMENTE `size` bytes.

Opcoes:
    --no-delim   nao anexa o delimitador 0x1E
    --crlf       usa \\n como delimitador (modo legado dos primeiros probes)
    --timeout N  timeout de leitura em ms (padrao 10000)

Como biblioteca:
    from test_pipe_client import PipeClient
    with PipeClient("CE_AGENT_BRIDGE") as c:
        print(c.request('{"jsonrpc":"2.0","id":1,"method":"ping"}'))
"""
import ctypes
import sys
import time
from ctypes import wintypes

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value
ERROR_PIPE_BUSY = 231
DELIM = 0x1E

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
kernel32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                               ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                              ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.PeekNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                                   ctypes.POINTER(wintypes.DWORD),
                                   ctypes.POINTER(wintypes.DWORD),
                                   ctypes.POINTER(wintypes.DWORD)]
kernel32.PeekNamedPipe.restype = wintypes.BOOL


def bytes_available(handle) -> int:
    """Bytes prontos para leitura no pipe (0 se desconectado/erro)."""
    avail = wintypes.DWORD(0)
    ok = kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None)
    return avail.value if ok else 0


class PipeClient:
    """Cliente minimo de named pipe (stdlib + ctypes) para o bridge do CE."""

    def __init__(self, name="CE_AGENT_BRIDGE", connect_timeout_ms=5000):
        self.path = "\\\\.\\pipe\\" + name
        self.handle = None
        self.buf = ctypes.create_string_buffer(65536)
        self.pending = b""
        self.last_error = 0

        if not kernel32.WaitNamedPipeW(self.path, connect_timeout_ms):
            self.last_error = ctypes.get_last_error()
            raise TimeoutError(
                f"WaitNamedPipe falhou em {self.path}: erro {self.last_error} "
                f"({ctypes.FormatError(self.last_error)})"
            )
        h = kernel32.CreateFileW(self.path, GENERIC_READ | GENERIC_WRITE, 0, None,
                                 OPEN_EXISTING, 0, None)
        if h == INVALID_HANDLE_VALUE:
            self.last_error = ctypes.get_last_error()
            raise OSError(
                f"CreateFile falhou em {self.path}: erro {self.last_error} "
                f"({ctypes.FormatError(self.last_error)})"
            )
        self.handle = h

    # -- io -----------------------------------------------------------------
    def send_raw(self, data: bytes) -> int:
        written = wintypes.DWORD(0)
        ok = kernel32.WriteFile(self.handle, data, len(data), ctypes.byref(written), None)
        if not ok:
            self.last_error = ctypes.get_last_error()
        return written.value

    def send(self, text: str, delim: bytes = bytes([DELIM])) -> int:
        return self.send_raw(text.encode("utf-8") + delim)

    def _recv_chunk(self, timeout_ms: int) -> bytes:
        """Le o que estiver disponivel, sem bloquear o handle.

        Usa PeekNamedPipe para saber se ha bytes antes de chamar ReadFile,
        de modo que uma leitura nunca fica pendente segurando o handle.
        """
        deadline = time.monotonic() + timeout_ms / 1000.0
        while True:
            n = bytes_available(self.handle)
            if n:
                read = wintypes.DWORD(0)
                ok = kernel32.ReadFile(self.handle, self.buf, 65536, ctypes.byref(read), None)
                if not ok:
                    self.last_error = ctypes.get_last_error()
                    return b""
                return self.buf.raw[: read.value]
            if time.monotonic() > deadline:
                return b""
            time.sleep(0.005)

    def recv_until(self, delim: bytes = bytes([DELIM]), timeout_ms: int = 10000) -> bytes:
        deadline = time.monotonic() + timeout_ms / 1000.0
        while delim not in self.pending:
            if time.monotonic() > deadline:
                raise TimeoutError(f"timeout esperando {delim!r}; recebido ate agora: {self.pending!r}")
            chunk = self._recv_chunk(min(1000, int((deadline - time.monotonic()) * 1000) or 1))
            if chunk:
                self.pending += chunk
        msg, _, self.pending = self.pending.partition(delim)
        return msg

    def request(self, text: str, timeout_ms: int = 10000) -> str:
        self.send(text)
        return self.recv_until(timeout_ms=timeout_ms).decode("utf-8", "replace")

    # -- contexto -----------------------------------------------------------
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        if self.handle:
            kernel32.CloseHandle(self.handle)
            self.handle = None


def main():
    args = [a for a in sys.argv[1:]]
    delim = bytes([DELIM])
    timeout_ms = 10000
    if "--no-delim" in args:
        args.remove("--no-delim")
        delim = b""
    if "--crlf" in args:
        args.remove("--crlf")
        delim = b"\n"
    if "--timeout" in args:
        i = args.index("--timeout")
        timeout_ms = int(args[i + 1])
        del args[i:i + 2]

    name = args[0] if len(args) > 0 else "CE_AGENT_BRIDGE"
    msgs = args[1:] or ['{"jsonrpc":"2.0","id":1,"method":"ping"}']

    print("pipe:", "\\\\.\\pipe\\" + name)
    try:
        client = PipeClient(name)
    except (TimeoutError, OSError) as exc:
        print(f"falha ao conectar: {exc}")
        return 1

    try:
        print("conectado! handle:", client.handle)
        for msg in msgs:
            t0 = time.monotonic()
            enviados = client.send(msg, delim)
            print(f"-> enviado ({enviados} bytes): {msg!r}")
            try:
                resp = client.recv_until(delim or b"\n", timeout_ms)
            except TimeoutError as exc:
                print(f"<- {exc}")
                continue
            dt = (time.monotonic() - t0) * 1000
            print(f"<- resposta em {dt:.0f}ms ({len(resp)} bytes): {resp.decode('utf-8', 'replace')!r}")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
