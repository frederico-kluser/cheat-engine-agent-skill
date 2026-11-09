# Protocolo da ponte `ce_agent_bridge.lua` (ce-agent-bridge/3)

A ponte roda **dentro** do Cheat Engine (autorun) e expõe a API CELua como
métodos JSON. O `ce` é só um cliente; qualquer linguagem fala com ela.

## Onde ela vive

| Item | Caminho |
|---|---|
| Código | `autorun/ce_agent_bridge.lua` (symlink `~/.local/share/cheatengine/autorun/00_ce_agent_bridge.lua`; o `00_` a faz carregar antes dos scripts do CE) |
| Estado | `$XDG_RUNTIME_DIR/ce-agent-bridge/` (0700) — muda com `CE_BRIDGE_DIR` |
| `bridge.json` | `{bridge, protocol, ce, ce_pid, host, port, mailbox, token_file, started}` (0600) |
| `token` | 48 hex de `/dev/urandom`, reaproveitado entre execuções (0600) |
| `bridge.log` | início/fim dos transportes e falhas |
| `ce.log` | stdout/stderr do CE quando aberto pelo `ce up` |
| `mailbox/` | caixa de correio (transporte reserva) |

Variáveis lidas pela ponte: `CE_BRIDGE_DIR`, `CE_BRIDGE_PORT` (padrão 52740; tenta
+0..+9), `CE_BRIDGE_TCP=0` / `CE_BRIDGE_MAILBOX=0` (desliga um transporte),
`CE_BRIDGE_LOG`.

## Transporte 1 — TCP 127.0.0.1 (principal, ~1 ms por chamada)

- `createSocketServer(porta, true)` → só loopback. (O `celua.txt` 7.7.1 chama de
  `createServerSocket`, mas a função real é `createSocketServer`.)
- Quadro = JSON UTF-8 + byte `0x1E` (ASCII RS), nos dois sentidos; várias chamadas por
  conexão.
- Pedido: `{"id": 1, "token": "<conteúdo do arquivo token>", "method": "read", "params": {...}}`
- Resposta: `{"id": 1, "ms": 0, "result": {...}}` ou `{"id": 1, "error": {"code": -32000, "message": "..."}}`
  (`-32700` JSON inválido, `-32001` token errado, `-32600` pedido > 16 MB).
- Cada conexão roda numa thread do CE que só **enfileira** o pedido; um **timer
  despachante** (5 ms) da thread principal executa o método num contexto normal (como
  um script de tabela) e devolve a resposta à thread da conexão. A v3.0 executava via
  `synchronize()`: esperar o scanner do CE lá dentro travou o CE de forma intermitente
  (gdb: thread principal em `pthread_cond_wait`, ~33 threads "Memscan TScanCo" presas).

## Scans são assíncronos

`scan_first`, `scan_next` e `aob_scan` só **disparam** o scan e voltam na hora
(`{"scan_id": "s3", "done": false, "running": true}`). Consulte `scan_status`
(`{"scan_id": "s3", "preview": 20}`) até `done: true` — aí vêm `found`, `results` (prévia),
`seconds` e, se o CE reclamar, `error`. `scan_cancel` interrompe; `scan_results` lê mais
resultados; `scan_free` libera. O `ce scan/next/aob` faz esse ciclo sozinho (polling de
10→250 ms). A thread principal nunca fica esperando o scanner.

```bash
TOKEN=$(cat $XDG_RUNTIME_DIR/ce-agent-bridge/token)
printf '{"id":1,"token":"%s","method":"ping"}\x1e' "$TOKEN" | nc -q1 127.0.0.1 52740
```

```python
import json, os, socket
d = os.path.join(os.environ["XDG_RUNTIME_DIR"], "ce-agent-bridge")
tok = open(f"{d}/token").read().strip()
port = json.load(open(f"{d}/bridge.json"))["port"]
s = socket.create_connection(("127.0.0.1", port))
s.sendall(json.dumps({"id": 1, "token": tok, "method": "info"}).encode() + b"\x1e")
buf = b""
while b"\x1e" not in buf:
    buf += s.recv(65536)
print(json.loads(buf.split(b"\x1e")[0]))
```

Ou, em Python, a biblioteca pronta: `sys.path.insert(0, "<skill>/scripts"); from ce import Bridge`
→ `Bridge().call("scan_first", {"value": "100"})`.

## Transporte 2 — caixa de correio (reserva, sem rede)

1. grave `mailbox/.req_<id>.tmp` e renomeie para `mailbox/req_<id>.json`
   (`{"id": ..., "method": ..., "params": ...}` — sem token: a pasta é 0700);
2. um timer do CE (20 ms, thread principal) lê, apaga e processa;
3. a resposta aparece atomicamente em `mailbox/resp_<id>.json` — leia e apague.

`ce --transport mailbox <cmd>` força este caminho. Foi o único que funcionou no CE 7.7
de Windows (lá a escrita em pipe/socket transferia 0 bytes).

## Segurança

- Só loopback + token por pedido; arquivos 0600 numa pasta 0700 do usuário.
- `eval` executa Lua arbitrário (e o Lua do CE tem `os.execute`): quem tem o token
  tem o seu usuário. Não exponha a porta (nada de túnel/proxy para ela).
- O `server.lua` oficial do CE Linux (0.0.0.0:11211, sem senha) é neutralizado por
  `autorun/server.lua` (override vazio). `ce doctor` alerta se 11211 estiver aberta.

## Estender

```lua
def("meu_metodo", "o que faz. params: x, y?", function(p)
  requireProcess()                 -- erro amigável se nada estiver anexado
  local a = addr(p.x, "x")         -- resolve número/hex/simbolo/modulo+off
  return { address = hex(a), valor = readInteger(a) }   -- vira JSON
end)
```
Erros: `fail("mensagem")`. Recarregar sem reiniciar o CE: `ce lua 'dofile(ce_bridge.path)'`
(a instância antiga é derrubada antes; o estado — scans, AA aplicados com seu `disableInfo`,
entradas do agente — é perdido: rode `ce cleanup` antes de recarregar).
Lint com a Lua do CE: `python3 scripts/lint_lua.py autorun/*.lua`. Teste: `python3 tests/test_e2e.py`.

## Métodos (`ce help` / `ce help <metodo>`)

Endereços nos parâmetros: número, `"0x…"`, hex puro, `modulo+hex`, `modulo.simbolo`,
símbolos e notação de ponteiro do CE. Endereços nas respostas: string `"0x…"`.

| Método | Documentação |
|---|---|
| `aa_apply` | executa [ENABLE] e guarda disableInfo p/ reverter. params: script, target_self? |
| `aa_check` | valida script Auto Assembler. params: script, target_self? |
| `aa_list` | scripts AA aplicados |
| `aa_revert` | executa [DISABLE] de um script aplicado. params: aa_id |
| `aa_revert_all` | reverte todos os scripts AA aplicados |
| `alloc` | aloca memoria no alvo. params: size, near? |
| `aob_scan` | DISPARA busca de padrao de bytes ('48 8B ?? 05'; assincrono, depois scan_status). params: pattern, module?, protection?='*W*X*C' |
| `assemble` | monta 1 instrucao. params: line, address? |
| `attach` | abre um processo. params: pid \| name (exato > parcial; mais novo vence) |
| `breakpoints` | lista breakpoints ativos |
| `ce_close` | fecha o Cheat Engine sem dialogo 'salvar tabela?' (salva backup .CT antes). params: backup?=true |
| `cleanup` | desfaz o estado do agente. params: revert_aa?=true, rollback_writes?=false, records?=true |
| `dealloc` | libera memoria alocada. params: address |
| `debug_start` | anexa o debugger. params: interface? (0 padrao) |
| `detach` | fecha o processo aberto |
| `disassemble` | desmonta N instrucoes. params: address, count?=10 (max 500) |
| `dump` | hexdump. params: address, size?=256 (max 64 KiB) |
| `eval` | executa Lua no CE (thread principal). params: code \| expr. Captura print() |
| `events` | eventos assincronos. params: since?=0 |
| `freeze` | congela valor (cria entrada ativa). params: address\|base, offsets[]?, type?, value?, description? |
| `gui_hide` | esconde as janelas do CE (continua funcionando) |
| `gui_show` | mostra a janela principal do CE |
| `help` | lista metodos e documentacao. params: method? |
| `hotkey_add` | hotkey global que roda Lua. params: keys (ex 'VK_F5' ou {VK_CONTROL,VK_F5}), action (Lua) |
| `hotkey_remove` | remove hotkey. params: hotkey_id |
| `info` | processo aberto: pid, nome, 64 bits, debugger |
| `instruction_size` | tamanho da instrucao. params: address |
| `modules` | modulos do alvo. params: filter?, limit? |
| `mono_launch` | injeta o MonoDataCollector (Unity/Mono). Depois use eval com mono_* |
| `pause` | pausa o alvo |
| `ping` | teste de vida: {pong, versoes, pid do CE} |
| `pointer` | segue cadeia [[base]+o1]+o2... params: base, offsets[], type?, signed? |
| `process_list` | processos visiveis ao CE. params: filter?, limit? |
| `read` | le memoria. params: address, type?=dword, count? (array), signed?, maxlen?, size? (bytes) |
| `read_many` | le varios enderecos. params: addresses[], type? |
| `record_add` | adiciona entrada na tabela. params: address (ou base), offsets[]?, type?, description?, value?, freeze?, hex?, signed?, length? (string/bytes) |
| `record_add_script` | cria entrada de script Auto Assembler na tabela (vira 'cheat' clicavel no CE). params: script, description?, enable? |
| `record_delete` | remove entrada(s). params: id \| description \| agent_only=true (as criadas pelo agente) |
| `records` | lista a tabela de enderecos. params: filter?, limit? |
| `record_set` | altera entrada. params: id\|description, value?, freeze? (bool), description_new? |
| `regions` | mapa de memoria. params: filter? (texto da linha/arquivo), writable?, executable?, limit? |
| `resolve` | simbolo/expressao -> endereco. params: symbol |
| `scan_cancel` | interrompe um scan em andamento. params: scan_id? |
| `scan_create` | alias de scan_first |
| `scan_first` | DISPARA um first scan (assincrono; depois scan_status). params: value?, value2?, type?=dword, option? (exact\|between\|bigger\|smaller\|unknown), rounding?, module?\|start?/stop?, protection?, aligned?=true, hex?, unicode?, case? |
| `scan_free` | libera scan(s) (interrompe se estiver rodando). params: scan_id? \| all=true |
| `scan_list` | scans abertos |
| `scan_new` | alias de scan_first |
| `scan_next` | DISPARA um next scan (assincrono; depois scan_status). params: scan_id?=ultimo, option? (exact\|between\|bigger\|smaller\|increased\|increased_by\|decreased\|decreased_by\|changed\|unchanged), value?, value2?, percentage?, compare_to? ('FIRST' ou salvo) |
| `scan_refine` | alias de scan_next |
| `scan_results` | resultados (scan concluido). params: scan_id?, offset?=0, limit?=100, values?=true, names? |
| `scan_save` | salva resultados p/ comparar depois (compare_to). params: scan_id?, name |
| `scan_status` | estado de um scan assincrono; com done=true traz found e previa. params: scan_id?, preview?=20, names? |
| `speedhack` | muda a velocidade do alvo (injeta o speedhack). params: speed (1.0 normal), force? (obrigatorio em alvo Linux nativo: no CE 7.7.1 isso ja derrubou o CE) |
| `symbol_register` | registra simbolo. params: name, address, dont_save? |
| `symbol_unregister` | remove simbolo. params: name |
| `table_load` | carrega .CT/.CETRAINER sem dialogo de Lua. params: path, merge?=false |
| `table_save` | salva a tabela (.CT). params: path |
| `timer_add` | roda Lua periodicamente no CE. params: action (Lua), interval?=1000 ms |
| `timer_remove` | remove timer. params: timer_id |
| `txn_list` | transacoes de escrita guardadas |
| `txn_rollback` | desfaz escritas. params: txn \| all=true |
| `unfreeze` | descongela. params: id\|description, delete?=false |
| `unpause` | retoma o alvo |
| `watch_poll` | hits coletados. params: watch_id |
| `watch_start` | breakpoint de dados que COLETA quem escreve/acessa (nao para o alvo). params: address, size?=4, kind?=write\|access\|execute, method?=debugreg |
| `watch_stop` | remove o breakpoint e devolve os hits. params: watch_id \| all=true |
| `write` | escreve memoria (guarda original p/ rollback). params: address, type?, value \| bytes, txn?, transactional?=true, terminate?=true (strings) |
