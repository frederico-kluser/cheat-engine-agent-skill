"""Verificacao ao vivo do contrato AA (aa_check / aa_apply / aa_revert).

Prova, contra um CE 7.7 rodando, o contrato real do autoAssemble:
  duas secoes  -> aplica, devolve disableInfo, e reversivel
  so [ENABLE]  -> recusado COM explicacao (o CE nao distingue valido de lixo)
  erro sintaxe -> recusado com a mensagem do proprio CE
"""
import sys
import time

sys.path.insert(0, "scripts")
from ce_bridge import CE, BridgeError  # noqa: E402

NOME = "cheatengine-x86_64-SSE4-AVX2.exe"
MARCA = str(int(time.time()))[-6:]
A1, A2, A3 = "zz_a" + MARCA, "zz_b" + MARCA, "zz_c" + MARCA

DUAS = "[ENABLE]\nalloc(%s,16)\n%s:\ndb 41 42 43 44\n[DISABLE]\ndealloc(%s)\n" % (A1, A1, A1)
SO_ENABLE = "[ENABLE]\nalloc(%s,16)\n" % A2
ERR_SINT = "[ENABLE]\nalloc(%s,16)\nxisso aqui\n[DISABLE]\ndealloc(%s)\n" % (A3, A3)

falhas = []


def checa(rotulo, cond, detalhe=""):
    print("%s %-44s %s" % ("OK  " if cond else "FALHA", rotulo, detalhe))
    if not cond:
        falhas.append(rotulo)


def main():
    with CE(reply_timeout=45) as ce:
        ce.attach(name=NOME)
        print("bridge %s | metodos %d" % (ce.call("version")["bridge"], len(ce.methods())))

        print("\n--- aa_check ---")
        r = ce.call("aa_check", {"script": DUAS})
        checa("duas secoes -> valid", r.get("valid") is True, repr(r))

        r = ce.call("aa_check", {"script": SO_ENABLE})
        checa("so [ENABLE] -> invalid + limitation",
              r.get("valid") is False and r.get("error") is None and "limitation" in r,
              repr(r))

        r = ce.call("aa_check", {"script": ERR_SINT})
        checa("erro de sintaxe -> mensagem do CE",
              r.get("valid") is False and "Error in line" in str(r.get("error")),
              repr(r.get("error")))

        r = ce.call("aa_check", {"script": SO_ENABLE, "smoke": True})
        checa("smoke -> parser saudavel + nota honesta",
              r.get("smoke_parser_ok") is True and "smoke_note" in r, repr(r))

        print("\n--- aa_apply ---")
        r = ce.call("aa_apply", {"script": DUAS})
        txn = r.get("transaction_id")
        checa("duas secoes -> success + revertible",
              r.get("success") is True and r.get("revertible") is True and bool(txn),
              repr(r))
        allocs = r.get("allocs") or []
        end_alloc = allocs[0]["address"] if allocs else None
        checa("allocs com endereco real", bool(end_alloc), "addr=%s" % end_alloc)

        if end_alloc:
            v = ce.read(end_alloc, "integer")["value"]
            checa("memoria alocada = 0x44434241", v == 0x44434241,
                  "lido=%s" % (hex(v) if isinstance(v, int) else v))

            r = ce.call("aa_revert", {"transaction_id": txn})
            checa("aa_revert desfaz o script",
                  r.get("reverted") == 1 and r.get("total") == 1, repr(r))

        try:
            ce.call("aa_apply", {"script": SO_ENABLE})
            checa("so [ENABLE] -> recusado", False, "nao levantou erro")
        except BridgeError as e:
            msg = str(e)
            checa("so [ENABLE] -> recusado com explicacao",
                  "sem mensagem de erro" in msg and "aa_check" in msg, msg[:110])

        try:
            ce.call("aa_apply", {"script": ERR_SINT})
            checa("erro de sintaxe -> recusado", False, "nao levantou erro")
        except BridgeError as e:
            checa("erro de sintaxe -> recusado com mensagem",
                  "Error in line" in str(e), str(e)[:110])

        r = ce.call("aa_revert_all")
        checa("aa_revert_all limpa a fila", r.get("reverted") == 0, repr(r))


if __name__ == "__main__":
    try:
        main()
    except BridgeError as e:
        print("\nBridgeError inesperado:", e)
        falhas.append("BridgeError inesperado")

    print("\nfalhas: %d %s" % (len(falhas), falhas if falhas else ""))
    sys.exit(1 if falhas else 0)
