# cheat-engine-agent-skill

O **Cheat Engine 7.7.1 nativo do Linux** controlado por agentes de IA (Claude Code,
Codex, qualquer coisa que rode um comando), em **qualquer programa** em execução —
nativo, Wine ou Steam/Proton. Começou no Windows (ponte por named pipe, ver
`legacy/windows/`) e foi concluída no Linux (CachyOS/Arch, KDE Wayland).

```
 agente ──ce──► TCP 127.0.0.1:52740 + token ──► autorun/ce_agent_bridge.lua ──► API CELua
   │          (reserva: caixa de correio em $XDG_RUNTIME_DIR/ce-agent-bridge)
   └──cemem──► /proc/PID/mem + numpy   (motor próprio, sem o CE)
```

## Instalar (idempotente)

```bash
bash install.sh           # pacotes, CE 7.7.1 (AUR cheatengine-bin), ptrace_scope=0,
                          # ponte no autorun, `ce`/`cemem` no PATH, registro da skill
bash install.sh --check   # só diagnostica
bash install.sh --uninstall
```

Registra a skill em `~/.claude/skills`, `$CLAUDE_CONFIG_DIR/skills`, `~/.agents/skills`
e `~/.codex/skills` (os que existirem). O agente carrega `SKILL.md` sozinho quando o
pedido fala em Cheat Engine, scan de memória, valores de jogo, ponteiros, AOB etc.

## Usar

```bash
ce up                         # abre o CE (ou --headless) e espera a ponte
ce ps hollow                  # acha o processo (nativo/Wine/Proton)
ce attach "hollow knight"
ce scan 100 && ce next 93     # first/next scan
ce write 0x55d0c0a1b2c4 999   # escrita transacional (ce undo --all)
ce freeze 0x55d0c0a1b2c4 999
ce watch 0x55d0c0a1b2c4       # que instruções escrevem aqui
ce aa apply cura.cea          # Auto Assembler (ce aa revert --all)
cemem ptrscan alvo 0x55d0c0a1b2c4   # cadeia de ponteiros estável
ce table save ~/jogo.CT
```

Tudo sai em JSON. Referência completa: `references/cli.md`. Receitas:
`references/workflows.md`. Modelos de AA testados: `references/auto-assembler.md`.

## O que foi verificado (2026-11-09, CE 7.7.1 Linux, alvo C de teste)

`python3 tests/test_e2e.py` — 17 passos, todos verdes, com o CE aberto ou fechado
(abre headless): lint da ponte com a Lua do CE · attach por nome · first/next scan ·
write + undo · cadeia de ponteiros · AOB · watch (acha `dano: sub [rdi],esi`) · AA
apply/revert · freeze por ponteiro (módulo com `-`) · .CT save/load · string · disasm/asm ·
cemem scan/next/ptrscan/aob/disasm/freeze · cleanup.

Também validados à mão: modo headless, transporte por caixa de correio, 3 `ce up`
simultâneos (um só CE), `ce down` com tabela modificada (backup + sem diálogo),
code cave com `alloc`+`jmp`, captura de ponteiro por injeção, scan de valor desconhecido,
alvo Wine (`ping.exe`: módulos PE, `MZ` em `ping.exe+0`, AOB).

Robustez (ponte 3.1): a v3.0 executava os métodos dentro de `synchronize()` e o CE
travou de forma intermitente esperando o scanner (diagnosticado com gdb). A 3.1 usa um
timer despachante e scans assíncronos: ~1.250 scans em estresse (conexão única e um
processo `ce` por comando) e 4 E2E completos sem nenhum travamento.

## Segurança

- A ponte só escuta em 127.0.0.1 e exige o token (0600). `eval` = Lua arbitrário.
- O CE 7.7.1 Linux traz um `server.lua` que abre **0.0.0.0:11211 sem senha** (Lua com
  `os.execute` na rede). O override `autorun/server.lua` o desliga.
- `ptrace_scope=0` deixa processos do mesmo usuário lerem a memória uns dos outros
  (o que o CE pede). Reverter: `bash install.sh --uninstall`.
- Não use em jogos online/anti-cheat.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `SKILL.md` | manual do agente (gatilhos, fluxo, regras de ouro, diagnóstico) |
| `autorun/ce_agent_bridge.lua` | ponte JSON-RPC (68 métodos, v3.1) que roda dentro do CE |
| `autorun/server.lua` | override que desliga o servidor Lua inseguro do CE |
| `scripts/ce.py` / `bin/ce` | CLI + biblioteca Python da ponte |
| `scripts/cemem.py` / `bin/cemem` | motor nativo sem CE (scan, ptrscan, freeze, aob, disasm/asm) |
| `scripts/lint_lua.py` | compila Lua com a `liblua53.so` do próprio CE |
| `scripts/inspect_lua_bytecode.py` | extrai constantes de bytecode Lua 5.3 (`string.dump`) |
| `tests/` | alvo C determinístico + teste ponta a ponta |
| `references/` | CLI, receitas, AA, protocolo, Linux/Proton, API CELua |
| `docs/` | pesquisas que originaram a skill |
| `legacy/windows/` | protótipo Windows (named pipe) e o que ele provou |

Licença: MIT.
