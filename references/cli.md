# Referência dos comandos `ce` e `cemem`

Ambos imprimem **JSON** no stdout. Em erro: `{"ok": false, "error": "..."}` e código 1.
Endereços são **hex** como no Cheat Engine (`7ffd10` = `0x7ffd10`); aceitam
`modulo+offset`, `"modulo com-hifen"+offset`, `modulo.simbolo`, símbolos do CE e a
notação de ponteiro `[[jogo+10]+8]+4`. Valores numéricos são decimais (`--hex` muda).

Tipos aceitos (aliases entre parênteses): `byte` (u8, int8), `word` (2, int16, short),
`dword` (4, int, integer, int32 — **padrão**), `qword` (8, int64, long), `float` (single,
f32), `double` (f64), `pointer` (ptr — 4/8 bytes conforme o alvo), `string`,
`widestring` (unicode, utf16), `bytes` (aob), e só no scan: `all` (todos os numéricos).

---

## `ce` — Cheat Engine via ponte

Opções globais: `--timeout S` (padrão 120 s por chamada e por scan), `--transport tcp|mailbox`.
Se o CE travar, a chamada falha nesse prazo com a dica `ce down && ce up`.

### Ciclo de vida

| Comando | O que faz |
|---|---|
| `ce up [--headless] [--wait S]` | Abre o CE se não estiver aberto e espera a ponte (`launched`, `seconds`, `port`). Sem `WAYLAND_DISPLAY/DISPLAY` vira headless sozinho. |
| `ce down` | Fecha o CE (pela ponte; força SIGTERM após 10 s). |
| `ce status` | `ce_running` (PIDs), dados da ponte e processo anexado. |
| `ce doctor` | Checa instalação, ptrace, autorun, porta 11211, ponte (TCP e caixa de correio), numpy/capstone/keystone. Lista `problems` e `fixes` (comandos prontos). |
| `ce help [metodo]` | Métodos da ponte com documentação curta. |
| `ce show` / `ce hide` | Mostra/esconde as janelas do CE (a ponte segue funcionando). |

### Processos

```bash
ce ps                 # processos do usuário (pid, name, exe, rss_mb, wine, steam_appid, prefix, cmdline)
ce ps proton --all    # filtra por texto em nome/exe/cmdline; --all inclui outros usuários
ce attach 12345       # por PID
ce attach "Hollow Knight"   # por nome: exato > parcial; ignora helpers do Wine; maior RSS vence
ce info               # pid, name, main_module, is64bit, pointer_size, debugging
ce modules [filtro]   # name, base, end, size, path
ce regions heap --writable --limit 50   # mapa de memória (linha do /proc/PID/maps em 'extra')
ce resolve "jogo.exe+1F00"              # endereço, nome simbólico, módulo e offset
ce pause / ce unpause
```

`attach` devolve `readable: true` quando consegue ler a memória de fato (prova de
ptrace ok) e `other_candidates` quando o nome bate em mais de um processo.

### Memória

```bash
ce read 7ffd1234                    # dword
ce read jogo+4058 -t qword
ce read 55d0c0a1b2c4 -t float -n 4  # 4 floats seguidos -> "values"
ce read 55d0c0a1b2c4 -t string --maxlen 64
ce read 55d0c0a1b2c4 -t bytes -n 32 # hex
ce write 55d0c0a1b2c4 999           # -> before/after/value/changed/txn
ce write 55d0c0a1b2c4 3.5 -t float
ce write 55d0c0a1b2c4 "Novo nome" -t string     # grava com \0 no fim
ce write 55d0c0a1b2c4 "90 90 90" -t bytes
ce undo --all                       # desfaz todas as escritas (ou: ce undo w5)
ce ptr jogo+4058 0 18 10 -t dword   # [[[jogo+4058]+0]+18]+10 -> chain + address + value
ce dump 55d0c0a1b2c0 -s 64          # hexdump com ASCII
ce aob "48 8B 05 ?? ?? ?? ?? 89" -m jogo     # todos os resultados no módulo
ce aob "DE AD BE EF" --unique                 # primeiro resultado (+ "warning" se não for único)
```

### Scanner (mesma semântica do CE)

```bash
ce scan 100                         # first scan exato (dword, alinhado, +W*X*C)
ce scan 50.5 -t float               # float "arredondado" como o CE (rounded)
ce scan -t float                    # valor desconhecido
ce scan 10 --op between --value2 20
ce scan 100 -m jogo                 # só dentro do módulo
ce scan "Heroi" -t string           # texto (widestring p/ UTF-16)
ce scan "48 8B ?? 05" -t bytes      # AOB como scan (permite next)
ce next 93                          # exato
ce next decreased                   # increased | decreased | changed | unchanged
ce next decreased 7                 # diminuiu EXATAMENTE 7 (decreased_by)
ce next bigger 1000                 # bigger | smaller | between (--value2)
ce next increased 10 --percentage    # subiu 10% (vale p/ between/increased/decreased)
ce next unchanged --compare-to FIRST  # compara com o first scan (ou um nome salvo)
ce results --limit 50 --offset 0 --names
ce scans                            # scans abertos (id, done, found)
ce scan-cancel                      # interrompe o scan em andamento
ce scan-free --all
```

Saída do `scan`/`next`: `scan_id`, `found`, `results` (prévia, `--preview N`),
`truncated`, `seconds`. O `next` usa o último scan (`--scan s3` para outro). Um novo
`ce scan` **descarta os scans anteriores** (como o "New Scan" do CE); `--keep` mantém.
Se o scanner do CE devolver erro interno com 0 resultados, o `ce scan` repete uma vez
sozinho (campo `retried_after`).

### Tabela de endereços (o "cheat table" do CE)

```bash
ce add 55d0c0a1b2c4 -d "Vida"                    # entrada simples
ce add jogo+4058 --offsets 0 18 -t float -d "Energia"     # ponteiro (offsets na ordem natural)
ce add '"meu-jogo"+4058' -d "X"                         # módulo com hífen: aspas DENTRO do argumento
ce freeze jogo.g_mundo 500 --offsets 0 0 -d "Vida infinita"
ce list                                          # id, description, address, offsets, value, active
ce set 3 --value 999 ; ce set 3 --freeze ; ce set 3 --unfreeze
ce unfreeze 3 [--delete]
ce rm 3 ; ce rm --agent                          # remove só as criadas pelo agente
ce add-script cura.cea -d "Cura infinita"        # script AA como cheat clicável (--enable ativa)
ce table save ~/Jogos/jogo.CT
ce table load ~/Jogos/jogo.CT [--merge]          # sem o diálogo "executar Lua da tabela?"
```

Entradas de módulo são gravadas como `"modulo"+offset` (sobrevivem a ASLR).

### Código

```bash
ce disasm dano -n 10                # address, name, bytes, opcode, size
ce asm "mov eax,[rbx+10]" --at 55d0c0a1b000
ce aa check cura.cea                # enable_ok/disable_ok + erros
ce aa apply cura.cea                # aa_id + allocs/símbolos
ce aa apply - <<'EOF'               # script pelo stdin
[ENABLE]
dano:
  nop 2
[DISABLE]
dano:
  db 29 37
EOF
ce aa list ; ce aa revert aa7 ; ce aa revert --all
ce watch 55d0c0a1b2c4               # quem ESCREVE (5 s): instruções, contagem, registradores
ce watch 55d0c0a1b2c4 --kind access --seconds 10 --size 8
ce watch dano --kind execute        # quantas vezes a função roda
```

### Extras

```bash
ce mono                             # MonoDataCollector (Unity/Mono)
ce speed 2.0                        # speedhack (alvo Wine/Proton); nativo exige --force
ce lua 'return getOpenedProcessID()'        # expressão ou bloco; print() é capturado
ce lua -f script.lua
ce call scan_first '{"type":"dword","value":"100","module":"jogo"}'   # qualquer método
ce cleanup [--rollback-writes] [--keep-records]
```

---

## `cemem` — motor nativo (sem Cheat Engine)

`<alvo>` = PID ou nome (mesma heurística do `ce attach`). Requer `ptrace_scope=0`.

```bash
cemem ps [filtro]
cemem modules <alvo> [filtro]           # ELF e PE (Wine/Proton) com base e tamanho
cemem maps <alvo> [filtro] [--writable]
cemem read <alvo> jogo+4058 -t qword
cemem write <alvo> 0x55d0c0a1b2c4 999 [-t tipo] [--no-terminator]
cemem scan <alvo> 100 [-t dword] [-s sessao] [-m modulo] [--unaligned] [--op between --value2 N]
cemem scan <alvo> -t float              # desconhecido: snapshot em ~/.cache/ce-agent/cemem
cemem next 93 | decreased | increased 5 | changed | unchanged [-s sessao]
cemem results [-s sessao] [--refresh] [--limit 100]
cemem ptr <alvo> jogo+4058 0 18 -t float
cemem ptrscan <alvo> 0x55d0c0a1b2c4 [--depth 3] [--max-offset 1000] [--main-only] [-m jogo] [--limit 50]
cemem aob <alvo> "48 8B ?? 05" [-m modulo] [--all-regions]
cemem dump <alvo> 0x55d0c0a1b2c0 -s 128
cemem freeze <alvo> jogo+4058 999 --offsets 0 0 --background   # -> freeze_id
cemem freezes ; cemem unfreeze f12345 ; cemem unfreeze --all
cemem disasm <alvo> 0x55d0c0a1b189 -n 10 [--bits 32]
cemem asm "add dword ptr [rdi], esi; ret" [--at 0x...] [--bits 32]
```

`ptrscan` monta um mapa reverso de ponteiros (valores alinhados que apontam para
memória legível), faz BFS do endereço-alvo até módulos estáticos e **revalida** cada
caminho. Ordem: módulos do próprio programa → menos níveis → offsets menores.
`ce_address` já vem no formato do CE (`"jogo"+4058`). Confirme reiniciando o alvo.

## scanmem (plano C, já instalado)

```bash
scanmem -p <PID> -c "100;list;exit"      # uma passada; cada execução é sessão nova
```
Interativo (`scanmem -p PID`): digite o valor, depois o novo valor, `list`, `set 999`.
