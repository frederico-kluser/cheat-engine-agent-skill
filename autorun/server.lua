--[[ server.lua (override do usuario) - desativa o "CELua server" do CE Linux

  O CE 7.7.1 para Linux traz autorun/server.lua, que abre 0.0.0.0:11211 SEM
  autenticacao e executa qualquer Lua recebido (Lua tem os.execute: e uma
  shell remota para quem estiver na mesma rede). Alem disso ele trava depois
  do primeiro comando de cada conexao (server.lua:143, concatena nil).

  O overlay do pacote AUR cheatengine-bin carrega ~/.local/share/cheatengine/
  autorun/<nome>.lua NO LUGAR do arquivo de mesmo nome do pacote, entao este
  arquivo (instalado por symlink pelo install.sh da skill) substitui o oficial.

  O mesmo poder (eval de Lua) continua disponivel, com seguranca, pela ponte
  ce_agent_bridge.lua: so 127.0.0.1 e com token.

  Para reativar o oficial (nao recomendado): remova o symlink
  ~/.local/share/cheatengine/autorun/server.lua e reinicie o CE.
]]
