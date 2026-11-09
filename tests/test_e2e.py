#!/usr/bin/env python3
"""Teste ponta a ponta da cheat-engine-agent-skill (Cheat Engine 7.7.1 Linux).

Compila tests/alvo/alvo.c como "alvo-e2e" (nome com '-' de propósito: exercita as
aspas de módulo do CE), abre o CE headless se ele não estiver aberto e valida,
pelo EFEITO no programa (o alvo imprime o próprio estado a cada tick):

  lint da ponte · attach · first/next scan · write + undo · cadeia de ponteiros ·
  AOB · watch (quem escreve) · Auto Assembler apply/revert · freeze por ponteiro ·
  .CT save/load · string · cemem (scan/next/ptrscan/aob/freeze/disasm) · cleanup

    python3 tests/test_e2e.py            # ~40 s
    python3 tests/test_e2e.py --keep-ce  # não fecha o CE se foi o teste que abriu
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable
CE = [PY, str(ROOT / "scripts" / "ce.py")]
CEMEM = [PY, str(ROOT / "scripts" / "cemem.py")]
TICK = 0.6  # segundos entre ticks do alvo


def sh(cmd: list[str], *args, check=True, timeout=180) -> dict:
    p = subprocess.run(cmd + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    try:
        out = json.loads(p.stdout) if p.stdout.strip() else {}
    except json.JSONDecodeError:
        out = {"raw": p.stdout}
    if check and p.returncode != 0:
        raise AssertionError(f"{' '.join(map(str, args))} -> {p.stdout.strip()[:400]} {p.stderr.strip()[:400]}")
    return out


class Alvo:
    def __init__(self, workdir: Path):
        src = ROOT / "tests" / "alvo" / "alvo.c"
        self.exe = workdir / "alvo-e2e"
        subprocess.run(["gcc", "-O1", "-g", "-o", str(self.exe), str(src)], check=True)
        self.out = workdir / "alvo.out"
        self.proc = subprocess.Popen([str(self.exe), str(int(TICK * 1000))],
                                     stdout=open(self.out, "w"), stderr=subprocess.STDOUT)
        t0 = time.time()
        while time.time() - t0 < 5:
            if self.out.exists() and self.out.read_text().count("\n") >= 1:
                break
            time.sleep(0.05)
        first = self.out.read_text().splitlines()[0]
        self.addr = {k: int(v, 16) for k, v in re.findall(r"&(\w+)=0x([0-9a-f]+)", first)}
        self.pid = self.proc.pid

    def last(self) -> dict:
        linhas = [x for x in self.out.read_text().splitlines() if x.startswith("vida=")]
        if not linhas:
            return {}
        return dict(kv.split("=", 1) for kv in linhas[-1].split())

    def vida(self) -> int:
        return int(self.last().get("vida", -1))

    def ticks(self, n: int = 1) -> list[dict]:
        out = []
        for _ in range(n):
            base = self.out.read_text().count("\n")
            t0 = time.time()
            while self.out.read_text().count("\n") == base and time.time() - t0 < 5:
                time.sleep(0.02)
            out.append(self.last())
        return out

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main() -> int:
    keep = "--keep-ce" in sys.argv
    results: list[dict] = []
    work = Path(tempfile.mkdtemp(prefix="ce-e2e-"))
    abriu_ce = False
    alvo = None

    def step(nome):
        def deco(fn):
            t0 = time.time()
            try:
                info = fn()
                results.append({"step": nome, "ok": True, "ms": int((time.time() - t0) * 1000), "info": info})
                print(f"  ok   {nome}  ({int((time.time() - t0) * 1000)} ms)", flush=True)
            except Exception as e:  # noqa: BLE001
                results.append({"step": nome, "ok": False, "error": str(e)})
                print(f"  FAIL {nome}: {e}", flush=True)
            return fn
        return deco

    try:
        @step("lint da ponte com a Lua do CE (liblua53.so)")
        def _():
            p = subprocess.run([PY, str(ROOT / "scripts" / "lint_lua.py"), *map(str, (ROOT / "autorun").glob("*.lua"))],
                               capture_output=True, text=True)
            assert p.returncode == 0, p.stdout
            return p.stdout.strip().splitlines()[-1]

        @step("ce up (headless se o CE estiver fechado)")
        def _():
            nonlocal abriu_ce
            st = sh(CE, "status")
            if not st.get("bridge"):
                r = sh(CE, "up", "--headless")
                abriu_ce = bool(r.get("launched"))
            assert sh(CE, "call", "ping")["pong"] is True
            return {"abriu": abriu_ce}

        alvo = Alvo(work)

        @step("attach pelo nome")
        def _():
            r = sh(CE, "attach", "alvo-e2e")
            assert r["pid"] == alvo.pid and r["readable"] is True, r
            return r["pid"]

        @step("first scan + next scan isolam &vida")
        def _():
            for _tentativa in range(3):
                v = alvo.vida()
                r = sh(CE, "scan", v, "--preview", "0")
                if r["found"] == 0:
                    continue
                alvo.ticks(1)
                r = sh(CE, "next", alvo.vida(), "--preview", "50")
                addrs = {int(x["address"], 16) for x in r.get("results", [])}
                if alvo.addr["vida"] in addrs:
                    return {"found": r["found"]}
            raise AssertionError("&vida não apareceu nos resultados")

        @step("write 777 muda o jogo; undo restaura")
        def _():
            sh(CE, "write", hex(alvo.addr["vida"]), "777")
            t = alvo.ticks(1)[0]
            assert int(t["vida"]) in (776, 775), t
            sh(CE, "undo", "--all")
            t = alvo.ticks(1)[0]
            assert int(t["vida"]) < 700, t
            return t["vida"]

        @step("cadeia de ponteiros alvo-e2e.g_mundo -> [0] -> [0]")
        def _():
            r = sh(CE, "ptr", "alvo-e2e.g_mundo", "0", "0")
            assert int(r["address"], 16) == alvo.addr["vida"], r
            return r["value"]

        @step("AOB único acha g_assinatura")
        def _():
            r = sh(CE, "aob", "DE AD BE EF ?? 37 C0 DE", "--unique")
            assert int(r["addresses"][0], 16) == alvo.addr["assinatura"], r
            return r["names"]

        @step("watch: quem escreve em &vida = dano()")
        def _():
            r = sh(CE, "watch", hex(alvo.addr["vida"]), "--seconds", str(TICK * 3 + 0.3))
            top = r["instructions"][0]
            assert int(top["address"], 16) == alvo.addr["dano"], r
            return top["instruction"]

        @step("Auto Assembler: apply inverte o dano, revert desfaz")
        def _():
            script = "[ENABLE]\ndano:\n  add [rdi],esi\n\n[DISABLE]\ndano:\n  sub [rdi],esi\n"
            chk = sh(CE, "aa", "check", script)
            assert chk["enable_ok"] and chk["disable_ok"], chk
            sh(CE, "aa", "apply", script)
            a, b = alvo.ticks(2)
            assert int(b["vida"]) > int(a["vida"]), (a, b)
            sh(CE, "aa", "revert", "--all")
            a, b = alvo.ticks(2)
            assert int(b["vida"]) < int(a["vida"]), (a, b)
            return "ok"

        @step("freeze por ponteiro (módulo com '-' entre aspas) + unfreeze")
        def _():
            r = sh(CE, "freeze", "alvo-e2e.g_mundo", "500", "--offsets", "0", "0", "-d", "vida e2e")
            assert r["active"] is True and r["address"] == '"alvo-e2e"+4058', r
            vals = [int(t["vida"]) for t in alvo.ticks(3)]
            assert all(v in (499, 500) for v in vals), vals
            sh(CE, "unfreeze", r["id"], "--delete")
            a, b = alvo.ticks(2)
            assert int(b["vida"]) < int(a["vida"]), (a, b)
            return vals

        @step("tabela .CT: save -> limpar -> load")
        def _():
            sh(CE, "add", "alvo-e2e.g_contador", "-d", "contador")
            ct = work / "e2e.CT"
            sh(CE, "table", "save", ct)
            assert "contador" in ct.read_text()
            sh(CE, "rm", "--agent")
            sh(CE, "table", "load", ct)
            recs = sh(CE, "list")["records"]
            assert any(x["description"] == "contador" and x["value"] not in ("??", None) for x in recs), recs
            return len(recs)

        @step("string: write com terminador")
        def _():
            nome = alvo.addr["vida"] + 16
            sh(CE, "write", hex(nome), "Claude", "-t", "string")
            t = alvo.ticks(1)[0]
            assert t["nome"] == "Claude", t
            return t["nome"]

        @step("disassembly e assemble")
        def _():
            d = sh(CE, "disasm", "dano", "-n", "2")["instructions"]
            assert d[0]["opcode"].startswith("sub") and d[0]["bytes"] == "29 37", d
            a = sh(CE, "asm", "add [rdi],esi")
            assert a["bytes"] == "01 37", a
            return d[0]["opcode"]

        @step("cemem: scan/next sem o CE")
        def _():
            for _tentativa in range(3):
                r = sh(CEMEM, "scan", alvo.pid, alvo.vida(), "-s", "e2e")
                if r["found"] == 0:
                    continue
                alvo.ticks(1)
                r = sh(CEMEM, "next", alvo.vida(), "-s", "e2e")
                if any(int(x["address"], 16) == alvo.addr["vida"] for x in r.get("results", [])):
                    return r["found"]
            raise AssertionError("cemem não isolou &vida")

        @step("cemem: ptrscan acha alvo-e2e+4058 -> [0,0]")
        def _():
            r = sh(CEMEM, "ptrscan", alvo.pid, hex(alvo.addr["vida"]), "--limit", "5")
            caminhos = [(p["base"], p["offsets"]) for p in r["paths"]]
            assert ("alvo-e2e+4058", ["0", "0"]) in caminhos, caminhos
            return caminhos[:3]

        @step("cemem: aob, disasm, freeze em segundo plano")
        def _():
            r = sh(CEMEM, "aob", alvo.pid, "DE AD BE EF ?? 37 C0 DE", "--all-regions")
            assert any(int(x["address"], 16) == alvo.addr["assinatura"] for x in r["results"]), r
            d = sh(CEMEM, "disasm", alvo.pid, hex(alvo.addr["dano"]), "-n", "1")
            assert d["instructions"][0]["opcode"].startswith("sub"), d
            f = sh(CEMEM, "freeze", alvo.pid, "alvo-e2e+4058", "321", "--offsets", "0", "0", "--background")
            vals = [int(t["vida"]) for t in alvo.ticks(2)]
            sh(CEMEM, "unfreeze", f["freeze_id"])
            assert all(v in (320, 321) for v in vals), vals
            return vals

        @step("ce cleanup")
        def _():
            return sh(CE, "cleanup")
    finally:
        if alvo:
            alvo.stop()
        try:
            sh(CE, "detach", check=False)
        except Exception:  # noqa: BLE001
            pass
        if abriu_ce and not keep:
            sh(CE, "down", check=False)
        shutil.rmtree(work, ignore_errors=True)

    falhas = [r for r in results if not r["ok"]]
    print(json.dumps({"ok": not falhas, "passed": len(results) - len(falhas), "failed": len(falhas),
                      "failures": falhas}, ensure_ascii=False, indent=2))
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
