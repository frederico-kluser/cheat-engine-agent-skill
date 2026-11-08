# API CELua — Address List, MemoryRecord e estruturas

> Fonte: `C:\Program Files\Cheat Engine\celua.txt`, linhas 2297–2505 e 2854–2970 (CE 7.7).
> Para o texto integral, abra o celua.txt na linha indicada.
> As pegadinhas remetem a identificadores globais que estão **fora** desses intervalos; nesses casos a linha exata do celua.txt é citada (ex.: `getAddressList()` em celua.txt:774, `saveTable`/`loadTable` em celua.txt:32–35, `SymbolList` em celua.txt:3523–3563).

## Addresslist (a lista de endereços do CE)

`Addresslist Class: (Inheritance: Panel->WinControl->Control->Component->Object)` (celua.txt:2455).

A instância da lista principal do CE vem da função global `getAddressList()`: "Returns the cheat table addresslist object" (celua.txt:774).

### Propriedades (celua.txt:2456–2475)

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `LoadedTableVersion` | integer | Returns the tableVersion of the last loaded table | celua.txt:2457 |
| `Count` | Integer | The number of records in the table | celua.txt:2458 |
| `SelCount` | integer | The number of records that are selected | celua.txt:2459 |
| `SelectedRecord` | MemoryRecord | The main selected record | celua.txt:2460 |
| `MemoryRecord[]` | MemoryRecord | Array to access the individial memory records | celua.txt:2461 |
| `List` | — | The internal Treeview control of the addresslist. It contains special MemoryRecordTreeNodes which hold a memrec variable that leads directly to the memoryrecord. (symbol link to node.data) | celua.txt:2462 |
| `[]` | MemoryRecord | Default accessor | celua.txt:2463 |
| `CheckboxActiveSelectedColor` | color | (sem descrição na fonte) | celua.txt:2465 |
| `CheckboxActiveColor` | color | (sem descrição na fonte) | celua.txt:2466 |
| `CheckboxSelectedColor` | color | (sem descrição na fonte) | celua.txt:2467 |
| `CheckboxColor` | color | (sem descrição na fonte) | celua.txt:2468 |
| `SelectedBackgroundColor` | color | (sem descrição na fonte) | celua.txt:2469 |
| `SelectedSecondaryBackgroundColor` | color | (sem descrição na fonte) | celua.txt:2470 |
| `ExpandSignColor` | color | (sem descrição na fonte) | celua.txt:2471 |
| `IncreaseArrowColor` | color | (sem descrição na fonte) | celua.txt:2472 |
| `DecreaseArrowColor` | color | (sem descrição na fonte) | celua.txt:2473 |
| `MouseHighlightedRecord()` | — | Returns the memoryrecord that the mouse points at. nil if nothing (listado sob "properties" na fonte) | celua.txt:2475 |

### Eventos (celua.txt:2478–2482)

| Evento | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `OnDescriptionChange` | `function(addresslist,memrec):boolean` | called when the user initiates a description column change on a record. Return true if you handle it, false for normal behaviour | celua.txt:2478 |
| `OnAddressChange` | `function(addresslist,memrec):boolean` | called when the user initiates an address column change on a record. Return true if you handle it, false for normal behaviour | celua.txt:2479 |
| `OnTypeChange` | `function(addresslist,memrec):boolean` | called when the user initiates a type column change on a record. Return true if you handle it, false for normal behaviour | celua.txt:2480 |
| `OnValueChange` | `function(addresslist,memrec):boolean` | called when the user initiates a value column change on a record. Return true if you handle it, false for normal behaviour | celua.txt:2481 |
| `OnAutoAssemblerEdit` | `function(addresslist,memrec)` | Called when the user initiates a memoryrecord AA script edit. This function will be responsible for changing the memory record | celua.txt:2482 |

### Métodos (celua.txt:2484–2503)

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getCount` | `getCount()` | (sem descrição na fonte) | celua.txt:2485 |
| `getMemoryRecord` | `getMemoryRecord(index)` | (sem descrição na fonte) | celua.txt:2486 |
| `getMemoryRecordByDescription` | `getMemoryRecordByDescription(description)` | returns a MemoryRecord object | celua.txt:2487 |
| `getMemoryRecordsWithDescription` | `getMemoryRecordsWithDescription(description)` | returns a table with MemoryRecords that have the same description (slower than when using unique names) | celua.txt:2488 |
| `getMemoryRecordByID` | `getMemoryRecordByID(ID)` | (sem descrição na fonte) | celua.txt:2489 |
| `createMemoryRecord` | `createMemoryRecord()` | creates an generic cheat table entry and add it to the list | celua.txt:2490 |
| `getSelectedRecords` | `getSelectedRecords()` | Returns a table containing all the selected records | celua.txt:2492 |
| `doDescriptionChange` | `doDescriptionChange()` | Will show the GUI window to change the description of the selected entry | celua.txt:2494 |
| `doAddressChange` | `doAddressChange()` | Will show the GUI window to change the address of the selected entry | celua.txt:2495 |
| `doTypeChange` | `doTypeChange()` | Will show the GUI window to change the type of the selected entries | celua.txt:2496 |
| `doValueChange` | `doValueChange()` | Will show the GUI window to change the value of the selected entries | celua.txt:2497 |
| `getSelectedRecord` | `getSelectedRecord()` | Gets the main selected memoryrecord | celua.txt:2499 |
| `setSelectedRecord` | `setSelectedRecord(memrec)` | Sets the currently selected memoryrecord. This will unselect all other entries | celua.txt:2500 |
| `disableAllWithoutExecute` | `disableAllWithoutExecute()` | Disables all memory records without executing their [Disable] section | celua.txt:2502 |
| `rebuildDescriptionCache` | `rebuildDescriptionCache()` | Rebuilds the description to record lookup table | celua.txt:2503 |

### Itens pedidos que NÃO existem na classe Addresslist

O intervalo 2455–2505 do celua.txt **não** documenta `freeze`, `unfreeze`, `saveTable`, `loadTable` nem `getSymbolList` como membros da Addresslist. Onde essas coisas de fato aparecem no arquivo:

- **Travar/destravar valor**: pela propriedade `Active` do MemoryRecord — "Set to true to activate/freeze, false to deactivate/unfreeze" (celua.txt:2361). Não há método `freeze()`/`unfreeze()` documentado para `MemoryRecord` nem para `Addresslist` nos intervalos 2297–2505 / 2854–2970. `AllowIncrease`/`AllowDecrease` são zerados pelo unfreeze: "unfreeze will reset it to false" (celua.txt:2365–2366).
- **Salvar/carregar tabela**: são funções **globais**, não métodos da lista: `loadTable(filename, merge OPTIONAL)` e `loadTable(stream, merge OPTIONAL, ignoreluascriptdialog BOOLEAN)` (celua.txt:32–33); `saveTable(filename, protect OPTIONAL, dontDeactivateDesignerForms OPTIONAL)` e `saveTable(stream, dontDeactivateDesignerForms OPTIONAL)` (celua.txt:34–35).
- **getSymbolList**: ver a pegadinha correspondente na última seção — não é global; existe como método da classe `SymbolList` (celua.txt:3563), e os globais relacionados são `createSymbolList()`/`createSymbolList(initlist, name OPTIONAL)` e `getMainSymbolList()` (celua.txt:3535–3537).

## MemoryRecord (uma entrada da lista)

`MemoryRecord Class:` — "The memoryrecord objects are the entries you see in the addresslist" (celua.txt:2328–2329).

### Propriedades (celua.txt:2331–2411)

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `ID` | Integer | Unique ID | celua.txt:2332 |
| `Index` | Integer | The index ID for this record. 0 is top. (ReadOnly) | celua.txt:2333 |
| `Description` | string | The description of the memory record | celua.txt:2334 |
| `Address` | string | Get/set the interpretable address string. Useful for simple address settings. | celua.txt:2335 |
| `AddressString` | string | Get the address string shown in CE (ReadOnly) | celua.txt:2336 |
| `OffsetCount` | integer | The number of offsets. Set to 0 for a normal address | celua.txt:2337 |
| `Offset[]` | integer | Array to access each offset | celua.txt:2338 |
| `OffsetText[]` | string | Array to access each offset using the interpretable text style | celua.txt:2339 |
| `CurrentAddress` | integer | The address the memoryrecord points to | celua.txt:2341 |
| `VarType` | ValueType (string) | The variable type of this record. See vtByte to vtCustom | celua.txt:2342 |
| `Type` | ValueType (number) | The variable type of this record. See vtByte to vtCustom | celua.txt:2343 |
| `CustomTypeName` | String | If the type is vtCustom this will contain the name of the CustomType | celua.txt:2356 |
| `Script` | String | If the type is vtAutoAssembler this will contain the auto assembler script | celua.txt:2357 |
| `Value` | string | The value in stringform. | celua.txt:2358 |
| `NumericalValue` | number | The value in numerical form. nil if it can not be parsed to a number | celua.txt:2359 |
| `Selected` | boolean | Set to true if selected (ReadOnly) | celua.txt:2360 |
| `Active` | boolean | Set to true to activate/freeze, false to deactivate/unfreeze | celua.txt:2361 |
| `Color` | integer | (sem descrição na fonte) | celua.txt:2362 |
| `ShowAsHex` | boolean | Self explanatory | celua.txt:2363 |
| `ShowAsSigned` | boolean | Self explanatory | celua.txt:2364 |
| `AllowIncrease` | boolean | Allow value increasing, unfreeze will reset it to false | celua.txt:2365 |
| `AllowDecrease` | boolean | Allow value decreasing, unfreeze will reset it to false | celua.txt:2366 |
| `Collapsed` | boolean | Set to true to collapse this record or false to expand it. Use expand/collapse methods for recursive operations. | celua.txt:2367 |
| `IsGroupHeader` | boolean | Set to true if the record was created as a Group Header with no address or value info. | celua.txt:2368 |
| `IsAddressGroupHeader` | boolean | Set to true if the record was created as a Group Header with address. | celua.txt:2369 |
| `IsReadable` | boolean | Set to false if record contains an unreadable address. NOTE: This property will not be set until the value property is accessed at least once. (ReadOnly) | celua.txt:2370 |
| `Selected` | boolean | (segunda declaração, sem descrição) | celua.txt:2371 |
| `Options` | String set | a string enclosed by square brackets filled with the options seperated by a comma. Valid options are: `moHideChildren`, `moActivateChildrenAsWell`, `moDeactivateChildrenAsWell`, `moRecursiveSetValue`, `moAllowManualCollapseAndExpand`, `moManualExpandCollapse`, `moAlwaysHideChildren` | celua.txt:2372 |
| `DropDownLinked` | boolean | if dropdown list refers to list of another memory record eg. (memrec name) | celua.txt:2374 |
| `DropDownLinkedMemrec` | string | Description of linked memrec or emptystring if not linked | celua.txt:2375 |
| `DropDownList` | StringList | list of "value:description" lines, lists are still separate objects when linked, read-write | celua.txt:2376 |
| `DropDownReadOnly` | boolean | true if 'Disallow manual user input' is set | celua.txt:2377 |
| `DropDownDescriptionOnly` | boolean | self explanatory | celua.txt:2378 |
| `DisplayAsDropDownListItem` | boolean | self explanatory | celua.txt:2379 |
| `DropDownCount` | integer | equivalent to `.DropDownList.Count` | celua.txt:2380 |
| `DropDownValue[index]` | — | Array to access values in DropDownList (ReadOnly) | celua.txt:2381 |
| `DropDownDescription[index]` | — | Array to access Descriptions in DropDownList (ReadOnly) | celua.txt:2382 |
| `Count` | — | Number of children | celua.txt:2386 |
| `Child[index]` | — | Array to access the child records | celua.txt:2387 |
| `[index]` | — | `[index] = Child[index]` | celua.txt:2388 |
| `Parent` | MemoryRecord | The parent of the memory record | celua.txt:2389 |
| `HotkeyCount` | integer | Number of hotkeys attached to this memory record | celua.txt:2391 |
| `Hotkey[]` | — | Array to index the hotkeys | celua.txt:2392 |
| `Async` | Boolean | Set to true if activating this entry will be asynchronious. (only for AA/Lua scripts) | celua.txt:2394 |
| `AsyncProcessing` | Boolean | True when async is true and it's being processed | celua.txt:2395 |
| `AsyncProcessingTime` | qword | The time that it has been processing in milliseconds | celua.txt:2396 |
| `HasMouseOver` | boolean | True if the mouse is currently over it | celua.txt:2398 |
| `OnActivate` | function(memoryrecord,before,currentstate):boolean | The function to call when the memoryrecord will change (or changed) Active to true. If before is true, not returning true will cause the activation to stop. | celua.txt:2400 |
| `OnDeactivate` | function(memoryrecord,before,currentstate):boolean | The function to call when the memoryrecord will change (or changed) Active to false. If before is true, not returning true will cause the deactivation to stop. | celua.txt:2401 |
| `OnActivationFailure` | function(memoryrecord,reason,reasonText) | Called when activating a record fails. You can use this to inform the user of an issue, or adjust the table/script and try again. Return true when you wish to try again. Warning: Watch out for infinite loops... | celua.txt:2402 |
| `OnDestroy` | function() | Called when the memoryrecord is destroyed. | celua.txt:2407 |
| `OnGetDisplayValue` | function(memoryrecord,valuestring):boolean,string | This function gets called when rendering the value of a memory record. Return true and a new string to override the value shown | celua.txt:2408 |
| `OnValueChanged` | function(memoryrecord, oldvalue, newvalue): | This function gets called whenever the value of a memory record has changed | celua.txt:2409 |
| `OnValueChangedByUser` | function(memoryrecord, oldvalue, newvalue): | This function gets called whenever the value of a memory record has changed by the user | celua.txt:2410 |
| `DontSave` | boolean | Don't save this memoryrecord and it's children | celua.txt:2411 |

Valores de `reason` em `OnActivationFailure` (celua.txt:2403): `afInaccessible`, `afGenericAutoAssembler`, `afAllocateFailure`, `afSyntaxError`, `afSyntaxErrorInLua`, `afStructureDefinitionError`, `afAssertFailure`, `afAOBModuleNotFound`, `afAOBNotFound`, `afIncludeNotFound`, `afDLLInjectionFailure`; "reasonText is a description provided by cheat engine" (celua.txt:2404).

#### Sub-propriedades dependentes do tipo (celua.txt:2344–2354)

"If the type is vtString then the following properties are available:" (celua.txt:2344)
- `String.Size`: Number of characters in the string (celua.txt:2345)
- `String.Unicode`: boolean (celua.txt:2346)
- `String.Codepage`: boolean (celua.txt:2347)

"If the type is vtBinary then the following properties are available" (celua.txt:2349)
- `Binary.Startbit`: First bit to start reading from (celua.txt:2350)
- `Binary.Size`: Number of bits (celua.txt:2351)

"If the type is vtByteArray then the following properties are available" (celua.txt:2353)
- `Aob.Size`: Number of bytes (celua.txt:2354)

### Métodos (celua.txt:2413–2437)

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getDescription` | `getDescription()` | (sem descrição na fonte) | celua.txt:2414 |
| `setDescription` | `setDescription()` | (sem descrição na fonte) | celua.txt:2415 |
| `getAddress` | `getAddress()` | Returns the interpretable addressstring of this record. If it is a pointer, it returns a second result as a table filled with the offsets | celua.txt:2416 |
| `setAddress` | `setAddress(string)` | Sets the interpretable address string, and if offsets are provided make it a pointer | celua.txt:2417 |
| `getOffsetCount` | `getOffsetCount()` | Returns the number of offsets for this memoryrecord | celua.txt:2419 |
| `setOffsetCount` | `setOffsetCount(integer)` | Lets you set the number of offsets | celua.txt:2420 |
| `getOffset` | `getOffset(index)` | Gets the offset at the given index | celua.txt:2422 |
| `setOffset` | `setOffset(index, value)` | Sets the offset at the given index | celua.txt:2423 |
| `getCurrentAddress` | `getCurrentAddress()` | Returns the current address as an integer (the final result of the interpretable address and pointer offsets) | celua.txt:2425 |
| `appendToEntry` | `appendToEntry(memrec)` | Appends the current memory record to the given memory record | celua.txt:2427 |
| `getHotkey` | `getHotkey(index)` | Returns the hotkey from the hotkey array | celua.txt:2429 |
| `getHotkeyByID` | `getHotkeyByID(integer)` | Returns the hotkey with the given id | celua.txt:2430 |
| `reinterpret` | `reinterpret()` | (sem descrição na fonte) | celua.txt:2432 |
| `createHotkey` | `createHotkey({keys}, action, value OPTIONAL, description OPTIONAL)` | Returns a hotkey object | celua.txt:2433 |
| `disableWithoutExecute` | `disableWithoutExecute()` | Sets the entry to disabled without executing the disable section | celua.txt:2435 |
| `beginEdit` | `beginEdit()` | Call when you wish to take a long time to edit a record. (e.g external editor) It prevents the record from getting deleted | celua.txt:2436 |
| `endEdit` | `endEdit()` | to mark the end of your long edit sequence | celua.txt:2437 |

### Eventos globais (celua.txt:2439–2451)

- `function onMemRecPreExecute(memoryrecord, newstate BOOLEAN):` — "If above function is defined it will be called before action* has been performed. Active property is about to change to newState." (celua.txt:2440–2442)
- `function onMemRecPostExecute(memoryrecord, newState BOOLEAN, succeeded BOOLEAN):` — "If above function is defined it will be called after action*. Active property was supposed to change to newState. If 'succeeded' is true it means that Active state has changed and is newState." (celua.txt:2444–2447)
  - "newState and succeeded are read only." (celua.txt:2449)
  - "*action can be: running auto assembler script (ENABLE or DISABLE section), freezing and unfreezing." (celua.txt:2451)

### Automação essencial: criar uma entrada, apontar para um endereço e travar o valor

Somente com o que a fonte documenta (nenhum passo inventado):

1. **Criar a entrada**: `getAddressList().createMemoryRecord()` — "creates an generic cheat table entry and add it to the list" (celua.txt:2490, 774).
2. **Apontar para um endereço**: `memrec.Address = "..."` ("Get/set the interpretable address string. Useful for simple address settings.", celua.txt:2335) ou `memrec.setAddress(string)` ("Sets the interpretable address string, and if offsets are provided make it a pointer", celua.txt:2417). Para endereços com offsets, use `setOffsetCount(integer)` (celua.txt:2420) + `setOffset(index, value)` (celua.txt:2423), ou passe tudo por `setAddress`.
3. **Conferir o endereço efetivo**: `getCurrentAddress()` — "Returns the current address as an integer (the final result of the interpretable address and pointer offsets)" (celua.txt:2425).
4. **Travar o valor**: `memrec.Active = true` — "Set to true to activate/freeze, false to deactivate/unfreeze" (celua.txt:2361). Para travar com folga de subida/descida, `AllowIncrease`/`AllowDecrease` (celua.txt:2365–2366).
5. **Definir o valor**: `memrec.Value` — "The value in stringform." (celua.txt:2358); leitura numérica por `NumericalValue` — "nil if it can not be parsed to a number" (celua.txt:2359).
6. **Definir o tipo**: `Type` (número) ou `VarType` (string) — "See vtByte to vtCustom" (celua.txt:2342–2343).
7. **Ler/observar**: `IsReadable` só é preenchido depois que `Value` for acessado ao menos uma vez — "NOTE: This property will not be set until the value property is accessed at least once. (ReadOnly)" (celua.txt:2370).
8. **Remover o que criou**: a fonte documenta `OnDestroy` no record — "Called when the memoryrecord is destroyed." (celua.txt:2407) — e `destroy()` na classe base `Object` ("Destroys the object", celua.txt:975). Não há, nos intervalos 2297–2505 / 2854–2970, um método `delete()`/`remove()` de MemoryRecord na Addresslist.

## MemoryRecordHotkey

`MemoryRecordHotkey Class: (Inheritance: object)` — "The memoryrecord hotkey class is mainly readonly with the exception of the event properties to be used to automatically create trainers" / "Use the generic hotkey class if you wish to create your own hotkeys" (celua.txt:2297–2299).

**Quando usar em vez do GenericHotkey**: esta classe é a representação do hotkey **preso a um MemoryRecord** (tem `Owner: MemoryRecord` e a propriedade `action` que já executa operações da entrada), e é "mainly readonly". A própria fonte manda usar a classe **generic hotkey** quando você quiser **criar seus próprios hotkeys** (celua.txt:2299). Ou seja: use MemoryRecordHotkey para hotkeys que ativam/desativam/alteram o valor de uma entrada existente (por exemplo, ao montar um trainer); use a classe genérica para hotkeys arbitrários.

### Propriedades (celua.txt:2301–2321)

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Owner` | MemoryRecord | The memoryrecord this hotkey belongs to (ReadOnly) | celua.txt:2302 |
| `Keys` | Table | Table containing the keys(combination) for this hotkey | celua.txt:2303 |
| `action` | integer | The action that should happen when this hotkey triggers (valores em celua.txt:2305–2312) | celua.txt:2304 |
| `value` | string | Value used depending on what kind of hotkey is used | celua.txt:2313 |
| `ID` | integer | Unique id of this hotkey (ReadOnly) | celua.txt:2314 |
| `Active` | boolean | True if it's hotkey will be handled, false if this hotkey is ignored | celua.txt:2315 |
| `Description` | string | The description of this hotkey | celua.txt:2316 |
| `HotkeyString` | string | The hotkey formatted as a string (ReadOnly) | celua.txt:2317 |
| `ActivateSound` | string | Tablefile name of a WAV file inside the table which will get played on activate events | celua.txt:2318 |
| `DeactivateSound` | string | Tablefile name of a .WAV file inside the table which will get played on deactivate events | celua.txt:2319 |
| `OnHotkey` | function(sender) | Function to be called when a hotkey has just been pressed | celua.txt:2320 |
| `OnPostHotkey` | function(sender) | Function to be called when a hotkey has been pressed and the action has been performed | celua.txt:2321 |

### Valores de `action` (celua.txt:2305–2312)

| Constante | Valor | O que faz | Linha |
|---|---|---|---|
| `mrhToggleActivation` | 0 | Toggles between active/deactive | celua.txt:2305 |
| `mrhToggleActivationAllowIncrease` | 1 | Toggles between active/deactive. Allows increase when active | celua.txt:2306 |
| `mrhToggleActivationAllowDecrease` | 2 | Toggles between active/deactive. Allows decrease when active | celua.txt:2307 |
| `mrhActivate` | 3 | Sets the state to active | celua.txt:2308 |
| `mrhDeactivate` | 4 | Sets the state to deactive | celua.txt:2309 |
| `mrhSetValue` | 5 | Sets a specific value to the value properyy (see value) | celua.txt:2310 |
| `mrhIncreaseValue` | 6 | Increases the current value with the value property (see value) | celua.txt:2311 |
| `mrhDecreaseValue` | 7 | Decreases the current value with the value property (see value) | celua.txt:2312 |

### Métodos (celua.txt:2324–2325)

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `doHotkey` | `doHotkey` | Executes the hotkey as if it got triggered by the keyboard | celua.txt:2325 |

Como obter um hotkey de um record: `MemoryRecord.getHotkey(index)` — "Returns the hotkey from the hotkey array" (celua.txt:2429) — e `MemoryRecord.getHotkeyByID(integer)` — "Returns the hotkey with the given id" (celua.txt:2430). Para criar: `MemoryRecord.createHotkey({keys}, action, value OPTIONAL, description OPTIONAL)` — "Returns a hotkey object" (celua.txt:2433). Contagem: `HotkeyCount` (celua.txt:2391) e o array `Hotkey[]` (celua.txt:2392).

## Estruturas (Structure / StructureElement)

### Funções globais relacionadas a Structure (celua.txt:2902–2907)

| Função | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getStructureCount` | `getStructureCount()` | Returns the number of Global structures. (Global structures are the visible structures) | celua.txt:2903 |
| `getStructure` | `getStructure(index)` | Returns the Structure object at the given index | celua.txt:2904 |
| `getStructure` | `getStructure(name)` | Returns the Structure object with the given name (Also finds internal types) Case sensitive | celua.txt:2905 |
| `createStructure` | `createStructure(name)` | Returns an empty structure object (Not yet added to the Global list. Call structure.addToGlobalStructureList manually) | celua.txt:2906 |
| `createStructureFromName` | `createStructureFromName(string)` | If PDB files are loaded this will create a structure with that name if it can be found. (Called by CE's structure dissect if ChildClassName is set. Can be overriden) | celua.txt:2907 |

### StructureFrm (a janela de estrutura)

`StructureFrm class:` (celua.txt:2854). Criada por `createStructureForm(address, groupname OPTIONAL, structurename OPTIONAL)` (celua.txt:2855); enumerável por `enumStructureForms() : returns a table of StructureFrm objects (can be useful for finding a structure window with the wanted structure)` (celua.txt:2856).

**Propriedades (celua.txt:2859–2867)**

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `MainStruct` | structure | The currently selected structure | celua.txt:2860 |
| `ColumnCount` | integer | the number of columns (columns=address) | celua.txt:2862 |
| `Column[index]` | structColumn | Fetches a structColumn object from the structure form | celua.txt:2863 |
| `GroupCount` | integer | The number of groups | celua.txt:2865 |
| `Group[index]` | structGroup | Fetches a structGroup object from the structure form | celua.txt:2866 |
| `OnStatusbarUpdate(function(notificationbar))` | — | Called when the statusbar gets updated | celua.txt:2867 |

**Métodos (celua.txt:2871–2875)**

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `structChange` | `structChange()` | Forces a refresh | celua.txt:2872 |
| `addColumn` | `addColumn()` | Adds a new column in the currently focuses group and returns it's structColumn object | celua.txt:2873 |
| `addGroup` | `addGroup()` | Adds a new group and returns the structGroup object | celua.txt:2874 |
| `getSelectedStructElement` | `getSelectedStructElement()` | Returns the currently selected StructureElement , and as second result a table containing an indexed list continaing 'struct', and 'element' describing the path to the base | celua.txt:2875 |

### structColumn class (celua.txt:2878–2885)

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Address` | integer | The current address | celua.txt:2880 |
| `AddressText` | string | Gets/sets the visual address | celua.txt:2881 |
| `Focused` | boolean | Gets/sets the focused state | celua.txt:2882 |
| `focus()` | método | focuses the current column | celua.txt:2885 |

### structGroup class (celua.txt:2888–2897)

| Propriedade / Método | Tipo | O que faz | Linha |
|---|---|---|---|
| `name` | string | gets the current name | celua.txt:2890 |
| `box` | Groupbox | Gets the groupbox object | celua.txt:2891 |
| `columnCount` | integer | Gets the number of columns in the group | celua.txt:2892 |
| `columns[index]` | structColumn | Returns the specific structColumn object | celua.txt:2893 |
| `addColumns()` | método | Adds a new columns to the specific group and returns it's structColumn objecy | celua.txt:2897 |

### structure class: (Inheritance: Object) (celua.txt:2911–2933)

**Propriedades**

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Name` | String | The name of the structure | celua.txt:2913 |
| `Size` | Integer | The number of bytes between the last element and the start. ReadOnly | celua.txt:2914 |
| `Count` | Integer | Number of elements in the structure. ReadOnly | celua.txt:2915 |
| `Internal` | boolean | When set this structure will be available for selection as a child but will not show up in the dissectedstruct list dropdown and won't be saved on table save. The structure will also be mostly read only so configure it before setting the flag | celua.txt:2916 |
| `Element[]` | structureElement | Returns the structure element at the given index. Readonly | celua.txt:2917 |
| `[]` | — | `[] = Element[]` | celua.txt:2918 |

**Métodos**

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getName` | `getName()` | Returns the name | celua.txt:2920 |
| `setName` | `setName(name)` | Sets the name | celua.txt:2921 |
| `getElement` | `getElement(index)` | Returns a structureElement object (Changing offsets can change the index) | celua.txt:2922 |
| `getElementByOffset` | `getElementByOffset(offset)` | Returns a structureElement object where the specified offset is at least the requested offset | celua.txt:2923 |
| `getElementByOffsetExact` | `getElementByOffsetExact(offset)` | Returns the first structureElement with the exact offset. Nil if no elements with this offset | celua.txt:2924 |
| `addElement` | `addElement()` | Adds a new blank structureElement and returns it | celua.txt:2925 |
| `autoGuess` | `autoGuess(baseaddresstoguessfrom, offset, size)` | (sem descrição na fonte) | celua.txt:2926 |
| `fillFromDotNetAddress` | `fillFromDotNetAddress(address, changeName)` | Fills the structure with the layout gathered from querying .NET. If changeName is true, the structure will take the name of the .NET class. (6.4+) | celua.txt:2927 |
| `beginUpdate` | `beginUpdate()` | Call this when you want to make multiple updates to a structure. It will speed up the update process | celua.txt:2929 |
| `endUpdate` | `endUpdate()` | Call this when done | celua.txt:2930 |
| `addToGlobalStructureList` | `addToGlobalStructureList()` | Add this to the list of structures for the user to select from. (Global structures will get saved to the table) | celua.txt:2931 |
| `removeFromGlobalStructureList` | `removeFromGlobalStructureList()` | Remove from the list of structures. | celua.txt:2932 |
| `clone` | `clone(newname: string)` | Duplicates a structure (useful for dealing with inheritance and you don't want it to look like pointers) | celua.txt:2933 |

### StructureElement class: (Inheritance: Object) (celua.txt:2936–2973)

**Propriedades**

| Propriedade | Tipo | O que faz | Linha |
|---|---|---|---|
| `Owner` | structure | The structure this element belongs to. Readonly | celua.txt:2938 |
| `Offset` | integer | The offset of this element | celua.txt:2939 |
| `Name` | string | The name of this element | celua.txt:2940 |
| `Vartype` | integer | The variable type of this element | celua.txt:2941 |
| `BitStart` | integer | If the vartype is vtBinary this specifies the start bit of the value | celua.txt:2942 |
| `BitSize` | integer | If the vartype is vtBinary this specifies the length in bits of the value | celua.txt:2943 |
| `CustomType` | CustomType | if Vartype is vtCustom this is the associated custom type | celua.txt:2945 |
| `CustomTypeName` | string | The name of the custom type. Empty string if no custom type | celua.txt:2946 |
| `DisplayMethod` | string | The displaymethod of the entry : `'dtUnsignedInteger'`, `'dtSignedInteger'` or `'dtHexadecimal'` | celua.txt:2947 |
| `ChildStruct` | structure | If not nil this element is a pointer to the structure defined here | celua.txt:2948 |
| `ChildStructStart` | integer | The number of bytes inside the provided childstruct. (E.g: It might point to offset 10 of a certain structure) | celua.txt:2949 |
| `ChildClassName` | string | A hint for autoguess when expanding a node when childstruct is nil. (If you hook CreateStructureFromName this will be the name given on expand) | celua.txt:2950 |
| `Bytesize` | integer | The number of bytes of this element. Readonly for basic types, writable for types that require a defined length like strings and array of bytes | celua.txt:2951 |
| `BackgroundColor` | integer | The background color of the element | celua.txt:2952 |
| `OnCreateChild` | function(sender, address OPTIONAL): struct | Called when the node of this element is being expanded by the user and ChildStruct is not defined yet. Here you can create your own structure and return that. If you return nil,true other routines will try to guess it. If you return only nil it stops there | celua.txt:2953 |

**Métodos**

| Método | Assinatura exata | O que faz | Linha |
|---|---|---|---|
| `getOwnerStructure` | `getOwnerStructure()` | Returns the structure this element belongs to | celua.txt:2957 |
| `getOffset` | `getOffset()` | Returns the offset of this element | celua.txt:2958 |
| `setOffset` | `setOffset(offset)` | Sets the offset of this element | celua.txt:2959 |
| `getName` | `getName()` | Returns the name of this element | celua.txt:2960 |
| `setName` | `setName(name)` | Sets the name of this element (tip: Leave blank if you only want to set the name of the variable) | celua.txt:2961 |
| `getVartype` | `getVartype()` | Returns the variable type of this element (check Variable types in defines.lua) | celua.txt:2962 |
| `setVartype` | `setVartype(vartype)` | (sem descrição na fonte) | celua.txt:2963 |
| `getValue` | `getValue(address)` | Gets the memory from the specified address and interprets it according to the element type | celua.txt:2964 |
| `setValue` | `setValue(address,value)` | Sets the memory at the specified address to the interpreted value according to the element type | celua.txt:2965 |
| `getValueFromBase` | `getValueFromBase(baseaddress)` | same as getValue but uses the offset to calculate the final address | celua.txt:2966 |
| `setValueFromBase` | `setValueFromBase(baseaddress,value)` | same as setValue but uses the offset to calculate the final address | celua.txt:2967 |
| `getChildStruct` | `getChildStruct()` | (sem descrição na fonte) | celua.txt:2968 |
| `setChildStruct` | `setChildStruct(structure)` | (sem descrição na fonte) | celua.txt:2969 |
| `getChildStructStart` | `getChildStructStart()` | (sem descrição na fonte) | celua.txt:2970 |
| `setChildStructStart` | `setChildStructStart(offset)` | (sem descrição na fonte) | celua.txt:2971 |
| `getBytesize` | `getBytesize()` | Gets the bytesize of the element. Usually returns the size of the type, except for string and aob | celua.txt:2972 |
| `setBytesize` | `setBytesize(size)` | sets the bytesize for types that are affected (string, aob) | celua.txt:2973 |

### Como dissecar e ler um campo (fluxo com os métodos documentados)

1. **Obter ou criar a estrutura**: `createStructure(name)` — "Returns an empty structure object (Not yet added to the Global list. Call structure.addToGlobalStructureList manually)" (celua.txt:2906) — ou pegar uma existente com `getStructure(index)` / `getStructure(name)` ("Also finds internal types. Case sensitive", celua.txt:2904–2905).
2. **Popular os campos**: adicione elementos com `structure.addElement()` — "Adds a new blank structureElement and returns it" (celua.txt:2925) — ou deixe o CE adivinhar com `structure.autoGuess(baseaddresstoguessfrom, offset, size)` (celua.txt:2926), ou ainda importar de .NET com `fillFromDotNetAddress(address, changeName)` (celua.txt:2927).
3. **Descrever cada elemento**: `element.setName(name)` (celua.txt:2961), `element.setVartype(vartype)` (celua.txt:2963), `element.setOffset(offset)` (celua.txt:2959), e para tamanho variável `element.setBytesize(size)` — "sets the bytesize for types that are affected (string, aob)" (celua.txt:2973).
4. **Tornar visível/selecionável**: `structure.addToGlobalStructureList()` (celua.txt:2931); ao terminar, `removeFromGlobalStructureList()` (celua.txt:2932). Envolva edições múltiplas em `beginUpdate()` / `endUpdate()` para acelerar (celua.txt:2929–2930).
5. **Ler o campo**: `element.getValue(address)` — "Gets the memory from the specified address and interprets it according to the element type" (celua.txt:2964) — ou, usando o offset já configurado, `element.getValueFromBase(baseaddress)` — "same as getValue but uses the offset to calculate the final address" (celua.txt:2966). Escrever: `setValue(address,value)` (celua.txt:2965) e `setValueFromBase(baseaddress,value)` (celua.txt:2967).
6. **Navegar/encadear**: para ponteiros para outra estrutura, `element.ChildStruct` (celua.txt:2948), `ChildStructStart` (celua.txt:2949) e os acessores `getChildStruct()`/`setChildStruct(structure)` (celua.txt:2968–2969), `getChildStructStart()`/`setChildStructStart(offset)` (celua.txt:2970–2971). Para expansão interativa sem ChildStruct definido, use `OnCreateChild` (celua.txt:2953).
7. **Achar elementos por posição**: `structure.getElement(index)` (celua.txt:2922), `getElementByOffset(offset)` (celua.txt:2923) e `getElementByOffsetExact(offset)` — "Nil if no elements with this offset" (celua.txt:2924).
8. **No GUI**: com um `StructureFrm` (celua.txt:2855), selecione `MainStruct` (celua.txt:2860) e leia o elemento selecionado pelo usuário com `getSelectedStructElement()`, que devolve o `StructureElement` e, como segundo resultado, a tabela com o caminho `'struct'`/`'element'` até a base (celua.txt:2875).

## Pegadinhas verificadas

- `getAddressList()` existe e é o caminho para a lista principal — "Returns the cheat table addresslist object" (celua.txt:774). `getSymbolList()` NÃO existe como global no CE 7.7 (`getSymbolList=nil` ao vivo) — se precisar da lista de símbolos, obtenha-a pelo objeto da Address List.
  - **Correção conforme a fonte**: no celua.txt, `getSymbolList()` aparece como **método da classe `SymbolList`** (celua.txt:3523, 3563), não como função global; os globais relacionados são `createSymbolList()` / `createSymbolList(initlist :{name,address}, name: string OPTIONAL)` e `getMainSymbolList()` (celua.txt:3535–3537). A classe `Addresslist` (celua.txt:2455–2505) **não** documenta nenhum `getSymbolList` — portanto "obter pelo objeto da Address List" não é suportado pela documentação; o caminho documentado é `createSymbolList`/`getMainSymbolList`/`enumRegisteredSymbolLists()` (celua.txt:3535–3538).
- `MemoryRecord.Address` é o endereço BASE como string/endereço, não o endereço resolvido final quando há offsets; use os métodos de resolução do record para o endereço efetivo. Na fonte: `Address` é "Get/set the interpretable address string. Useful for simple address settings." (celua.txt:2335), `AddressString` é "Get the address string shown in CE (ReadOnly)" (celua.txt:2336), e o endereço final sai de `getCurrentAddress()` — "Returns the current address as an integer (the final result of the interpretable address and pointer offsets)" (celua.txt:2425). A propriedade `CurrentAddress` também é descrita como "The address the memoryrecord points to" (celua.txt:2341), enquanto os offsets vivem em `OffsetCount` (celua.txt:2337), `Offset[]` (celua.txt:2338) e `OffsetText[]` (celua.txt:2339). Vale ainda a nota de `IsReadable`: só é definido depois de acessar `Value` ao menos uma vez (celua.txt:2370).
- Criar records a partir de um script e esquecer de limpá-los polui a tabela do usuário: sempre remova o que criou se for só automação temporária. Ferramentas documentadas para isso: `createMemoryRecord()` adiciona a entrada à lista (celua.txt:2490); `OnDestroy: function()` é "Called when the memoryrecord is destroyed." (celua.txt:2407); `destroy()` na base `Object` — "Destroys the object" (celua.txt:975). Marcar `DontSave = true` evita que a entrada seja salva — "Don't save this memoryrecord and it's children" (celua.txt:2411). Não há, nos intervalos consultados, `delete()`/`remove()` de MemoryRecord na Addresslist.
