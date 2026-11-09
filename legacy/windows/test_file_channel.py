"""Teste do canal de resposta por arquivo do bridge do Cheat Engine.

Envia um pedido pelo named pipe (via de entrada, que funciona) e espera a
resposta no arquivo de saída gravado pelo CE (via de retorno).

Uso:  python scripts/test_file_channel.py [pedido]
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pipe_client import PipeClient  # noqa: E402

SPOOL = os.path.join(os.environ.get("TEMP", "."), "ce_bridge_spool")
OUTBOX = os.path.join(SPOOL, "resp.txt")


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def main() -> int:
    pedido = sys.argv[1] if len(sys.argv) > 1 else '{"jsonrpc":"2.0","id":1,"method":"ping"}'
    if os.path.exists(OUTBOX):
        os.remove(OUTBOX)
        log(f"removi resposta antiga: {OUTBOX}")

    try:
        with PipeClient("CE_AGENT_BRIDGE_TEST", connect_timeout_ms=8000) as cli:
            log(f"conectado! handle={cli.handle}")
            enviados = cli.send(pedido)
            log(f"-> enviado ({enviados} bytes): {pedido!r}")
            time.sleep(0.3)
            log("fechando o pipe para o CE ver o fim do pedido")
    except Exception as exc:  # noqa: BLE001
        log(f"falha no pipe: {type(exc).__name__}: {exc}")
        return 1

    prazo = time.monotonic() + 15.0
    while time.monotonic() < prazo:
        if os.path.exists(OUTBOX):
            with open(OUTBOX, "rb") as fh:
                bruto = fh.read()
            try:
                texto = bruto.decode("utf-8")
            except UnicodeDecodeError:
                texto = repr(bruto)
            log(f"<- resposta em arquivo ({len(bruto)} bytes): {texto}")
            try:
                json.loads(texto)
                log("   JSON valido")
            except ValueError as exc:
                log(f"   JSON invalido: {exc}")
            return 0
        time.sleep(0.1)

    log("<- timeout esperando a resposta em arquivo")
    if os.path.isdir(SPOOL):
        log(f"   conteudo de {SPOOL}: {os.listdir(SPOOL)}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
