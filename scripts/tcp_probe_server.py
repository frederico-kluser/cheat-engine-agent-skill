"""Servidores TCP multiplos de diagnostico para sondar o Cheat Engine.

Cada porta aceita uma conexao, envia um payload de teste e registra o que
o Cheat Engine enviar.  Uso:  python scripts/tcp_probe_server.py <porta> [porta...]
"""
from __future__ import annotations

import socket
import sys
import threading
import time
from datetime import datetime

HOST = "127.0.0.1"
DURACAO = 40.0
_lock = threading.Lock()


def log(msg: str) -> None:
    with _lock:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def atender(porta: int) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, porta))
    srv.listen(2)
    srv.settimeout(DURACAO)
    log(f":{porta} escutando")
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        log(f":{porta} nenhuma conexao")
        srv.close()
        return
    log(f":{porta} conexao de {addr}")
    conn.settimeout(1.5)
    try:
        # payload inicial: para a porta 20003 usa 11 bytes exatos
        payload = b"OlaMundo!" if porta == 20003 else b"BEM-VINDO-DO-PYTHON" + bytes([0x1E])
        n = conn.send(payload)
        log(f":{porta} enviei {n} bytes: {payload!r}")
        for _ in range(6):
            try:
                dados = conn.recv(4096)
            except socket.timeout:
                continue
            if not dados:
                log(f":{porta} peer fechou")
                break
            log(f":{porta} RECEBIDO ({len(dados)} bytes): {dados!r}")
    except OSError as exc:
        log(f":{porta} erro: {exc}")
    finally:
        try:
            conn.close()
        except OSError:
            pass
        srv.close()
    log(f":{porta} encerrado")


def main() -> int:
    portas = [int(a) for a in sys.argv[1:]] or [20002, 20003, 20004]
    threads = [threading.Thread(target=atender, args=(p,), daemon=True) for p in portas]
    for t in threads:
        t.start()
    time.sleep(2.0)
    log("pronto; aguardando o Cheat Engine")
    for t in threads:
        t.join()
    log("fim de todos os servidores")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
