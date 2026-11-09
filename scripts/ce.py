#!/usr/bin/env python3
"""ce — Cheat Engine 7.7 (Linux nativo) controlado pelo terminal, feito para agentes.

Fala com a ponte ``autorun/ce_agent_bridge.lua`` que roda DENTRO do Cheat Engine:
TCP 127.0.0.1 + token (principal) ou caixa de correio em disco (reserva).
Toda saída é JSON (stdout). Erro => {"ok": false, "error": ...} e código 1.

Endereços são HEX como no CE (``7ffd1234`` = ``0x7ffd1234``), aceitam
``modulo+offset`` e a notação de ponteiro do CE (``[[jogo+10]+8]+4``).
Valores são decimais (use ``--hex`` para hexadecimal).

Uso rápido (o fluxo clássico do Cheat Engine):

    ce up                         # abre o CE (se preciso) e espera a ponte
    ce ps hollow                  # acha o processo (nativo, Wine ou Proton)
    ce attach "Hollow Knight"     # abre no CE (melhor candidato)
    ce scan 100                   # first scan (dword exato)
    ce next 93                    # next scan com o valor novo
    ce write 0x55d0c0a1b2c4 999   # escreve (transacional: ce undo --all)
    ce freeze 0x55d0c0a1b2c4 999  # congela (entrada na tabela do CE)
    ce watch 0x55d0c0a1b2c4       # quem escreve nesse endereço? (5 s)

Rode ``ce --help`` ou ``ce <comando> --help`` para tudo.
Biblioteca: ``from ce import Bridge; Bridge().call("read", {"address": "..."})``.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
AUR_PREFIX = Path("/usr/lib/cheatengine")              # pacote AUR cheatengine-bin
MANUAL_PREFIX = Path.home() / ".local/opt/cheatengine"  # zip oficial (install.sh sem AUR)


def _ce_prefix() -> Path:
    if os.environ.get("CE_PREFIX"):
        return Path(os.environ["CE_PREFIX"])
    for p in (AUR_PREFIX, MANUAL_PREFIX):
        if (p / "cheatengine-x86_64").exists():
            return p
    return AUR_PREFIX


CE_PREFIX = _ce_prefix()
CE_BIN = CE_PREFIX / "cheatengine-x86_64"
CE_LAUNCHER = shutil.which("cheatengine") or "/usr/bin/cheatengine"
CE_USERDIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "cheatengine"
# AUR: overlay por usuário (~/.local/share/cheatengine/autorun); manual: autorun do próprio CE
CE_AUTORUN = CE_USERDIR / "autorun" if CE_PREFIX == AUR_PREFIX else CE_PREFIX / "autorun"
BRIDGE_LINK = "00_ce_agent_bridge.lua"  # "00_" = carrega antes de qualquer autorun do CE
RS = b"\x1e"


def state_dir() -> Path:
    if os.environ.get("CE_BRIDGE_DIR"):
        return Path(os.environ["CE_BRIDGE_DIR"])
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if rt:
        return Path(rt) / "ce-agent-bridge"
    return Path(f"/tmp/ce-agent-bridge-{os.environ.get('USER', 'user')}")


class BridgeError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Processos (via /proc — mais rico que a lista do CE: Wine/Proton, Steam, RSS)
# ---------------------------------------------------------------------------
WINE_HELPERS = {
    "wineserver", "winedevice.exe", "services.exe", "plugplay.exe", "explorer.exe",
    "rpcss.exe", "svchost.exe", "steam.exe", "conhost.exe", "winedbg", "start.exe",
    "tabtip.exe", "rundll32.exe", "wineboot.exe", "steamwebhelper.exe", "crashpad_handler.exe",
}
SHELLISH = {"zsh", "bash", "sh", "fish", "python", "python3", "sudo", "timeout", "setsid",
            "pressure-vessel", "pv-bwrap", "reaper", "srt-bwrap", "steam-runtime-l"}


def _read(path: str, binary: bool = False):
    try:
        with open(path, "rb") as f:
            data = f.read()
        return data if binary else data.decode("utf-8", "replace")
    except OSError:
        return None


def ce_pids() -> list[int]:
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            if os.readlink(f"/proc/{d}/exe") == str(CE_BIN):
                out.append(int(d))
                continue
        except OSError:
            pass
        arg0 = (_read(f"/proc/{d}/cmdline", binary=True) or b"").split(b"\0", 1)[0]
        if arg0 and arg0.decode("utf-8", "replace") == str(CE_BIN):
            out.append(int(d))  # exe ilegível (processo saindo), mas é o CE
    return sorted(out)


def proc_info(pid: int) -> dict | None:
    comm = _read(f"/proc/{pid}/comm")
    if comm is None:
        return None
    raw = _read(f"/proc/{pid}/cmdline", binary=True) or b""
    argv = [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a]
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        exe = None
    rss_kb = 0
    status = _read(f"/proc/{pid}/status") or ""
    uid = None
    for line in status.splitlines():
        if line.startswith("VmRSS:"):
            rss_kb = int(line.split()[1])
        elif line.startswith("Uid:"):
            uid = int(line.split()[1])
    exe_base = os.path.basename(exe) if exe else ""
    arg0 = argv[0].replace("\\", "/").split("/")[-1] if argv else ""
    wine = exe_base.startswith("wine") or arg0.lower().endswith(".exe")
    info = {"pid": pid, "comm": comm.strip(), "name": arg0 or comm.strip(), "exe": exe,
            "rss_mb": round(rss_kb / 1024, 1), "uid": uid, "wine": wine,
            "cmdline": " ".join(argv)[:300]}
    if wine:
        env = _read(f"/proc/{pid}/environ", binary=True) or b""
        for item in env.split(b"\0"):
            if item.startswith((b"SteamAppId=", b"STEAM_COMPAT_APP_ID=", b"SteamGameId=")):
                info["steam_appid"] = item.split(b"=", 1)[1].decode()
                break
        for item in env.split(b"\0"):
            if item.startswith(b"WINEPREFIX=") or item.startswith(b"STEAM_COMPAT_DATA_PATH="):
                info["prefix"] = item.split(b"=", 1)[1].decode()
                break
    return info


def list_processes(filtro: str | None = None) -> list[dict]:
    me = {os.getpid(), os.getppid()}
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) in me:
            continue
        info = proc_info(int(d))
        if not info:
            continue
        if filtro:
            f = filtro.lower()
            hay = f"{info['comm']} {info['name']} {info['exe'] or ''} {info['cmdline']}".lower()
            if f not in hay and f != str(info["pid"]):
                continue
        out.append(info)
    out.sort(key=lambda i: i["pid"], reverse=True)
    return out


def best_process(alvo: str) -> tuple[dict, list[dict]]:
    """Escolhe o processo que o usuário quis dizer com `alvo` (nome, exe, pid)."""
    if alvo.isdigit() and Path(f"/proc/{alvo}").exists():
        info = proc_info(int(alvo))
        if info:
            return info, []
    a = alvo.lower()
    ce = set(ce_pids())
    cands = []
    for p in list_processes(alvo):
        if p["pid"] in ce:
            continue
        nome, comm = p["name"].lower(), p["comm"].lower()
        exe_base = os.path.basename(p["exe"] or "").lower()
        stem = nome.rsplit(".", 1)[0]
        score = 0
        if a in (nome, comm, exe_base, stem):
            score += 100
        elif a in nome or a in comm or a in exe_base:
            score += 50
        else:
            score += 20  # só no cmdline
        if nome in WINE_HELPERS or comm in WINE_HELPERS or comm in SHELLISH or exe_base in SHELLISH:
            score -= 200
        cands.append((score, p["rss_mb"], p["pid"], p))
    if not cands:
        raise BridgeError(f"nenhum processo corresponde a {alvo!r} (veja: ce ps)")
    cands.sort(key=lambda c: (c[0], c[1], c[2]), reverse=True)
    return cands[0][3], [c[3] for c in cands[1:6]]


# ---------------------------------------------------------------------------
# Cliente da ponte
# ---------------------------------------------------------------------------
class Bridge:
    """Cliente da ponte ce_agent_bridge (TCP com token; reserva: caixa de correio)."""

    def __init__(self, timeout: float = 120.0, transport: str | None = None):
        self.dir = state_dir()
        self.timeout = timeout
        self.transport = transport or os.environ.get("CE_BRIDGE_TRANSPORT")  # tcp|mailbox|None
        self._sock: socket.socket | None = None
        self._buf = b""
        self._seq = 0
        self.info: dict = {}

    # -- descoberta ---------------------------------------------------------
    def load_info(self) -> dict:
        p = self.dir / "bridge.json"
        try:
            info = json.loads(p.read_text())
        except (OSError, ValueError):
            raise BridgeError(f"ponte não encontrada ({p}). O CE está aberto? Rode: ce up")
        pid = info.get("ce_pid")
        if pid and pid not in ce_pids():
            raise BridgeError(f"bridge.json é de um CE que já fechou (pid {pid}). Rode: ce up")
        self.info = info
        return info

    def token(self) -> str:
        return (self.dir / "token").read_text().strip()

    # -- transportes ----------------------------------------------------------
    def _tcp_call(self, req: dict, timeout: float) -> dict:
        if self._sock is None:
            port = self.info.get("port")
            if not port:
                raise BridgeError("ponte sem TCP")
            self._sock = socket.create_connection((self.info.get("host", "127.0.0.1"), port), timeout=5)
        self._sock.settimeout(timeout)
        req = dict(req, token=self.token())
        self._sock.sendall(json.dumps(req).encode() + RS)
        while RS not in self._buf:
            try:
                chunk = self._sock.recv(1 << 20)
            except socket.timeout:
                self.close()
                raise BridgeError(f"o CE não respondeu em {timeout:.0f}s (travado ou ocupado). "
                                  "Recupere com: ce down && ce up  (ou ce show para ver a janela)")
            if not chunk:
                self.close()
                raise BridgeError("a ponte fechou a conexão")
            self._buf += chunk
        raw, _, self._buf = self._buf.partition(RS)
        return json.loads(raw.decode("utf-8", "replace"))

    def _mailbox_call(self, req: dict, timeout: float) -> dict:
        mb = Path(self.info.get("mailbox") or self.dir / "mailbox")
        rid = uuid.uuid4().hex[:16]
        tmp, dst, resp = mb / f".req_{rid}.tmp", mb / f"req_{rid}.json", mb / f"resp_{rid}.json"
        tmp.write_text(json.dumps(req))
        tmp.rename(dst)
        t0 = time.time()
        while not resp.exists():
            if time.time() - t0 > timeout:
                dst.unlink(missing_ok=True)
                raise BridgeError(f"sem resposta em {timeout:.0f}s pela caixa de correio")
            time.sleep(0.005)
        data = resp.read_bytes()
        resp.unlink(missing_ok=True)
        return json.loads(data.decode("utf-8", "replace"))

    def call(self, method: str, params: dict | None = None, timeout: float | None = None):
        if not self.info:
            self.load_info()
        self._seq += 1
        req = {"id": self._seq, "method": method, "params": params or {}}
        t = timeout or self.timeout
        if self.transport == "mailbox" or not self.info.get("port"):
            resp = self._mailbox_call(req, t)
        else:
            try:
                resp = self._tcp_call(req, t)
            except (ConnectionError, OSError) as e:
                if self.transport == "tcp":
                    raise BridgeError(f"TCP falhou: {e}")
                self.close()
                resp = self._mailbox_call(req, t)
        if "error" in resp and resp["error"]:
            raise BridgeError(resp["error"].get("message", str(resp["error"])))
        return resp.get("result")

    def ping(self) -> bool:
        try:
            return bool(self.call("ping", timeout=5).get("pong"))
        except Exception:
            return False

    def close(self):
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
        self._sock, self._buf = None, b""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


# ---------------------------------------------------------------------------
# Ciclo de vida do CE
# ---------------------------------------------------------------------------
def _bridge_ok() -> dict | None:
    try:
        b = Bridge(timeout=5)
        b.load_info()
        if b.ping():
            return b.info
    except BridgeError:
        pass
    return None


def start_ce(headless: bool = False, timeout: float = 45.0) -> dict:
    import fcntl
    sd = state_dir()
    sd.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = open(sd / "up.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)  # dois "ce up" ao mesmo tempo não abrem dois CEs
    try:
        return _start_ce_locked(headless, timeout)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def _start_ce_locked(headless: bool, timeout: float) -> dict:
    info = _bridge_ok()
    if info:
        return {**info, "launched": False, "already_running": True}
    vivos = ce_pids()
    if vivos:  # CE abrindo (ou fechando): dá um tempo para a ponte aparecer
        t0 = time.time()
        while time.time() - t0 < 15 and ce_pids():
            info = _bridge_ok()
            if info:
                return {**info, "launched": False, "already_running": True}
            time.sleep(0.3)
        vivos = ce_pids()
    if vivos:
        raise BridgeError(f"o CE está aberto (pid {vivos}) mas a ponte não responde há 15 s "
                          "(diálogo modal aberto? ponte fora do autorun?). Rode: ce doctor; "
                          "ou ce down && ce up")
    if not CE_BIN.exists():
        raise BridgeError("Cheat Engine não instalado. Rode: bash ~/Agent-Skills/cheat-engine-agent-skill/install.sh")
    env = dict(os.environ)
    sem_tela = not (env.get("WAYLAND_DISPLAY") or env.get("DISPLAY"))
    if headless or sem_tela:
        env["QT_QPA_PLATFORM"] = "offscreen"
    sd = state_dir()
    (sd / "bridge.json").unlink(missing_ok=True)
    log = open(sd / "ce.log", "ab")
    subprocess.Popen([CE_LAUNCHER], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                     env=env, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            b = Bridge()
            b.load_info()
            if b.ping():
                return {**b.info, "launched": True, "headless": env.get("QT_QPA_PLATFORM") == "offscreen",
                        "seconds": round(time.time() - t0, 1)}
        except BridgeError:
            pass
        time.sleep(0.3)
    raise BridgeError(f"o CE não publicou a ponte em {timeout:.0f}s (veja $XDG_RUNTIME_DIR/ce-agent-bridge/bridge.log)")


def stop_ce(timeout: float = 10.0) -> dict:
    pids = ce_pids()
    if not pids:
        (state_dir() / "bridge.json").unlink(missing_ok=True)
        return {"running": False}
    r = {"closed": pids}
    try:
        r["backup"] = Bridge(timeout=5).call("ce_close", timeout=5).get("backup")
    except (BridgeError, OSError, ValueError):
        pass

    def esperar(seg):
        t0 = time.time()
        while ce_pids() and time.time() - t0 < seg:
            time.sleep(0.2)
        return ce_pids()

    restantes = esperar(timeout)
    if restantes:  # diálogo modal ou debugger preso: TERM e depois KILL
        for pid in restantes:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        r["sigterm"] = restantes
        restantes = esperar(3)
        for pid in restantes:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        if restantes:
            r["sigkill"] = restantes
            esperar(2)
    (state_dir() / "bridge.json").unlink(missing_ok=True)
    r["running"] = bool(ce_pids())
    return r


# ---------------------------------------------------------------------------
# Diagnóstico
# ---------------------------------------------------------------------------
def doctor() -> dict:
    checks, problems, fixes = {}, [], []

    checks["ce_binary"] = str(CE_BIN) if CE_BIN.exists() else None
    if not CE_BIN.exists():
        problems.append("Cheat Engine nativo não instalado")
        fixes.append("bash ~/Agent-Skills/cheat-engine-agent-skill/install.sh")
    try:
        checks["ce_package"] = subprocess.run(["pacman", "-Q", "cheatengine-bin"], capture_output=True,
                                              text=True).stdout.strip() or None
    except OSError:
        checks["ce_package"] = None

    try:
        scope = int(Path("/proc/sys/kernel/yama/ptrace_scope").read_text())
    except OSError:
        scope = None
    checks["ptrace_scope"] = scope
    if scope not in (0, None):
        problems.append(f"kernel.yama.ptrace_scope={scope}: o CE só lê processos filhos ou como root")
        fixes.append("echo 'kernel.yama.ptrace_scope = 0' | sudo tee /etc/sysctl.d/99-cheat-engine-ptrace.conf "
                     "&& sudo sysctl -w kernel.yama.ptrace_scope=0")

    links = {BRIDGE_LINK: "ce_agent_bridge.lua"}
    if CE_PREFIX == AUR_PREFIX:
        links["server.lua"] = "server.lua"
    for link, fonte in links.items():
        p = CE_AUTORUN / link
        ok = p.exists() and p.resolve() == (SKILL_DIR / "autorun" / fonte).resolve()
        checks[f"autorun/{link}"] = str(p.resolve()) if p.exists() else None
        if not ok:
            problems.append(f"{p} não aponta para a skill")
            fixes.append(f"ln -sfn {SKILL_DIR / 'autorun' / fonte} {p}")
    antigo = CE_AUTORUN / "ce_agent_bridge.lua"
    if antigo.exists() or antigo.is_symlink():
        problems.append(f"{antigo} (nome antigo) carregaria a ponte 2 vezes")
        fixes.append(f"rm {antigo}")
    if CE_PREFIX != AUR_PREFIX and (CE_AUTORUN / "server.lua").exists():
        problems.append(f"{CE_AUTORUN / 'server.lua'} (shell Lua sem senha em 0.0.0.0:11211) está ativo")
        fixes.append(f"mv {CE_AUTORUN / 'server.lua'} {CE_AUTORUN / 'server.lua.disabled'}")

    ouvindo = subprocess.run(["ss", "-ltnH"], capture_output=True, text=True).stdout
    checks["porta_11211_aberta"] = ":11211" in ouvindo
    if ":11211" in ouvindo and "0.0.0.0:11211" in ouvindo:
        problems.append("algo escuta em 0.0.0.0:11211 (server.lua oficial do CE? shell Lua sem senha na rede)")
        fixes.append("ce down && ce up   (com o override autorun/server.lua instalado)")

    checks["ce_running"] = ce_pids()
    b = Bridge(timeout=5)
    try:
        b.load_info()
        checks["bridge"] = b.info
        checks["bridge_ping_tcp"] = Bridge(timeout=5, transport="tcp").ping() if b.info.get("port") else False
        checks["bridge_ping_mailbox"] = Bridge(timeout=5, transport="mailbox").ping()
        if not (checks["bridge_ping_tcp"] or checks["bridge_ping_mailbox"]):
            problems.append("ponte publicada mas sem resposta")
            fixes.append("ce down && ce up")
    except BridgeError as e:
        checks["bridge"] = None
        if checks["ce_running"]:
            problems.append(str(e))
            fixes.append("ce down && ce up")
        else:
            checks["bridge_note"] = "CE fechado (normal). Abra com: ce up"

    for mod in ("numpy", "capstone", "keystone"):
        try:
            __import__(mod)
            checks[f"py_{mod}"] = True
        except ImportError:
            checks[f"py_{mod}"] = False
            problems.append(f"python: falta {mod} (usado pelo cemem)")
            fixes.append(f"sudo pacman -S --needed python-{mod}")
    checks["scanmem"] = shutil.which("scanmem")
    checks["display"] = os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY") or None
    for b_ in ("ce", "cemem"):
        checks[f"bin_{b_}"] = shutil.which(b_)
    return {"ok": not problems, "problems": problems, "fixes": fixes, "checks": checks}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def emit(obj, code: int = 0):
    print(json.dumps(obj, indent=2, ensure_ascii=False, default=str))
    sys.exit(code)


def addr_arg(s: str) -> str:
    """Endereço do CLI -> string para a ponte (hex puro vira 0x...)."""
    s = s.strip()
    if all(c in "0123456789abcdefABCDEF" for c in s) and s:
        return "0x" + s
    return s


def offsets_arg(vals: list[str] | None) -> list[int] | None:
    if not vals:
        return None
    out = []
    for v in vals:
        v = v.strip()
        neg = v.startswith("-")
        v = v.lstrip("+-")
        n = int(v, 16) if not v.lower().startswith("0d") else int(v[2:])
        out.append(-n if neg else n)
    return out


def read_script(arg: str) -> str:
    if arg == "-":
        return sys.stdin.read()
    p = Path(arg)
    if p.exists():
        return p.read_text()
    return arg  # script inline


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="ce", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--timeout", type=float, default=120,
                    help="timeout por chamada e por scan (s); scans são assíncronos")
    ap.add_argument("--transport", choices=["tcp", "mailbox"], help="força o transporte")
    sp = ap.add_subparsers(dest="cmd", required=True, metavar="comando")

    def add(name, help_, **kw):
        return sp.add_parser(name, help=help_, description=help_, **kw)

    p = add("up", "abre o CE (se preciso) e espera a ponte")
    p.add_argument("--headless", action="store_true", help="sem janela (QT_QPA_PLATFORM=offscreen)")
    p.add_argument("--wait", type=float, default=45)
    add("down", "fecha o Cheat Engine")
    add("status", "CE aberto? ponte? processo anexado?")
    add("doctor", "diagnóstico completo com correções sugeridas")
    p = add("help", "métodos da ponte (ou a doc de um)")
    p.add_argument("method", nargs="?")

    p = add("ps", "lista processos (nativo/Wine/Proton) via /proc")
    p.add_argument("filtro", nargs="?")
    p.add_argument("--all", action="store_true", help="inclui processos de outros usuários")
    p = add("attach", "abre um processo no CE (pid ou nome; escolhe o melhor candidato)")
    p.add_argument("alvo")
    add("detach", "fecha o processo no CE")
    add("info", "processo aberto no CE")
    p = add("modules", "módulos do alvo")
    p.add_argument("filtro", nargs="?")
    p = add("regions", "mapa de memória do alvo")
    p.add_argument("filtro", nargs="?")
    p.add_argument("--writable", action="store_true")
    p.add_argument("--executable", action="store_true")
    p.add_argument("--limit", type=int, default=500)
    p = add("resolve", "símbolo/expressão -> endereço")
    p.add_argument("simbolo")

    p = add("read", "lê memória")
    p.add_argument("endereco")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("-n", "--count", type=int, default=1, help="nº de elementos (ou bytes p/ -t bytes)")
    p.add_argument("--signed", action="store_true")
    p.add_argument("--maxlen", type=int, default=256)
    p = add("write", "escreve memória (transacional: desfaça com ce undo)")
    p.add_argument("endereco")
    p.add_argument("valor", help="número, texto (-t string) ou bytes hex (-t bytes)")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("--hex", action="store_true", help="valor numérico em hexadecimal")
    p = add("undo", "desfaz escritas (ce undo <txn> | ce undo --all)")
    p.add_argument("txn", nargs="?")
    p.add_argument("--all", action="store_true")
    p = add("ptr", "segue uma cadeia de ponteiros: ce ptr <base> <off1> <off2> ...")
    p.add_argument("base")
    p.add_argument("offsets", nargs="*", help="offsets em hex (ex.: 10 1c 0)")
    p.add_argument("-t", "--type", default="dword")
    p = add("dump", "hexdump")
    p.add_argument("endereco")
    p.add_argument("-s", "--size", type=int, default=256)
    p = add("aob", "procura padrão de bytes ('48 8B ?? 05')")
    p.add_argument("padrao")
    p.add_argument("-m", "--module")
    p.add_argument("--unique", action="store_true")
    p.add_argument("--limit", type=int, default=100)

    p = add("scan", "first scan (novo scan)")
    p.add_argument("valor", nargs="?", help="omitido = valor inicial desconhecido")
    p.add_argument("-t", "--type", default="dword",
                   help="byte|word|dword|qword|float|double|string|widestring|bytes|all")
    p.add_argument("--op", default=None, help="exact|between|bigger|smaller|unknown")
    p.add_argument("--value2")
    p.add_argument("-m", "--module", help="restringe ao módulo")
    p.add_argument("--rounding", default="rounded", help="rounded|truncated|extreme (float)")
    p.add_argument("--unaligned", action="store_true")
    p.add_argument("--hex", action="store_true")
    p.add_argument("--protection", help="ex.: +W*X*C (padrão Linux)")
    p.add_argument("--preview", type=int, default=20)
    p.add_argument("--keep", action="store_true", help="não descarta os scans anteriores")
    p = add("next", "next scan: valor | increased | decreased | changed | unchanged | bigger N ...")
    p.add_argument("op_ou_valor")
    p.add_argument("valor", nargs="?")
    p.add_argument("--value2")
    p.add_argument("--scan", default="last")
    p.add_argument("--percentage", action="store_true")
    p.add_argument("--compare-to", help="'FIRST' ou nome salvo")
    p.add_argument("--rounding", default="rounded")
    p.add_argument("--preview", type=int, default=20)
    p = add("results", "resultados do scan")
    p.add_argument("--scan", default="last")
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--names", action="store_true")
    add("scans", "scans abertos")
    p = add("scan-cancel", "interrompe um scan em andamento")
    p.add_argument("--scan", default="last")
    p = add("scan-free", "libera scan(s)")
    p.add_argument("--scan", default="last")
    p.add_argument("--all", action="store_true")

    p = add("list", "tabela de endereços do CE")
    p.add_argument("filtro", nargs="?")
    p = add("add", "adiciona entrada na tabela do CE")
    p.add_argument("endereco")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("-d", "--description")
    p.add_argument("--offsets", nargs="*")
    p.add_argument("--value")
    p.add_argument("--freeze", action="store_true")
    p = add("add-script", "grava um script AA como entrada (cheat clicável) na tabela do CE")
    p.add_argument("script", help="arquivo, '-' (stdin) ou texto")
    p.add_argument("-d", "--description")
    p.add_argument("--enable", action="store_true", help="ativa já")
    p = add("freeze", "congela um valor (entrada ativa na tabela)")
    p.add_argument("endereco")
    p.add_argument("valor", nargs="?")
    p.add_argument("-t", "--type", default="dword")
    p.add_argument("--offsets", nargs="*")
    p.add_argument("-d", "--description")
    p = add("unfreeze", "descongela (id da entrada)")
    p.add_argument("id")
    p.add_argument("--delete", action="store_true")
    p = add("set", "altera uma entrada da tabela")
    p.add_argument("id")
    p.add_argument("--value")
    p.add_argument("--freeze", action="store_true")
    p.add_argument("--unfreeze", action="store_true")
    p = add("rm", "remove entrada (id) ou --agent (todas as criadas pelo agente)")
    p.add_argument("id", nargs="?")
    p.add_argument("--agent", action="store_true")
    p = add("table", "salva/carrega tabela .CT")
    p.add_argument("acao", choices=["save", "load"])
    p.add_argument("arquivo")
    p.add_argument("--merge", action="store_true")

    p = add("disasm", "desmonta instruções")
    p.add_argument("endereco")
    p.add_argument("-n", "--count", type=int, default=20)
    p = add("asm", "monta uma instrução")
    p.add_argument("linha")
    p.add_argument("--at")
    p = add("aa", "Auto Assembler: check|apply <arquivo|-|script> ; revert <aa_id>|--all ; list")
    p.add_argument("acao", choices=["check", "apply", "revert", "list"])
    p.add_argument("alvo", nargs="?")
    p.add_argument("--all", action="store_true")
    p = add("watch", "descobre que instruções escrevem/acessam um endereço")
    p.add_argument("endereco")
    p.add_argument("--kind", default="write", choices=["write", "access", "execute"])
    p.add_argument("--size", type=int, default=4)
    p.add_argument("--seconds", type=float, default=5)
    p = add("speed", "speedhack (1.0 = normal). Em alvo Linux nativo exige --force (instável no CE 7.7.1)")
    p.add_argument("fator", type=float)
    p.add_argument("--force", action="store_true")
    add("mono", "injeta o MonoDataCollector (jogos Unity/Mono)")
    add("pause", "pausa o alvo")
    add("unpause", "retoma o alvo")
    add("show", "mostra a janela do CE")
    add("hide", "esconde a janela do CE")

    p = add("lua", "executa Lua no CE: ce lua 'return 1+1' | ce lua -f arq.lua")
    p.add_argument("codigo", nargs="?")
    p.add_argument("-f", "--file")
    p = add("call", "chama qualquer método da ponte: ce call <metodo> '<json>'")
    p.add_argument("method")
    p.add_argument("params", nargs="?", default="{}")
    p = add("cleanup", "desfaz o estado do agente no CE")
    p.add_argument("--rollback-writes", action="store_true")
    p.add_argument("--keep-records", action="store_true")
    return ap


def run_scan(c, metodo: str, params: dict, timeout: float, preview: int = 20, names: bool = False) -> dict:
    """Scans são assíncronos na ponte: dispara, consulta scan_status até done e devolve o resumo."""
    r = c(metodo, params)
    sid = r["scan_id"]
    t0, pausa = time.time(), 0.01
    while True:
        st = c("scan_status", {"scan_id": sid, "preview": preview, "names": names}, timeout=15)
        if st.get("done"):
            return st
        if time.time() - t0 > timeout:
            try:
                c("scan_cancel", {"scan_id": sid}, timeout=15)
            finally:
                raise BridgeError(f"o scan {sid} passou de {timeout:.0f}s e foi interrompido "
                                  "(restrinja com -m modulo ou aumente --timeout)")
        time.sleep(pausa)
        pausa = min(pausa * 1.5, 0.25)


NEXT_WORDS = {"increased", "decreased", "changed", "unchanged", "bigger", "smaller", "between",
              "exact", "increased_by", "decreased_by", "greater", "less", "+", "-", "="}


def run(args) -> object:
    cmd = args.cmd
    if cmd == "up":
        return start_ce(headless=args.headless, timeout=args.wait)
    if cmd == "down":
        return stop_ce()
    if cmd == "doctor":
        r = doctor()
        return r
    if cmd == "ps":
        procs = list_processes(args.filtro)
        if not args.all:
            procs = [p for p in procs if p["uid"] == os.getuid()]
        return {"count": len(procs), "processes": procs[:200]}

    b = Bridge(timeout=args.timeout, transport=args.transport)
    c = b.call

    if cmd == "status":
        r = {"ce_running": ce_pids()}
        try:
            b.load_info()
            r["bridge"] = {k: b.info.get(k) for k in ("bridge", "port", "mailbox", "ce", "ce_pid")}
            r["info"] = c("info", timeout=10)
        except BridgeError as e:
            r["bridge"] = None
            r["note"] = str(e)
        return r
    if cmd == "help":
        return c("help", {"method": args.method} if args.method else {})
    if cmd == "attach":
        info, outros = best_process(args.alvo)
        r = c("attach", {"pid": info["pid"]})
        r["process"] = info
        if outros:
            r["other_candidates"] = [{"pid": o["pid"], "name": o["name"], "rss_mb": o["rss_mb"]} for o in outros]
        return r
    if cmd == "detach":
        return c("detach")
    if cmd == "info":
        return c("info")
    if cmd == "modules":
        return c("modules", {"filter": args.filtro})
    if cmd == "regions":
        p = {"filter": args.filtro, "limit": args.limit}
        if args.writable:
            p["writable"] = True
        if args.executable:
            p["executable"] = True
        return c("regions", p)
    if cmd == "resolve":
        return c("resolve", {"symbol": addr_arg(args.simbolo)})
    if cmd == "read":
        p = {"address": addr_arg(args.endereco), "type": args.type, "signed": args.signed,
             "maxlen": args.maxlen}
        if args.type in ("bytes", "aob", "bytearray"):
            p["size"] = args.count if args.count > 1 else 16
        else:
            p["count"] = args.count
        return c("read", p)
    if cmd == "write":
        p = {"address": addr_arg(args.endereco), "type": args.type}
        if args.type in ("bytes", "aob", "bytearray"):
            p["bytes"] = args.valor
        elif args.type in ("string", "widestring", "str", "unicode"):
            p["value"] = args.valor
        else:
            p["value"] = int(args.valor, 16) if args.hex else (
                float(args.valor) if any(ch in args.valor for ch in ".eE") else int(args.valor))
        return c("write", p)
    if cmd == "undo":
        return c("txn_rollback", {"all": True} if args.all or not args.txn else {"txn": args.txn})
    if cmd == "ptr":
        return c("pointer", {"base": addr_arg(args.base), "offsets": offsets_arg(args.offsets) or [],
                             "type": args.type})
    if cmd == "dump":
        return c("dump", {"address": addr_arg(args.endereco), "size": args.size})
    if cmd == "aob":
        st = run_scan(c, "aob_scan", {"pattern": args.padrao, "module": args.module},
                      args.timeout, preview=1 if args.unique else args.limit, names=True)
        res = st.get("results", [])
        r = {"pattern": args.padrao, "scan_id": st["scan_id"], "total": st.get("found", 0),
             "addresses": [x["address"] for x in res], "names": [x.get("name") for x in res],
             "seconds": st.get("seconds")}
        if args.unique and st.get("found", 0) > 1:
            r["warning"] = f"padrão NÃO é único ({st['found']} ocorrências): mostrei a primeira"
        c("scan_free", {"scan_id": st["scan_id"]})
        return r
    if cmd == "scan":
        op = args.op or ("exact" if args.valor is not None else "unknown")
        p = {"type": args.type, "option": op, "value": args.valor, "value2": args.value2,
             "module": args.module, "rounding": args.rounding, "hex": args.hex,
             "preview": args.preview}
        if args.unaligned:
            p["aligned"] = False
        if args.protection:
            p["protection"] = args.protection
        p.pop("preview", None)
        if not args.keep:  # como o "New Scan" do CE: descarta os scans anteriores
            c("scan_free", {"all": True})
        params = {k: v for k, v in p.items() if v is not None}
        r = run_scan(c, "scan_first", params, args.timeout, preview=args.preview)
        if r.get("error") and not r.get("found"):
            # erro interno do scanner do CE (ex.: "thread 2:Duplicate ID ...", visto no
            # 7.7.1): descarta e repete uma vez antes de devolver o erro
            erro1 = r["error"]
            c("scan_free", {"scan_id": r["scan_id"]})
            r = run_scan(c, "scan_first", params, args.timeout, preview=args.preview)
            r["retried_after"] = erro1
        return r
    if cmd == "next":
        w = args.op_ou_valor.lower()
        if w in NEXT_WORDS:
            op = {"+": "increased", "-": "decreased", "=": "unchanged", "greater": "bigger",
                  "less": "smaller"}.get(w, w)
            if op in ("increased", "decreased") and args.valor is not None:
                op += "_by"
            val = args.valor
        else:
            op, val = "exact", args.op_ou_valor
        p = {"scan_id": args.scan, "option": op, "value": val, "value2": args.value2,
             "percentage": args.percentage, "compare_to": args.compare_to,
             "rounding": args.rounding}
        return run_scan(c, "scan_next", {k: v for k, v in p.items() if v is not None},
                        args.timeout, preview=args.preview)
    if cmd == "results":
        return c("scan_results", {"scan_id": args.scan, "offset": args.offset, "limit": args.limit,
                                  "names": args.names})
    if cmd == "scans":
        return c("scan_list")
    if cmd == "scan-cancel":
        return c("scan_cancel", {"scan_id": args.scan})
    if cmd == "scan-free":
        return c("scan_free", {"all": True} if args.all else {"scan_id": args.scan})
    if cmd == "list":
        return c("records", {"filter": args.filtro})
    if cmd in ("add", "freeze"):
        p = {"address": addr_arg(args.endereco), "type": args.type,
             "description": args.description, "offsets": offsets_arg(args.offsets)}
        if cmd == "add":
            p["value"], p["freeze"] = args.value, args.freeze
            return c("record_add", {k: v for k, v in p.items() if v is not None})
        p["value"] = args.valor
        return c("freeze", {k: v for k, v in p.items() if v is not None})
    if cmd == "add-script":
        p = {"script": read_script(args.script), "description": args.description, "enable": args.enable}
        return c("record_add_script", {k: v for k, v in p.items() if v is not None})
    if cmd == "unfreeze":
        return c("unfreeze", {"id": int(args.id), "delete": args.delete})
    if cmd == "set":
        p = {"id": int(args.id)}
        if args.value is not None:
            p["value"] = args.value
        if args.freeze:
            p["freeze"] = True
        if args.unfreeze:
            p["freeze"] = False
        return c("record_set", p)
    if cmd == "rm":
        if args.agent:
            return c("record_delete", {"agent_only": True})
        if not args.id:
            raise BridgeError("informe o id ou --agent")
        return c("record_delete", {"id": int(args.id)})
    if cmd == "table":
        path = str(Path(args.arquivo).expanduser().resolve())
        if args.acao == "save":
            return c("table_save", {"path": path})
        return c("table_load", {"path": path, "merge": args.merge})
    if cmd == "disasm":
        return c("disassemble", {"address": addr_arg(args.endereco), "count": args.count})
    if cmd == "asm":
        p = {"line": args.linha}
        if args.at:
            p["address"] = addr_arg(args.at)
        return c("assemble", p)
    if cmd == "aa":
        if args.acao == "list":
            return c("aa_list")
        if args.acao == "revert":
            if args.all or not args.alvo:
                return c("aa_revert_all")
            return c("aa_revert", {"aa_id": args.alvo})
        if not args.alvo:
            raise BridgeError("informe o script: arquivo, '-' (stdin) ou texto")
        script = read_script(args.alvo)
        return c("aa_check" if args.acao == "check" else "aa_apply", {"script": script})
    if cmd == "watch":
        w = c("watch_start", {"address": addr_arg(args.endereco), "kind": args.kind, "size": args.size})
        try:
            time.sleep(args.seconds)
        finally:
            r = c("watch_stop", {"watch_id": w["watch_id"]})
        r["seconds"] = args.seconds
        return r
    if cmd == "speed":
        return c("speedhack", {"speed": args.fator, "force": args.force})
    if cmd == "mono":
        return c("mono_launch")
    if cmd in ("pause", "unpause"):
        return c(cmd)
    if cmd == "show":
        return c("gui_show")
    if cmd == "hide":
        return c("gui_hide")
    if cmd == "lua":
        if args.file:
            code = sys.stdin.read() if args.file == "-" else Path(args.file).read_text()
        else:
            code = sys.stdin.read() if args.codigo == "-" else args.codigo
        if not code:
            raise BridgeError("informe o código ou -f arquivo")
        if not args.file and "return" not in code and "\n" not in code and "=" not in code:
            return c("eval", {"expr": code})
        return c("eval", {"code": code})
    if cmd == "call":
        return c(args.method, json.loads(args.params))
    if cmd == "cleanup":
        return c("cleanup", {"rollback_writes": args.rollback_writes, "records": not args.keep_records})
    raise BridgeError(f"comando desconhecido: {cmd}")


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        r = run(args)
    except BridgeError as e:
        emit({"ok": False, "error": str(e)}, 1)
    except KeyboardInterrupt:
        emit({"ok": False, "error": "interrompido"}, 130)
    if args.cmd == "doctor":
        emit(r, 0 if r.get("ok") else 1)
    emit(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
