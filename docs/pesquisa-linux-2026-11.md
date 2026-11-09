# Pesquisa profunda — Cheat Engine no Linux para agentes (09/11/2026)

> Gerada pelo workflow `/deep-research` (5 ângulos de busca, 24 fontes lidas, 119 afirmações extraídas,
> 25 verificadas por 3 votos adversariais: 21 confirmadas, 4 refutadas; 106 agentes). Achados com voto
> 3-0. Ao final, a seção **Respostas locais** fecha as lacunas que a pesquisa marcou como não verificadas,
> com testes feitos nesta máquina durante a montagem da skill.

## Resumo

Em 09/11/2026, a base recomendada no CachyOS é o Cheat Engine 7.7.1 nativo oficial para Linux. É um ELF x86-64 baixado de cheatengine.org e empacotado no AUR como cheatengine-bin 7.7.1-1, que já está instalado nesta máquina. Ele acessa a memória de processos locais sem Wine nem ceserver e pode ser controlado por um agente sem janela (QT_QPA_PLATFORM=offscreen) por meio de scripts em ~/.local/share/cheatengine/autorun/, com IPC TCP em 127.0.0.1 via createSocketServer(porta, true) e scans pela API Lua createMemScan/createFoundList; ambos foram verificados em teste real. Para jogos Steam/Proton, o próprio 7.7.1 traz autorun/Protonlauncher.lua: ele acha o compatdata e o Proton do processo aberto lendo /proc/<pid>/maps e relança o CE para Windows com 'proton run ... --OPENPID <pid>'. Para isso é preciso copiar a instalação Windows do CE para windowsbin/, pasta que o pacote AUR não cria. As alternativas comunitárias verificadas são: o protonhax ('protonhax init %COMMAND%' nas opções de lançamento e depois 'protonhax run <appid> <exe>', que reaproveita o Proton, o prefixo e o wineserver do jogo), o cehelper e o 'protontricks-launch --appid'. O ceserver (TCP 52736; connectToCEServer(host, porta) no Lua ou o botão Network na GUI) só é necessário no fluxo antigo 'CE Windows no Wine + servidor nativo' ou para alvos remotos, em VM ou Android. O README oficial é de 2021 e manda rodar com sudo; o binário oficial mais novo é o do ceserver77.zip, cujo único build Linux glibc é x86-64. Já o pacote AUR ceserver está parado na 7.5, roda como serviço root escutando em todas as interfaces e não compila no GCC 16 sem patch. Como ptrace/PTRACE_SEIZE, process_vm_readv/writev e /proc/<pid>/mem passam todos pela checagem PTRACE_MODE_ATTACH do Yama, o ptrace_scope precisa permitir o acesso: 0 via /etc/sysctl.d (já aplicado aqui) ou root/CAP_SYS_PTRACE. O valor 3 bloqueia qualquer scanner até o reboot. As alternativas nativas (scanmem, PINCE, Frida, GDB), os servidores MCP de terceiros e o formato .CT ficaram sem verificação nesta rodada.

## Achados (confiança alta, voto 3-0)

### 1. Build nativa oficial: Cheat Engine 7.7.1 para Linux

Existe build nativa oficial do Cheat Engine para Linux, e a versão atual é a 7.7.1. Ela é só para Linux: Windows e Mac seguem na 7.7, lançada no fim de maio de 2026 como a primeira versão oficial com suporte a Linux. O zip oficial CheatEngineLinux771.zip traz o executável ELF x86-64 cheatengine-x86_64, além de libceapi.so, liblua53.so, libtcc*.so e libceserver-extension_{x86_64,x86,i386}_linux.so. No CachyOS, instala-se pelo AUR com 'paru -S cheatengine-bin' (7.7.1-1). O pacote reempacota esse zip sem Wine (depends: qt6-base, libx11, glibc), instala em /usr/lib/cheatengine e cria o lançador /usr/bin/cheatengine. O readme-linux.txt pede ptrace_scope=0 (ou CE como root) para ler memória, e root ou acesso ao event device do teclado para hotkeys.

*Confiança: high · voto: 3-0 (afirmações 9 e 15 fundidas)*

<details><summary>Evidência</summary>

Página de downloads e zip:
- A página de downloads, sem datas, linka 'Download Cheat Engine 7.7.1 For Linux' ao lado da 7.7 para Windows e Mac.
- HEAD do zip: HTTP 200, 21.255.083 bytes, Last-Modified 16/08/2026.
- O sha256 0fb0d9043ae856acde03b5b871a2f3627ebcf674aeacd045f86d56d91a07f177 é igual ao do PKGBUILD.
- 'file' confirma ELF 64-bit x86-64. A versão embutida é ProductVersion 7.7.1 / FileVersion 7.7.1.10829.

Pacote AUR (RPC):
- 7.7.1-1, mantenedor lapsus, 4 votos.
- Enviado em 07/06/2026 e atualizado em 19/08/2026 (commit '7.7 -> 7.7.1').
- provides/conflicts cheatengine.

Corroboração: o GamingOnLinux (12/06/2026) confirma a 7.7 como primeira versão oficial com Linux. Na época o download ficava atrás do Patreon; hoje é público.

Dependências: o readme usa nomes Debian (qt6-base-dev, libqt6pas6), que no Arch são qt6-base e qt6pas. Mas o zip já inclui libQt6Pas.so.6 com RUNPATH $ORIGIN: nesta máquina o qt6pas não está instalado e o CE roda.

Conclusão prática (inferência apoiada no scan real de um processo Python feito pelos verificadores): para alvos locais, o CE nativo acessa a memória diretamente, sem Wine e sem ceserver.

</details>

Fontes: <https://cheatengine.org/downloads.php> · <https://cheatengine.org/download/CheatEngineLinux771.zip> · <https://aur.archlinux.org/packages/cheatengine-bin> · GamingOnLinux, 12/06/2026 (CE 7.7 como primeira versão oficial com Linux; corroboração citada pelos verificadores) · inspeção local: pacman -Q cheatengine-bin e pacman -Q qt6pas (09/11/2026)

### 2. Automação: overlay de autorun por usuário, socket só em localhost e modo offscreen

O ponto de entrada para automação por agente é o overlay de autorun por usuário do cheatengine-bin. Todo ${XDG_DATA_HOME:-~/.local/share}/cheatengine/autorun/NOME.lua roda quando o CE inicia pelo /usr/bin/cheatengine, sem root. Um script do usuário com o mesmo nome de um script do pacote o substitui. Dentro dele, createSocketServer(porta, true) abre um servidor TCP só em 127.0.0.1, um IPC que não depende de pipes do Wine. Com QT_QPA_PLATFORM=offscreen o CE roda sem janela. O pacote traz um autorun/server.lua (porta 11211) que funciona como shell Lua remoto; o overlay permite neutralizá-lo com um server.lua de mesmo nome.

*Confiança: high · voto: 3-0 (afirmação 16) + inspeção local*

<details><summary>Evidência</summary>

Como o lançador funciona (PKGBUILD e lançador do AUR, idênticos aos instalados):
- userdir=${XDG_DATA_HOME:-$HOME/.local/share}/cheatengine e cria autorun/.
- Se não houver main.lua, faz symlink para /usr/lib/cheatengine/user-overlay.lua e executa 'cd $userdir && exec .../cheatengine-x86_64 NOAUTORUN $@'.
- O overlay faz dofile do main.lua do pacote e mescla getFileList(PKGDIR..'autorun/','*.lua') com getFileList('autorun/','*.lua'), dando prioridade ao do usuário.
- O código upstream confirma: cheatengine.lpr trata o parâmetro NOAUTORUN, e LuaHandler.pas procura main.lua no diretório corrente antes do diretório do CE.

Testes reais como usuário comum (HOME isolado, offscreen):
- Rodaram aaa_first.lua, Mixed.lua, zz_probe.lua e um versioncheck.lua que substituiu o do pacote.
- NÃO rodaram UPPER.LUA, custom/sub.lua nem sub2/x.lua. Saída 0.
- Teste TCP: createSocketServer(52799,true) escutou em 127.0.0.1:52799 e um cliente Python recebeu a resposta.

Armadilhas:
- (a) O celua.txt documenta createServerSocket, mas no 7.7.1 Linux esse global é nil. A função real é createSocketServer.
- (b) Um main.lua que seja arquivo regular no diretório do usuário desliga o overlay: o CE sobe sem NOAUTORUN e não lê o autorun do usuário.
- (c) Rodar cheatengine-x86_64 direto, ou via sudo (o HOME muda), pula o overlay.
- (d) Só carregam arquivos com extensão .lua minúscula e sem subpastas. Por isso os scripts do pacote AddToNewGroup.LUA e autosave.LUA provavelmente não carregam.

Inspeção local:
- /usr/lib/cheatengine/autorun/server.lua chama createSocketServer(11211) sem o flag de localhost.
- O projeto local o trata como shell Lua sem autenticação em 0.0.0.0:11211.
- Em ~/.local/share/cheatengine/autorun/ já existem um server.lua que o desativa e o 00_ce_agent_bridge.lua, que usa createSocketServer com fallback para createServerSocket.

</details>

Fontes: <https://aur.archlinux.org/packages/cheatengine-bin> · <https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=cheatengine-bin> · <https://aur.archlinux.org/cgit/aur.git/tree/user-overlay.lua?h=cheatengine-bin> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/LuaHandler.pas> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/cheatengine.lpr> · inspeção local: /usr/lib/cheatengine/autorun/server.lua e ~/.local/share/cheatengine/autorun/ (09/11/2026)

### 3. Scans headless pela API Lua (MemScan + FoundList)
1

Scans de memória rodam headless pela API Lua do CE, nesta sequência:
1. ms=createMemScan()
2. ms.firstScan(scanoption, vartype, roundingtype, input1, input2, startAddress, stopAddress, protectionflags, alignmenttype, alignmentparam, isHexadecimalInput, isNotABinaryString, isunicodescan, iscasesensitive), com 14 argumentos, ou ms.nextScan(...), com 9
3. ms.waitTillDone(), sempre
4. fl=createFoundList(ms); fl.initialize()
5. fl.getCount(), fl.getAddress(i) e fl.getValue(i), com índice começando em 0

*Confiança: high · voto: 3-0 (afirmação 14)*

<details><summary>Evidência</summary>

Documentação e código:
- O celua.txt do master e a cópia do 7.7.1 em /usr/lib/cheatengine/celua.txt documentam essa assinatura.
- LuaMemscan.pas lê os parâmetros nessa ordem e só usa a forma com argumentos se houver ≥14 no firstScan e ≥9 no nextScan. Com menos, os argumentos são ignorados em silêncio e valem as propriedades do objeto.
- LuaFoundlist.pas: getAddress devolve string hex sem '0x' (inttohex(...,8)), então use tonumber(s,16). getValue devolve string e getCount devolve inteiro.
- foundlisthelper.pas confirma índice 0.
- O wiki oficial concorda: waitTillDone depois de iniciar o scan, e initialize abre o arquivo de resultados.

Teste real no CE 7.7.1 nativo desta máquina (QT_QPA_PLATFORM=offscreen, NOAUTORUN, main.lua próprio), contra um c_int32=1234567891 de um processo Python:
- getCount=1.
- getAddress(0)='7FD30A13E600', o endereço exato do ctypes.
- getValue(0)='1234567891' e getAddress(Count)='00000000'.
- Um nextScan seguido de initialize achou 1234567892.

Armadilha: a propriedade nova ms.Results (7.7+) travou o CE depois de nextScan + fl.destroy(), e foi preciso SIGKILL. Use o caminho FoundList.

</details>

Fontes: <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/bin/celua.txt> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/LuaMemscan.pas> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/LuaFoundlist.pas> · wiki.cheatengine.org (páginas Lua:Class:MemScan e createFoundList) · /usr/lib/cheatengine/celua.txt (cópia do 7.7.1) e teste real dos verificadores nesta máquina

### 4. connectToCEServer: ceserver sem a GUI

Para usar um ceserver sem a GUI, o Lua do CE oferece connectToCEServer(hostname, port). Depois de conectar, a lista de processos e as leituras e escritas de memória passam a ir pelo servidor, exatamente como no botão 'Network' da janela de processos. A porta tem de ser passada explicitamente; a padrão do ceserver é 52736, mudável com -p. Depois ainda é preciso conferir isConnectedToCEServer() e chamar openProcess(pid).

*Confiança: high · voto: 3-0 (afirmação 13; parte GUI das afirmações 8 e 12)*

<details><summary>Evidência</summary>

Documentação e código:
- O celua.txt (seção ----CEServer----, master e 7.7.1) traz a assinatura e também isConnectedToCEServer(), getCEServerPath() e getCEServerInterface().
- Em LuaHandler.pas, lua_connectToCEServer só age com exatamente 2 argumentos e não devolve nada. Tipagens de terceiros que prometem boolean estão erradas.
- CEconnect (networkConfig.pas) chama InitializeNetworkInterface, que chama ApplyNetworkAPIPointers. Este troca OpenProcess, ReadProcessMemory, VirtualQueryEx e as chamadas Toolhelp pelas versões Network*.
- O btnConnectClick da GUI chama o mesmo CEconnect.
- A porta 52736 vem de ceserver.c (PORT=52736) e de networkConfig.lfm (edtPort='52736'), não do celua.txt.
- Na GUI, 'Network' é um botão (btnNetwork em ProcessWindowUnit.lfm), não uma aba como diz o README. Ele abre 'Connect to server', com Host e Port.

Armadilhas no uso headless:
- Falha de conexão na thread principal abre um MessageDlg modal ('Failed connecting to the server') que bloqueia.
- Hostname que não resolve gera exceção.
- Um ceserver com versão de rede abaixo de 6 abre o diálogo 'Invalid ceserver version'.
- O wiki não tem página para a função (404).

</details>

Fontes: <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/bin/celua.txt> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/LuaHandler.pas> · <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver> · <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/ceserver/README.md>

### 5. O README oficial do ceserver
1

O README oficial do ceserver documenta um único fluxo para alvos Linux:
1. Compilar com gcc rodando make em 'Cheat Engine/ceserver/gcc'. O caminho tem espaço; o README escreve cheat-engine/CheatEngine/ceserver/gcc, que dá 404.
2. Iniciar com 'sudo ./ceserver'.
3. No CE para Windows rodando no Wine (ou no host, se o Linux for uma VM), conectar pelo Network com Host=localhost (ou o IP da VM).

Opções documentadas:
- -a: enumeração de módulos de um único PID
- -m 1: ler/escrever só via ptrace, em vez do /proc
- -p: porta (padrão 52736)
- -s: arquitetura do disassembler (0-3)
- -t: modo de teste

O README não cita alternativas de menor privilégio (setcap, ptrace_scope), connectToCEServer, GUI nativa nem limites de debugger, speedhack ou símbolos.

*Confiança: high · voto: 3-0 (afirmações 6, 7, 8 e 12 fundidas)*

<details><summary>Evidência</summary>

Origem e estado do README:
- 1673 bytes, blob 9a90f381….
- Inalterado desde o commit 92e1426, de 06/08/2021, que só renomeou description.md (escrito em 2019).
- Idêntico nas tags 7.4, 7.5 e no master (último push em 19/04/2025).
- A pasta real contém só makefile e makefile32.

Dependências reais que o README omite:
- zlib: #include <zlib.h> em ceserver.c e symbols.c; LDFLAGS = -lz -ldl -pthread.
- No makefile32, -m32 com libz de 32 bits.

Outros pontos:
- Para Android, o README manda usar su e 'adb forward tcp:52736 tcp:52736'.
- Guias de terceiros (dica da CodeWeavers, relatos no Reddit) descrevem o mesmo 'sudo ./ceserver' + Network 127.0.0.1.
- O fluxo continua válido, mas desde a 7.7 não é mais a única opção oficial para Linux.

</details>

Fontes: <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/ceserver/README.md> · <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver>

### 6. Binários oficiais do ceserver

Os binários oficiais prontos do ceserver ficam em cheatengine.org, na seção 'Server (For network scanning)': ceserver75.zip, ceserverbin76.zip e ceserver77.zip. O mais novo é o 77; não existe ceserver para a 7.7.1. Apesar do rótulo 'linux, android, x86, x86_64, arm and arm64', cada pacote tem um único binário Linux glibc, 'ceserver', que é x86-64. As variantes arm32/arm64/x86/x86_64 são para Android. No CachyOS, use o 'ceserver' simples.

*Confiança: high · voto: 3-0 (afirmação 10)*

<details><summary>Evidência</summary>

Downloads (downloads.php, linhas 279-286, e HEADs):
- ceserver77.zip: 12.274.307 bytes, Last-Modified 29/05/2026.
- ceserverbin76.zip: 5.830.002 bytes, 16/01/2025.
- ceserver75.zip: 1.310.783 bytes, 14/02/2023.
- Nomes da 7.7.1 (ceserver771.zip e variações) dão 404, e as releases do GitHub param na 7.5 (23/02/2023).

Conteúdo ('file' nos zips):
- ceserver é ELF x86-64 (/lib64/ld-linux-x86-64.so.2).
- ceserver_arm32/_arm64/_x86/_x86_64 usam /system/bin/linker(64) (NDK r23, API 31).
- Os pacotes 7.6/7.7 trazem libceserver-extension_x86_64_linux.so e libMonoDataCollector-linux-x86_64.so.
- O info.txt do 7.7 recomenda rodar como root ou ptrace_scope=0.

O zip nativo 7.7.1 não traz ceserver avulso. A libceapi.so contém código do ceserver (símbolos ceserver, launchceserver, newconnection) que roda dentro do CE como backend.

</details>

Fontes: <https://cheatengine.org/downloads.php> · <https://cheatengine.org/download/ceserver77.zip> · <https://cheatengine.org/download/ceserverbin76.zip>

### 7. Pacote AUR ceserver (7.5, serviço root na rede)
- makedepends: lib32-gcc-libs, lib32-glibc e lib32-zlib

O pacote AUR 'ceserver' (7.5-9, mantenedor alstruit, atualizado em 13/11/2024) compila o ceserver da tag 7.5:
- makedepends: lib32-gcc-libs, lib32-glibc e lib32-zlib. depends: glibc e zlib.
- Aplica ceserver.patch e roda 'make all -C gcc -f makefile', 'make all -C extension/gcc -f makefile' e 'make all -C extension/gcc -f makefile32'.

Ele instala /opt/ceserver/ceserver com uma unit systemd de sistema sem User=, ou seja, roda como root. O hook de instalação habilita e inicia o serviço na hora ('systemctl enable --now') e o reinicia a cada upgrade. Como o ceserver faz bind em INADDR_ANY na 52736, isso deixa um serviço root exposto na rede.

*Confiança: high · voto: 3-0 (afirmações 17 e 18 fundidas)*

<details><summary>Evidência</summary>

Arquivos do pacote, lidos do git do AUR (HEAD ea0a701):
- PKGBUILD e .SRCINFO.
- ceserver.service (161 bytes): ExecStart=/opt/ceserver/ceserver, Restart=on-failure, WantedBy=multi-user.target.
- ceserver.install: post_install faz daemon-reload + enable --now; post_upgrade faz restart incondicional; pre_remove faz disable --now.
- systemd.exec(5): o User= padrão de serviço de sistema é root.
- ceserver.c:1805/2003 faz bind em INADDR_ANY.

Build testado nesta máquina (GCC 16.2.1, make 4.4.1): a fonte 7.5 + patch do AUR, com make serial, gerou ceserver, libceserver-extension.so e libceserver-extension_x86.so.

Armadilhas:
- (a) Sem o patch, os três alvos falham no GCC ≥14: ceservertest.c:479 com -Wint-conversion; extension/server.c:344 com -Wincompatible-pointer-types.
- (b) O make precisa ser serial. 'all: clean $(TARGET)' corre em paralelo e o link do makefile32 falha com 'cannot find obj/server.o'. O alias zsh desta máquina, make='make -j32', sobrepõe MAKEFLAGS=-j1, então chame /usr/bin/make.
- (c) O master upstream (última mudança no ceserver em 15/08/2023) não compila no GCC 16: api.c:2884/3319 e extension/server.c:348, em PROCESS_VM_WRITEV/READV. O patch do AUR não cobre isso; acrescentar -fpermissive aos CFLAGS fez os três alvos compilarem.
- (d) lib32-zlib é satisfeito por lib32-zlib-ng-compat.

Recomendação derivada: preferir o binário oficial do ceserver77.zip, iniciado manualmente só quando necessário, a um serviço root permanente.

</details>

Fontes: <https://aur.archlinux.org/packages/ceserver> · <https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=ceserver> · <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver>

### 8. Proton: CE de Windows dentro do prefixo do jogo (Protonlauncher.lua, cehelper)

Para jogos Steam/Proton, tanto a ferramenta oficial quanto a comunidade relançam o CE para Windows dentro do Proton e do prefixo do jogo. O comando é STEAM_COMPAT_DATA_PATH=<steamapps/compatdata/<AppID>> <pasta do Proton>/proton run cheatengine-x86_64.exe. STEAM_COMPAT_CLIENT_INSTALL_PATH fica vazio no script oficial e aponta para a raiz do Steam no cehelper.

O CE 7.7.1 nativo já traz isso pronto em autorun/Protonlauncher.lua:
- Ao abrir um processo, ele lê /proc/<pid>/maps.
- Acha 'compatdata/<appid>' e a instalação do Proton: o caminho antes de /bin/wine ou /lib/wine, com o script 'proton' na raiz.
- Oferece o botão 'Launch Windows Version', que roda proton run cheatengine-x86_64.exe (ou cheatengine-i386.exe) --OPENPID <pid>.
- O <pid> é o PID Windows, obtido com executeCode_wine('GetCurrentProcessID').

O script comunitário cehelper faz o mesmo a partir do AppID achado com ps.

*Confiança: high · voto: 3-0 (afirmações 11, 2, 3 e 4 fundidas) + inspeção local*

<details><summary>Evidência</summary>

Protonlauncher.lua (4.519 bytes), lido no CheatEngineLinux771.zip e conferido em /usr/lib/cheatengine/autorun/Protonlauncher.lua:
- Casa 'compatdata/(%d+)', checa fileExists(s..'proton'), escapa os caminhos e executa com shellExecute.
- Há wrapper 'snap run --shell steam -c' para Steam Snap.
- Dispara em MainForm.OnProcessOpened.
- Procura o .exe direto em getCheatEngineDir()..'windowsbin/' e depois em getCheatEngineDir(). A mensagem de erro fala 'windowsdir', mas a pasta checada é windowsbin/.

Inspeção local:
- O cheatengine-bin NÃO instala windowsbin/ (pacman -Ql não a lista), e /usr/lib/cheatengine pertence ao root.
- É preciso copiar a instalação Windows do CE para /usr/lib/cheatengine/windowsbin/ com sudo, fora do controle do pacman.
- Sugestão não testada: sobrepor o Protonlauncher.lua pelo overlay do usuário, apontando para uma pasta própria.

Outras fontes:
- CEProtonLauncher.zip (Last-Modified 21/02/2023) é a versão antiga: um ELF Lazarus/GTK2 que acha o Steam por registry.vdf e config_info.
- O Protonlauncher.lua não está no GitHub público.

cehelper (MIT, 51 linhas, 1 estrela, criado em 01/02/2025, último commit em 04/09/2026):
- Detecta o AppID com APPID=$(ps -eo args | grep -Pom 1 'AppId=\K\d+').
- Depois roda STEAM_COMPAT_DATA_PATH=$COMPDATA/$GAME/ STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAMPATH $PRTEXEC run $CEPATH/cheatengine-x86_64.exe em primeiro plano.
- Um AppID passado como argumento pula o menu e sobrepõe o detectado.
- Limitações: Proton fixo em 'Proton - Experimental' (pode não ser o do jogo); Steam nativo em ~/.local/share/Steam (não Flatpak); regex sem âncora que pega o primeiro processo com 'AppId='. Ela pode casar SteamAppId= ou o próprio grep, e devolver dois valores se a linha tiver dois tokens.

O script proton define internamente WINEPREFIX=compatdata/<id>/pfx e WINEESYNC/WINEFSYNC.

</details>

Fontes: <https://cheatengine.org/downloads.php> · <https://cheatengine.org/download/CheatEngineLinux771.zip (autorun/Protonlauncher.lua e windowsbin/)> · <https://cheatengine.org/download/CEProtonLauncher.zip> · <https://github.com/chrisgdouglas/cehelper> · inspeção local: /usr/lib/cheatengine/autorun/Protonlauncher.lua e pacman -Ql cheatengine-bin (09/11/2026)

### 9. protonhax

O protonhax (AUR 'protonhax' 1.0.5-4, instala /usr/bin/protonhax) é a forma mais robusta de rodar o CE para Windows no contexto exato de um jogo Proton já em execução. Defina as opções de lançamento do jogo na Steam como 'protonhax init %COMMAND%'. Com o jogo aberto, use:
- 'protonhax ls': lista os AppIDs ativos.
- 'protonhax run <appid> /caminho/completo/cheatengine-x86_64.exe': o PATH é ignorado, então use caminho absoluto, entre aspas se tiver espaços.
- 'protonhax cmd <appid>': abre o cmd.exe no contexto do jogo.
- 'protonhax exec <appid> <programa nativo>': roda um programa Linux com o ambiente do jogo.

Como reaproveita o binário proton, o prefixo e as variáveis do jogo, o programa lançado entra no wineserver do jogo. É disso que o CE para Windows precisa para enxergar o processo.

*Confiança: high · voto: 3-0 (afirmações 0 e 1 fundidas)*

<details><summary>Evidência</summary>

Código (tag 1.0.5 = main, commit d6c67a4, 11/04/2024):
- init cria ${XDG_RUNTIME_DIR:-/run/user/$UID}/protonhax/<SteamAppId>/ com três arquivos: exe (1º argumento do %command% que contém /proton), pfx ($STEAM_COMPAT_DATA_PATH/pfx) e env (declare -px).
- Em seguida roda o jogo e apaga a pasta quando ele fecha.
- run faz source do env e 'exec <proton> run $@'.
- Sem a pasta, imprime 'No app running with appid' e sai com 2. O agente pode testar a existência da pasta antes de anexar.

Wineserver compartilhado, verificado:
- Nos branches proton_10.0/11.0/experimental_11.0 do ValveSoftware/wine, o socket fica em /tmp/.wine-<uid>/server-<dev>-<ino>.
- Com SteamLinuxRuntime_sniper (pressure-vessel 0.20260925.0), o /tmp do container tem o mesmo dev:inode do host.
- O verbo run do proton não faz 'wineserver -w'.
- O programa roda no host, fora do container.
- Relatos de 2026 (inclusive 01/09/2026, Linux Mint 22.3) dizem que funciona.

Ressalvas:
- Sem commits de código desde 04/2024.
- Issues #26/#16: 'protonhax init %COMMAND%' sem caminho absoluto pode impedir o jogo de abrir. O pacote AUR instala em /usr/bin, o que deve evitar isso; se falhar, use /usr/bin/protonhax init %COMMAND%.
- Issue #30 (aberta): sob gamescope, o CE congela ao clicar na lista de processos (_XAllocID assertion).
- exec com .exe falha (Exec format error, issue #15).
- Não funciona com Steam Flatpak.
- A pasta pode ficar órfã se o bash for morto.
- Não está instalado nesta máquina.

</details>

Fontes: <https://github.com/jcnils/protonhax> · <https://aur.archlinux.org/packages/protonhax> · <https://github.com/ValveSoftware/wine (branches proton_10.0, proton_11.0 e experimental_11.0)>

### 10. protontricks-launch

'protontricks-launch --appid <APPID> <PROGRAMA.exe>' roda qualquer executável Windows no prefixo Proton de um app Steam. Vem do pacote protontricks do repositório extra ('sudo pacman -S protontricks'); a versão é 1.14.1-1 no Arch e 1.15.0 upstream, de 04/10/2026. Para uso headless, o --appid é obrigatório: sem ele abre um seletor gráfico YAD/Zenity.

*Confiança: high · voto: 3-0 (afirmação 5)*

<details><summary>Evidência</summary>

Código e documentação:
- README (master 4f1cadb, 26/10/2026) e setup.cfg (protontricks-launch = protontricks.cli.launch:cli).
- launch.py monta 'wine start /wait /unix <exe> [args]' e chama 'protontricks -c <cmd> <appid>'.
- O CHANGELOG 1.6.0 (08/08/2021) introduziu o comando, já com --appid.
- A 1.15.0 passou a usar a pasta do executável como diretório de trabalho.

Requisitos e erros:
- O app precisa estar instalado com Proton e ter sido aberto ao menos uma vez. Caso contrário: 'Steam app with the given app ID could not be found... have you launched it at least once?'.
- Sem YAD/Zenity e sem --appid, sai com erro.

Limites do que foi verificado:
- O repositório não menciona Cheat Engine.
- Não foi verificado se o programa lançado assim entra no wineserver do jogo já em execução. O protonhax, ao contrário, reutiliza o proton do jogo.
- Não está instalado nesta máquina.

</details>

Fontes: <https://github.com/Matoking/protontricks> · <https://github.com/Matoking/protontricks/blob/master/CHANGELOG.md>

### 11. Permissões: PTRACE_MODE_ATTACH e Yama ptrace_scope
- PTRACE_ATTACH.
- PTRACE_SEIZE (Linux 3.4+): não para o alvo, mas não contorna o Yama.
- process_vm_readv/process_vm_writev (ATTACH_REALCREDS).
- Abertura de /proc/<pid>/mem (ATTACH_FSCREDS).

Valores de /proc/sys/kernel/yama/ptrace_scope:
- 0: permissões clássicas (mesmo UID e alvo dumpable).
- 2: só quem tem CAP_SYS_PTRACE no user namespace do alvo (root ou binário com cap_sys_ptrace).
- 3: ninguém, e o valor fica travado até o reboot

No Linux, toda forma de um scanner externo acessar a memória de outro processo passa pela checagem PTRACE_MODE_ATTACH e, portanto, pelo Yama:
- PTRACE_ATTACH.
- PTRACE_SEIZE (Linux 3.4+): não para o alvo, mas não contorna o Yama.
- process_vm_readv/process_vm_writev (ATTACH_REALCREDS).
- Abertura de /proc/<pid>/mem (ATTACH_FSCREDS).

Valores de /proc/sys/kernel/yama/ptrace_scope:
- 0: permissões clássicas (mesmo UID e alvo dumpable).
- 2: só quem tem CAP_SYS_PTRACE no user namespace do alvo (root ou binário com cap_sys_ptrace).
- 3: ninguém, e o valor fica travado até o reboot. Com 3, nenhum scanner externo funciona (CE, ceserver, scanmem, /proc/pid/mem).

Só root (euid 0 com CAP_SYS_PTRACE) grava o valor. Para persistir, use um arquivo em /etc/sysctl.d/. Nesta máquina já existe 99-cheat-engine-ptrace.conf, e o valor atual é 0.

*Confiança: high · voto: 3-0 (afirmações 19 e 20 fundidas)*

<details><summary>Evidência</summary>

Man pages:
- ptrace(2) (man-pages 6.19, 05/06/2026) traz os textos citados.
- process_vm_readv(2) e proc_pid_mem(5) confirmam os modos ATTACH_REALCREDS e ATTACH_FSCREDS.

Fonte do kernel (torvalds/linux master, 7.4-rc2):
- yama_lsm.c, linha 437: exige capable(CAP_SYS_PTRACE) para escrever.
- Linhas 440-443: travam o máximo quando o valor é 3.
- Linha 372: o escopo 2 usa ns_capable(user_ns do alvo, CAP_SYS_PTRACE).
- Linhas 376-378: negam tudo no 3.
- proc_sysctl.c, test_perm(): só dá escrita ao euid 0.
- kernel/ptrace.c trata PTRACE_ATTACH e PTRACE_SEIZE no mesmo ptrace_attach(), com PTRACE_MODE_ATTACH_REALCREDS.
- mm/process_vm_access.c usa mm_access(task, PTRACE_MODE_ATTACH_REALCREDS) para leitura e escrita.
- fs/proc/base.c, mem_open: usa PTRACE_MODE_ATTACH|FSCREDS.

Outras fontes:
- O arquivo 10-default-yama-scope.conf do elfutils diz o mesmo.
- O Yama.rst diz 'writable only with CAP_SYS_PTRACE' e define o modo 0 como 'same uid, as long as it is dumpable'.
- O readme-linux.txt do CE 7.7.1 e o info.txt do ceserver77 recomendam 'echo 0 > /proc/sys/kernel/yama/ptrace_scope', como root, ou um arquivo em /etc/sysctl.d/.

Comandos práticos:
- Temporário: 'sudo sysctl -w kernel.yama.ptrace_scope=0'.
- Persistente: 'kernel.yama.ptrace_scope = 0' num arquivo /etc/sysctl.d/99-*.conf, depois 'sudo sysctl --system'.
- O 10-ptrace.conf citado pelo readme é o nome usado no Ubuntu. Um prefixo alto garante precedência sobre outros arquivos.

Nuances:
- (a) O acesso ao próprio thread group nunca é negado.
- (b) A man page avisa que, nos valores 1 e 2, user namespaces anulam a proteção do Yama: um processo cujo euid criou o namespace filho tem CAP_SYS_PTRACE dentro dele, e jogos Proton rodam em bwrap/pressure-vessel.
- (c) ptrace_scope=0 enfraquece a segurança do sistema inteiro: qualquer processo do mesmo usuário pode ler a memória dos outros.
- (d) Nesta máquina estão ativos os módulos capability, landlock, lockdown, yama e bpf (sem AppArmor/SELinux). O kernel tem CONFIG_SECURITY_YAMA=y e CONFIG_PROC_MEM_ALWAYS_FORCE=y.

</details>

Fontes: <https://man7.org/linux/man-pages/man2/ptrace.2.html> · <https://man7.org/linux/man-pages/man2/process_vm_readv.2.html> · <https://man7.org/linux/man-pages/man5/proc_pid_mem.5.html> · <https://docs.kernel.org/admin-guide/LSM/Yama.html> · <https://github.com/torvalds/linux/blob/master/security/yama/yama_lsm.c> · inspeção local: /proc/sys/kernel/yama/ptrace_scope e /etc/sysctl.d/99-cheat-engine-ptrace.conf (09/11/2026)

## Ressalvas da pesquisa

Prazo de validade das informações:
- Tudo foi conferido em 09/11/2026.
- A linha Linux do CE é recente: a 7.7 saiu em 29/05/2026, e o zip 7.7.1 tem Last-Modified 16/08/2026.
- O upstream já trocou um zip sem mudar o nome: comentários do AUR de 26/06 e 02/07/2026 relatam sha256 divergente. O build do cheatengine-bin pode voltar a falhar por checksum.
- O verificador interno de versões (latestversion.txt) ainda diz 7.7.
- O GitHub (releases até a 7.5; último push no master em 19/04/2025) não reflete a 7.7.x nem contém o Protonlauncher.lua.
- O README do ceserver é de 2021.

Fontes fracas:
- O cehelper é um script pessoal com 1 estrela.
- O protonhax não recebe código desde 04/2024, e os relatos de que funciona são anedóticos.
- cheatengine-bin e ceserver são empacotamentos comunitários do AUR.
- Vários detalhes práticos vêm de testes dos verificadores nesta mesma máquina, não de documentação, e podem mudar com atualizações: o overlay, createSocketServer vs createServerSocket, o travamento com ms.Results, o build do ceserver no GCC 16.2.1 e o /tmp compartilhado com o pressure-vessel 0.20260925.0.

Afirmações REFUTADAS (0-3) que o relatório não deve repetir:
- Que gcc, make e os headers da zlib bastam para compilar o ceserver.
- A descrição dos backends -m 0..3 e do padrão 'lê com process_vm_readv / escreve com attach'. Só '-m 1 = só ptrace', do README, é seguro.
- Detalhes do pacote AUR ceserver, como o suposto conflito com um ceserver-bin.
- A descrição do ptrace_scope=1 como padrão documentado que sempre bloqueia um CE iniciado à parte. Os user namespaces do pressure-vessel podem mudar isso, e a pista de que o Wine chama PR_SET_PTRACER não foi verificada.

Lacunas (o relatório deve marcar estes itens como não verificados nesta rodada):
- scanmem/libscanmem/GameConqueror, PINCE/libpince, Frida, a API Python do GDB e bibliotecas Python como mem_edit e PyMemoryEditor.
- Pointer scan no Linux e capstone/keystone.
- Servidores MCP de terceiros: cheat-engine/AITools, cheatengine-mcp-bridge e ce-mcp.
- Named pipes do Wine.
- O formato .CT.
- Bases de módulos PE em /proc/<pid>/maps.
- setcap num binário dedicado e PR_SET_PTRACER.
- Limites de debugger, speedhack e símbolos do ceserver e do CE nativo.

Wayland: o cheatengine-bin depende de libx11 (Qt6). O comportamento no KDE Plasma Wayland não foi testado, nem o das hotkeys (o readme pede root ou acesso ao event device do teclado).

Segurança:
- ptrace_scope=0 vale para o sistema inteiro.
- O server.lua oficial do 7.7.1 abre um shell Lua na porta 11211 sem o flag de localhost.
- O serviço do AUR ceserver roda como root em INADDR_ANY.

Estado local observado:
- cheatengine-bin 7.7.1-1 instalado.
- ptrace_scope=0 via /etc/sysctl.d/99-cheat-engine-ptrace.conf.
- O autorun do usuário tem 00_ce_agent_bridge.lua e um server.lua que neutraliza o oficial.
- protontricks, protonhax e ceserver não estão instalados.
- /usr/lib/cheatengine/windowsbin não existe.
- Nenhum listener em 11211/52736 no momento da checagem.

## Afirmações refutadas (não repetir)

- **0-3** — On Linux, ceserver is built with gcc by running `make` in the repo's ceserver/gcc directory. The README writes the path as `cheat-engine/CheatEngine/ceserver/gcc`, but the real path is `Cheat Engine/ceserver/gcc`, with a space. The makefile compiles every ../*.c file into ./ceserver and links only `-lz -ldl -pthread`, so gcc, make and the zlib headers are the only build requirements.  
  Fonte checada: <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver>
- **0-3** — ceserver listens on TCP 52736 by default, and `-p` changes the port. The getopt string is a:m:p:s:t:, so every flag takes an argument, including `-t <pid>`. `-m` picks the memory backend: options.c defines 0=/proc/pid/mem, 1=ptrace, 2=process_vm_readv and 3=raw process_vm_readv syscall, and api.c defaults to 2. With the defaults (ATTACH_TO_ACCESS_MEMORY=0, ATTACH_TO_WRITE_MEMORY=1), reads use process_vm_readv without attaching, but each write ptrace-attaches to the target, writes with process_vm_writev, then detaches. So writes need ptrace permission (Yama ptrace_scope) even when reads work. The README only documents `-m 1` and implies the default is /proc/pid/mem, which is out of date.  
  Fonte checada: <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver>
- **0-3** — The AUR 'ceserver' package, which builds from source, is at version 7.5-9 and was last updated on 2024-11-13. It downloads the upstream cheat-engine GitHub '7.5' release tarball, so it ships ceserver 7.5, not 7.6 or 7.7. It conflicts with the separate 'ceserver-bin' AUR package.  
  Fonte checada: <https://aur.archlinux.org/packages/ceserver>
- **0-3** — With the Yama LSM, /proc/sys/kernel/yama/ptrace_scope = 1 ('restricted ptrace') is the documented default. At this value, any operation that needs a PTRACE_MODE_ATTACH check is allowed only if one of two things holds: the caller has CAP_SYS_PTRACE in the target's user namespace, or the caller has a predefined relationship with the target. By default that relationship is that the target must be a descendant of the caller. The target process can also call prctl(2) PR_SET_PTRACER itself to allow one additional PID. So at scope 1, a scanner or CE instance started separately from an already-running game (for example one launched by Steam) is refused. The exceptions are a scanner that launched the target, one named by the target through PR_SET_PTRACER, and one with CAP_SYS_PTRACE in the target's user namespace. [Lead to check elsewhere, not on this page: Wine's ntdll reportedly calls prctl(PR_SET_PTRACER, wineserver_pid) so the wineserver can trace its client processes. That would explain why CE must share the game's wineserver/prefix.]  
  Fonte checada: <https://man7.org/linux/man-pages/man2/ptrace.2.html>

## Perguntas que a pesquisa deixou em aberto

- Contra jogos Proton, o que o CE 7.7.1 nativo consegue fazer direto no processo Linux do jogo, e quando é obrigatório relançar o CE para Windows via Protonlauncher.lua ou protonhax? Os pontos em aberto são: listar módulos PE e suas bases a partir de /proc/<pid>/maps, símbolos, Mono/Unity, speedhack e debugger/breakpoints de dados. E o protontricks-launch, que usa 'wine start /wait /unix', entra no wineserver do jogo já em execução, como o protonhax comprovadamente faz?
- Qual configuração de menor privilégio funciona na prática para o agente? As opções a testar são: ptrace_scope=2 com 'setcap cap_sys_ptrace+ep' num binário auxiliar dedicado (incluindo se o modo de execução segura quebra o carregamento das bibliotecas do CE via RUNPATH $ORIGIN), PR_SET_PTRACER, ou o próprio user namespace do pressure-vessel. Em particular: com ptrace_scope=1, um CE externo consegue anexar a jogos Proton?
- Qual o estado atual das alternativas nativas: versões e pacotes (pacman/AUR) e uso por CLI de scanmem/GameConqueror, PINCE, Frida, GDB Python, mem_edit/PyMemoryEditor e capstone/keystone? E os servidores MCP de terceiros (cheat-engine/AITools, cheatengine-mcp-bridge, ce-mcp) funcionam com o CE nativo do Linux, ou dependem de named pipes do Windows?
- Qual o formato exato do Cheat Table (.CT) gravado pelo 7.7.1 (CheatEntries/CheatEntry, Address, VariableType, Offsets e a ordem dos <Offset> numa cadeia de ponteiros)? E loadTable/saveTable funcionam no modo offscreen, para o agente importar e exportar tabelas sem GUI?

## Fontes

- <https://github.com/jcnils/protonhax> — primary · Primary: Cheat Engine on Wine/Proton, current state
- <https://github.com/chrisgdouglas/cehelper> — primary · Primary: Cheat Engine on Wine/Proton, current state
- <https://gamingonlinux.com/2026/06/cheat-engine-now-has-a-linux-version-released> — secondary · Primary: Cheat Engine on Wine/Proton, current state
- <https://github.com/Matoking/protontricks> — primary · Primary: Cheat Engine on Wine/Proton, current state
- <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/ceserver/README.md> — primary · Technical: ceserver for native Linux targets
- <https://cheatengine.org/downloads.php> — primary · Technical: ceserver for native Linux targets
- <https://github.com/cheat-engine/cheat-engine/tree/master/Cheat%20Engine/ceserver> — primary · Technical: ceserver for native Linux targets
- <https://github.com/cheat-engine/cheat-engine/blob/master/Cheat%20Engine/bin/celua.txt> — primary · Technical: ceserver for native Linux targets
- <https://aur.archlinux.org/packages/cheatengine-bin> — primary · Technical: ceserver for native Linux targets
- <https://aur.archlinux.org/packages/ceserver> — primary · Technical: ceserver for native Linux targets
- <https://man7.org/linux/man-pages/man2/ptrace.2.html> — primary · Fundamentals/limitations: Linux memory access and ptrace permissions
- <https://docs.kernel.org/admin-guide/LSM/Yama.html> — primary · Fundamentals/limitations: Linux memory access and ptrace permissions
- <https://man7.org/linux/man-pages/man2/process_vm_readv.2.html> — primary · Fundamentals/limitations: Linux memory access and ptrace permissions
- <https://man7.org/linux/man-pages/man5/proc_pid_maps.5.html> — primary · Fundamentals/limitations: Linux memory access and ptrace permissions
- <https://man7.org/linux/man-pages/man7/capabilities.7.html> — primary · Fundamentals/limitations: Linux memory access and ptrace permissions
- <https://pymemoryeditor.readthedocs.io/en/latest/mcp.html> — primary · Alternatives: native Linux scanners and Python libraries
- <https://github.com/korcankaraokcu/PINCE> — primary · Alternatives: native Linux scanners and Python libraries
- <https://github.com/ValveSoftware/Proton/blob/proton_9.0/docs/DEBUGGING.md> — primary · Alternatives: native Linux scanners and Python libraries
- <https://www.mankier.com/1/scanmem> — primary · Alternatives: native Linux scanners and Python libraries
- <https://forum.cheatengine.org/viewtopic.php?t=624128> — forum · Practitioner: agent automation and MCP bridges across the Wine boundary
- <https://github.com/miscusi-peek/cheatengine-mcp-bridge> — primary · Practitioner: agent automation and MCP bridges across the Wine boundary
- <https://github.com/cheat-engine/AITools> — primary · Practitioner: agent automation and MCP bridges across the Wine boundary
- <https://bugs.winehq.org/show_bug.cgi?id=50045> — primary · Practitioner: agent automation and MCP bridges across the Wine boundary
- <https://github.com/CheatEngineNet/CheatEngine.Mcp> — primary · Practitioner: agent automation and MCP bridges across the Wine boundary

*Estatísticas: {"angles": 5, "sourcesFetched": 24, "claimsExtracted": 119, "claimsVerified": 25, "confirmed": 21, "killed": 4, "unverified": 0, "afterSynthesis": 11, "urlDupes": 4, "budgetDropped": 2, "agentCalls": 106}*

## Respostas locais (testes nesta máquina, 09/11/2026)

O que a pesquisa deixou "não verificado", e que a montagem da skill testou de fato
(CE 7.7.1 Linux, `cheatengine-bin 7.7.1-1`, `ptrace_scope=0`):

| Pergunta em aberto | Resultado local |
|---|---|
| CE nativo contra processo **Wine**: módulos PE e bases? | Sim. `ping.exe` num prefixo Wine 11.16: `ce attach ping` → 23 módulos (PE + ELF); `ping.exe+0` = `4D 5A` (MZ); `ping.exe` em `0x140000000`, igual ao `cemem modules` (lido do `/proc/PID/maps`). AOB no módulo PE também funcionou. |
| Speedhack | Alvo **nativo**: a injeção do `libceserver-extension` falhou (`recvall errno=9`) e o CE fechou. Alvo **Wine**: injetou, `speedhack_getSpeed()`=4, CE seguiu vivo (efeito não medido). |
| Debugger / breakpoints de dados no CE nativo | Funcionam em alvo nativo: `ce watch` achou `alvo.dano: sub [rdi],esi` com registradores. Em alvo Wine: não testado. |
| Mono / Unity | Não testado (nenhum jogo Unity foi aberto). O `monoscript.lua` usa `WinePipe2Socket(52737)` sozinho em alvos Wine. |
| Formato `.CT` gravado pelo 7.7.1 | `<CheatTable CheatEngineTableVersion="52">` → `<CheatEntries><CheatEntry>` com `ID`, `Description` (entre aspas), `VariableType` (`4 Bytes`, `Float`…), `Address` (`"alvo"+4058`), `<Offsets><Offset>`. Cadeia natural `[0, 4]` grava `<Offset>4</Offset><Offset>0</Offset>`: **o XML lista do último offset aplicado para o primeiro**. |
| `loadTable`/`saveTable` sem janela | Funcionam com `QT_QPA_PLATFORM=offscreen` (teste E2E). A ponte usa `loadTable(stream, merge, true)` para não abrir o diálogo de Lua da tabela. |
| Wayland (KDE Plasma) | O CE abre a partir da sessão Wayland e a ponte responde. A janela não foi inspecionada; o modo offscreen funciona por completo. |
| CE lançado à parte lê um processo já em execução? | Sim, com `ptrace_scope=0`: o alvo de teste e o `ping.exe` foram iniciados separadamente e lidos/escritos. |
| `ms.Results` trava | A ponte não usa `Results`: lê com `createFoundList` + `initialize` (funciona). |
| `createSocketServer` vs `createServerSocket` | Só `createSocketServer(porta, true)` existe; liga em `127.0.0.1` (visto no `ss -ltnp`). |
| `server.lua` oficial | Escuta em `0.0.0.0:11211` sem senha e trava após 1 comando por conexão (erro em `server.lua:143`). Neutralizado pelo override do overlay. |
| Alternativas nativas | `scanmem` 0.17 instalado (`extra`). O `cemem` da skill faz scan/next, valor desconhecido, ptrscan, aob, freeze, disasm (capstone) e asm (keystone), coberto pelo E2E. PINCE, Frida, mem_edit e PyMemoryEditor não foram avaliados. |
| MCP de terceiros | Não usados. O CE 7.7.1 Linux já traz `Extensions/AITools` (`aibase.lua`, `tools/aitools.lua`), a extensão oficial de IA, para o diálogo interno do CE. A integração com o agente externo desta skill é a ponte própria. |
| `setcap cap_sys_ptrace` / `PR_SET_PTRACER` | Não testados: foi adotado `ptrace_scope=0`, como pede o `readme-linux.txt` do CE. |
