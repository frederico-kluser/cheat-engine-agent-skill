"""Testa o bridge vivo: varias conexoes seguidas, depois um roteiro real.

Uso:
    python scripts/test_bridge_live.py [--pid N | --name processo.exe]
"""
from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ce_bridge import CE, BridgeError, list_pipes  # noqa: E402


def passo(titulo: str) -> None:
    print(f"\n=== {titulo} ===")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int)
    ap.add_argument("--name")
    ap.add_argument("--repeticoes", type=int, default=5)
    args = ap.parse_args()

    falhas = 0

    passo("descoberta do pipe")
    pipes = list_pipes()
    print("pipes:", pipes)
    if not pipes:
        print("NENHUM pipe do bridge. O Cheat Engine esta aberto e reiniciado?")
        return 1

    passo(f"ping x{args.repeticoes} (o listener sobrevive a varias conexoes?)")
    for i in range(1, args.repeticoes + 1):
        t0 = time.monotonic()
        try:
            with CE(reply_timeout=15) as ce:
                r = ce.ping()
            ms = (time.monotonic() - t0) * 1000
            print(f"  {i}: ok em {ms:6.0f} ms  bridge={r['bridge']} ce={r['ce']}")
        except (BridgeError, OSError) as exc:
            falhas += 1
            ms = (time.monotonic() - t0) * 1000
            print(f"  {i}: FALHA em {ms:6.0f} ms -> {type(exc).__name__}: {exc}")
        time.sleep(0.25)

    if falhas:
        print(f"\n{falhas} falha(s) de conexao: o listener nao esta re-aceitando.")
        return 1

    passo("version / info / methods")
    try:
        with CE(reply_timeout=20) as ce:
            v = ce.call("version")
            print("version:", {k: v[k] for k in ("bridge", "protocol", "ce", "pid",
                                                 "pipe", "methods")})
            print("info   :", ce.info())
            m = ce.methods()
            print(f"methods: {len(m)} expostos")

            passo("process_list")
            pl = ce.call("process_list", {"filter": "cheat"})
            print(f"processos com 'cheat' no nome: {pl['count']} de {pl['total']}")
            processos = list(pl.get("processes") or [])
            for e in processos[:5]:
                print(f"   {e['pid']:>7}  {e['name']}")

            alvo_pid = args.pid
            if alvo_pid is None and args.name is None and processos:
                alvo_pid = processos[0]["pid"]

            if not alvo_pid and not args.name:
                print("\nsem alvo para attach; use --pid ou --name para o teste completo")
                return 0

            passo("attach")
            alvo = ce.attach(pid=alvo_pid, name=args.name)
            print("attach:", alvo)

            passo("modules (primeiros 3)")
            mods = ce.modules()
            print(f"modulos: {mods['count']}")
            for mod in mods["modules"][:3]:
                print(f"   {mod['name']:<32} base=0x{mod['base']:X} size=0x{mod['size']:X}")

            passo("resolve + read na base do primeiro modulo")
            base = mods["modules"][0]["base"]
            print("resolve:", ce.call("resolve", {"symbol": mods["modules"][0]["name"]}))
            leitura = ce.read(base, "integer")
            print("read dword na base:", leitura)

            passo("read_many em 4 enderecos")
            rm = ce.call("read_many", {"addresses": [base, base + 4, base + 8, base + 12],
                                       "type": "integer"})
            print("read_many:", rm["count"], "valores")

            passo("scan_create (dword == valor lido na base do 2o modulo)")
            # A base de um modulo e o cabecalho PE; o valor dessa dword dificilmente
            # se repete. Usamos uma dword do .text (2o modulo) para ter o que achar.
            alvo_leitura = mods["modules"][1]["base"] if mods["count"] > 1 else base
            valor = ce.read(alvo_leitura, "integer")["value"]
            print(f"procurando o valor {valor} (0x{alvo_leitura:X})")
            scan = ce.call("scan_create", {"vartype": "dword", "scanvalue": str(valor),
                                           "scanoption": "soExactValue"})
            # Chaves com valor nil nao sobrevivem ao JSON: 'error' so existe quando
            # o CE realmente reportou erro.
            print(f"scan: found={scan['found']} last_type={scan['last_type']} "
                  f"err={scan.get('error')}")
            res = ce.call("scan_results", {"scan_id": scan["scan_id"], "limit": 5})
            print(f"resultados: {res['count']} de {res['total']} "
                  f"truncated={res['truncated']}")
            if res["addresses"]:
                print("  primeiros:", [hex(a) for a in res["addresses"][:5]])
            print("free:", ce.call("scan_free", {"scan_id": scan["scan_id"]}))

            passo("regions (contrato real do CE 7.7)")
            reg = ce.call("regions", {"limit": 8})
            print(f"regioes: count={reg['count']} total={reg['total']} "
                  f"truncated={reg['truncated']}")
            if reg["regions"]:
                r0 = reg["regions"][0]
                print(f"  primeira: base=0x{r0['base']:X} size=0x{r0['size']:X} "
                      f"protect={r0['protection']}")

            passo("aa_check / aa_apply (contrato real do autoAssemble)")
            marca = str(int(time.time()))[-6:]
            nome = "zz_live" + marca
            duas = f"[ENABLE]\nalloc({nome},16)\n[DISABLE]\ndealloc({nome})\n"
            so_enable = f"[ENABLE]\nalloc(zz_le{marca},16)\n"

            print("check dual-section :", ce.call("aa_check", {"script": duas}))
            print("check [ENABLE]-only:", ce.call("aa_check", {"script": so_enable}))
            print("check sintaxe ruim :",
                  ce.call("aa_check", {"script": "[ENABLE]\nisso nao existe\n[DISABLE]\n"}))

            ap = ce.call("aa_apply", {"script": duas})
            print(f"apply: success={ap['success']} revertible={ap['revertible']} "
                  f"allocs={ap['allocs']}")
            # O endereco de um alloc do AA so existe em disableInfo.allocs: o
            # symbolhandler NAO resolve esse nome (namespace ccodesymbols privado).
            try:
                ce.call("resolve", {"symbol": nome})
                print("resolve do alloc: RESOLVEU (o contrato mudou!)")
                falhas += 1
            except BridgeError as exc:
                print(f"resolve do alloc: nao resolve, como esperado -> {str(exc)[:70]}")
            if ap["allocs"]:
                end = ap["allocs"][0]["address"]
                print(f"  leitura em 0x{end:X}:", ce.read(end, "integer")["value"])
            print("revert:",
                  ce.call("aa_revert", {"transaction_id": ap["transaction_id"]}))

            try:
                ce.call("aa_apply", {"script": so_enable})
                print("apply [ENABLE]-only: ACEITO (inesperado)")
                falhas += 1
            except BridgeError as exc:
                print(f"apply [ENABLE]-only: recusado -> {str(exc)[:80]}")

            print("revert_all:", ce.call("aa_revert_all"))

            passo("cleanup")
            print(ce.call("cleanup"))
    except BridgeError as exc:
        print(f"\nBridgeError: {exc}")
        falhas += 1

    if falhas:
        print(f"\n{falhas} FALHA(S)")
        return 1
    print("\nBRIDGE VIVO E FUNCIONAL")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
