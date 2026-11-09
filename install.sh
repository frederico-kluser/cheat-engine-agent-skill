#!/usr/bin/env bash
# install.sh — instala e configura TUDO da cheat-engine-agent-skill (idempotente).
#
#   bash install.sh             # instala/atualiza tudo
#   bash install.sh --check     # só diagnostica (ce doctor)
#   bash install.sh --no-sysctl # não mexe em kernel.yama.ptrace_scope
#   bash install.sh --uninstall # remove symlinks/sysctl (mantém pacotes e o CE)
#
# O que faz:
#   1. pacotes: python-numpy python-capstone python-keystone scanmem (pacman)
#   2. Cheat Engine 7.7.1 NATIVO para Linux (AUR cheatengine-bin via paru/yay;
#      sem helper AUR: zip oficial de cheatengine.org em ~/.local/opt/cheatengine)
#   3. kernel.yama.ptrace_scope=0 em /etc/sysctl.d/99-cheat-engine-ptrace.conf
#      (recomendação do readme-linux.txt do próprio CE: ler memória sem root)
#   4. ponte autorun/ce_agent_bridge.lua + override autorun/server.lua (fecha o
#      "CELua server" oficial que abre 0.0.0.0:11211 sem senha)
#   5. comandos `ce` e `cemem` em ~/.local/bin
#   6. registra a skill em ~/.claude/skills, $CLAUDE_CONFIG_DIR/skills,
#      ~/.agents/skills e ~/.codex/skills (os que existirem)
#   7. roda `ce doctor`
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SKILL_NAME="cheat-engine-agent-skill"
CE_VERSION="7.7.1"
CE_ZIP_URL="https://cheatengine.org/download/CheatEngineLinux${CE_VERSION//./}.zip"
# o upstream já trocou o zip sem mudar o nome: CE_ZIP_SHA256=<novo> ou =skip sobrescreve
CE_ZIP_SHA256="${CE_ZIP_SHA256:-0fb0d9043ae856acde03b5b871a2f3627ebcf674aeacd045f86d56d91a07f177}"
SYSCTL_FILE="/etc/sysctl.d/99-cheat-engine-ptrace.conf"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
USER_CE_DIR="$DATA_HOME/cheatengine"           # overlay do pacote AUR
MANUAL_PREFIX="$HOME/.local/opt/cheatengine"   # instalação sem AUR
BIN_DIR="$HOME/.local/bin"

DO_SYSCTL=1
MODE=install
for arg in "$@"; do
  case "$arg" in
    --no-sysctl) DO_SYSCTL=0 ;;
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2; exit 1; }

skill_dirs() {
  local d
  for d in "$HOME/.claude/skills" "${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/skills}" \
           "$HOME/.agents/skills" "$HOME/.codex/skills"; do
    [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
  done | sort -u
}

if [ "$MODE" = check ]; then
  exec python3 "$SKILL_DIR/scripts/ce.py" doctor
fi

if [ "$MODE" = uninstall ]; then
  say "removendo symlinks da skill"
  for d in $(skill_dirs); do
    [ -L "$d/$SKILL_NAME" ] && rm -f "$d/$SKILL_NAME" && echo "  - $d/$SKILL_NAME"
  done
  for b in ce cemem; do
    [ -L "$BIN_DIR/$b" ] && rm -f "$BIN_DIR/$b" && echo "  - $BIN_DIR/$b"
  done
  for f in "$USER_CE_DIR/autorun/00_ce_agent_bridge.lua" "$USER_CE_DIR/autorun/ce_agent_bridge.lua" \
           "$USER_CE_DIR/autorun/server.lua" "$MANUAL_PREFIX/autorun/00_ce_agent_bridge.lua"; do
    [ -L "$f" ] && rm -f "$f" && echo "  - $f"
  done
  if [ -f "$MANUAL_PREFIX/autorun/server.lua.disabled" ]; then
    mv "$MANUAL_PREFIX/autorun/server.lua.disabled" "$MANUAL_PREFIX/autorun/server.lua"
  fi
  if [ -f "$SYSCTL_FILE" ]; then
    sudo rm -f "$SYSCTL_FILE" && sudo sysctl -w kernel.yama.ptrace_scope=1 >/dev/null
    echo "  - $SYSCTL_FILE (ptrace_scope=1)"
  fi
  say "pronto (pacotes e o Cheat Engine continuam instalados: sudo pacman -Rns cheatengine-bin)"
  exit 0
fi

command -v pacman >/dev/null || die "este instalador é para Arch/CachyOS (pacman)."
command -v python3 >/dev/null || die "python3 não encontrado."

# 1. pacotes ------------------------------------------------------------------
say "pacotes: python-numpy python-capstone python-keystone scanmem"
faltam=()
for p in python-numpy python-capstone python-keystone scanmem; do
  pacman -Q "$p" >/dev/null 2>&1 || faltam+=("$p")
done
if [ ${#faltam[@]} -gt 0 ]; then
  sudo pacman -S --needed --noconfirm "${faltam[@]}"
else
  echo "  já instalados"
fi

# 2. Cheat Engine nativo ----------------------------------------------------------
CE_LAYOUT=""
if [ -x /usr/lib/cheatengine/cheatengine-x86_64 ]; then
  CE_LAYOUT=aur
  echo "  Cheat Engine: $(pacman -Q cheatengine-bin 2>/dev/null || echo /usr/lib/cheatengine)"
elif [ -x "$MANUAL_PREFIX/cheatengine-x86_64" ]; then
  CE_LAYOUT=manual
  echo "  Cheat Engine: $MANUAL_PREFIX"
else
  AUR=""
  for h in paru yay; do command -v "$h" >/dev/null && AUR="$h" && break; done
  if [ -n "$AUR" ]; then
    say "instalando Cheat Engine $CE_VERSION (AUR cheatengine-bin via $AUR)"
    ( cd "$(mktemp -d)" && "$AUR" -S --needed --noconfirm --skipreview cheatengine-bin ) \
      || ( cd "$(mktemp -d)" && "$AUR" -S --needed --noconfirm cheatengine-bin )
    CE_LAYOUT=aur
  else
    say "sem paru/yay: instalando o zip oficial em $MANUAL_PREFIX"
    sudo pacman -S --needed --noconfirm qt6-base libx11
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/ce.zip" "$CE_ZIP_URL"
    if [ "$CE_ZIP_SHA256" = skip ]; then
      warn "CE_ZIP_SHA256=skip: zip sem verificação de integridade"
    else
      echo "$CE_ZIP_SHA256  $tmp/ce.zip" | sha256sum -c - >/dev/null \
        || die "sha256 do zip não confere (upstream trocou o arquivo? confira e use CE_ZIP_SHA256=<novo>)"
    fi
    mkdir -p "$MANUAL_PREFIX"
    bsdtar -xf "$tmp/ce.zip" -C "$MANUAL_PREFIX"
    CE_LAYOUT=manual
  fi
fi
[ -n "$CE_LAYOUT" ] || die "não consegui instalar o Cheat Engine"

# 3. ptrace -------------------------------------------------------------------
if [ "$DO_SYSCTL" = 1 ]; then
  scope="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)"
  if [ ! -f "$SYSCTL_FILE" ] || [ "$scope" != 0 ]; then
    say "kernel.yama.ptrace_scope=0 (persistente em $SYSCTL_FILE)"
    printf '%s\n' \
      '# cheat-engine-agent-skill: deixa processos do MESMO usuário lerem a memória' \
      '# uns dos outros (ptrace / process_vm_readv / /proc/PID/mem), como pede o' \
      '# readme-linux.txt do Cheat Engine. Reverter:' \
      '#   sudo rm /etc/sysctl.d/99-cheat-engine-ptrace.conf && sudo sysctl -w kernel.yama.ptrace_scope=1' \
      'kernel.yama.ptrace_scope = 0' | sudo tee "$SYSCTL_FILE" >/dev/null
    sudo sysctl -w kernel.yama.ptrace_scope=0 >/dev/null
  else
    echo "  ptrace_scope já é 0"
  fi
else
  warn "--no-sysctl: sem ptrace_scope=0 o CE só lê processos como root"
fi

# 4. ponte + override do server.lua -----------------------------------------------------
if [ "$CE_LAYOUT" = aur ]; then
  say "ponte em $USER_CE_DIR/autorun (overlay do pacote AUR)"
  mkdir -p "$USER_CE_DIR/autorun"
  # "00_" faz a ponte carregar ANTES dos scripts do CE (um diálogo deles não a bloqueia)
  rm -f "$USER_CE_DIR/autorun/ce_agent_bridge.lua"
  ln -sfn "$SKILL_DIR/autorun/ce_agent_bridge.lua" "$USER_CE_DIR/autorun/00_ce_agent_bridge.lua"
  ln -sfn "$SKILL_DIR/autorun/server.lua" "$USER_CE_DIR/autorun/server.lua"
else
  say "ponte em $MANUAL_PREFIX/autorun"
  rm -f "$MANUAL_PREFIX/autorun/ce_agent_bridge.lua"
  ln -sfn "$SKILL_DIR/autorun/ce_agent_bridge.lua" "$MANUAL_PREFIX/autorun/00_ce_agent_bridge.lua"
  if [ -f "$MANUAL_PREFIX/autorun/server.lua" ] && [ ! -L "$MANUAL_PREFIX/autorun/server.lua" ]; then
    mv "$MANUAL_PREFIX/autorun/server.lua" "$MANUAL_PREFIX/autorun/server.lua.disabled"
  fi
  mkdir -p "$BIN_DIR"
  printf '%s\n' '#!/bin/sh' "cd \"$MANUAL_PREFIX\" && exec ./cheatengine-x86_64 \"\$@\"" > "$BIN_DIR/cheatengine"
  chmod +x "$BIN_DIR/cheatengine"
fi

# 5. comandos ---------------------------------------------------------------------
say "comandos ce e cemem em $BIN_DIR"
mkdir -p "$BIN_DIR"
chmod +x "$SKILL_DIR/bin/ce" "$SKILL_DIR/bin/cemem" "$SKILL_DIR/scripts/ce.py" "$SKILL_DIR/scripts/cemem.py"
ln -sfn "$SKILL_DIR/bin/ce" "$BIN_DIR/ce"
ln -sfn "$SKILL_DIR/bin/cemem" "$BIN_DIR/cemem"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR não está no PATH" ;; esac

# 6. registro da skill --------------------------------------------------------------
say "registrando a skill"
for d in $(skill_dirs); do
  alvo="$d/$SKILL_NAME"
  if [ -e "$alvo" ] && [ ! -L "$alvo" ]; then
    warn "$alvo existe e não é symlink: deixei como está"
    continue
  fi
  ln -sfn "$SKILL_DIR" "$alvo"
  echo "  + $alvo"
done

# 7. diagnóstico --------------------------------------------------------------------
say "ce doctor"
python3 "$SKILL_DIR/scripts/ce.py" doctor || true
say "pronto. Teste rápido: ce up && ce ps && ce attach <programa> && ce scan <valor>"
