---
name: cheat-engine-agent-skill
version: "3.1.0"
description: >-
  Controla o Cheat Engine 7.7.1 NATIVO do Linux (CachyOS/Arch) pelo terminal em QUALQUER
  programa que o usuário nomear — nativo, Wine ou Steam/Proton — através da ponte
  ce_agent_bridge.lua (TCP 127.0.0.1 + token) e do comando `ce`; inclui o motor reserva
  `cemem` (sem CE: /proc/PID/mem + numpy). Faz first/next scan (exato, desconhecido,
  aumentou/diminuiu, float/double/string/AOB), leitura/escrita transacional com undo,
  cadeias de ponteiros e pointer scan, freeze, tabela .CT, "o que escreve neste endereço"
  (breakpoint de dados), Auto Assembler com revert, disassembly/assemble, Mono/Unity e eval
  de Lua dentro do CE, com ou sem janela (headless). Use SEMPRE que o pedido mencionar Cheat
  Engine, cheatengine, "CE", trainer, cheat table/.CT, scan de memória, achar/editar/congelar
  valor (vida, ouro, munição, dinheiro, pontos), endereço/ponteiro/offset/pointer scan, AOB,
  "o que escreve nesse endereço", injeção/Auto Assembler, speedhack, scanmem/GameConqueror/
  PINCE, ou mexer na memória de um jogo/programa em execução no Linux.
license: MIT
compatibility: >-
  Linux x86-64 Arch/CachyOS; Cheat Engine 7.7.1 for Linux (AUR cheatengine-bin, Qt6);
  python3 + numpy/capstone/keystone; kernel.yama.ptrace_scope=0 (install.sh configura)
metadata:
  author: Frederico Kluser
  requires: ["python3", "cheatengine-bin"]
---

# cheat-engine-agent-skill — o Cheat Engine na mão do agente (Linux)

O Cheat Engine **tem build nativo para Linux** (7.7.1, Qt6, `/usr/lib/cheatengine`).
Esta skill põe uma **ponte JSON-RPC** dentro dele (`autorun/ce_agent_bridge.lua`) e
um CLI (`ce`) que o agente usa de fora. Tudo o que o CE faz pela GUI vira um comando
com saída **JSON**. Para quando o CE não estiver disponível existe o **`cemem`**,
motor nativo próprio que lê `/proc/PID/mem` (scan, ponteiros, pointer scan, freeze).

```
 agente ──ce (python)──► TCP 127.0.0.1:52740 + token ──► ce_agent_bridge.lua ──► API CELua
   │                    (reserva: $XDG_RUNTIME_DIR/ce-agent-bridge/mailbox)      (thread principal)
   └──cemem (python+numpy)──► /proc/PID/mem  (sem CE; ptrace_scope=0)
```

Já instalado nesta máquina (`bash install.sh` refaz tudo, idempotente). Comandos no
PATH: **`ce`**, **`cemem`**. Estado da ponte: `$XDG_RUNTIME_DIR/ce-agent-bridge/`.

## Quando usar / não usar

- **Use** para: achar e mudar valores em programas/jogos em execução, congelar, montar
  tabela .CT, descobrir quem escreve num endereço, patch/injeção (AA), ponteiros estáveis,
  inspecionar memória/disassembly de qualquer processo do usuário (nativo, Wine, Proton).
- **Não use** em jogos **online/multiplayer** ou com anti-cheat (EAC, BattlEye, Vanguard…):
  dá ban e viola os termos — avise o usuário e só prossiga em modo offline/single-player.
  Não mexa em processos de outros usuários/sistema sem pedido explícito.

## Pré-voo (sempre, ~1 s)

```bash
ce up                 # abre o CE se preciso e espera a ponte (já aberto = no-op)
ce up --headless      # sem janela (QT_QPA_PLATFORM=offscreen) — bom p/ automação
ce doctor             # se algo falhar: diagnóstico + comando exato de correção
```

## Fluxo padrão (o "tutorial" do Cheat Engine, em comandos)

```bash
ce ps hollow                      # 1. achar o processo (nome/exe/cmdline; mostra wine/proton/steam_appid)
ce attach "hollow knight"         # 2. abrir no CE (pid ou nome; escolhe o melhor candidato)
ce scan 100                       # 3. first scan (dword exato). Valor desconhecido: ce scan
#   ...o valor muda no jogo...
ce next 93                        # 4. next scan com o valor novo (ou: increased|decreased|changed|unchanged)
ce next 87                        #    repita até sobrar 1–5 endereços
ce write 0x5601B7A02030 999       # 5. testar escrevendo (transacional: ce undo --all)
ce freeze 0x5601B7A02030 999      # 6. congelar (entrada ativa na tabela do CE; ce unfreeze <id>)
cemem ptrscan alvo 0x5601B7A02030 # 7. cadeia estável p/ sobreviver a reinício (ver abaixo)
ce watch 0x5601B7A02030           # 8. que instruções escrevem nesse endereço? (5 s, não pausa o jogo)
ce aa apply cura.cea              # 9. patch/injeção Auto Assembler (ce aa revert --all desfaz)
ce table save ~/jogo.CT           # 10. salvar a tabela (.CT abre no CE GUI / Windows)
ce cleanup                        # fim: reverte AA, para watches, libera scans e entradas do agente
ce detach                         # solta o processo (ce down SÓ se foi você que abriu o CE)
```

**Valide sempre pelo efeito no programa** (o valor na tela mudou?), não só pelo `after`.

## Comandos `ce` (saída JSON; erro → `{"ok": false, "error": ...}` e código 1)

| Área | Comandos |
|---|---|
| Ciclo | `up [--headless]` · `down` · `status` · `doctor` · `help [metodo]` · `show` · `hide` |
| Processo | `ps [filtro]` · `attach <pid\|nome>` · `detach` · `info` · `modules [filtro]` · `regions [filtro] [--writable]` · `resolve <simbolo>` · `pause` · `unpause` |
| Memória | `read <end> [-t tipo] [-n N] [--signed]` · `write <end> <valor> [-t tipo] [--hex]` · `undo [txn\|--all]` · `ptr <base> <off...> [-t tipo]` · `dump <end> [-s N]` · `aob "<padrão>" [-m mod] [--unique]` |
| Scanner | `scan [valor] [-t tipo] [--op exact\|between\|bigger\|smaller\|unknown] [--value2 V] [-m mod] [--unaligned]` · `next <valor\|increased\|decreased\|changed\|unchanged\|bigger N…> [--by]` · `results [--limit] [--offset] [--names]` · `scans` · `scan-free [--all]` |
| Tabela | `list` · `add <end> [-t] [-d desc] [--offsets o1 o2] [--value V] [--freeze]` · `freeze <end> [valor] [--offsets…]` · `unfreeze <id> [--delete]` · `set <id> --value V` · `rm <id>\|--agent` · `add-script <arq.cea> -d desc [--enable]` · `table save\|load <arq.CT> [--merge]` |
| Código | `disasm <end> [-n N]` · `asm "<instr>" [--at end]` · `aa check\|apply <arq\|-\|texto>` · `aa revert <id>\|--all` · `aa list` · `watch <end> [--kind write\|access\|execute] [--seconds S]` |
| Extras | `mono` (Unity/Mono) · `speed <x> [--force]` · `lua '<código>'` / `lua -f arq.lua` · `call <metodo> '<json>'` · `cleanup` |

Tipos: `byte word dword qword float double pointer string widestring bytes all`
(aliases `int`, `int32`, `i16`, `f32`…). Endereços são **hex como no CE** (`7ffd10`
= `0x7ffd10`), aceitam `modulo+offset`, símbolos e a notação `[[jogo+10]+8]+4`.
Valores são decimais (`--hex` para hex). Mais: `references/cli.md`.

## `cemem` — motor nativo (sem CE)

Use quando o CE não puder abrir, para conferir algo de fora do CE, ou para o
**pointer scan** (o CE GUI tem, mas a API Lua não). Sessões em `~/.cache/ce-agent/cemem`.

```bash
cemem scan <alvo> 100 [-t dword] [-s sessao]   cemem next 93 | decreased | changed
cemem read|write <alvo> <end> [valor] [-t tipo] cemem ptr <alvo> "jogo+4058" 0 0
cemem ptrscan <alvo> <end> [--depth 3] [--max-offset 1000] [--main-only] [-m modulo]
cemem aob <alvo> "48 8B ?? 05" [-m mod]        cemem freeze <alvo> <end> 999 --background
cemem modules|maps <alvo> [filtro]              cemem unfreeze --all · cemem freezes
cemem disasm <alvo> <end> [-n 20] (capstone)    cemem asm "mov eax,1; ret" (keystone)
```

## Regras de ouro (verificadas no CE 7.7.1 Linux, 2026-11)

1. **O valor anda enquanto você escaneia.** Leia o valor e dispare o `scan`/`next`
   imediatamente; se o first scan der 0, o valor já mudou — repita ou use `ce scan`
   (desconhecido) + `ce next decreased`.
2. **Tipo certo**: inteiros → `dword` (padrão); vida/energia com casas decimais →
   `float` (às vezes `double`). Na dúvida: `-t all`.
3. **Endereço de heap muda a cada execução.** Para algo reutilizável: `cemem ptrscan`
   → teste cada caminho com `ce ptr`/`cemem ptr` **depois de reiniciar o programa**
   → grave com `ce add "jogo"+4058 --offsets 0 0` (o CE guarda como `"modulo"+offset`).
4. **Símbolos ELF no Linux**: o CE *mostra* `alvo.dano`, mas o parser de AA/tabela só
   aceita `dano` ou `"alvo"+1189`. A ponte traduz `modulo.simbolo` em `read/write/ptr/
   add/freeze`; **dentro de scripts AA escreva `dano:` ou `"alvo"+1189:`**. Nome de
   módulo com `-` ou espaço vai entre aspas: `"tutorial-x86_64"+2A0F0`.
5. **`ce watch`** coloca breakpoint de hardware, coleta quem escreve/acessa e
   **continua o processo** (não trava o jogo). Para dados, a instrução culpada é a
   anterior ao RIP — a ponte já corrige isso.
6. **AA é transacional**: `ce aa apply` guarda o `disableInfo`; `ce aa revert --all`
   roda o `[DISABLE]`. Sempre escreva `[ENABLE]` **e** `[DISABLE]` (o check do 7.7
   só valida scripts com as duas seções). Modelos: `references/auto-assembler.md`.
7. **Escrita é transacional**: `ce write` guarda os bytes originais (`ce undo --all`).
   Strings são gravadas com terminador `\0` (desligue com `ce call write '{"terminate":false,...}'`).
8. **Speedhack em alvo Linux nativo derrubou o CE 7.7.1** em teste real: a ponte
   recusa sem `--force`. Em alvo Wine/Proton é permitido (injetou e reportou a
   velocidade sem derrubar o CE; confira o efeito no jogo).
9. **Scans são assíncronos na ponte** (o `ce scan/next/aob` espera sozinho; via
   `ce call scan_first` consulte `scan_status` até `done`). A thread principal do CE
   nunca fica presa esperando o scanner — isso travava o CE 7.7.1. Se mesmo assim uma
   chamada estourar o prazo: `ce down && ce up` (o `ce down` salva a tabela antes).
10. **Não afete o resto do computador.** Encerre só o que você abriu: se `ce up`
    respondeu `already_running` (o CE já estava aberto pelo usuário), termine com
    `ce cleanup` + `ce detach` — **nunca** `ce down`. Nada de `pkill`/`killall` por nome,
    restart de serviço ou de sessão; o jogo/programa alvo continua aberto.
11. **Segurança**: o `server.lua` oficial do CE Linux abre `0.0.0.0:11211` **sem senha**
    (Lua com `os.execute` = shell remota na rede). O install.sh o substitui por um
    override vazio; a ponte só escuta em 127.0.0.1 e exige o token (arquivo 0600).

## Wine / Proton (Steam)

- Jogo Proton **é um processo Linux**: `ce attach <nome.exe>` funciona direto no CE
  nativo (módulos aparecem como `Game.exe`, `UnityPlayer.dll`…). `ce ps` mostra
  `wine: true`, `steam_appid` e o prefixo.
- Em processos Wine o `ce ps` filtra os auxiliares (`wineserver`, `services.exe`,
  `explorer.exe`…) e prefere o de maior RSS — confira `other_candidates`.
- Unity/Mono: `ce mono` injeta o MonoDataCollector; depois `ce lua` com `mono_*`
  (`references/workflows.md`). IL2CPP: use AOB/ponteiros.
- O CE Linux sugere abrir o **CE de Windows dentro do Proton** (Protonlauncher.lua) —
  só necessário para recursos Windows-only (DBK, VEH). Ver `references/linux-proton.md`.

## Diagnóstico rápido

| Sintoma | Causa provável → correção |
|---|---|
| `ponte não encontrada` / `CE que já fechou` | CE fechado → `ce up` |
| `o CE está aberto mas a ponte não responde` | bridge fora do autorun → `bash install.sh`; ou CE em diálogo modal → `ce show` |
| `attach` ok mas `readable: false` / leitura falha | `ptrace_scope` ≠ 0 → `ce doctor` mostra o fix |
| first scan = 0 | valor mudou / tipo errado / float → repita, `-t float`, `-t all` |
| `simbolo nao resolvido` | use `modulo+offset` hex, ou símbolo sem módulo (`dano`) |
| `o CE não respondeu em Ns` | CE travado/ocupado → `ce down && ce up` (scan enorme: `-m modulo` ou `--timeout 600`) |
| `error: thread N:Duplicate ID ...` | erro interno do scanner do CE 7.7.1 → o `ce scan` já repete 1x; se persistir, `ce down && ce up` |
| CE fechou sozinho | speedhack/injeção em alvo nativo; reabra (`ce up`) e `ce attach` de novo |

## Referências (carregue sob demanda)

- `references/cli.md` — todos os comandos `ce`/`cemem` com exemplos e saídas.
- `references/workflows.md` — receitas: vida/ouro, valor desconhecido, float, ponteiros,
  "o que escreve" → injeção, freeze, trainer .CT, Unity/Mono, Proton.
- `references/auto-assembler.md` — sintaxe AA e modelos x86-64 Linux (patch, code cave, NOP).
- `references/bridge-protocol.md` — protocolo, os 60+ métodos da ponte, segurança, como estender.
- `references/linux-proton.md` — ptrace, root, hotkeys, Wayland/headless, Proton,
  CE Windows no Proton, ceserver, peculiaridades verificadas do 7.7.1.
- `references/celua-scan.md`, `references/celua-addresslist.md` — API CELua de scan e
  address list (transcrição comentada do `celua.txt`; o original fica em
  `/usr/lib/cheatengine/celua.txt`).
- `docs/pesquisa-linux-2026-11.md` — pesquisa profunda verificada (CE 7.7.1 Linux, Proton,
  protonhax/protontricks, ceserver, Yama) + respostas dos testes locais.
- `docs/pesquisa-ecossistema-agentes-mcp.md` — o estudo original (Windows): AITools, MCPs do CE.

## Manutenção

- Teste ponta a ponta (compila um alvo C, valida scan/next/write/ptr/AOB/watch/AA/
  freeze/.CT/cemem): `python3 tests/test_e2e.py` (≈40 s, abre o CE headless se preciso).
- Lint da ponte com a Lua do próprio CE: `python3 scripts/lint_lua.py autorun/*.lua`.
- Editou a ponte? `ce lua 'dofile(ce_bridge.path)'` recarrega sem reiniciar o CE —
  mas **zera o estado da ponte** (scans, AA aplicados, entradas do agente): rode
  `ce cleanup` antes.
- Atualizar o CE: `paru -Syu cheatengine-bin` (o overlay em `~/.local/share/cheatengine`
  mantém a ponte). Desinstalar a integração: `bash install.sh --uninstall`.
