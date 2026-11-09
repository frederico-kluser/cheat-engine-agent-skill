# Auto Assembler (AA) no CE 7.7.1 Linux — sintaxe e modelos testados

Todo script tem **duas seções**: `[ENABLE]` (aplica) e `[DISABLE]` (desfaz). Fluxo:

```bash
ce watch <end> --kind write        # 1. quem escreve? -> endereço/símbolo da instrução
ce disasm <instr> -n 8             # 2. contexto e bytes originais (para o [DISABLE])
ce aa check script.cea             # 3. sintaxe (enable_ok / disable_ok / note)
ce aa apply script.cea             # 4. aplica; guarda disableInfo (allocs, símbolos)
ce disasm <instr> -n 3             # 5. confere o jmp/patch; teste no programa
ce aa revert --all                 # 6. desfaz ([DISABLE] + libera memória)
ce add-script script.cea -d "..."  # 7. vira cheat clicável na tabela; ce table save x.CT
```

## Endereços dentro do script (Linux)

| Quer apontar para | Escreva | Observação |
|---|---|---|
| símbolo ELF (função/global) | `dano:` / `[g_contador]` | **sem** o módulo: `alvo.dano` NÃO resolve no AA do CE Linux |
| módulo + offset | `alvo+1189:` | módulo com `-`, espaço ou `.` no meio: `"tutorial-x86_64"+2A0F0:` |
| módulo PE (Proton) | `"Game.exe"+1A2B3C:` / `GameAssembly.dll+...` | igual ao Windows |
| endereço absoluto | `558BBC233295:` | evite: muda a cada execução (ASLR) |
| padrão de bytes | `aobscanmodule(INJECT,alvo,83 05 ?? ?? ?? ?? 01)` | o jeito robusto (sobrevive a ASLR e a pequenas atualizações) |

Números: hex por padrão (`10` = 16); decimal com `#` (`#100`); float com `(float)1.5`.

## Modelo 1 — trocar uma instrução no lugar (mesmo tamanho)

Testado: `sub [rdi],esi` (29 37) → `add [rdi],esi` (01 37) — a vida passa a subir.

```asm
[ENABLE]
dano:
  add [rdi],esi        // era: sub [rdi],esi  (mesmo tamanho: 2 bytes)

[DISABLE]
dano:
  sub [rdi],esi
```

## Modelo 2 — anular (NOP)

```asm
[ENABLE]
dano:
  nop 2                // 2 bytes de NOP (CE gera a sequência certa)

[DISABLE]
dano:
  db 29 37             // bytes originais (copie do ce disasm)
```

## Modelo 3 — injeção com code cave (AOB + alloc + jmp) — o padrão do CE

Testado no alvo: `add dword ptr [g_contador],01` (7 bytes, RIP-relativo) virou +100.

```asm
[ENABLE]
aobscanmodule(INJECT,alvo,83 05 ?? ?? ?? ?? 01 8B 15) // precisa ser ÚNICO (ce aob ... -m alvo)
alloc(newmem,$1000,INJECT)   // aloca PERTO de INJECT: o jmp de 5 bytes alcança

label(code)
label(return)

newmem:
  add dword ptr [g_contador],#100   // código novo (o CE remonta o RIP-relativo)

code:
  jmp return

INJECT:
  jmp newmem
  nop 2                             // 7 bytes originais - 5 do jmp
return:
registersymbol(INJECT)

[DISABLE]
INJECT:
  db 83 05 A4 2D 00 00 01           // bytes originais

unregistersymbol(INJECT)
dealloc(newmem)
```

Regras do modelo 3:
- O `jmp newmem` ocupa **5 bytes**: cubra instruções inteiras (≥ 5 bytes) e complete
  com `nop N`. Copie as instruções sobrescritas para `code:` se ainda forem
  necessárias (aqui a instrução original foi substituída de propósito).
- `alloc(nome,tamanho,PERTO_DE)` — o 3º argumento é essencial em x86-64.
- `aa check` pode acusar `dealloc`/`unregistersymbol` no `[DISABLE]` isolado: é falso
  negativo conhecido (a ponte marca `note` e `disable_ok: true`); o revert real usa
  o `disableInfo` guardado no `aa apply`.
- Instrução com `[rip+...]`: escreva-a pelo **símbolo** (`[g_contador]`) ou pelo
  endereço absoluto entre colchetes; o CE recalcula o deslocamento no novo lugar.

## Modelo 4 — capturar o ponteiro do objeto (achar a struct do jogador)

Testado: em `main` do alvo, `mov esi,[rbx]; mov r8d,DE` (8 bytes) roda a cada tick
com `rbx = Jogador*`. O script guarda `rbx` num símbolo; a tabela lê `[pJogador]+0`.

```asm
[ENABLE]
aobscanmodule(INJECT,alvo,8B 33 41 B8 DE 00 00 00) // mov esi,[rbx] ; mov r8d,DE
alloc(newmem,$1000,INJECT)
alloc(pJogador,8,INJECT)      // PERTO: permite 'mov [pJogador],rbx' RIP-relativo
registersymbol(pJogador)
label(code)
label(return)

newmem:
  mov [pJogador],rbx          // guarda o ponteiro do jogador
code:
  mov esi,[rbx]               // instruções originais (8 bytes)
  mov r8d,000000DE
  jmp return

INJECT:
  jmp newmem
  nop 3                       // 8 bytes originais - 5 do jmp
return:

[DISABLE]
INJECT:
  db 8B 33 41 B8 DE 00 00 00

unregistersymbol(pJogador)
dealloc(newmem)
dealloc(pJogador)
```
Depois: `ce add pJogador --offsets 0 -d "Vida via pJogador"` (o símbolo registrado vale
na tabela enquanto o script estiver ativo).

**Nunca** ponha o `jmp` de 5 bytes sobre uma função menor que 5 bytes (ex.: `dano` =
`sub [rdi],esi; ret`, 3 bytes): ele sobrescreveria o começo da função seguinte.
Escolha um ponto com ≥ 5 bytes de instruções inteiras, sem alvos de salto no meio.

## Convenções de chamada (ao chamar funções do alvo)

- Linux x86-64 (System V): args em `rdi, rsi, rdx, rcx, r8, r9`; retorno `rax`; pilha
  alinhada em 16 antes do `call`.
- Wine/Proton x64 (código do jogo é Windows): `rcx, rdx, r8, r9` + 32 bytes de
  shadow space.
- 32 bits: argumentos na pilha (cdecl/stdcall).

## Lua e C dentro do AA

```asm
[ENABLE]
{$lua}
  if syntaxcheck then return "define(ALVO, dano)" end  -- no check também precisa definir
  print("habilitando em " .. string.format("%X", getAddress("dano")))
  return "define(ALVO, dano)"     -- o texto devolvido vira AA
{$asm}
ALVO:
  nop 2
[DISABLE]
dano:
  db 29 37
```

(Modelos 1, 2, 3, 4 e este bloco Lua foram aplicados e revertidos num alvo real em 2026-11-09.)

O CE Linux traz o TCC (`libtcc-64.so`, usado pelo próprio CE em tempo de execução), base
dos blocos `{$c} ... {$asm}` de C embutido — não validado por esta skill; prefira asm.

## Erros comuns

| Erro | Causa |
|---|---|
| `This address specifier is not valid` | `modulo.simbolo` → use só o símbolo ou `"modulo"+off` |
| `aobscanmodule ... not found` | padrão mudou/não é único → `ce aob "<padrão>" -m <mod>` |
| jogo trava/fecha após o patch | jmp cortou instrução no meio / registradores alterados sem salvar (`push`/`pop`) |
| `Access violation` no check do [DISABLE] | falso negativo com `dealloc` (ver modelo 3) |
