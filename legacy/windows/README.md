# legacy/windows — protótipo da ponte no CE 7.7 de Windows (nov/2026)

Arquivos do começo do projeto, no Windows, guardados para referência histórica.
**Não são usados no Linux.** A ponte atual (v3) está em `autorun/ce_agent_bridge.lua`
e o cliente em `scripts/ce.py`.

O que eles provaram (e que moldou a v3):

- No CE 7.7 de Windows, `writeString/writeBytes` em `TPipeConnection` e em sockets
  devolviam sucesso e transferiam **0 bytes**; ler de um named pipe funcionava.
  Por isso a v2 usava pedido por named pipe e resposta por arquivo — de onde vem a
  "caixa de correio" que a v3 mantém como transporte reserva.
- `TPipeConnection.ReadBytes` só retorna com o tamanho exato; ler byte a byte até
  um delimitador (0x1E) é o caminho estável.
- `autoAssembleCheck` só valida scripts com `[ENABLE]` e `[DISABLE]`.

No CE 7.7.1 **Linux** a escrita em socket funciona (medido), então a v3 usa TCP
127.0.0.1 + token como principal.

| Arquivo | O que era |
|---|---|
| `ce_bridge.py` | cliente v2 (named pipe Win32 via ctypes + resposta em arquivo) |
| `test_pipe_client.py`, `test_file_channel.py`, `tcp_probe_server.py` | sondas de transporte |
| `test_bridge_live.py`, `test_aa_contract.py` | testes ao vivo da v2 |
| `test_autorun.py`, `lua_stubs.lua` | execução offline da ponte v2 com stubs da API |
| `probe_aa.lua`, `probe_sym.lua` | sondas de Auto Assembler e símbolos |
