# Cheat Engine no Linux: permissões, Proton/Wine, ceserver e peculiaridades do 7.7.1

## 1. O que está instalado

| Peça | Onde | Para quê |
|---|---|---|
| Cheat Engine 7.7.1 **para Linux** (Qt6) | `/usr/lib/cheatengine` (AUR `cheatengine-bin`, zip oficial `CheatEngineLinux771.zip`, sha256 `0fb0d904…f177`) | GUI + Lua + scanner + debugger nativos |
| Lançador | `/usr/bin/cheatengine` | roda o CE com CWD em `~/.local/share/cheatengine` (overlay por usuário) |
| Overlay | `~/.local/share/cheatengine/autorun/` | scripts do usuário; nome igual ao do pacote **substitui** o do pacote |
| Ponte da skill | `autorun/00_ce_agent_bridge.lua` → repo | JSON-RPC (TCP 127.0.0.1:52740 + token; caixa de correio) |
| Override de segurança | `autorun/server.lua` → repo | desliga o "CELua server" oficial (0.0.0.0:11211, sem senha) |
| `libceapi.so` | pacote | código do ceserver embutido (o CE Linux lê memória com `process_vm_readv/writev`) |
| `libceserver-extension_*.so` | pacote | injetada no alvo para alloc/loadModule/speedhack |
| `autorun/dlls/libMonoDataCollector-linux-x86_64.so` | pacote | Mono em jogos Unity nativos |
| `Extensions/AITools` | pacote | extensão oficial de IA do CE (diálogo interno + `aitools.lua`) |
| `autorun/Protonlauncher.lua`, `lua/wineOnLinuxPipe2Socket.lua` | pacote | integração com alvos Proton/Wine |

Linha do tempo: o CE **7.7** (29/05/2026) foi a primeira versão oficial com Linux; a **7.7.1**
é só Linux (zip com Last-Modified 16/08/2026). O GitHub oficial parou na 7.5 e não tem o
código da 7.7.x (nem o `Protonlauncher.lua`). O upstream já trocou o zip sem mudar o nome
(relatos de sha256 divergente no AUR em 26/06 e 02/07/2026): se o build do
`cheatengine-bin` falhar por checksum, é isso — aguarde o PKGBUILD ou use o fallback do
`install.sh` com `CE_ZIP_SHA256=skip`. Fontes: cheatengine.org/downloads.php,
aur.archlinux.org/packages/cheatengine-bin, gamingonlinux.com (12/06/2026); detalhes em
`docs/pesquisa-linux-2026-11.md`.

Atualizar: `paru -Syu cheatengine-bin`. A ponte vive no overlay; sobrevive a updates.

## 2. Permissão para ler memória (ptrace)

O CE (e o `cemem`) precisam de `PTRACE_MODE_ATTACH` sobre o alvo. Com o Yama LSM:

| `kernel.yama.ptrace_scope` | Efeito |
|---|---|
| 0 | qualquer processo do **mesmo usuário** (o que o readme-linux.txt do CE recomenda) |
| 1 (padrão do Arch/CachyOS) | só ancestrais (o CE só leria o que ele mesmo lançou) ou root/CAP_SYS_PTRACE |
| 2 | só root (CAP_SYS_PTRACE) |
| 3 | ninguém (até reiniciar) |

Tudo passa pela mesma checagem `PTRACE_MODE_ATTACH` (e portanto pelo Yama):
`PTRACE_ATTACH`, `PTRACE_SEIZE` (não para o alvo, mas não contorna o Yama),
`process_vm_readv/writev` (ATTACH_REALCREDS) e abrir `/proc/PID/mem` (ATTACH_FSCREDS).
Com scope **3** nenhum scanner funciona até reiniciar. Fontes: man7.org ptrace(2),
process_vm_readv(2); docs.kernel.org/admin-guide/LSM/Yama.html.

Esta máquina: `/etc/sysctl.d/99-cheat-engine-ptrace.conf` com `kernel.yama.ptrace_scope = 0`
(aplicado pelo install.sh; o próprio CE sugere `/etc/sysctl.d/10-ptrace.conf`).
Reverter: `sudo rm /etc/sysctl.d/99-cheat-engine-ptrace.conf && sudo sysctl -w kernel.yama.ptrace_scope=1`.

Alternativas (piores): rodar o CE como root (`sudo -E cheatengine` — arquivos e
autorun do root, sem a ponte do usuário); `setcap cap_sys_ptrace` num binário (dá
acesso a processos de **todos** os usuários — mais amplo que scope=0).

Hotkeys globais do CE leem `/dev/input/event*`: exigem root ou o grupo `input`
(isso permite a qualquer processo seu ler o teclado — por isso NÃO foi configurado).
Hotkeys não são necessárias para o agente.

## 3. Tela: janela, Wayland e headless

- O CE usa Qt6 → abre nativo no Wayland (KDE). `ce up` abre com janela.
- `ce up --headless` usa `QT_QPA_PLATFORM=offscreen`: sem janela, tudo funciona
  (testado: scan, write, watch, AA, tabela). Sem `WAYLAND_DISPLAY`/`DISPLAY` o `ce up`
  já entra em headless.
- Diálogos modais em headless ficam invisíveis e seguram a thread principal.
  A ponte carrega primeiro (`00_`) e o `ce_close` salva a tabela em
  `~/.local/share/cheatengine/agent-backups/` e fecha **sem** o diálogo "salvar?".
  Se algo travar: `ce down` (TERM→KILL automático) e `ce up`.

## 4. Jogos Proton / Wine

- Um jogo Proton é um processo Linux (o `wine64-preloader` carregando `Game.exe`).
  O CE Linux abre direto: `ce attach Game.exe`. Módulos PE (`Game.exe`,
  `UnityPlayer.dll`, `GameAssembly.dll`, `ntdll.dll`…) aparecem em `ce modules`.
- `ce ps` marca `wine: true`, mostra `steam_appid` (`SteamAppId`/`STEAM_COMPAT_APP_ID`)
  e `prefix` (`STEAM_COMPAT_DATA_PATH`/`WINEPREFIX`), e o `attach` por nome ignora
  auxiliares (`wineserver`, `services.exe`, `explorer.exe`, `steam.exe`…).
- **CE de Windows dentro do Proton** (Protonlauncher.lua): ao abrir um alvo Proton o
  CE Linux oferece "Launch Windows Version", que roda
  `STEAM_COMPAT_DATA_PATH=<compatdata/APPID> <Proton>/proton run cheatengine-x86_64.exe --OPENPID <pid-wine>`
  procurando o CE de Windows em `<pasta do CE>/windowsbin/` (o pacote AUR não cria essa
  pasta: seria `sudo mkdir /usr/lib/cheatengine/windowsbin` + copiar a instalação Windows).
  Só vale a pena se algo específico do lado Windows falhar no CE Linux; para scan,
  ponteiros, AA, watch e Mono o CE Linux bastou nos testes. (DBK/DBVM são driver e
  hipervisor do Windows: não existem no Wine.)
- Duas alternativas da comunidade para pôr o **CE de Windows** no mesmo wineserver
  do jogo (só se o CE Linux não bastar):
  - **protonhax** (AUR `protonhax`): nas opções de lançamento do jogo na Steam,
    `protonhax init %COMMAND%`; com o jogo aberto: `protonhax ls` (AppIDs ativos),
    `protonhax run <appid> "/caminho/absoluto/cheatengine-x86_64.exe"`,
    `protonhax cmd <appid>` (cmd.exe no contexto do jogo). Reaproveita Proton,
    prefixo e wineserver do jogo — é o que o CE de Windows precisa para ver o processo.
    (Sem commits desde 04/2024.)
  - **protontricks-launch** (`sudo pacman -S protontricks`):
    `protontricks-launch --appid <APPID> cheatengine-x86_64.exe` — o `--appid` é
    obrigatório para não abrir o seletor gráfico.
  Fontes: github.com/jcnils/protonhax, github.com/Matoking/protontricks,
  github.com/chrisgdouglas/cehelper (script pessoal).
- Mono em jogo Unity **Windows** sob Proton: o coletor do CE usa named pipe do
  Windows, que o CE Linux não alcança. O `monoscript.lua` resolve sozinho: faz
  `require('wineOnLinuxPipe2Socket')` + `WinePipe2Socket(52737)`, que intercepta
  `CreateNamedPipeW` no alvo e troca o pipe por um socket TCP em 127.0.0.1:52737.
  Basta `ce mono` (a porta 52737 precisa estar livre; a ponte usa 52740).
- 32 bits (WoW64 do Proton): ponteiros de 4 bytes — `ce ptr`/`readPointer` respeitam;
  para procurar ponteiros: `ce scan <end> -t dword --hex`; `cemem --bits 32`.
- **Anti-cheat** (EAC/BattlEye no Proton): não use em jogo online — ban garantido e
  violação de termos. A skill é para single-player/offline/depuração.

## 5. ceserver (quando o CE não roda na mesma máquina)

O CE Linux nativo **não precisa** de ceserver para alvos locais. Ele serve para:
CE de Windows (ou de outra máquina) analisando um Linux/Android/Steam Deck pela rede.

- Binários oficiais: cheatengine.org/downloads.php → "Server (For network scanning)":
  `ceserver75.zip`, `ceserverbin76.zip`, `ceserver77.zip` (o mais novo; não há para
  7.7.1). Em cada zip o único binário Linux glibc é `ceserver` (x86-64); as variantes
  arm/x86/x86_64 são Android. O 77 se identifica como "CHEATENGINE Network 2.4".
- **Não instale o AUR `ceserver`** (7.5-9): compila a tag 7.5 (protocolo antigo), cria
  uma unit systemd **root** sem `User=`, faz `systemctl enable --now` na instalação e
  escuta em **INADDR_ANY:52736** — serviço root exposto na rede (e não compila no
  GCC 16 sem patch).
- Compilar do GitHub: `make` em `Cheat Engine/ceserver/gcc` (o caminho tem espaço; o
  README escreve errado). Só gcc+make+zlib **não** bastam (afirmação refutada na pesquisa).
- Rodar: `sudo ./ceserver` (README oficial, de 2021). Opções documentadas: `-p <porta>`
  (padrão 52736), `-m 1` (ler/escrever só via ptrace), `-a` (módulos de um PID),
  `-s <0-3>` (arquitetura do disassembler), `-t` (teste). Ele dá acesso total à memória
  a quem conectar: só em rede confiável/VPN, nunca exposto.
- No CE: File → Open Process → Network → host:52736; em Lua
  `connectToCEServer(host, 52736)` (porta explícita), confira `isConnectedToCEServer()` e
  depois `openProcess(pid)` — lista de processos e leitura/escrita passam pelo servidor.
  Pela skill: `ce lua 'connectToCEServer("192.168.0.50", 52736) return isConnectedToCEServer()'`.

## 6. Peculiaridades verificadas no CE 7.7.1 Linux (2026-11-09)

| Item | Comportamento real | Como a skill lida |
|---|---|---|
| `server.lua` oficial | escuta **0.0.0.0:11211** sem senha; executa Lua; trava após 1 comando por conexão (`server.lua:143`) | override vazio no overlay; `ce doctor` vigia a porta |
| socket server | `celua.txt` documenta `createServerSocket`; a função que existe é `createSocketServer(porta, localhostOnly)` | ponte usa a que existir |
| `splitDisassembledString` | devolve os campos na ordem **inversa** da documentada | ponte parseia a string do `disassemble` |
| símbolos ELF | `getNameFromAddress` mostra `alvo.dano`, mas `getAddressSafe("alvo.dano")` = nil; `dano` resolve | ponte traduz `modulo.simbolo`; em AA use `dano` |
| endereço de tabela | `MemoryRecord.Address = "alvo.g_mundo"` fica `??` | ponte grava `"modulo"+offset` |
| `autoAssembleCheck` | só valida script com `[ENABLE]`+`[DISABLE]`; `[DISABLE]` isolado acusa `dealloc` | ponte anota falso negativo |
| speedhack em alvo nativo | injeção do `libceserver-extension` falhou (`recvall errno=9`) e o CE fechou | ponte exige `force=true` |
| speedhack em alvo Wine | extensão injetou, `speedhack_getSpeed()` = 4 e o CE seguiu vivo (efeito não medido: o alvo de teste não tinha saída temporizada) | permitido sem `force` |
| `getCEVersion()` | `7.7` (float), mesmo no 7.7.1 | `ce doctor` mostra o pacote |
| resultados de scan | ficam em `/var/tmp/Cheat Engine/` (scan desconhecido = centenas de MB) | `ce scan-free --all` / `ce cleanup` |
| `loadTable(arquivo)` | pode perguntar "executar o Lua da tabela?" (modal) | ponte usa `loadTable(stream, merge, true)` |
| `.CT` gravado | `CheatEngineTableVersion="52"`; `<Offsets>` do XML vai do **último** offset aplicado ao primeiro (cadeia `[0,4]` → `<Offset>4</Offset><Offset>0</Offset>`) | `ce add`/`ce list` usam a ordem natural |
| `MemScan.Results` | travou em teste dos verificadores da pesquisa | ponte lê por `createFoundList` |
| `waitTillDone()` dentro de `synchronize` | travou o CE de forma intermitente (1 em ~10 execuções do E2E) | ponte 3.1: despachante por timer + scans assíncronos (0 travamentos em ~1.250 scans) |
| erro interno do scanner | `thread 2:Duplicate ID: <endereço> (100)`, 0 resultados (visto 1x com ~14 MemScan acumulados); o CE parou de responder em seguida | `ce scan` libera scans antigos, repete 1x em erro; a ponte não chama `destroy()` em scan com erro |

## 7. Ferramentas nativas alternativas

| Ferramenta | Situação | Uso |
|---|---|---|
| `cemem` (desta skill) | instalado | scan/next, ptrscan, freeze, aob, disasm — sem CE |
| scanmem 0.17 | instalado (`extra`) | `scanmem -p PID -c "100;list;exit"` (sessão por execução) |
| GameConqueror | `pacman -S gameconqueror` | GUI GTK do scanmem |
| PINCE | AUR `pince`/`pince-bin` | front-end GDB "estilo CE" (Python, `libpince`) |
| GDB 17 | instalado | `gdb -p PID` para depuração clássica |
