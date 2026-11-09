# API CELua — escaneamento de memória (MemScan / FoundList)

> **Linux:** o mesmo arquivo está em `/usr/lib/cheatengine/celua.txt` (CE 7.7.1). Os números de
> linha abaixo são do `celua.txt` do CE 7.7 **Windows**; no Linux o texto está ~10–40 linhas
> abaixo — procure pelo nome da função (`grep -n createMemScan /usr/lib/cheatengine/celua.txt`).
> Diferenças reais do 7.7.1 Linux (testadas): `references/linux-proton.md` §6.

> Fonte: `C:\Program Files\Cheat Engine\celua.txt`, linhas 2506–2688 (CE 7.7).
> Para o texto integral, abra o celua.txt na linha indicada.
> As linhas 841–858 (documentação de `AOBScan`) são transcritas aqui porque `MemScan.firstScan` remete explicitamente a elas ("protectionflags : See aobscan about protectionflags", celua.txt:2602).
> O método `destroy()` citado nas pegadinhas vem da classe base `Object` (celua.txt:967–975), herdada por `MemScan Class (Inheritance: Object)` (celua.txt:2506).

## Visão geral do fluxo

Não existe um único "scan()" com parâmetros no celua.txt. O fluxo documentado é:

1. **Criar o scanner** — `createMemScan(progressbar OPTIONAL)` devolve um novo objeto `MemScan` (celua.txt:2508). Existe também `getCurrentMemscan()`, que devolve o memscan da aba atual (celua.txt:2507).
2. **Configurar** — ou pelas propriedades (`ScanOption`, `VariableType`/`VarType`, `Roundingtype`, `Scanvalue`, `Scanvalue1`, `Scanvalue2`, `Startaddress`, `Stopaddress`, `Hexadecimal`, `Casesensitive`, etc., celua.txt:2536–2559), ou passando tudo por parâmetro em `firstScan(...)` (celua.txt:2568).
3. **Disparar** — `scan()` faz primeiro OU próximo scan conforme os valores das propriedades atuais (celua.txt:2562); `firstScan(...)`/`nextScan(...)` fazem explicitamente um ou outro (celua.txt:2563–2564, 2568, 2618).
4. **Esperar** — `waitTillDone(timeout OPTIONAL): boolean` espera a(s) thread(s) do memscan terminarem; **sempre use isto (ou `Results`)**; devolve `false` se o timeout disparou (celua.txt:2649).
5. **Ler os resultados** — `getAttachedFoundlist()` devolve um objeto `FoundList` se houver um anexado aos resultados deste scan, e `nil` caso contrário (celua.txt:2653). Alternativamente crie um com `createFoundList(memscan)` (celua.txt:2664).
6. **Abrir e percorrer** — `FoundList.initialize()` abre os resultados para leitura (celua.txt:2673); depois use `Count`/`getCount()` e `Address[index]`/`getAddress(index)`/`Value[index]`/`getValue(index)` (celua.txt:2667–2677).
7. **Liberar** — `FoundList.deinitialize()` libera os resultados (celua.txt:2674) e `destroy()` destrói o objeto (celua.txt:975).

**Fluxo com callback (assíncrono, sem polling):** defina `OnScanDone: function(memscan)` — "Set a function to be called when the scan has finished" (celua.txt:2525) — antes de iniciar o scan. Para feedback de progresso durante o scan existe `OnGuiUpdate: function(memscan, TotalAddressesToScan, CurrentlyScanned, ResultsFound)` — "Called during the scan so you can update the interface if needed" (celua.txt:2526). O mesmo trio de dados pode ser consultado sob demanda por `getProgress()`, que devolve uma tabela com os campos `TotalAddressesToScan`, `CurrentlyScanned`, `ResultsFound` (celua.txt:2658).

**Fluxo sem callback (síncrono, com createFoundList):** crie o memscan, chame `firstScan(...)`/`scan()`, chame `waitTillDone()` e só então crie e inicialize o `FoundList` com `createFoundList(ms)` + `initialize()`, lendo `Count` e os endereços. `Results` também força a espera — "Returns an indexed table with all the found addresses 7.7+ (Fetching this will call waitTillDone() for you)" (celua.txt:2533) — mas veja as pegadinhas sobre não confiar em `Results`/`FoundList` como equivalentes.

**Caminho de resultado único (sem FoundList):** `OnlyOneResult`/`setOnlyOneResult(state)` fazem o scanner parar no primeiro resultado e gravar o endereço em `Result` (celua.txt:2528, 2532, 2656); `IsUnique` é o mesmo, mas usa múltiplas threads — logo, se o valor não for único, você recebe um endereço **aleatório** (celua.txt:2529). Recupere com `getOnlyResult()`, que só funciona se `returnOnlyOneResult` for true e devolve `nil` se não encontrou, senão o endereço encontrado (integer) (celua.txt:2657). Observação da fonte: "Note that it does not work with a foundlist" (celua.txt:2656).

## createMemScan / createFoundList

| Função | Assinatura exata | O que devolve | Linha |
|---|---|---|---|
| `createMemScan` | `createMemScan(progressbar OPTIONAL) : Returns a new MemScan class object` | um novo objeto da classe `MemScan` | celua.txt:2508 |
| `getCurrentMemscan` | `getCurrentMemscan() : Returns the current memory scan object. If tabs are used the current tab's memscan object` | o objeto de memscan atual | celua.txt:2507 |
| `createFoundList` | `createFoundList(memscan)` | a classe `FoundList` — "The foundlist is an object that opens the current memscan's result file and provides an interface for reading out the addresses" | celua.txt:2661–2664 |

Não há, no intervalo 2506–2688, nenhuma descrição do que o parâmetro `progressbar` de `createMemScan` faz além de ser opcional (celua.txt:2508).

## Propriedades do MemScan

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Priority` | string | Thread priority in which the scanner scans the memory. Can be one of: `'tpIdle'`, `'tpLowest'`, `'tpLower'`, `'tpNormal'`, `'tpHigher'`, `'tpHighest'`, `'tpTimeCritical'` | celua.txt:2519 |
| `FoundCount` | integer | the number of results found in the last scan (7.7+) | celua.txt:2520 |
| `LastScanWasRegionScan` | boolean | returns true is the previous scan was an unknown initial value | celua.txt:2521 |
| `LastScanValue` | string | (sem descrição na fonte) | celua.txt:2522 |
| `LastScanType` | ScanType/string | `'stNewScan'`, `'stNextScan'`, `'stFirstScan'` | celua.txt:2523 |
| `ScanresultFolder` | string | Path where the results are stored (READONLY) | celua.txt:2524 |
| `OnScanDone` | function(memscan) | Set a function to be called when the scan has finished | celua.txt:2525 |
| `OnGuiUpdate` | function(memscan, TotalAddressesToScan, CurrentlyScanned, ResultsFound) | Called during the scan so you can update the interface if needed | celua.txt:2526 |
| `FoundList` | FoundList | The foundlist currently attached to this memscan object | celua.txt:2527 |
| `OnlyOneResult` | boolean | If this is set to true memscan will stop scanning after having found the first result, and written the address to "Result" | celua.txt:2528 |
| `IsUnique` | boolean | Same as OnlyOneResult but will use multiple threads, so if the value is not unique you will be given a random address | celua.txt:2529 |
| `ErrorString` | string | contains a string containing an error if an error occured | celua.txt:2530 |
| `FoundCount` | Integer | The number of results that where found in the previous scan (segunda declaração, mesma propriedade) | celua.txt:2531 |
| `Result` | Integer | If OnlyOneResult is used this will contain the address after a scan has finished | celua.txt:2532 |
| `Results` | {} | Returns an indexed table with all the found addresses 7.7+ (Fetching this will call waitTillDone() for you) | celua.txt:2533 |
| `CodePage` | boolean | (sem descrição na fonte) | celua.txt:2535 |
| `ScanOption` | TScanoption | one of : for first and next: `soExactValue`, `soValueBetween`, `soBiggerThan`, `soSmallerThan`. next can also use: `soIncreasedValue`, `soIncreasedValueBy`, `soDecreasedValue`, `soDecreasedValueBy`, `soChanged`, `soUnchanged` | celua.txt:2536 |
| `VariableType` | TVariableType | (sem descrição na fonte) | celua.txt:2537 |
| `VarType` | TVariableType | `^` (mesma coisa que `VariableType`) | celua.txt:2538 |
| `Roundingtype` | TRoundingType | (sem descrição na fonte; valores em celua.txt:2592–2594) | celua.txt:2539 |
| `Scanvalue` | string | Value to scan | celua.txt:2540 |
| `Scanvalue1` | string | `^` (mesma coisa que `Scanvalue`) | celua.txt:2541 |
| `Scanvalue2` | string | Secondary value to scan (e.g value between scan) | celua.txt:2542 |
| `Startaddress` | integer | (sem descrição na fonte) | celua.txt:2543 |
| `Stopaddress` | integer | (sem descrição na fonte) | celua.txt:2544 |
| `Hexadecimal` | boolean | (sem descrição na fonte) | celua.txt:2545 |
| `BinaryStringAsDecimal` | boolean | (sem descrição na fonte) | celua.txt:2546 |
| `UTF16` | boolean | (sem descrição na fonte) | celua.txt:2547 |
| `Casesensitive` | boolean | (sem descrição na fonte) | celua.txt:2548 |
| `Fastscanmethod` | TFastScanMethod | (sem descrição na fonte; valores não listados neste intervalo) | celua.txt:2549 |
| `Fastscanparameter` | string | (sem descrição na fonte) | celua.txt:2550 |
| `Customtype` | TCustomType | (sem descrição na fonte) | celua.txt:2551 |
| `ScanWritable` | TScanregionpreference | `'scanDontCare'`, `'scanExclude'`, `'scanInclude'` | celua.txt:2553 |
| `ScanExecutable` | TScanregionpreference | `'scanDontCare'`, `'scanExclude'`, `'scanInclude'` | celua.txt:2554 |
| `ScanCopyOnWrite` | TScanregionpreference | `'scanDontCare'`, `'scanExclude'`, `'scanInclude'` | celua.txt:2555 |
| `Percentage` | boolean | (sem descrição na fonte) | celua.txt:2557 |
| `CompareToSavedScan` | boolean | (sem descrição na fonte) | celua.txt:2558 |
| `SavedScanName` | string | (sem descrição na fonte) | celua.txt:2559 |

Nota: o intervalo 2506–2688 **não** documenta uma propriedade `Alignmenttype`; a alignment é passada como parâmetro de `firstScan` (celua.txt:2568, 2603–2608).

## Métodos do MemScan

### `setSpecialScanOptionsOverride({})` — celua.txt:2510
"Sets certain scan options that are usually only set in settings". Opções:
- `MEM_PRIVATE`: boolean - Scan memory owned by just the target process (celua.txt:2512)
- `MEM_IMAGE`: boolean - scan memory belonging to modules (celua.txt:2513)
- `MEM_MAPPED`: boolean - scan memory of files mapped in memory and accessed on demand (celua.txt:2514)

"Not setting an entry will make them revert back to the original state if they where previously set" (celua.txt:2516).

### `scan()` — celua.txt:2562
`scan(): Does either a first scan or next scan based on the given property values`

**Assinatura sem parâmetros.** O celua.txt **não** documenta `scan(start, stop, protectionflags, alignmenttype, alignmentparam)`. A variante com parâmetros é `firstScan(...)` (celua.txt:2568); veja abaixo.

### `firstScan()` — celua.txt:2563
`firstScan() : Does a first scan based on the given property values`

### `nextScan()` — celua.txt:2564
`nextScan() : Does a next scan based on the given property values`

### `newScan()` — celua.txt:2565
`newScan() : Clears the current results`

### `terminateScan(force:Boolean OPTIONAL)` — celua.txt:2566
"Tells the scanner you wish to stop the ongoing scan. If force is true, be more aggressive in killing the scan and wait up to 5 seconds"

### `firstScan(scanoption, vartype, roundingtype, input1, input2, startAddress, stopAddress, protectionflags, alignmenttype, "alignmentparam", isHexadecimalInput, isNotABinaryString, isunicodescan, iscasesensitive)` — celua.txt:2568

Assinatura exata na fonte (celua.txt:2568):

```
firstScan(scanoption, vartype, roundingtype, input1, input2 ,startAddress ,stopAddress ,protectionflags ,alignmenttype ,"alignmentparam" ,isHexadecimalInput ,isNotABinaryString, isunicodescan, iscasesensitive);
```

Descrição: "Does an initial scan." (celua.txt:2569). Parâmetros, literalmente:

- **`memscan`**: "The MemScan object created with createMemScan" (celua.txt:2570).
- **`scanOption`**: "Defines what type of scan is done. Valid values for firstscan are:" (celua.txt:2571)
  - `soUnknownValue`: Unknown initial value scan (celua.txt:2572)
  - `soExactValue`: Exact Value scan (celua.txt:2573)
  - `soValueBetween`: Value between scan (celua.txt:2574)
  - `soBiggerThan`: Bigger than ... scan (celua.txt:2575)
  - `soSmallerThan`: smaller than ... scan (celua.txt:2576)
- **`vartype`**: "Defines the variable type. Valid variable types are:" (celua.txt:2578) — lista completa em celua.txt:2579–2589 (ver seção "Tipos de variável aceitos").
- **`roundingtype`**: "Defined the way scans for exact value floating points are handled" (celua.txt:2591)
  - `rtRounded`: "Normal rounded scans. If exact value = "3" then it includes 3.0 to 3.49999999. If exact value is "3.0" it includes 3.00 to 3.0499999999" (celua.txt:2592)
  - `rtTruncated`: "Truncated algorithm. If exact value = "3" then it includes 3.0 to 3.99999999. If exact value is "3.0" it includes 3.00 to 3.099999999" (celua.txt:2593)
  - `rtExtremerounded`: "Rounded Extreme. If exact value = "3" then it includes 2.0000001 to 3.99999999. If exact value is "3.0" it includes 2.900000001 to 3.099999999" (celua.txt:2594)
- **`input1`**: "If required by the scanoption this is a string of the given variable type" (celua.txt:2596)
- **`input2`**: "If requires by the scanoption this is the secondary input" (celua.txt:2597)
- **`startAddress`**: "The start address to scan from. You want to set this to 0" (celua.txt:2599)
- **`stopAddress`**: "The address the scan should stop at. (You want to set this to 0xffffffffffffffff)" (celua.txt:2600)
- **`protectionflags`**: "See aobscan about protectionflags" (celua.txt:2602) — transcrição literal das linhas 841–847 abaixo.
- **`alignmenttype`**: "Scan alignment type. Valid options are:" (celua.txt:2603)
  - `fsmNotAligned`: No alignment check (celua.txt:2604)
  - `fsmAligned`: The address must be dividable by the value in alignmentparam (celua.txt:2605)
  - `fsmLastDigits`: The last digits of the address must end with the digits provided by alignmentparam (celua.txt:2606)
- **`alignmentparam`**: "String that holds the alignment parameter." (celua.txt:2608)
- **`isHexadecimalInput`**: "When true this will handle the input field as a hexadecimal string else decimal" (celua.txt:2610)
- **`isNotABinaryString`**: "When true and the varType is vtBinary this will handle the input field as a decimal instead of a binary string" (celua.txt:2611)
- **`isunicodescan`**: "When true and the vartype is vtString this will do a unicode (utf16) string scan else normal utf8 string" (celua.txt:2612)
- **`iscasesensitive`**: "When true and the vartype is vtString this check if the case matches" (celua.txt:2613)

#### protectionflags — transcrição literal (celua.txt:841–847)

```
protectionflags is a string.
  X=Executable W=Writable memory C=Copy On Write. Add a + to indicate that flag MUST be set and a - to indicate that that flag MUST NOT be set. (* sets it to don't care)
  Examples:
    +W-C = Writable memory exluding copy on write and doesn't care about the Executable flag
    +X-C-W = Find readonly executable memory
    +W = Finds all writable memory and don't care about copy on write or execute
    "" = Find everything (is the same as "*X*C*W" )
```

(linhas 841 a 847 do celua.txt)

#### alignmenttype / alignmentparam — atenção à contradição da própria documentação

O celua.txt descreve **alignmenttype de duas formas incompatíveis**:

- Em `MemScan.firstScan`, como strings `fsmNotAligned`, `fsmAligned`, `fsmLastDigits`, com o parâmetro em `alignmentparam` (celua.txt:2603–2606, 2608).
- Em `AOBScan` (para onde o próprio `firstScan` remete), como **inteiro**, transcrito literalmente (celua.txt:850–854):

```
alignmenttype is an integer:
  0=No alignment check
  1=Address must be dividable by alignmentparam
  2=Address must end with alignmentparam
alignmentparam is a string which either holds the value the addresses must be dividable by or what the last digits of the address must be
```

Ou seja: os dois vocabulários (`fsmAligned`/`fsmLastDigits` vs. `1`/`2`) descrevem o mesmo comportamento, e a fonte não resolve qual deles `firstScan` realmente espera. Um erro aqui tende a ser silencioso (o scan roda, mas com alinhamento diferente do pretendido).

### `nextScan(scanoption, roundingtype, input1, input2, isHexadecimalInput, isNotABinaryString, isunicodescan, iscasesensitive, ispercentagescan, savedresultname OPTIONAL)` — celua.txt:2618

Assinatura exata na fonte (celua.txt:2618):

```
nextScan(scanoption, roundingtype, input1,input2, isHexadecimalInput, isNotABinaryString, isunicodescan, iscasesensitive, ispercentagescan, savedresultname OPTIONAL);
```

Descrição: "Does a next scan based on the current addresslist and values of the previous scan or values of a saved scan" (celua.txt:2619). Parâmetros, literalmente:

- **`memscan`**: "The MemScan object that has previously done a first scan" (celua.txt:2620)
- **`scanoption`** (celua.txt:2621):
  - `soExactValue`: Exact Value scan (celua.txt:2622)
  - `soValueBetween`: Value between scan (celua.txt:2623)
  - `soBiggerThan`: Bigger than ... scan (celua.txt:2624)
  - `soSmallerThan`: smaller than ... scan (celua.txt:2625)
  - `soIncreasedValue`: Increased value scan (celua.txt:2626)
  - `soIncreasedValueBy`: Increased value by scan (celua.txt:2627)
  - `soDecreasedValue`: Decreased value scan (celua.txt:2628)
  - `soDecreasedValueBy`: Decreased value by scan (celua.txt:2629)
  - `soChanged`: Changed value scan (celua.txt:2630)
  - `soUnchanged`: Unchanged value scan (celua.txt:2631)
- **`roundingtype`** (celua.txt:2633): `rtRounded` (celua.txt:2634), `rtTruncated` (celua.txt:2635), `rtExtremerounded` (celua.txt:2636) — textos idênticos aos do firstScan, com "Truncated algoritm" no lugar de "algorithm".
- **`input1`**: "If required by the scanoption this is a string of the given variable type" (celua.txt:2638)
- **`input2`**: "If requires by the scanoption this is the secondary input" (celua.txt:2639)
- **`isHexadecimalInput`**: "When true this will handle the input field as a hexadecimal string else decimal" (celua.txt:2641)
- **`isNotABinaryString`**: "When true and the varType is vtBinary this will handle the input field as a decimal instead of a binary string" (celua.txt:2642)
- **`isunicodescan`**: "When true and the vartype is vtString this will do a unicode (utf16) string scan else normal utf8 string" (celua.txt:2643)
- **`iscasesensitive`**: "When true and the vartype is vtString this check if the case matches" (celua.txt:2644)
- **`ispercentage`**: "When true and the scanoption is of type soValueBetween, soIncreasedValueBy or soDecreasedValueBy will cause CE to do a precentage scan instead of a normal value scan" (celua.txt:2645)
- **`savedResultName`**: "String that holds the name of a saved result list that should be compared against. First scan is called "FIRST"" (celua.txt:2646)

### `waitTillDone(timeout OPTIONAL)` — celua.txt:2649
`waitTillDone(timeout OPTIONAL): boolean - Waits for the memscan thread(s) to finish scanning. Always use this (or Results). Returns false if timeout triggered`

### `saveCurrentResults(name)` — celua.txt:2650
"Save the current scanresults to a unique name for this memscan. This save can be used to compare against in a subsequent next scan"

### `getSavedResultList()` — celua.txt:2651
"Returns an indexed table of all the saved results (strings)"

### `getSavedResultHandler(name)` — celua.txt:2652
"Gets the 'SavedResultHandler' object with this name (nil on failure)"

### `getAttachedFoundlist()` — celua.txt:2653
"Returns a FoundList object if one is attached to this scanresults. Returns nil otherwise"

### `setOnlyOneResult(state)` — celua.txt:2656
"If set to true before you start a scan, this will cause the scanner to only return one result. Note that it does not work with a foundlist"

### `getOnlyResult()` — celua.txt:2657
"Only works if returnOnlyOneResult is true. Returns nil if not found, else returns the address that was found (integer)"

### `getProgress()` — celua.txt:2658
"returns a table with fields: TotalAddressesToScan, CurrentlyScanned, ResultsFound"

## Tipos de variável aceitos (vartype)

Nomes exatos, na ordem da fonte (celua.txt:2579–2589):

| vartype | Observação na fonte | Linha |
|---|---|---|
| `vtByte` | — | celua.txt:2579 |
| `vtWord` | 2 bytes | celua.txt:2580 |
| `vtDword` | 4 bytes | celua.txt:2581 |
| `vtQword` | 8 bytes | celua.txt:2582 |
| `vtSingle` | float | celua.txt:2583 |
| `vtDouble` | — | celua.txt:2584 |
| `vtString` | — | celua.txt:2585 |
| `vtByteArray` | — | celua.txt:2586 |
| `vtGrouped` | — | celua.txt:2587 |
| `vtBinary` | — | celua.txt:2588 |
| `vtAll` | — | celua.txt:2589 |

O tipo de `VariableType`/`VarType` é `TVariableType` (celua.txt:2537–2538). Não há, neste intervalo, tabela de valores para `TFastScanMethod` nem para `TCustomType`.

## Opções de scan (scanoption)

Valores exatos, com onde são válidos:

| scanoption | firstScan | nextScan | Descrição na fonte | Linha |
|---|---|---|---|---|
| `soUnknownValue` | sim | não listado | Unknown initial value scan | celua.txt:2572 |
| `soExactValue` | sim | sim | Exact Value scan | celua.txt:2573, 2622 |
| `soValueBetween` | sim | sim | Value between scan | celua.txt:2574, 2623 |
| `soBiggerThan` | sim | sim | Bigger than ... scan | celua.txt:2575, 2624 |
| `soSmallerThan` | sim | sim | smaller than ... scan | celua.txt:2576, 2625 |
| `soIncreasedValue` | não listado | sim | Increased value scan | celua.txt:2626 |
| `soIncreasedValueBy` | não listado | sim | Increased value by scan | celua.txt:2627 |
| `soDecreasedValue` | não listado | sim | Decreased value scan | celua.txt:2628 |
| `soDecreasedValueBy` | não listado | sim | Decreased value by scan | celua.txt:2629 |
| `soChanged` | não listado | sim | Changed value scan | celua.txt:2630 |
| `soUnchanged` | não listado | sim | Unchanged value scan | celua.txt:2631 |

A propriedade `ScanOption` (tipo `TScanoption`) resume: "for first and next: soExactValue, soValueBetween, soBiggerThan, soSmallerThan. next can also use: soIncreasedValue, soIncreasedValueBy, soDecreasedValue, soDecreasedValueBy, soChanged, soUnchanged" (celua.txt:2536).

## Propriedades e métodos do FoundList

"The foundlist is an object that opens the current memscan's result file and provides an interface for reading out the addresses" (celua.txt:2662). Criado por `createFoundList(memscan)` (celua.txt:2664).

### Propriedades (celua.txt:2666–2670)

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Count` | integer | Number of results found | celua.txt:2667 |
| `Address[index]` | string | Returns the address as a string at the given index (index starts at 0) | celua.txt:2668 |
| `Value[index]` | string | Returns the value as a string at the given index (index starts at 0) | celua.txt:2669 |
| `[index]` | string | Same as Address (index starts at 0) | celua.txt:2670 |

### Métodos (celua.txt:2672–2677)

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `initialize` | `initialize()` | Call this when a memscan has finished scanning. This will open the results for reading | celua.txt:2673 |
| `deinitialize` | `deinitialize()` | Release the results | celua.txt:2674 |
| `getCount` | `getCount()` | (sem descrição na fonte) | celua.txt:2675 |
| `getAddress` | `getAddress(index)` | Returns the address as a string | celua.txt:2676 |
| `getValue` | `getValue(index)` | Returns the value as a string | celua.txt:2677 |

O `destroy()` (celua.txt:975) destrói o objeto. A declaração da classe na fonte é apenas `FoundList Class` (celua.txt:2661), sem a anotação `(Inheritance: Object)` que o `MemScan` traz (celua.txt:2506); o caminho de liberação **explicitamente documentado** para o FoundList neste intervalo é `deinitialize()` (celua.txt:2674).

### SavedResultHandler — celua.txt:2680–2683

Classe listada sem propriedades. Métodos:

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getStringFromAddress` | `getStringFromAddress(address, hexadecimal:boolean OPTIONAL, signed: boolean OPTIONAL)` | Returns the value in string format at the given address | celua.txt:2683 |

Obtido por `MemScan.getSavedResultHandler(name)` — "nil on failure" (celua.txt:2652).

## Pegadinhas verificadas

- `ms.ErrorString` vem string VAZIA quando deu certo; só cheque erro se ela não for vazia. A fonte apenas diz "contains a string containing an error if an error occured" (celua.txt:2530) — ou seja, a ausência de erro não é sinalizada de outra forma.
- `ms.Results` e `ms.FoundList` não são equivalentes — prefira `getFoundList()` e sempre cheque se voltou `nil`. Na fonte, `Results` é "an indexed table with all the found addresses 7.7+" e força `waitTillDone()` por você (celua.txt:2533), enquanto `FoundList` é "The foundlist currently attached to this memscan object" (celua.txt:2527) e `getAttachedFoundlist()` "Returns a FoundList object if one is attached to this scanresults. Returns nil otherwise" (celua.txt:2653). São objetos de naturezas diferentes: um é tabela, o outro é o leitor do arquivo de resultados.
- Um `FoundList` pode vir `nil` se o scan ainda não terminou; chame `waitTillDone()` antes. A fonte é explícita: "Waits for the memscan thread(s) to finish scanning. Always use this (or Results)" (celua.txt:2649), e `initialize()` só deve ser chamado "when a memscan has finished scanning" (celua.txt:2673). `getAttachedFoundlist()` pode devolver `nil` (celua.txt:2653).
- `count` é o total encontrado; ao ler endereços, itere de `0` a `count-1` (o FoundList é indexado a partir de 0, diferente de outras tabelas do CE). A fonte repete "(index starts at 0)" em `Address[index]` (celua.txt:2668), `Value[index]` (celua.txt:2669) e `[index]` (celua.txt:2670); `Count` é "Number of results found" (celua.txt:2667).
- Sempre libere o objeto depois (`ms.destroy()` / `fl.destroy()`), senão o CE acumula scans vivos e o uso de memória cresce. As ferramentas documentadas: `FoundList.deinitialize()` "Release the results" (celua.txt:2674), `MemScan.newScan()` "Clears the current results" (celua.txt:2565) e `destroy()` "Destroys the object" (celua.txt:975, herdado por `MemScan` conforme celua.txt:2506). Para abortar um scan em andamento use `terminateScan(force)` (celua.txt:2566).
- Runtime é variável: um scan simples em ~1000 regiões levou ~1 segundo e achou ~110 resultados, mas valores comuns podem achar centenas de milhares — limite sempre a quantidade de resultados que você vai materializar. A fonte dá os meios de medir/limitar: `getProgress()` devolve `TotalAddressesToScan`, `CurrentlyScanned`, `ResultsFound` (celua.txt:2658, e o mesmo trio em `OnGuiUpdate`, celua.txt:2526); `FoundCount` é "the number of results found in the last scan (7.7+)" (celua.txt:2520, repetido em celua.txt:2531); e para não materializar nada, `OnlyOneResult`/`setOnlyOneResult(state)` param no primeiro resultado (celua.txt:2528, 2656) — lembrando que `IsUnique` usa múltiplas threads e pode devolver endereço aleatório se o valor não for único (celua.txt:2529).
