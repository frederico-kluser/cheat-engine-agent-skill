--[[==========================================================================
  ce_agent_bridge.lua - ponte de controle do Cheat Engine para agentes

  O que faz
  ---------
  Expoe TODA a API CELua do Cheat Engine como um servico JSON-RPC 2.0 que um
  agente (Python, Node, qualquer coisa) controla de fora do processo.

  Transporte (medido, nao suposto)
  --------------------------------
  O Cheat Engine 7.7 tem um cano de ESCRITA quebrado: writeByte/writeBytes/
  writeString/writeDword em TPipeConnection e em TCEConnection retornam
  sucesso e transferem ZERO bytes, tanto em named pipe quanto em TCP. Isso foi
  provado com sondas dentro do CE (v9 a v13, 2026-11).

  Ja a LEITURA de um named pipe entregue por acceptConnection funciona
  perfeitamente byte a byte. Logo o bridge usa um transporte assimetrico:

      pedido   : Python  --(named pipe)-->  CE    [funciona]
      resposta : CE  --(arquivo em disco)-->  Python [funciona]

  Regras que o codigo abaixo respeita por causa disso:

    * NUNCA usar readBytes/readBytesMin no cliente: TPipeConnection.ReadBytes
      so retorna quando le EXATAMENTE `size` bytes, e readBytesMin e inerte no
      7.7. A leitura valida e readByte() em loop ate o delimitador.
    * Delimitador de fim de mensagem e 0x1E (ASCII Record Separator). Nao
      precisamos escapar nada: 0x1E nunca aparece dentro de JSON valido.
    * acceptConnection(split) BLOQUEIA, entao roda numa worker thread.
    * Depois do accept o objeto servidor perde o handle (handle=0) e o cliente
      devolvido e quem tem o handle. Sempre usar o cliente devolvido.
    * lock() na main thread levanta excecao, entao nada de I/O de pipe fora de
      worker thread.
    * O retorno dos write* nao informa quantidade de bytes. Nunca interpretar.

  Instalacao
  ----------
  Copie este arquivo para  <Cheat Engine>\autorun\  e reinicie o CE.
  O autorun so roda uma vez, na inicializacao: toda edicao exige reiniciar.
  Para remover, apague o arquivo e reinicie o CE.

  Auto-teste
  ----------
  Rode  python scripts/install_ce_bridge.py doctor
  Ele descobre o nome do pipe, conecta, faz um ping e valida a resposta.

  Uso interno (console Lua do CE / tabela de treino)
  --------------------------------------------------
  ce_bridge.call("version")
  ce_bridge.call("read", { address = "jogo.exe+1000", type = "integer" })
  ce_bridge.call("scan_create", { vartype = "dword", scanvalue = "100" })

  Licenca: MIT.  Protocolo: ce-agent-bridge/2.
==========================================================================]]--

local BRIDGE_VERSION = "2.0.0"
local PROTOCOL       = "ce-agent-bridge/2"

-- ---------------------------------------------------------------------------
-- Configuracao
-- ---------------------------------------------------------------------------
local function envOr(nome, padrao)
  local v = os.getenv and os.getenv(nome)
  if v == nil or v == "" then return padrao end
  return v
end

local CONFIG = {
  -- Nome base do named pipe. O sufixo com o PID evita colisao entre varias
  -- instancias do CE abertas ao mesmo tempo.
  pipe_base        = envOr("CE_BRIDGE_PIPE", "CE_AGENT_BRIDGE"),
  pipe_suffix_pid  = true,

  -- Caixa de correio em disco: por onde as RESPOSTAS saem do CE.
  spool_dir        = envOr("CE_BRIDGE_SPOOL",
                      (os.getenv and os.getenv("TEMP") or ".") .. "\\ce_bridge_spool"),

  -- Limites de seguranca.
  max_payload      = 4 * 1024 * 1024,
  max_read_bytes   = 1024 * 1024,
  max_scan_results = 10000,

  -- Fila de resultados de eventos assincronos (breakpoints/watchpoints).
  max_events       = 4096,

  -- Arquivo de log opcional. Vazio = so no console Lua.
  log_file         = envOr("CE_BRIDGE_LOG", nil),

  -- Intervalo do timer que drena synchronize() das worker threads.
  check_interval   = 25,

  -- Intervalo do timer que varre a caixa de correio.
  poll_interval    = 10,
}

-- O sufixo identifica ESTA instancia do CE (varias podem estar abertas ao mesmo
-- tempo). Nao ha API CELua para ler o PID do proprio CE, entao usamos relogio
-- mais sorteio - o que basta para unicidade entre instancias vivas.
local PIPE_NAME = CONFIG.pipe_base ..
  (CONFIG.pipe_suffix_pid and
    ("_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)))
    or "")

-- ---------------------------------------------------------------------------
-- Log
-- ---------------------------------------------------------------------------
local function log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  if CONFIG.log_file then
    local ok, f = pcall(io.open, CONFIG.log_file, "a")
    if ok and f then
      pcall(function()
        f:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
      end)
      pcall(function() f:close() end)
    end
  end
  if print then pcall(print, "[ce_agent_bridge] " .. msg) end
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------
local json
do
  local ok, mod = pcall(require, "json")
  if ok and type(mod) == "table" and mod.encode and mod.decode then
    json = mod
  else
    -- Fallback minimo: nao tenta ser completo, so evita derrubar o bridge.
    json = {
      encode = function() error("biblioteca 'json' nao encontrada no search path do CE") end,
      decode = function() error("biblioteca 'json' nao encontrada no search path do CE") end,
    }
  end
end

-- ---------------------------------------------------------------------------
-- Base64 (para payloads binarios)
-- ---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(s)
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    a, b, c = a or 0, b or 0, c or 0
    local v = a * 65536 + b * 256 + c
    local c1 = math.floor(v / 262144) % 64 + 1
    local c2 = math.floor(v / 4096) % 64 + 1
    local c3 = math.floor(v / 64) % 64 + 1
    local c4 = v % 64 + 1
    n = n + 1; out[n] = B64:sub(c1, c1)
    n = n + 1; out[n] = B64:sub(c2, c2)
    n = n + 1; out[n] = (i + 1 <= #s) and B64:sub(c3, c3) or "="
    n = n + 1; out[n] = (i + 2 <= #s) and B64:sub(c4, c4) or "="
  end
  return table.concat(out)
end

local function b64decode(s)
  s = s:gsub("[^" .. B64:sub(1, 62) .. "=]", "")
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local chunk = s:sub(i, i + 3)
    if #chunk < 4 then break end
    local v = 0
    for j = 1, 4 do
      local ch = chunk:sub(j, j)
      local idx = ch == "=" and 0 or (B64:find(ch, 1, true) or 1) - 1
      v = v * 64 + idx
    end
    local b1 = math.floor(v / 65536) % 256
    local b2 = math.floor(v / 256) % 256
    local b3 = v % 256
    n = n + 1; out[n] = string.char(b1)
    if chunk:sub(3, 3) ~= "=" then n = n + 1; out[n] = string.char(b2) end
    if chunk:sub(4, 4) ~= "=" then n = n + 1; out[n] = string.char(b3) end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Helpers de erro / endereco
-- ---------------------------------------------------------------------------
local function fail(msg) error(tostring(msg), 0) end

-- Aceita numero ou simbolo ("jogo.exe+1000") e devolve endereco absoluto.
local function resolve(param)
  if type(param) == "number" then return param end
  if type(param) == "string" then
    if param:match("^0[xX]%x+$") then return tonumber(param) end
    if param:match("^%d+$") then return tonumber(param) end
    local ok, addr = pcall(getAddressSafe, param)
    if ok and addr and addr ~= 0 then
      -- getAddressSafe pode devolver string hexadecimal para enderecos que
      -- nao cabem exatamente num double (visto com modulos do sistema).
      if type(addr) == "string" then addr = tonumber(addr) end
      if addr then return addr end
    end
    return nil, "simbolo nao resolvido: " .. param
  end
  return nil, "endereco invalido (esperado numero ou simbolo)"
end

-- O CE 7.7 entrega campos numericos de forma instavel: enumModules() devolve
-- Address como string hexadecimal ("0x7ff805f80000") quando o valor nao cabe
-- exatamente num double e como numero no modulo principal; enumMemoryRegions()
-- faz o mesmo. Qualquer consumidor precisa normalizar. Declarado aqui em cima
-- (antes dos def) por causa da regra de upvalue: helper referenciado dentro de
-- um closure precisa existir como local antes da chamada de def.
local function paraNumero(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

-- ---------------------------------------------------------------------------
-- Estado transacional
-- ---------------------------------------------------------------------------
local NextId      = 1
local TxnScripts  = {}   -- txn_id -> { {disableInfo=...}, ... }
local TxnWrites   = {}   -- txn_id -> { {address=, original=, size=}, ... }

local function generateId(prefix)
  local id = string.format("%s-%d-%d", prefix, os.time(), NextId)
  NextId = NextId + 1
  return id
end

-- ---------------------------------------------------------------------------
-- Registro de metodos
-- ---------------------------------------------------------------------------
local Methods = {}
local function def(name, fn) Methods[name] = fn end

-- ===========================================================================
-- 1. Identidade e avaliacao
-- ===========================================================================
-- getProcesslist() devolve {pid, nome, pid, nome, ...}; nao existe
-- getProcessNameFromID no CELua 7.7, entao a busca e feita aqui.
-- Declarada ANTES dos handlers que a usam: Lua fecha os upvalues na criacao
-- da closure, e uma local declarada depois seria nil dentro deles.
-- getProcesslist() devolve {[pid] = "nome.exe"} (comprovado ao vivo no 7.7);
-- getProcessNameFromID nao existe no CELua. Aceitamos tambem a forma plana
-- {pid, nome, pid, nome, ...} por seguranca entre versoes.
local function processListPairs()
  local ok, raw = pcall(getProcesslist)
  if not ok or type(raw) ~= "table" then return {} end
  local out = {}
  if type(raw[1]) == "number" and type(raw[2]) == "string" then
    for i = 1, #raw, 2 do
      out[#out + 1] = { pid = raw[i], name = raw[i + 1] }
    end
    return out
  end
  for k, v in pairs(raw) do
    if type(k) == "number" and type(v) == "string" then
      out[#out + 1] = { pid = k, name = v }
    elseif type(v) == "table" then
      local pid = v.pid or v.PID
      local name = v.name or v.Name
      if type(pid) == "number" and type(name) == "string" then
        out[#out + 1] = { pid = pid, name = name }
      end
    end
  end
  table.sort(out, function(a, b) return a.pid < b.pid end)
  return out
end

local function processNameFromPID(pid)
  if not pid or pid == 0 then return nil end
  local ok, raw = pcall(getProcesslist)
  if ok and type(raw) == "table" then
    local direto = raw[pid]
    if type(direto) == "string" then return direto end
    for i = 1, #raw, 2 do
      if raw[i] == pid then return raw[i + 1] end
    end
  end
  return nil
end

def("ping", function()
  return { pong = true, bridge = BRIDGE_VERSION, protocol = PROTOCOL,
           time = os.time(), ce = (getCEVersion and getCEVersion() or "?") }
end)

def("version", function()
  return {
    bridge   = BRIDGE_VERSION,
    protocol = PROTOCOL,
    ce       = getCEVersion and getCEVersion() or "?",
    process  = processNameFromPID(getOpenedProcessID and getOpenedProcessID() or 0),
    pid      = getOpenedProcessID and getOpenedProcessID() or 0,
    is64bit  = (targetIs64Bit and targetIs64Bit()) and true or false,
    pipe     = PIPE_NAME,
    spool    = CONFIG.spool_dir,
    methods  = (function() local n = 0 for _ in pairs(Methods) do n = n + 1 end return n end)(),
  }
end)

def("eval", function(p)
  local code = p.code or p.script
  if type(code) ~= "string" then fail("'code' obrigatorio") end
  if #code > 256 * 1024 then fail("codigo grande demais") end
  local chunk, err = load(code, "=ce_bridge_eval", "t", _G)
  if not chunk then fail("erro de sintaxe: " .. tostring(err)) end
  local results = { pcall(chunk) }
  local ok = table.remove(results, 1)
  if not ok then fail("erro em execucao: " .. tostring(results[1])) end
  return { count = #results, values = results }
end)

-- ===========================================================================
-- 2. Processos
-- ===========================================================================
local function normalizeProcessList()
  return processListPairs()
end

def("process_list", function(p)
  local list = normalizeProcessList()
  local filtro = p.filter and tostring(p.filter):lower() or nil
  if filtro then
    local f = {}
    for _, e in ipairs(list) do
      if e.name and e.name:lower():find(filtro, 1, true) then f[#f + 1] = e end
    end
    return { count = #f, total = #list, processes = f }
  end
  return { count = #list, total = #list, processes = list }
end)

def("info", function()
  local pid = getOpenedProcessID and getOpenedProcessID() or 0
  local is64 = (targetIs64Bit and targetIs64Bit()) and true or false
  return {
    pid       = pid,
    name      = processNameFromPID(pid),
    is64bit   = is64,
    pointer_size = is64 and 8 or 4,
    handle    = (getOpenedProcessHandle and getOpenedProcessHandle()) or 0,
    attached  = pid ~= 0,
    ce        = getCEVersion and getCEVersion() or "?",
  }
end)

-- processNameFromPID esta declarada na secao 1 (precisa existir antes dos
-- handlers que a usam como upvalue).

def("attach", function(p)
  local pid = p.pid
  if not pid and p.name then
    local ok, found = pcall(getProcessIDFromProcessName, p.name)
    if not ok or not found or found == 0 then
      fail("processo nao encontrado: " .. tostring(p.name))
    end
    pid = found
  end
  if not pid or pid == 0 then fail("informe 'pid' ou 'name'") end

  local ok, err = pcall(openProcess, pid)
  if not ok then fail("openProcess falhou: " .. tostring(err)) end
  -- openProcess nao retorna nada: confirmar pelo estado
  local aberto = getOpenedProcessID and getOpenedProcessID() or 0
  if aberto ~= pid then fail("nao foi possivel abrir o PID " .. tostring(pid)) end

  return { pid = pid, name = processNameFromPID(pid),
           is64bit = (targetIs64Bit and targetIs64Bit()) and true or false }
end)

def("detach", function()
  pcall(openProcess, 0)
  return { attached = false }
end)

def("modules", function()
  if (getOpenedProcessID and getOpenedProcessID() or 0) == 0 then
    fail("nenhum processo aberto; use 'attach' antes")
  end
  -- O enumModules() do 7.7 entrega Address como string hexadecimal
  -- ("0x7ff805f80000") quando o valor nao cabe num double exato, e como
  -- numero no modulo principal. Normalizamos sempre para numero.
  local mods = {}
  pcall(function()
    local ml = enumModules()
    if not ml then return end
    local i = 1
    while true do
      local m = ml[i]
      if not m then break end
      local base = paraNumero(m.Address)
      mods[#mods + 1] = {
        name      = m.Name,
        address   = base,
        base      = base,
        size      = paraNumero(m.Size) or 0,
        is64bit   = m.Is64Bit and true or false,
        path      = m.PathToFile,
      }
      i = i + 1
    end
    pcall(function() ml:destroy() end)
  end)
  return { count = #mods, modules = mods }
end)

-- O enumMemoryRegions() NAO e uma funcao por indice: devolve uma tabela
-- indexada 1-based (1185 entradas num CE tipico) onde cada entrada e
-- {BaseAddress, AllocationBase, AllocationProtect, RegionSize, State,
-- Protect, Type, Extra?}. Os valores vem como number aqui, mas passamos por
-- paraNumero de qualquer forma porque o 7.7 ja mostrou tipos instaveis.
local function lerRegioes(limite)
  local regioes = {}
  local total = 0
  pcall(function()
    local ml = enumMemoryRegions()
    if type(ml) ~= "table" then return end
    for _, e in pairs(ml) do
      total = total + 1
      if #regioes < limite and type(e) == "table" then
        local base = paraNumero(e.BaseAddress)
        if base then
          regioes[#regioes + 1] = {
            base             = base,
            size             = paraNumero(e.RegionSize) or 0,
            protection       = paraNumero(e.Protect),
            allocation_base  = paraNumero(e.AllocationBase),
            allocation_protect = paraNumero(e.AllocationProtect),
            state            = paraNumero(e.State),
            type             = paraNumero(e.Type),
            extra            = e.Extra,
          }
        end
      end
    end
  end)
  table.sort(regioes, function(a, b) return a.base < b.base end)
  return regioes, total
end

def("regions", function(p)
  if (getOpenedProcessID and getOpenedProcessID() or 0) == 0 then
    fail("nenhum processo aberto; use 'attach' antes")
  end
  local limite = tonumber(p.limit) or 512
  local regioes, total = lerRegioes(limite)
  return {
    count     = #regioes,
    total     = total,
    limit     = limite,
    truncated = total > #regioes,
    regions   = regioes,
  }
end)

def("resolve", function(p)
  if not p.symbol then fail("'symbol' obrigatorio") end
  local addr, err = resolve(p.symbol)
  if not addr then fail(err) end
  addr = tonumber(addr) or addr

  local nome
  pcall(function() nome = getNameFromAddress(addr) end)

  local modulo, offset
  if type(nome) == "string" then
    modulo, offset = nome:match("^(.-)%+(%x+)$")
    if modulo then offset = tonumber(offset, 16) end
  end

  return { symbol = p.symbol, address = addr, name = nome,
           module = modulo, offset = offset }
end)

def("symbol_register", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  if not p.name then fail("'name' obrigatorio") end
  local ok, e = pcall(registerSymbol, p.name, addr, p.dontSave and true or false)
  if not ok then fail("registerSymbol falhou: " .. tostring(e)) end
  return { name = p.name, address = addr }
end)

def("symbol_unregister", function(p)
  if not p.name then fail("'name' obrigatorio") end
  pcall(unregisterSymbol, p.name)
  return { name = p.name, removed = true }
end)

-- ===========================================================================
-- 3. Memoria: leitura
-- ===========================================================================
local READERS = {
  byte    = function(a) return readBytes(a, 1, false) end,
  integer = function(a) return readInteger(a) end,
  dword   = function(a) return readInteger(a) end,
  qword   = function(a) return readQword(a) end,
  pointer = function(a) return readPointer(a) end,
  float   = function(a) return readFloat(a) end,
  double  = function(a) return readDouble(a) end,
}

local function readStringSafe(addr, tipo, maxlen)
  maxlen = tonumber(maxlen) or 256
  if maxlen < 1 then maxlen = 1 end
  if maxlen > 4096 then maxlen = 4096 end
  if tipo == "widestring" or tipo == "unicode" then
    local ok, s = pcall(readString, addr, maxlen, true)
    return ok and s or nil
  end
  local ok, s = pcall(readString, addr, maxlen, false)
  return ok and s or nil
end

def("read", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  local tipo = tostring(p.type or "integer"):lower()

  if tipo == "string" or tipo == "widestring" or tipo == "unicode" then
    local s = readStringSafe(addr, tipo, p.maxlen)
    if s == nil then fail("readString falhou em 0x" .. string.format("%X", addr)) end
    return { address = addr, type = tipo, value = s }
  end

  local reader = READERS[tipo]
  if not reader then fail("tipo desconhecido: " .. tipo) end

  local ok, valor = pcall(reader, addr)
  if not ok then fail("leitura falhou em 0x" .. string.format("%X", addr) .. ": " .. tostring(valor)) end
  return { address = addr, type = tipo, value = valor }
end)

def("read_many", function(p)
  local tipo = tostring(p.type or "integer"):lower()
  local addrs = p.addresses
  if type(addrs) ~= "table" then fail("'addresses' deve ser uma lista") end
  if #addrs > 4096 then fail("limite de 4096 enderecos por chamada") end

  local reader = READERS[tipo]
  local isString = (tipo == "string" or tipo == "widestring" or tipo == "unicode")
  if not reader and not isString then fail("tipo desconhecido: " .. tipo) end

  local out = {}
  for i, a in ipairs(addrs) do
    local addr = resolve(a)
    if addr then
      if isString then
        out[i] = { address = addr, value = readStringSafe(addr, tipo, p.maxlen) }
      else
        local ok, v = pcall(reader, addr)
        out[i] = { address = addr, value = ok and v or nil, error = ok and nil or tostring(v) }
      end
    else
      out[i] = { address = nil, error = "endereco invalido: " .. tostring(a) }
    end
  end
  return { count = #out, values = out }
end)

-- ===========================================================================
-- 4. Memoria: escrita (transacional por padrao)
-- ===========================================================================
local WRITERS = {
  byte    = function(a, v) writeBytes(a, { v % 256 }) end,
  integer = function(a, v) writeInteger(a, v) end,
  dword   = function(a, v) writeInteger(a, v) end,
  qword   = function(a, v) writeQword(a, v) end,
  pointer = function(a, v) writePointer(a, v) end,
  float   = function(a, v) writeFloat(a, v) end,
  double  = function(a, v) writeDouble(a, v) end,
}

local SIZE_OF = { byte = 1, integer = 4, dword = 4, qword = 8, pointer = 8,
                  float = 4, double = 8 }

def("write", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  local tipo = tostring(p.type or "integer"):lower()

  -- Preparar os bytes ANTES do snapshot: assim o tamanho e sempre conhecido.
  local bytesPayload = nil
  if tipo == "bytes" then
    if type(p.bytes) == "table" then
      bytesPayload = p.bytes
    elseif type(p.base64) == "string" then
      local decodificado = b64decode(p.base64)
      bytesPayload = { decodificado:byte(1, #decodificado) }
    else
      fail("para type='bytes' informe 'bytes' (lista) ou 'base64'")
    end
    if #bytesPayload == 0 then fail("payload de bytes vazio") end
  elseif tipo == "string" or tipo == "widestring" then
    if type(p.value) ~= "string" then fail("'value' deve ser string") end
    if p.value == "" then fail("writeString nao aceita string vazia no CE 7.7") end
  else
    if WRITERS[tipo] == nil then fail("tipo desconhecido: " .. tipo) end
    if type(p.value) ~= "number" then
      fail("'value' deve ser numero para o tipo " .. tipo)
    end
  end

  -- Tamanho em bytes do que sera gravado (0 = nao transacional).
  local size = 0
  if tipo == "bytes" then
    size = #bytesPayload
  elseif tipo == "string" then
    size = #p.value
  elseif tipo == "widestring" then
    size = #p.value * 2
  else
    size = SIZE_OF[tipo]
  end

  -- Snapshot dos bytes originais para permitir rollback.
  local txn_id = p.transaction_id or generateId("txn")
  if p.transactional ~= false and size > 0 then
    local okS, original = pcall(readBytes, addr, size, true)
    if okS and original then
      TxnWrites[txn_id] = TxnWrites[txn_id] or {}
      table.insert(TxnWrites[txn_id],
                   { address = addr, original = original, size = size })
    end
  end

  local ok, e
  if tipo == "bytes" then
    ok, e = pcall(writeBytes, addr, bytesPayload)
  elseif tipo == "string" or tipo == "widestring" then
    ok, e = pcall(writeString, addr, p.value, tipo == "widestring")
  else
    ok, e = pcall(WRITERS[tipo], addr, p.value)
  end
  if not ok then fail("escrita falhou: " .. tostring(e)) end

  -- Confirmacao real: reler o que ficou na memoria. O retorno de write* nao
  -- informa bytes, entao a releitura e a unica prova de que gravou.
  local lido
  if tipo == "bytes" then
    local okR, r = pcall(readBytes, addr, size, true)
    lido = (okR and r) and b64encode(r) or nil
  elseif tipo == "string" or tipo == "widestring" then
    lido = readStringSafe(addr, tipo, #p.value + 2)
  else
    local okR, r = pcall(READERS[tipo], addr)
    lido = okR and r or nil
  end

  return { address = addr, type = tipo, written = true, transaction_id = txn_id,
           size = size, verified_value = lido }
end)

def("txn_list", function()
  local out = {}
  for id, writes in pairs(TxnWrites) do
    out[#out + 1] = { transaction_id = id, writes = #writes }
  end
  for id, scripts in pairs(TxnScripts) do
    out[#out + 1] = { transaction_id = id, scripts = #scripts }
  end
  return { count = #out, transactions = out }
end)

def("txn_rollback_writes", function(p)
  local id = p.transaction_id
  local writes = TxnWrites[id]
  if not writes then fail("transacao nao encontrada: " .. tostring(id)) end
  local revertidos = 0
  -- desfaz na ordem inversa
  for i = #writes, 1, -1 do
    local w = writes[i]
    local ok = pcall(writeBytes, w.address, w.original)
    if ok then revertidos = revertidos + 1 end
  end
  TxnWrites[id] = nil
  return { transaction_id = id, reverted = revertidos }
end)

def("alloc", function(p)
  local size = tonumber(p.size)
  if not size or size < 1 then fail("'size' obrigatorio") end
  if size > 64 * 1024 * 1024 then fail("limite de 64 MB por alocacao") end
  local addr = allocateMemory(size)
  if not addr or addr == 0 then fail("allocateMemory falhou") end
  return { address = addr, size = size }
end)

def("dealloc", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  local ok, e = pcall(deAlloc, addr)
  if not ok then fail("deAlloc falhou: " .. tostring(e)) end
  return { address = addr, freed = true }
end)

-- ===========================================================================
-- 5. Scanner de memoria
-- ===========================================================================
local Scans = {}

def("scan_create", function(p)
  if (getOpenedProcessID and getOpenedProcessID() or 0) == 0 then
    fail("nenhum processo aberto; use 'attach' antes de escanear")
  end
  if not p.vartype then fail("'vartype' obrigatorio") end

  local ms = createMemScan()
  local id = generateId("scan")
  Scans[id] = { memscan = ms, at = os.time() }

  local props = {
    ScanOption   = p.scanoption or "soExactValue",
    VarType      = p.vartype,
    Roundingtype = p.roundingtype or "roundedDefault",
    Scanvalue    = p.scanvalue ~= nil and tostring(p.scanvalue) or nil,
    Scanvalue2   = p.scanvalue2 ~= nil and tostring(p.scanvalue2) or nil,
    Startaddress = nil,
    Stopaddress  = nil,
    Hexadecimal  = p.hexadecimal,
    UTF16        = p.utf16,
    Casesensitive= p.casesensitive,
    Percentage   = false,
  }

  if p.start_address then
    local a, err = resolve(p.start_address)
    if not a then pcall(function() ms:destroy() end); fail(err) end
    props.Startaddress = a
  end
  if p.stop_address then
    local a, err = resolve(p.stop_address)
    if not a then pcall(function() ms:destroy() end); fail(err) end
    props.Stopaddress = a
  end

  for k, v in pairs(props) do
    if v ~= nil then
      local ok, e = pcall(function() ms[k] = v end)
      if not ok and k ~= "Scanvalue2" then
        pcall(function() ms:destroy() end)
        fail(string.format("nao foi possivel definir %s=%s: %s", k, tostring(v), tostring(e)))
      end
    end
  end

  local ok, e = pcall(function() ms:firstScan() end)
  if not ok then pcall(function() ms:destroy() end); fail("firstScan falhou: " .. tostring(e)) end
  pcall(function() ms:waitTillDone(tonumber(p.timeout) or 0) end)

  return {
    success   = true,
    scan_id   = id,
    found     = ms.FoundCount,
    last_type = ms.LastScanType,
    error     = (ms.ErrorString and ms.ErrorString ~= "") and ms.ErrorString or nil,
  }
end)

def("scan_refine", function(p)
  local rec = Scans[p.scan_id]
  if not rec then fail("scan nao encontrado: " .. tostring(p.scan_id)) end
  local ms = rec.memscan

  local props = {
    ScanOption   = p.scanoption,
    VarType      = p.vartype,
    Roundingtype = p.roundingtype,
    Scanvalue    = p.scanvalue ~= nil and tostring(p.scanvalue) or nil,
    Scanvalue2   = p.scanvalue2 ~= nil and tostring(p.scanvalue2) or nil,
  }
  for k, v in pairs(props) do
    if v ~= nil then pcall(function() ms[k] = v end) end
  end

  local ok, e = pcall(function() ms:nextScan() end)
  if not ok then fail("nextScan falhou: " .. tostring(e)) end
  pcall(function() ms:waitTillDone(tonumber(p.timeout) or 0) end)

  return { success = true, scan_id = p.scan_id, found = ms.FoundCount,
           last_type = ms.LastScanType }
end)

def("scan_results", function(p)
  local rec = Scans[p.scan_id]
  if not rec then fail("scan nao encontrado: " .. tostring(p.scan_id)) end
  local ms = rec.memscan

  local limite = tonumber(p.limit) or 1000
  if limite > CONFIG.max_scan_results then limite = CONFIG.max_scan_results end

  local total = ms.FoundCount or 0

  -- Caminho rapido: ms.Results costuma estar preenchido depois do firstScan.
  if not p.with_values then
    local ok, res = pcall(function() return ms.Results end)
    if ok and type(res) == "table" then
      local out = {}
      for i = 1, math.min(#res, limite) do out[i] = res[i] end
      return { scan_id = p.scan_id, count = #out, total = total,
               truncated = total > #out, addresses = out }
    end
  end

  local fl = ms.FoundList
  local okI = pcall(function() fl:initialize() end)
  if not okI then fail("nao foi possivel inicializar a FoundList") end

  local addrs, vals = {}, {}
  local n = math.min(fl.Count or 0, limite)
  for i = 1, n do
    local v = fl.Address[i - 1]
    addrs[i] = v
    if p.with_values then vals[i] = fl.Value[i - 1] end
  end
  pcall(function() fl:deinitialize() end)

  local r = { scan_id = p.scan_id, count = #addrs, total = total,
              truncated = total > #addrs, addresses = addrs }
  if p.with_values then r.values = vals end
  return r
end)

def("scan_free", function(p)
  local rec = Scans[p.scan_id]
  if not rec then return { scan_id = p.scan_id, freed = false } end
  pcall(function()
    local fl = rec.memscan.FoundList
    if fl then
      pcall(function() fl:deinitialize() end)
      pcall(function() fl:destroy() end)
    end
  end)
  pcall(function() rec.memscan:destroy() end)
  Scans[p.scan_id] = nil
  return { scan_id = p.scan_id, freed = true }
end)

-- ===========================================================================
-- 6. Auto Assembler (transacional)
-- ===========================================================================
-- O autoAssembleCheck do CE 7.7 so valida scripts que possuem AS DUAS secoes
-- ([ENABLE] e [DISABLE]) ou nenhuma. Um script valido so com [ENABLE] devolve
-- false com erro nil, enquanto o autoAssemble real o aceita sem reclamar.
-- Portanto: (a) a ausencia de erro em 'err' nunca prova invalidez; (b) quando
-- o CE recusa e nao explica, fazemos um teste de fumaca com um script minimo
-- que exercita o MESMO parser para separar "erro de sintaxe" de "limitacao do
-- check". O smoke test e opt-in (p.smoke == true) porque mexe na memoria.
local SmokeSeq = 0
local function smokeTestAA()
  SmokeSeq = SmokeSeq + 1
  local nome = "ce_bridge_smoke_" .. tostring(os.time()) .. "_" .. tostring(SmokeSeq)
  local script = "[ENABLE]\nalloc(" .. nome .. ",16)\n[DISABLE]\ndealloc(" .. nome .. ")\n"
  local ok, err = pcall(autoAssemble, script)
  pcall(autoAssemble, "dealloc(" .. nome .. ")\n")
  return ok == true, ok and nil or tostring(err)
end

def("aa_check", function(p)
  if type(p.script) ~= "string" then fail("'script' obrigatorio") end

  local valid, err = autoAssembleCheck(p.script, true, p.target_self and true or false)
  if valid == true then
    return { valid = true, checked = "autoAssembleCheck" }
  end
  if err ~= nil then
    return { valid = false, checked = "autoAssembleCheck", error = tostring(err) }
  end

  -- CE recusou sem explicar: pode ser script so-[ENABLE] (valido) ou erro de
  -- sintaxe. Informamos a limitacao e, se pedido, testamos se o PARSER esta
  -- saudavel. Isso NAO valida o script do chamador: so descarta a hipotese de
  -- "o auto assembler esta quebrado".
  local out = {
    valid = false,
    checked = "autoAssembleCheck",
    limitation = "autoAssembleCheck do CE 7.7 so valida scripts com as duas "
              .. "secoes [ENABLE] e [DISABLE] (ou sem secao alguma). Um script "
              .. "so com [ENABLE] e executado normalmente pelo autoAssemble, "
              .. "mas este check o recusa sem mensagem de erro.",
  }
  if p.smoke == true then
    local ctrl_ok, ctrl_err = smokeTestAA()
    out.smoke_parser_ok = ctrl_ok
    if not ctrl_ok then out.smoke_error = ctrl_err end
    out.smoke_note = "smoke_parser_ok=true apenas confirma que o auto assembler "
                  .. "aceita um script com as duas secoes; nao valida o seu script."
  end
  return out
end)

def("aa_apply", function(p)
  if type(p.script) ~= "string" then fail("'script' obrigatorio") end
  local targetSelf = p.target_self and true or false

  -- O autoAssembleCheck do 7.7 nao valida scripts so-[ENABLE]. So barramos
  -- quando ele da uma mensagem concreta; caso contrario quem decide e o
  -- autoAssemble logo abaixo.
  local valid, checkErr = autoAssembleCheck(p.script, true, targetSelf)
  if valid ~= true and checkErr ~= nil then
    fail("erro de sintaxe AA: " .. tostring(checkErr))
  end

  -- Contrato real do CE 7.7 (verificado ao vivo):
  --   sucesso            -> true, disableInfo (tabela)
  --   so [ENABLE]        -> false, nil       (o script EXECUTA, mas nao ha o
  --                                           que reverter depois)
  --   script invalido    -> false, "<mensagem de erro>"
  --   excecao            -> pcall captura
  local ok, ret, info = pcall(autoAssemble, p.script, targetSelf)
  if not ok then fail("autoAssemble falhou: " .. tostring(ret)) end

  -- O CE chama autoAssemble com (script, targetself); o disableInfo chega como
  -- 2o retorno. Se algum dia vier como 1o retorno (tabela), aceitamos tambem.
  local disableInfo = info
  if type(ret) == "table" and info == nil then
    ret, disableInfo = true, ret
  end

  if ret ~= true then
    local detalhe = disableInfo
    if type(detalhe) ~= "string" then detalhe = nil end
    if detalhe then
      fail("autoAssemble recusou o script: " .. detalhe)
    end
    fail("autoAssemble recusou o script sem mensagem de erro. No CE 7.7 isso "
      .. "acontece quando o script so tem a secao [ENABLE] e tambem quando a "
      .. "sintaxe e invalida; nao ha como distinguir por este retorno. Use "
      .. "aa_check ou envie o script com as duas secoes [ENABLE]/[DISABLE].")
  end

  if type(disableInfo) ~= "table" then
    return { success = true, transaction_id = nil, record_id = nil,
             checked = "autoAssemble", revertible = false, allocs = {},
             message = "Script executado, porem o CE nao devolveu disableInfo: "
                    .. "nao ha como reverter (script sem [DISABLE])." }
  end

  -- disableInfo.allocs = { nome = { address =, size =, prefered = } }
  -- Esses enderecos NAO ficam resolviveis por getAddressSafe/getAddress no
  -- CE 7.7 (so existem dentro desta compilacao), entao devolvemos os valores.
  local allocs = {}
  if type(disableInfo.allocs) == "table" then
    for nome, dados in pairs(disableInfo.allocs) do
      if type(dados) == "table" then
        allocs[#allocs + 1] = {
          name    = tostring(nome),
          address = paraNumero(dados.address),
          size    = paraNumero(dados.size),
        }
      end
    end
  end

  local txn_id = p.transaction_id or generateId("txn")
  TxnScripts[txn_id] = TxnScripts[txn_id] or {}
  table.insert(TxnScripts[txn_id], { disableInfo = disableInfo, script = p.script })

  local n = 0
  for _ in pairs(disableInfo) do n = n + 1 end

  return { success = true, transaction_id = txn_id, record_id = txn_id,
           checked = "autoAssemble", revertible = true,
           entries = n, allocs = allocs }
end)

def("aa_revert", function(p)
  local id = p.transaction_id
  local scripts = TxnScripts[id]
  if not scripts then fail("transacao nao encontrada: " .. tostring(id)) end
  local revertidos = 0
  local falhas = {}
  for i = #scripts, 1, -1 do
    local entry = scripts[i]
    -- Forma de 3 argumentos: autoAssemble(text, targetself, disableInfo). O
    -- disableInfo e uma TABELA, nao um script: passar so ele como 1o argumento
    -- nao reverte nada.
    local ok, ret = pcall(autoAssemble, entry.script or "", false, entry.disableInfo)
    if ok and ret == true then
      revertidos = revertidos + 1
    else
      falhas[#falhas + 1] = tostring(ret)
    end
  end
  TxnScripts[id] = nil
  local saida = { transaction_id = id, reverted = revertidos, total = #scripts }
  if #falhas > 0 then saida.errors = falhas end
  return saida
end)

def("aa_revert_all", function()
  local n = 0
  local falhas = {}
  for id, scripts in pairs(TxnScripts) do
    for i = #scripts, 1, -1 do
      local entry = scripts[i]
      local ok, ret = pcall(autoAssemble, entry.script or "", false, entry.disableInfo)
      if ok and ret == true then
        n = n + 1
      else
        falhas[#falhas + 1] = tostring(ret)
      end
    end
    TxnScripts[id] = nil
  end
  for id, writes in pairs(TxnWrites) do
    for i = #writes, 1, -1 do
      if pcall(writeBytes, writes[i].address, writes[i].original) then n = n + 1 end
    end
    TxnWrites[id] = nil
  end
  local saida = { reverted = n }
  if #falhas > 0 then saida.errors = falhas end
  return saida
end)

-- ===========================================================================
-- 7. Desmontagem
-- ===========================================================================
def("disassemble", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  local ok, s = pcall(disassemble, addr, p.include_module_names and true or false)
  if not ok then fail("disassemble falhou: " .. tostring(s)) end
  return { address = addr, text = s }
end)

def("instruction_size", function(p)
  local addr, err = resolve(p.address)
  if not addr then fail(err) end
  local ok, n = pcall(getInstructionSize, addr)
  if not ok then fail("getInstructionSize falhou: " .. tostring(n)) end
  return { address = addr, size = n }
end)

-- ===========================================================================
-- 8. GUI (via MainForm / formularios abertos)
-- ===========================================================================
local function resolveForm(name)
  if not name then return nil, "informe o nome do form" end
  local ok, f = pcall(getForm, name)
  if ok and f then return f end
  for i = 0, (getFormCount and getFormCount() or 0) - 1 do
    local ok2, form = pcall(getForm, i)
    if ok2 and form and form.Name == name then return form end
  end
  return nil, "form nao encontrado: " .. tostring(name)
end

def("gui_forms", function()
  local out = {}
  local n = getFormCount and getFormCount() or 0
  for i = 0, n - 1 do
    local ok, f = pcall(getForm, i)
    if ok and f then
      out[#out + 1] = { index = i, name = f.Name, caption = f.Caption,
                        class = f.ClassName, visible = f.Visible and true or false }
    end
  end
  return { count = #out, forms = out }
end)

def("gui_show", function(p)
  local f, err = resolveForm(p.form)
  if not f then fail(err) end
  if p.visible == false then f:hide() else f:show() end
  return { form = p.form, visible = p.visible ~= false }
end)

def("gui_activate", function(p)
  local f, err = resolveForm(p.form)
  if not f then fail(err) end
  pcall(function() f:bringToFront() end)
  pcall(function() f:setFocus() end)
  return { form = p.form, active = true }
end)

def("gui_click", function(p)
  local f, err = resolveForm(p.form)
  if not f then fail(err) end
  local comp = f
  if p.path then
    for part in tostring(p.path):gmatch("[^/]+") do
      local nextComp = comp[part]
      if not nextComp and comp.findComponent then
        local ok, found = pcall(function() return comp:findComponent(part) end)
        if ok then nextComp = found end
      end
      if not nextComp then fail("componente nao encontrado: " .. part) end
      comp = nextComp
    end
  end
  if comp.doClick then comp:doClick()
  elseif comp.Click then comp:Click()
  else fail("componente nao tem doClick/Click") end
  return { form = p.form, path = p.path, clicked = true }
end)

def("gui_set", function(p)
  local f, err = resolveForm(p.form)
  if not f then fail(err) end
  local comp = f
  if p.path then
    for part in tostring(p.path):gmatch("[^/]+") do
      local nextComp = comp[part]
      if not nextComp and comp.findComponent then
        local ok, found = pcall(function() return comp:findComponent(part) end)
        if ok then nextComp = found end
      end
      if not nextComp then fail("componente nao encontrado: " .. part) end
      comp = nextComp
    end
  end
  if p.property == nil then fail("'property' obrigatorio") end
  local ok, e = pcall(function() comp[p.property] = p.value end)
  if not ok then fail("nao foi possivel definir " .. tostring(p.property) .. ": " .. tostring(e)) end
  local lido
  pcall(function() lido = comp[p.property] end)
  return { form = p.form, path = p.path, property = p.property, value = lido }
end)

-- ===========================================================================
-- 9. Hotkeys e timers
-- ===========================================================================
local Hotkeys = {}

def("hotkey_add", function(p)
  if not p.keys then fail("'keys' obrigatorio (ex: 'CTRL+ALT+1')") end
  if type(p.action) ~= "string" then fail("'action' deve ser codigo Lua") end
  local fn, err = load(p.action, "=ce_bridge_hotkey", "t", _G)
  if not fn then fail("erro de sintaxe na acao: " .. tostring(err)) end

  local id = p.id or generateId("hk")
  local hk
  if createHotkeyEx then
    hk = createHotkeyEx(fn, p.keys)
  else
    hk = createHotkey(fn, p.keys)
  end
  if not hk then fail("createHotkey falhou para " .. tostring(p.keys)) end
  Hotkeys[id] = hk
  return { id = id, keys = p.keys }
end)

def("hotkey_remove", function(p)
  local hk = Hotkeys[p.id]
  if not hk then return { id = p.id, removed = false } end
  pcall(function() hk:destroy() end)
  Hotkeys[p.id] = nil
  return { id = p.id, removed = true }
end)

local Timers = {}

def("timer_create", function(p)
  if type(p.action) ~= "string" then fail("'action' deve ser codigo Lua") end
  local fn, err = load(p.action, "=ce_bridge_timer", "t", _G)
  if not fn then fail("erro de sintaxe na acao: " .. tostring(err)) end

  local intervalo = tonumber(p.interval) or 1000
  if intervalo < 10 then intervalo = 10 end

  local t = createTimer(nil)
  local id = p.id or generateId("timer")
  Timers[id] = t
  t.Interval = intervalo
  t.OnTimer = function() pcall(fn) end
  return { id = id, interval = intervalo }
end)

-- ===========================================================================
-- 10. Eventos assincronos (breakpoints / watchpoints)
-- ===========================================================================
local EventBuffer = {}
local EventCount  = 0

local function pushEvent(kind, address, extra)
  if EventCount >= CONFIG.max_events then return end
  EventCount = EventCount + 1
  local ev = { seq = EventCount, kind = kind, address = address, at = os.time() }
  if type(extra) == "table" then
    for k, v in pairs(extra) do ev[k] = v end
  end
  EventBuffer[EventCount] = ev
end

def("events_poll", function(p)
  local desde = tonumber(p.since) or 0
  local out = {}
  for i = desde + 1, EventCount do
    if EventBuffer[i] then out[#out + 1] = EventBuffer[i] end
  end
  return { count = #out, last_seq = EventCount, events = out }
end)

def("events_clear", function()
  EventBuffer, EventCount = {}, 0
  return { cleared = true }
end)

-- ===========================================================================
-- 11. Limpeza
-- ===========================================================================
def("cleanup", function()
  local ms, mt, mh = 0, 0, 0
  for id in pairs(Scans) do
    local rec = Scans[id]
    pcall(function()
      local fl = rec.memscan.FoundList
      if fl then
        pcall(function() fl:deinitialize() end)
        pcall(function() fl:destroy() end)
      end
    end)
    if pcall(function() rec.memscan:destroy() end) then ms = ms + 1 end
  end
  Scans = {}
  for id, hk in pairs(Hotkeys) do
    if pcall(function() hk:destroy() end) then mh = mh + 1 end
    Hotkeys[id] = nil
  end
  for id, t in pairs(Timers) do
    if pcall(function() t.destroy() end) then mt = mt + 1 end
    Timers[id] = nil
  end
  TxnScripts, TxnWrites = {}, {}
  EventBuffer, EventCount = {}, 0
  return { scans_freed = ms, timers_freed = mt, hotkeys_freed = mh }
end)

-- ===========================================================================
-- Ponte worker-thread -> main-thread
-- ===========================================================================
local CheckTimer = nil

local function bootstrapCheckTimer()
  if CheckTimer then return end
  CheckTimer = createTimer(nil)
  CheckTimer.Interval = CONFIG.check_interval
  CheckTimer.OnTimer = function()
    pcall(checkSynchronize, 1)
  end
  log("timer de checkSynchronize ativo (%d ms)", CONFIG.check_interval)
end

local function invokeMain(method, params)
  local fn = Methods[method]
  if not fn then return nil, "metodo desconhecido: " .. tostring(method) end

  local function runner()
    local ok, res, err = pcall(fn, params or {})
    if not ok then return nil, "excecao no handler: " .. tostring(res) end
    if res == nil then return nil, err or "handler nao retornou resultado" end
    return res, nil
  end

  if inMainThread and inMainThread() then return runner() end

  local box = {}
  local syncOk, syncErr = pcall(synchronize, function()
    box.result, box.error = runner()
  end)
  if not syncOk then return nil, "synchronize falhou: " .. tostring(syncErr) end
  if box.error then return nil, box.error end
  return box.result, nil
end

local function dispatch(request)
  local id = request.id
  local method = request.method

  if method == "rpc_methods" then
    local names = {}
    for k in pairs(Methods) do names[#names + 1] = k end
    table.sort(names)
    return { jsonrpc = "2.0", id = id, result = { methods = names, count = #names,
             bridge = BRIDGE_VERSION, protocol = PROTOCOL } }
  end

  local result, err = invokeMain(method, request.params)
  if err then
    return { jsonrpc = "2.0", id = id, error = { code = -32000, message = err } }
  end
  return { jsonrpc = "2.0", id = id, result = result }
end

local function safeEncode(tbl)
  local ok, s = pcall(json.encode, tbl)
  if ok and s then return s end
  local ok2, s2 = pcall(json.encode, { jsonrpc = "2.0", id = tbl.id,
    error = { code = -32700, message = "falha ao serializar resposta: " .. tostring(s) } })
  if ok2 and s2 then return s2 end
  return '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"resposta nao serializavel"}}'
end

-- ===========================================================================
-- Canal de resposta em disco
-- ---------------------------------------------------------------------------
-- O CE escreve aqui o que o agente vai ler. Escrevemos num temporario e
-- renomeamos: assim o agente nunca ve um arquivo pela metade.
-- ===========================================================================
local function ensureSpoolDir()
  pcall(function() os.execute('mkdir "' .. CONFIG.spool_dir .. '" 2>nul') end)
  local f = io.open(CONFIG.spool_dir .. "\\probe.tmp", "wb")
  if f then f:close(); os.remove(CONFIG.spool_dir .. "\\probe.tmp"); return true end
  return false
end

local function writeSpool(nome, conteudo)
  local tmp = CONFIG.spool_dir .. "\\" .. nome .. ".tmp"
  local dst = CONFIG.spool_dir .. "\\" .. nome

  local ok, err = pcall(function()
    local f = io.open(tmp, "wb")
    if not f then error("nao foi possivel criar " .. tmp) end
    f:write(conteudo)
    f:close()
  end)
  if not ok then return false, tostring(err) end

  -- os.rename nao sobrescreve no Windows: apagar o destino antes.
  pcall(os.remove, dst)
  local okR, errR = pcall(os.rename, tmp, dst)
  if not okR then
    pcall(os.remove, tmp)
    return false, "rename falhou: " .. tostring(errR)
  end
  return true
end

-- ===========================================================================
-- Servidor de named pipe (via de ENTRADA)
-- ---------------------------------------------------------------------------
-- Cada conexao e tratada numa worker thread propria. O CE le byte a byte ate
-- 0x1E e grava a resposta na caixa de correio.
-- ===========================================================================
local ActiveClients = 0
local RequestsServed = 0

local function readMessage(client)
  local buf, n = {}, 0
  while true do
    local ok, b = pcall(function() return client:readByte() end)
    if not ok then return nil, "readByte falhou: " .. tostring(b) end
    if b == nil then return nil, "cliente desconectou" end
    if b == 0x1E then return table.concat(buf), nil end
    n = n + 1
    buf[n] = string.char(b)
    if n > CONFIG.max_payload then return nil, "mensagem excede o limite" end
  end
end

local function handleClient(client)
  ActiveClients = ActiveClients + 1
  log("cliente conectado (ativos=%d)", ActiveClients)

  while true do
    local raw, err = readMessage(client)
    if not raw then
      log("fim do cliente: %s", tostring(err))
      break
    end

    local inicio = os.clock()
    local okD, req = pcall(json.decode, raw)
    local resposta
    local id = nil

    if not okD or type(req) ~= "table" then
      resposta = { jsonrpc = "2.0", id = nil,
                   error = { code = -32700, message = "JSON invalido: " .. tostring(req) } }
    else
      id = req.id
      resposta = dispatch(req)
      resposta.ms = math.floor((os.clock() - inicio) * 1000)
      RequestsServed = RequestsServed + 1
    end

    local nomeResp = "resp_" .. tostring(id == nil and "null" or id) .. ".json"
    local okW, errW = writeSpool(nomeResp, safeEncode(resposta))
    if not okW then
      log("FALHA ao gravar a resposta %s: %s", nomeResp, tostring(errW))
    end
  end

  ActiveClients = ActiveClients - 1
  pcall(function() client:destroy() end)
  log("cliente desconectado (ativos=%d)", ActiveClients)
end

local PipeServer = nil

local function startPipeServer()
  local ok, err = pcall(function() PipeServer = createPipe(PIPE_NAME) end)
  if not ok or not PipeServer then
    log("FALHA ao criar o pipe %s: %s", PIPE_NAME, tostring(err))
    return false
  end

  createThread(function(thread)
    thread.Name = "ce_agent_bridge:listener"
    thread:freeOnTerminate(true)
    log("escutando no pipe %s", PIPE_NAME)

    while true do
      -- split=true: varias instancias do cliente em sequencia sao aceitas.
      local okA, client = pcall(PipeServer.acceptConnection, PipeServer, true)
      if not okA then
        log("acceptConnection falhou: %s", tostring(client))
        sleep(500)
      elseif client then
        createThread(function(ct)
          ct.Name = "ce_agent_bridge:client"
          ct:freeOnTerminate(true)
          local okC, errC = pcall(handleClient, client)
          if not okC then
            log("erro no cliente: %s", tostring(errC))
            pcall(function() client:destroy() end)
          end
        end)
      else
        sleep(50)
      end
    end
  end)
  return true
end

-- ===========================================================================
-- Bootstrap
-- ===========================================================================
local function announce()
  local spoolOk = ensureSpoolDir()
  if not spoolOk then
    log("AVISO: nao consegui usar a caixa de correio em %s", CONFIG.spool_dir)
  end
  startPipeServer()
  log("v%s pronta | pipe=%s | spool=%s | CE=%s",
      BRIDGE_VERSION, PIPE_NAME, CONFIG.spool_dir,
      (getCEVersion and getCEVersion() or "?"))
end

-- ===========================================================================
-- API interna (console Lua do CE / tabela de treino)
-- ===========================================================================
_G.ce_bridge = {
  version  = BRIDGE_VERSION,
  protocol = PROTOCOL,
  config   = CONFIG,
  methods  = Methods,
  pipe     = PIPE_NAME,
  spool    = CONFIG.spool_dir,

  call = function(method, params)
    local res, err = invokeMain(method, params)
    if err then error(err, 2) end
    return res
  end,

  safe_call = function(method, params)
    return invokeMain(method, params)
  end,

  cleanup = function() return Methods["cleanup"]({}) end,
  clients = function() return ActiveClients end,
  served  = function() return RequestsServed end,
  push_event = pushEvent,
  status = function()
    return { version = BRIDGE_VERSION, pipe = PIPE_NAME, spool = CONFIG.spool_dir,
             clients = ActiveClients, served = RequestsServed,
             scans = (function() local n = 0 for _ in pairs(Scans) do n = n + 1 end return n end)(),
             events = EventCount }
  end,
}

bootstrapCheckTimer()
announce()
