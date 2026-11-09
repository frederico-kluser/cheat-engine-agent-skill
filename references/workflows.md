# Receitas (fluxos completos com `ce` / `cemem`)

Em todas: `ce up` antes, `ce attach <alvo>` depois de achar o processo com `ce ps`.
**Confirme sempre pelo efeito no programa** (a tela/estado mudou), não só pela memória.

## 1. Valor conhecido (vida 100, ouro 2500, munição 30)

```bash
ce scan 100                 # muitos resultados
# faça o valor mudar no jogo (leve dano, gaste ouro)
ce next 93                  # repita até 1–5 resultados
ce write <end> 999          # o jogo mostra 999? achou.
ce freeze <end> 999 -d "Vida"   # ou ce add <end> -d "Vida" para só anotar
```

- 0 resultados no first scan: o valor mudou enquanto você digitava ou o tipo está
  errado → repita rápido, tente `-t float`, `-t double`, ou `-t all`.
- Sobram 2+ endereços que mudam juntos: geralmente um é o "real" e o outro é cópia
  para exibição (ou pilha). Escreva em cada um e veja qual o jogo respeita; endereços
  `0x7ff…` costumam ser pilha (cópia temporária).

## 2. Valor desconhecido (barra sem número, tempo, posição)

```bash
ce scan -t float            # valor desconhecido (snapshot; pode dar milhões)
# barra diminuiu
ce next decreased
# nada mudou
ce next unchanged
# barra aumentou
ce next increased
# repita alternando até poucos resultados; depois ce results --limit 20
```

Dica: alterne `changed`/`unchanged` muitas vezes com o jogo parado/em movimento —
filtra rápido. Para inteiros desconhecidos use `-t dword` (ou `-t all`).

## 3. Valor exibido ≠ valor guardado

- Vida "100" pode ser `float` 100.0, `double`, ou fração 1.0 (=100%) → `ce scan 1 -t float`.
- Ouro ×10/×100 ou com XOR/criptografia simples: use valor desconhecido + increased/decreased.
- Faixa: `ce scan 90 --op between --value2 110 -t float`.

## 4. Endereço estável (sobrevive a reiniciar o jogo)

Endereços de heap mudam a cada execução. Duas rotas:

**A) Pointer scan (automático)**
```bash
cemem ptrscan <alvo> <end> --depth 3 --max-offset 1000 --main-only --limit 30
# reinicie o jogo, ache o valor de novo (ou só teste os caminhos):
cemem ptr <alvo> jogo+4058 0 18     # cada caminho candidato -> chega no valor certo?
ce add jogo+4058 --offsets 0 18 -d "Vida (ponteiro)"
ce table save ~/Jogos/jogo.CT
```
Aumente `--depth` (4–5) e `--max-offset` (2000–4000) para jogos grandes (Unity/Unreal).
Bases em libs do sistema (`libc`, `ld-linux`, `ntdll.dll`) quase sempre são ruído.

**B) Manual ("o que acessa este endereço", como no passo 8 do tutorial do CE)**
```bash
ce watch <end> --kind access --seconds 5
#  instrução: "mov eax,[rbx+18]"  registers.RBX = 0x55d0c0b00000  -> offset 0x18
ce scan 55d0c0b00000 -t qword --hex     # quem guarda esse ponteiro? (32 bits: -t dword)
#  repita até chegar num endereço "verde" (dentro de um módulo: ce resolve <end>)
```

## 5. "O que escreve aqui?" → injeção de código

```bash
ce watch <end_da_vida>                  # -> instrução, ex.: alvo.dano "sub [rdi],esi"
ce disasm dano -n 8                     # contexto
# escreva o script (modelos em references/auto-assembler.md)
ce aa check cura.cea && ce aa apply cura.cea
# teste no jogo; desfaça com:
ce aa revert --all
# para virar "cheat" clicável:
ce add-script cura.cea -d "Vida não diminui" && ce table save ~/Jogos/jogo.CT
```
Injeção (AA) é mais robusta que freeze: atua na instrução, vale para todos os
inimigos/instâncias e não "pisca".

## 6. Freeze

```bash
ce freeze <end> 999                     # o CE reescreve no intervalo de freeze (~100 ms)
ce freeze jogo+4058 999 --offsets 0 18  # por ponteiro
ce list ; ce unfreeze <id> --delete
cemem freeze <alvo> <end> 999 --background   # sem o CE (processo próprio); cemem unfreeze --all
```

## 7. Trainer / tabela .CT

```bash
ce table save ~/Jogos/jogo.CT           # entradas, ponteiros, scripts AA
ce table load ~/Jogos/jogo.CT --merge   # carrega sem o diálogo de Lua
```
Formato (XML): `<CheatTable><CheatEntries><CheatEntry>` com `<Description>`,
`<VariableType>` (4 Bytes, Float, Double, String, Array of byte, Auto Assembler Script),
`<Address>` (`"jogo"+4058`) e `<Offsets><Offset>…` — **a lista de `<Offset>` no XML vai
do ÚLTIMO aplicado para o primeiro** (o CLI recebe na ordem natural e converte).
Tabelas da comunidade (fearlessrevolution.com, .CT de Windows) funcionam com jogos
Proton quando os módulos têm o mesmo nome (`Game.exe`, `GameAssembly.dll`).

## 8. Unity / Mono

```bash
ce attach Game.exe                      # (ou o binário nativo do jogo Unity)
ce mono                                 # injeta o MonoDataCollector -> ok: true
ce lua 'local c = mono_findClass("", "PlayerController") return c and mono_class_getName(c)'
ce lua -f - <<'EOF'
local c = mono_findClass("", "PlayerController")
local out = {}
for _, f in ipairs(mono_class_enumFields(c, true)) do
  out[#out+1] = string.format("%s +0x%X %s", f.name, f.offset or 0, f.typename or "")
end
return table.concat(out, "\n")
EOF
```
Funções úteis do `monoscript.lua`: `mono_enumImages`, `mono_image_enumClasses`,
`mono_findClass(ns, nome)`, `mono_class_enumFields`, `mono_class_enumMethods`,
`mono_findMethod(ns, classe, metodo)` + `mono_compile_method` (endereço nativo para
injeção), `mono_class_getStaticFieldAddress`, `mono_class_findInstancesOfClassListOnly`.
No AA: `{$lua} LaunchMonoDataCollector() {$asm}` e símbolos `Classe:Metodo`.
IL2CPP (GameAssembly.dll/.so): sem Mono — use AOB, ponteiros e `ce watch`.

## 9. Jogos Proton/Wine (Steam)

```bash
ce ps "Game.exe"          # wine: true, steam_appid, prefix
ce attach "Game.exe"      # o CE Linux lê o processo direto (é um processo Linux)
ce modules game           # PE: Game.exe, UnityPlayer.dll, GameAssembly.dll...
```
- 32 bits (WoW64): ponteiros têm 4 bytes; `ce ptr` respeita (readPointer), e para
  procurar ponteiros use `-t dword --hex`.
- Convenção de chamada em scripts AA de alvo Wine x64: **Windows** (rcx, rdx, r8, r9).
- Se algo só funcionar no CE de **Windows**, rode-o no wineserver do jogo:
  `protonhax run <appid> "/caminho/cheatengine-x86_64.exe"` (opção de lançamento
  `protonhax init %COMMAND%`) ou `protontricks-launch --appid <appid> cheatengine-x86_64.exe`.
  Detalhes e fontes: `references/linux-proton.md` §4.

## 10. Conferir algo sem o CE (cemem)

```bash
cemem read <alvo> <end> -t float        # confirma o que o CE escreveu
cemem maps <alvo> heap                  # regiões
cemem modules <alvo> game               # base de módulos PE/ELF (calcula offsets)
```

## 11. Limpeza ao terminar

```bash
ce cleanup                 # reverte AA, para watches, libera scans, remove entradas do agente
ce cleanup --rollback-writes   # + desfaz todas as escritas
ce detach                  # solta o processo
ce down                    # SÓ se foi o agente que abriu o CE (ce up -> "launched": true);
                           # se o CE já estava aberto pelo usuário, não feche
```
