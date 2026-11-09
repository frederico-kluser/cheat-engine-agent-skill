--[[==========================================================================
  ce_agent_bridge.lua - ponte de controle do Cheat Engine para agentes de IA

  O que faz
  ---------
  Expoe a API CELua do Cheat Engine como um servico JSON-RPC que um agente
  (o `ce` CLI desta skill, ou qualquer cliente) controla de FORA do CE:
  processos, leitura/escrita, scanner (first/next), AOB, ponteiros, Auto
  Assembler transacional, tabela de enderecos (freeze), disassembly,
  debugger ("o que escreve neste endereco"), speedhack, Mono e eval de Lua.

  Transportes (medidos no CE 7.7.1 Linux, 2026-11)
  -------------------------------------------------
    1. TCP 127.0.0.1:<porta>  (padrao 52740; CE_BRIDGE_PORT)  -> principal
       createServerSocket(porta, true) -> so localhost. Cada pedido leva o
       token de STATE_DIR/token. Quadro = JSON + 0x1E (ASCII RS), nos dois
       sentidos. No Linux a escrita em socket do CE funciona (no Windows 7.7
       ela transferia 0 bytes - por isso existe o transporte 2).
    2. Caixa de correio em disco (STATE_DIR/mailbox)          -> reserva
       O cliente grava req_<id>.json (atomico), um timer do CE (thread
       principal) processa e grava resp_<id>.json (atomico). Nao usa rede.

  STATE_DIR = $CE_BRIDGE_DIR  ou  $XDG_RUNTIME_DIR/ce-agent-bridge  (Linux)
                                  %TEMP%\ce-agent-bridge          (Windows)
  Arquivos: token (0600), bridge.json (porta, pid, versao), bridge.log,
            mailbox/.

  Regras que o codigo respeita
  ----------------------------
    * acceptConnection() BLOQUEIA: roda numa worker thread (createThread).
    * Toda chamada a API do CE roda na thread principal (synchronize no TCP;
      o timer da caixa de correio ja roda nela).
    * Objetos do CE usam chamada com ponto (obj.metodo()), como o codigo
      oficial do CE.
    * JSON proprio para codificar (o json.lua do CE falha com arrays
      esparsos e NaN/inf); decodifica com o json.lua do CE.

  Instalacao (Linux, pacote AUR cheatengine-bin)
  ----------------------------------------------
    ~/.local/share/cheatengine/autorun/ce_agent_bridge.lua  (symlink)
    -> o install.sh da skill faz isso. O autorun so roda na inicializacao:
       editou, reinicie o CE (ou: ce lua 'dofile(ce_bridge.path)').

  Uso interno (console Lua do CE)
  -------------------------------
    ce_bridge.call("info")
    ce_bridge.call("scan_first", { type = "dword", value = "100" })

  Licenca: MIT.  Protocolo: ce-agent-bridge/3.
==========================================================================]]--

local BRIDGE_VERSION = "3.1.0"
local PROTOCOL       = "ce-agent-bridge/3"

-- Recarregar o arquivo (dofile) derruba a instancia anterior primeiro.
if type(_G.ce_bridge) == "table" and type(_G.ce_bridge.stop) == "function" then
  pcall(_G.ce_bridge.stop)
end

local OS     = (getOperatingSystem and getOperatingSystem()) or 0  -- 0 win, 1 mac, 2 linux
local IS_WIN = (OS == 0)
local SEP    = IS_WIN and "\\" or "/"

-- ---------------------------------------------------------------------------
-- Utilitarios basicos
-- ---------------------------------------------------------------------------
local function envOr(nome, padrao)
  local v = os.getenv and os.getenv(nome)
  if v == nil or v == "" then return padrao end
  return v
end

local function shq(s)  -- aspas de shell POSIX
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function defaultStateDir()
  if IS_WIN then
    return (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\ce-agent-bridge"
  end
  local rt = os.getenv("XDG_RUNTIME_DIR")
  if rt and rt ~= "" then return rt .. "/ce-agent-bridge" end
  return "/tmp/ce-agent-bridge-" .. (os.getenv("USER") or "user")
end

local CONFIG = {
  state_dir        = envOr("CE_BRIDGE_DIR", defaultStateDir()),
  port             = tonumber(envOr("CE_BRIDGE_PORT", "52740")) or 52740,
  port_tries       = 10,
  enable_tcp       = envOr("CE_BRIDGE_TCP", "1") ~= "0",
  enable_mailbox   = envOr("CE_BRIDGE_MAILBOX", "1") ~= "0",
  mailbox_interval = 20,              -- ms
  max_payload      = 16 * 1024 * 1024,
  max_read_bytes   = 1024 * 1024,
  max_results      = 20000,
  max_events       = 4096,
  max_hits         = 512,             -- instrucoes distintas por watch
}
CONFIG.mailbox_dir = CONFIG.state_dir .. SEP .. "mailbox"
CONFIG.log_file    = envOr("CE_BRIDGE_LOG", CONFIG.state_dir .. SEP .. "bridge.log")

local function mkdirs(path)
  if IS_WIN then
    pcall(os.execute, 'mkdir "' .. path .. '" 2>nul')
  else
    pcall(os.execute, "mkdir -p -m 700 " .. shq(path) .. " 2>/dev/null")
  end
end

local function writeFileAtomic(path, conteudo, privado)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, "nao foi possivel criar " .. tmp .. ": " .. tostring(err) end
  f:write(conteudo)
  f:close()
  if privado and not IS_WIN then pcall(os.execute, "chmod 600 " .. shq(tmp) .. " 2>/dev/null") end
  if IS_WIN then pcall(os.remove, path) end  -- rename nao sobrescreve no Windows
  local ok, errR = os.rename(tmp, path)
  if not ok then pcall(os.remove, tmp); return false, "rename falhou: " .. tostring(errR) end
  return true
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function randomHex(nbytes)
  if not IS_WIN then
    local f = io.open("/dev/urandom", "rb")
    if f then
      local b = f:read(nbytes)
      f:close()
      if b and #b == nbytes then
        return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      end
    end
  end
  math.randomseed(os.time() + ((getTickCount and getTickCount()) or 0))
  local t = {}
  for i = 1, nbytes do t[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

local function log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  local f = io.open(CONFIG.log_file, "a")
  if f then
    f:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
    f:close()
  end
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------
local jsonDecode
do
  local ok, mod = pcall(require, "json")
  if ok and type(mod) == "table" and mod.decode then
    jsonDecode = mod.decode
  else
    jsonDecode = function() error("json.lua do CE nao encontrado no package.path") end
  end
end

local jsonEncode
do
  local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  local function str(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
      return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  local function num(v)
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type and math.type(v) == "integer" then return string.format("%d", v) end
    if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%.0f", v) end
    local s = string.format("%.15g", v)
    if tonumber(s) ~= v then s = string.format("%.17g", v) end
    return s
  end
  local function enc(v, depth)
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then return num(v) end
    if tv == "string" then return str(v) end
    if tv ~= "table" then return str(tostring(v)) end
    if depth > 48 then return '"<profundidade excedida>"' end
    local n, isArr = 0, true
    for k in pairs(v) do
      if type(k) == "number" and k >= 1 and math.floor(k) == k then
        if k > n then n = k end
      else
        isArr = false
        break
      end
    end
    local out = {}
    if isArr then
      for i = 1, n do out[i] = enc(v[i], depth + 1) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, val in pairs(v) do
      local tk = type(k)
      if tk == "string" or tk == "number" then
        out[#out + 1] = str(tostring(k)) .. ":" .. enc(val, depth + 1)
      end
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  jsonEncode = function(v) return enc(v, 0) end
end

-- ---------------------------------------------------------------------------
-- Base64 (payloads binarios)
-- ---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = (v >> 18) & 63
    local c2 = (v >> 12) & 63
    local c3 = (v >> 6) & 63
    local c4 = v & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) ..
      ((i + 1 <= #s) and B64:sub(c3 + 1, c3 + 1) or "=") ..
      ((i + 2 <= #s) and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

local function b64decode(s)
  s = s:gsub("[^%w%+/=]", "")
  local out = {}
  for i = 1, #s, 4 do
    local chunk = s:sub(i, i + 3)
    if #chunk < 4 then break end
    local v = 0
    for j = 1, 4 do
      local ch = chunk:sub(j, j)
      v = v * 64 + (ch == "=" and 0 or ((B64:find(ch, 1, true) or 1) - 1))
    end
    out[#out + 1] = string.char((v >> 16) & 255)
    if chunk:sub(3, 3) ~= "=" then out[#out + 1] = string.char((v >> 8) & 255) end
    if chunk:sub(4, 4) ~= "=" then out[#out + 1] = string.char(v & 255) end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Erros, enderecos, tipos
-- ---------------------------------------------------------------------------
local function fail(msg) error(tostring(msg), 0) end

local function hex(a)
  if type(a) ~= "number" then return a end
  return string.format("0x%X", math.tointeger(a) or a)
end

local function bytesToHex(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for i = 1, #t do out[i] = string.format("%02X", t[i]) end
  return table.concat(out, " ")
end

-- "48 8B ?? 05" / "488B05" / {0x48,0x8B} -> tabela de bytes
local function parseBytes(v)
  if type(v) == "table" then
    local t = {}
    for i, b in ipairs(v) do
      local n = type(b) == "string" and tonumber(b, 16) or tonumber(b)
      if not n then fail("byte invalido na posicao " .. i) end
      t[i] = n & 255
    end
    return t
  end
  if type(v) ~= "string" then fail("bytes devem ser lista ou string hexadecimal") end
  local s = v:gsub("0[xX]", ""):gsub("[%s,]", "")
  if #s % 2 ~= 0 or s:find("[^%x]") then fail("string hexadecimal invalida: " .. v) end
  local t = {}
  for i = 1, #s, 2 do t[#t + 1] = tonumber(s:sub(i, i + 1), 16) end
  return t
end

local function opened()
  return (getOpenedProcessID and getOpenedProcessID()) or 0
end

local function requireProcess()
  if opened() == 0 then fail("nenhum processo aberto; use 'attach' antes") end
end

local function is64()
  return (targetIs64Bit and targetIs64Bit()) and true or false
end

-- O CE 7.7 entrega numeros como string hexadecimal quando nao cabem num double.
local function toNumber(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    if v:match("^0[xX]%x+$") then return tonumber(v:sub(3), 16) end
    return tonumber(v) or tonumber(v, 16)
  end
  return nil
end

local function listModules()
  local mods = {}
  local ok, ml = pcall(enumModules)
  if ok and type(ml) == "table" then
    for _, m in ipairs(ml) do
      mods[#mods + 1] = { name = m.Name, base = toNumber(m.Address) or 0,
                          size = toNumber(m.Size) or 0, path = m.PathToFile,
                          is64bit = m.Is64Bit and true or false }
    end
  end
  return mods
end

local function findModule(nome)
  if not nome then return nil end
  local alvo = tostring(nome):gsub('^"(.*)"$', "%1"):lower()
  local parcial
  for _, m in ipairs(listModules()) do
    local n = (m.name or ""):lower()
    if n == alvo then return m end
    if not parcial and n:find(alvo, 1, true) then parcial = m end
  end
  return parcial
end

-- Numero, "0x..", decimal, simbolo do CE ("[jogo.exe+10]+8"), ou "modulo+hex"
-- (nomes de modulo Linux tem '-', que o parser do CE le como subtracao).
local function resolve(param)
  if type(param) == "number" then return param end
  if type(param) ~= "string" or param == "" then
    return nil, "endereco invalido (esperado numero ou simbolo)"
  end
  local s = param:gsub("^%s+", ""):gsub("%s+$", "")
  -- como no CE: texto hexadecimal puro e endereco HEX ("7ff0" == 0x7ff0)
  if s:match("^0[xX]%x+$") then return tonumber(s:sub(3), 16) end
  if s:match("^%x+$") then return tonumber(s, 16) end
  local mod, off = s:match('^"?([^%[%]"]-)"?%+([%x]+)$')
  if mod and mod ~= "" then
    local m = findModule(mod)
    if m then return m.base + tonumber(off, 16) end
  end
  local ok, addr = pcall(getAddressSafe, s)
  if ok and addr ~= nil then
    addr = toNumber(addr)
    if addr and addr ~= 0 then return addr end
  end
  -- "modulo.simbolo[+off]": e assim que o getNameFromAddress mostra simbolos
  -- ELF no Linux, mas o parser do CE so resolve o simbolo sem o modulo.
  for _, m in ipairs(listModules()) do
    local pref = (m.name or "") .. "."
    if #s > #pref and s:sub(1, #pref):lower() == pref:lower() then
      local ok2, a2 = pcall(getAddressSafe, s:sub(#pref + 1))
      a2 = ok2 and toNumber(a2) or nil
      if a2 and a2 ~= 0 then return a2 end
    end
  end
  if mod then
    local m = findModule(mod)
    if not m then return nil, "modulo nao encontrado: " .. mod end
  end
  return nil, "simbolo nao resolvido: " .. param
end

local function addr(param, campo)
  local a, err = resolve(param)
  if not a then fail((campo and (campo .. ": ") or "") .. tostring(err)) end
  return a
end

local function nameOf(a)
  local ok, n = pcall(getNameFromAddress, a)
  if ok and type(n) == "string" and n ~= "" then
    -- sem simbolo o CE devolve o proprio endereco em hex: nao repetir
    if type(a) == "number" and n:upper() == string.format("%X", a) then return nil end
    return n
  end
  return nil
end

-- "endereco - bytes - opcode : extra". O splitDisassembledString do 7.7.1
-- devolve os campos na ordem INVERSA da documentada; parsear a string e estavel.
local function splitDis(s)
  local a, resto = s:match("^(%S+)%s+%-%s+(.*)$")
  if not a then return nil, nil, s, nil end
  local bytes, op = resto:match("^(.-)%s+%-%s+(.*)$")
  if not bytes then return a, nil, resto, nil end
  local opcode, extra = op:match("^(.-)%s+:%s+(.*)$")
  opcode = opcode or op
  return a, (bytes:gsub("%s+$", "")), (opcode:gsub("%s+$", "")), extra
end

local TYPE_ALIAS = {
  byte = "byte", u8 = "byte", i8 = "byte", int8 = "byte", ["1"] = "byte",
  word = "word", u16 = "word", i16 = "word", int16 = "word", short = "word",
  ["2"] = "word", ["2bytes"] = "word",
  dword = "dword", u32 = "dword", i32 = "dword", int32 = "dword", int = "dword",
  integer = "dword", ["4"] = "dword", ["4bytes"] = "dword",
  qword = "qword", u64 = "qword", i64 = "qword", int64 = "qword", long = "qword",
  ["8"] = "qword", ["8bytes"] = "qword",
  float = "float", single = "float", f32 = "float",
  double = "double", f64 = "double",
  pointer = "pointer", ptr = "pointer",
  string = "string", str = "string", text = "string", utf8 = "string",
  widestring = "widestring", wstring = "widestring", unicode = "widestring",
  utf16 = "widestring",
  bytes = "bytes", aob = "bytes", bytearray = "bytes", array = "bytes",
  all = "all", binary = "binary",
}

local function canonType(t, padrao)
  local k = tostring(t or padrao or "dword"):lower()
  local c = TYPE_ALIAS[k]
  if not c then fail("tipo desconhecido: " .. tostring(t) ..
    " (use byte|word|dword|qword|float|double|pointer|string|widestring|bytes)") end
  return c
end

local function sizeOf(t)
  if t == "byte" then return 1 end
  if t == "word" then return 2 end
  if t == "dword" or t == "float" then return 4 end
  if t == "qword" or t == "double" then return 8 end
  if t == "pointer" then return is64() and 8 or 4 end
  return nil
end

local function signExtend(v, bits)
  if v == nil then return nil end
  local lim = 1 << (bits - 1)
  if v >= lim then return v - (1 << bits) end
  return v
end

local function readTyped(a, t, signed)
  if t == "byte" then
    local v = readBytes(a, 1, false)
    return signed and signExtend(v, 8) or v
  elseif t == "word" then
    local v = readSmallInteger(a)
    if v and v < 0 and not signed then v = v + 65536 end
    return signed and signExtend(v, 16) or v
  elseif t == "dword" then
    local v = readInteger(a)
    if v and v < 0 and not signed then v = v + 4294967296 end
    return signed and signExtend(v, 32) or v
  elseif t == "qword" then return readQword(a)
  elseif t == "float" then return readFloat(a)
  elseif t == "double" then return readDouble(a)
  elseif t == "pointer" then return readPointer(a)
  end
  fail("tipo sem leitor numerico: " .. tostring(t))
end

local function writeTyped(a, t, v)
  local n = tonumber(v)
  if n == nil then fail("valor numerico invalido: " .. tostring(v)) end
  if t == "byte" then return writeBytes(a, { math.tointeger(n) & 255 })
  elseif t == "word" then return writeSmallInteger(a, math.tointeger(n) or n)
  elseif t == "dword" then return writeInteger(a, math.tointeger(n) or n)
  elseif t == "qword" then return writeQword(a, math.tointeger(n) or n)
  elseif t == "float" then return writeFloat(a, n)
  elseif t == "double" then return writeDouble(a, n)
  elseif t == "pointer" then return writePointer(a, math.tointeger(n) or n)
  end
  fail("tipo sem escritor numerico: " .. tostring(t))
end

local function readStringSafe(a, wide, maxlen)
  maxlen = math.max(1, math.min(tonumber(maxlen) or 256, 65536))
  local ok, s = pcall(readString, a, maxlen, wide and true or false)
  if ok then return s end
  return nil
end

-- ---------------------------------------------------------------------------
-- Estado da sessao
-- ---------------------------------------------------------------------------
local NextId    = 1
local Scans     = {}   -- id -> { ms=, type=, created=, last=, count= }
local ScanOrder = {}   -- ids na ordem de criacao
local Txn       = {}   -- id -> { {address=, original={bytes}}, ... }
local AAScripts = {}   -- id -> { script=, target_self=, disableInfo=, at= }
local Watches   = {}   -- id -> { address=, size=, kind=, hits={}, order={}, total= }
local Records   = {}   -- ids de memory records criados pelo agente
local Hotkeys   = {}
local Timers    = {}
local Events, EventSeq = {}, 0

local function newId(prefix)
  local id = string.format("%s%d", prefix, NextId)
  NextId = NextId + 1
  return id
end

local function pushEvent(kind, data)
  EventSeq = EventSeq + 1
  local ev = { seq = EventSeq, kind = kind, at = os.time() }
  if type(data) == "table" then for k, v in pairs(data) do ev[k] = v end end
  Events[#Events + 1] = ev
  if #Events > CONFIG.max_events then table.remove(Events, 1) end
end

local stop  -- definido no bootstrap (derruba transportes); usado por ce_close

-- ---------------------------------------------------------------------------
-- Registro de metodos (com documentacao curta, exposta em 'help')
-- ---------------------------------------------------------------------------
local Methods, Docs = {}, {}
local function def(name, doc, fn)
  Methods[name] = fn
  Docs[name] = doc
end
local function alias(novo, existente)
  Methods[novo] = Methods[existente]
  Docs[novo] = "alias de " .. existente
end

-- ===========================================================================
-- 1. Identidade, ajuda e eval
-- ===========================================================================
local function processList()
  local ok, raw = pcall(getProcesslist)
  local out = {}
  if not ok or type(raw) ~= "table" then return out end
  if type(raw[1]) == "number" and type(raw[2]) == "string" then
    for i = 1, #raw, 2 do out[#out + 1] = { pid = raw[i], name = raw[i + 1] } end
  else
    for k, v in pairs(raw) do
      if type(k) == "number" and type(v) == "string" then
        out[#out + 1] = { pid = k, name = v }
      elseif type(v) == "table" then
        local pid, name = v.pid or v.PID, v.name or v.Name
        if type(pid) == "number" then out[#out + 1] = { pid = pid, name = name } end
      end
    end
  end
  table.sort(out, function(a, b) return a.pid > b.pid end)
  return out
end

local function processName(pid)
  if not pid or pid == 0 then return nil end
  for _, e in ipairs(processList()) do
    if e.pid == pid then return e.name end
  end
  return nil
end

def("ping", "teste de vida: {pong, versoes, pid do CE}", function()
  return { pong = true, bridge = BRIDGE_VERSION, protocol = PROTOCOL,
           ce = getCEVersion and getCEVersion() or nil, os = OS,
           ce_pid = getCheatEngineProcessID and getCheatEngineProcessID() or nil }
end)

def("help", "lista metodos e documentacao. params: method?", function(p)
  if p.method then
    if not Docs[p.method] then fail("metodo desconhecido: " .. tostring(p.method)) end
    return { method = p.method, doc = Docs[p.method] }
  end
  local names = {}
  for k in pairs(Methods) do names[#names + 1] = k end
  table.sort(names)
  local out = {}
  for i, k in ipairs(names) do out[i] = { method = k, doc = Docs[k] } end
  return { count = #out, methods = out }
end)

def("eval", "executa Lua no CE (thread principal). params: code | expr. Captura print()",
function(p)
  local code = p.code or p.script
  if p.expr then code = "return " .. tostring(p.expr) end
  if type(code) ~= "string" then fail("'code' ou 'expr' obrigatorio") end
  if #code > 1024 * 1024 then fail("codigo grande demais (>1 MB)") end
  local chunk, err = load(code, "=agent_eval", "t", _G)
  if not chunk then fail("erro de sintaxe: " .. tostring(err)) end
  local prints = {}
  local oldprint = print
  print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    prints[#prints + 1] = table.concat(t, "\t")
  end
  local res = table.pack(pcall(chunk))
  print = oldprint
  if not res[1] then fail("erro em execucao: " .. tostring(res[2])) end
  local values = {}
  for i = 2, res.n do values[i - 1] = res[i] end
  return { count = res.n - 1, values = values, prints = prints }
end)

-- ===========================================================================
-- 2. Processos, modulos, regioes, simbolos
-- ===========================================================================
def("process_list", "processos visiveis ao CE. params: filter?, limit?", function(p)
  local list = processList()
  local filtro = p.filter and tostring(p.filter):lower()
  local out = {}
  local limite = tonumber(p.limit) or 500
  for _, e in ipairs(list) do
    if not filtro or (e.name or ""):lower():find(filtro, 1, true) or tostring(e.pid) == filtro then
      if #out < limite then out[#out + 1] = e end
    end
  end
  return { count = #out, total = #list, processes = out }
end)

local function infoTable()
  local pid = opened()
  return {
    pid = pid, attached = pid ~= 0, name = processName(pid),
    main_module = rawget(_G, "process"),
    is64bit = pid ~= 0 and is64() or nil,
    pointer_size = pid ~= 0 and (is64() and 8 or 4) or nil,
    debugging = (debug_isDebugging and debug_isDebugging()) and true or false,
    symbols_loaded = (symbolsDoneLoading and symbolsDoneLoading()) and true or false,
    ce = getCEVersion and getCEVersion() or nil,
  }
end

def("info", "processo aberto: pid, nome, 64 bits, debugger", function() return infoTable() end)

def("attach", "abre um processo. params: pid | name (exato > parcial; mais novo vence)",
function(p)
  local pid = tonumber(p.pid)
  local candidatos = {}
  if not pid then
    if not p.name then fail("informe 'pid' ou 'name'") end
    local alvo = tostring(p.name):lower()
    local exatos, parciais = {}, {}
    for _, e in ipairs(processList()) do
      local n = (e.name or ""):lower()
      if n == alvo then exatos[#exatos + 1] = e
      elseif n:find(alvo, 1, true) then parciais[#parciais + 1] = e end
    end
    candidatos = #exatos > 0 and exatos or parciais
    if #candidatos == 0 then fail("processo nao encontrado: " .. tostring(p.name)) end
    pid = candidatos[1].pid  -- lista ordenada por pid decrescente
  end
  local ok, err = pcall(openProcess, pid)
  if not ok then fail("openProcess falhou: " .. tostring(err)) end
  if opened() ~= pid then fail("nao foi possivel abrir o PID " .. tostring(pid)) end
  if p.wait_symbols and waitForSections then pcall(waitForSections) end
  local r = infoTable()
  -- prova de acesso real a memoria (ptrace_scope/permissoes)
  local mods = listModules()
  r.modules = #mods
  if mods[1] then
    local okR, b = pcall(readBytes, mods[1].base, 4, true)
    r.readable = (okR and type(b) == "table" and #b == 4) and true or false
    r.main_base = hex(mods[1].base)
  end
  if #candidatos > 1 then
    r.other_matches = {}
    for i = 2, math.min(#candidatos, 10) do r.other_matches[#r.other_matches + 1] = candidatos[i] end
  end
  return r
end)

def("detach", "fecha o processo aberto", function()
  pcall(openProcess, 0)
  return { attached = opened() ~= 0 }
end)

def("modules", "modulos do alvo. params: filter?, limit?", function(p)
  requireProcess()
  local filtro = p.filter and tostring(p.filter):lower()
  local limite = tonumber(p.limit) or 1000
  local out = {}
  for _, m in ipairs(listModules()) do
    if not filtro or (m.name or ""):lower():find(filtro, 1, true) or (m.path or ""):lower():find(filtro, 1, true) then
      if #out < limite then
        out[#out + 1] = { name = m.name, base = hex(m.base), size = m.size,
                          ["end"] = hex(m.base + m.size), path = m.path, is64bit = m.is64bit }
      end
    end
  end
  return { count = #out, modules = out }
end)

def("regions", "mapa de memoria. params: filter? (texto da linha/arquivo), writable?, executable?, limit?",
function(p)
  requireProcess()
  local ok, rs = pcall(enumMemoryRegions)
  if not ok or type(rs) ~= "table" then fail("enumMemoryRegions falhou") end
  local filtro = p.filter and tostring(p.filter):lower()
  local limite = tonumber(p.limit) or 500
  local out, total = {}, 0
  for _, e in ipairs(rs) do
    total = total + 1
    local prot = toNumber(e.Protect) or 0
    -- PAGE_* do Windows (o CE usa os mesmos codigos no Linux)
    local w = (prot & 0xCC) ~= 0      -- READWRITE|WRITECOPY|EXECUTE_READWRITE|EXECUTE_WRITECOPY
    local x = (prot & 0xF0) ~= 0
    local extra = e.Extra and tostring(e.Extra) or ""
    local okF = (not filtro) or extra:lower():find(filtro, 1, true)
    if okF and (p.writable == nil or p.writable == w) and (p.executable == nil or p.executable == x) then
      if #out < limite then
        local base = toNumber(e.BaseAddress) or 0
        out[#out + 1] = { base = hex(base), size = toNumber(e.RegionSize) or 0,
                          protect = prot, writable = w, executable = x,
                          state = toNumber(e.State), type = toNumber(e.Type),
                          extra = extra ~= "" and extra or nil }
      end
    end
  end
  return { count = #out, total = total, truncated = #out >= limite, regions = out }
end)

def("resolve", "simbolo/expressao -> endereco. params: symbol", function(p)
  local s = p.symbol or p.address
  local a = addr(s, "symbol")
  local n = nameOf(a)
  local modulo, off
  if n then
    modulo, off = n:match("^(.-)%+(%x+)$")
    if modulo then off = hex(tonumber(off, 16)) end
  end
  return { symbol = s, address = hex(a), name = n, module = modulo, offset = off }
end)

def("symbol_register", "registra simbolo. params: name, address, dont_save?", function(p)
  if not p.name then fail("'name' obrigatorio") end
  local a = addr(p.address, "address")
  local ok, e = pcall(registerSymbol, p.name, a, p.dont_save and true or false)
  if not ok then fail("registerSymbol falhou: " .. tostring(e)) end
  return { name = p.name, address = hex(a) }
end)

def("symbol_unregister", "remove simbolo. params: name", function(p)
  if not p.name then fail("'name' obrigatorio") end
  pcall(unregisterSymbol, p.name)
  return { name = p.name, removed = true }
end)

-- ===========================================================================
-- 3. Leitura
-- ===========================================================================
local function readOne(a, t, p)
  if t == "string" or t == "widestring" then
    local s = readStringSafe(a, t == "widestring", p.maxlen)
    if s == nil then fail("readString falhou em " .. hex(a)) end
    return s
  elseif t == "bytes" then
    local n = math.max(1, math.min(tonumber(p.size or p.count) or 16, CONFIG.max_read_bytes))
    local ok, b = pcall(readBytes, a, n, true)
    if not ok or type(b) ~= "table" then fail("readBytes falhou em " .. hex(a)) end
    return bytesToHex(b)
  end
  local ok, v = pcall(readTyped, a, t, p.signed)
  if not ok or v == nil then fail("leitura falhou em " .. hex(a)) end
  return v
end

def("read", "le memoria. params: address, type?=dword, count? (array), signed?, maxlen?, size? (bytes)",
function(p)
  requireProcess()
  local a = addr(p.address, "address")
  local t = canonType(p.type, "dword")
  local count = tonumber(p.count) or 1
  if t ~= "bytes" and t ~= "string" and t ~= "widestring" and count > 1 then
    if count > 65536 then fail("count maximo 65536") end
    local sz = sizeOf(t)
    local vals = {}
    for i = 0, count - 1 do
      local ok, v = pcall(readTyped, a + i * sz, t, p.signed)
      vals[i + 1] = ok and v or nil
    end
    return { address = hex(a), type = t, count = count, values = vals }
  end
  return { address = hex(a), name = nameOf(a), type = t, value = readOne(a, t, p) }
end)

def("read_many", "le varios enderecos. params: addresses[], type?", function(p)
  requireProcess()
  if type(p.addresses) ~= "table" then fail("'addresses' deve ser uma lista") end
  if #p.addresses > 20000 then fail("limite de 20000 enderecos por chamada") end
  local t = canonType(p.type, "dword")
  local out = {}
  for i, s in ipairs(p.addresses) do
    local a = resolve(s)
    if a then
      local ok, v = pcall(readOne, a, t, p)
      out[i] = { address = hex(a), value = ok and v or nil, error = (not ok) and tostring(v) or nil }
    else
      out[i] = { address = s, error = "endereco invalido" }
    end
  end
  return { count = #out, type = t, values = out }
end)

local function walkPointer(base, offsets)
  local a = addr(base, "base")
  local passos = { { step = "base", address = hex(a), name = nameOf(a) } }
  for i, o in ipairs(offsets or {}) do
    local off = type(o) == "number" and o or toNumber(o)
    if off == nil then fail("offset invalido na posicao " .. i .. ": " .. tostring(o)) end
    local okP, ptr = pcall(readPointer, a)
    if not okP or ptr == nil or ptr == 0 then
      passos[#passos + 1] = { step = i, error = "ponteiro nulo/ilegivel em " .. hex(a) }
      return nil, passos
    end
    a = ptr + off
    passos[#passos + 1] = { step = i, pointer = hex(ptr), offset = hex(off), address = hex(a) }
  end
  return a, passos
end

def("pointer", "segue cadeia [[base]+o1]+o2... params: base, offsets[], type?, signed?",
function(p)
  requireProcess()
  local final, passos = walkPointer(p.base or p.address, p.offsets)
  local r = { chain = passos, address = final and hex(final) or nil, valid = final ~= nil }
  if final and p.type then
    local t = canonType(p.type)
    local ok, v = pcall(readOne, final, t, p)
    r.type, r.value = t, ok and v or nil
    if not ok then r.error = tostring(v) end
  end
  return r
end)

def("dump", "hexdump. params: address, size?=256 (max 64 KiB)", function(p)
  requireProcess()
  local a = addr(p.address, "address")
  local n = math.max(1, math.min(tonumber(p.size) or 256, 65536))
  local ok, b = pcall(readBytes, a, n, true)
  if not ok or type(b) ~= "table" then fail("readBytes falhou em " .. hex(a)) end
  local linhas = {}
  for i = 1, #b, 16 do
    local hx, asc = {}, {}
    for j = i, math.min(i + 15, #b) do
      hx[#hx + 1] = string.format("%02X", b[j])
      asc[#asc + 1] = (b[j] >= 32 and b[j] < 127) and string.char(b[j]) or "."
    end
    linhas[#linhas + 1] = string.format("%s  %-47s  %s", hex(a + i - 1), table.concat(hx, " "), table.concat(asc))
  end
  return { address = hex(a), size = #b, lines = linhas }
end)

-- ===========================================================================
-- 4. Escrita transacional
-- ===========================================================================
def("write", "escreve memoria (guarda original p/ rollback). params: address, type?, value | bytes, txn?, transactional?=true, terminate?=true (strings)",
function(p)
  requireProcess()
  local a = addr(p.address, "address")
  local t = canonType(p.type, p.bytes and "bytes" or "dword")
  local payload, size
  if t == "bytes" then
    payload = parseBytes(p.bytes or p.value)
    size = #payload
    if size == 0 then fail("payload vazio") end
  elseif t == "string" or t == "widestring" then
    if type(p.value) ~= "string" or p.value == "" then fail("'value' deve ser string nao vazia") end
    size = #p.value * (t == "widestring" and 2 or 1)
    if p.terminate ~= false then size = size + (t == "widestring" and 2 or 1) end
  else
    if p.value == nil then fail("'value' obrigatorio") end
    size = sizeOf(t)
  end

  local txnId = p.txn or newId("w")
  local okO, original = pcall(readBytes, a, size, true)
  if not okO or type(original) ~= "table" then fail("endereco ilegivel: " .. hex(a)) end
  if p.transactional ~= false then
    Txn[txnId] = Txn[txnId] or {}
    table.insert(Txn[txnId], { address = a, original = original })
  end

  local ok, e
  if t == "bytes" then ok, e = pcall(writeBytes, a, payload)
  elseif t == "string" or t == "widestring" then
    ok, e = pcall(writeString, a, p.value, t == "widestring")
    if ok and p.terminate ~= false then
      local n = #p.value * (t == "widestring" and 2 or 1)
      ok, e = pcall(writeBytes, a + n, t == "widestring" and { 0, 0 } or { 0 })
    end
  else ok, e = pcall(writeTyped, a, t, p.value) end
  if not ok then fail("escrita falhou: " .. tostring(e)) end

  local okD, depois = pcall(readBytes, a, size, true)
  local r = { address = hex(a), name = nameOf(a), type = t, size = size,
              before = bytesToHex(original), after = okD and bytesToHex(depois) or nil,
              txn = p.transactional ~= false and txnId or nil }
  if t ~= "bytes" and t ~= "string" and t ~= "widestring" then
    local okV, v = pcall(readTyped, a, t, p.signed)
    r.value = okV and v or nil
  end
  r.changed = r.before ~= r.after
  return r
end)

def("txn_list", "transacoes de escrita guardadas", function()
  local out = {}
  for id, ws in pairs(Txn) do out[#out + 1] = { txn = id, writes = #ws } end
  table.sort(out, function(x, y) return x.txn < y.txn end)
  return { count = #out, transactions = out }
end)

def("txn_rollback", "desfaz escritas. params: txn | all=true", function(p)
  local alvos = {}
  if p.all then for id in pairs(Txn) do alvos[#alvos + 1] = id end
  elseif p.txn then alvos[1] = p.txn
  else fail("informe 'txn' ou all=true") end
  local revertidas = 0
  for _, id in ipairs(alvos) do
    local ws = Txn[id]
    if ws then
      for i = #ws, 1, -1 do
        if pcall(writeBytes, ws[i].address, ws[i].original) then revertidas = revertidas + 1 end
      end
      Txn[id] = nil
    end
  end
  return { transactions = #alvos, reverted_writes = revertidas }
end)

def("alloc", "aloca memoria no alvo. params: size, near?", function(p)
  requireProcess()
  local size = tonumber(p.size)
  if not size or size < 1 then fail("'size' obrigatorio") end
  local base = p.near and addr(p.near, "near") or nil
  local a = allocateMemory(size, base)
  if not a or a == 0 then fail("allocateMemory falhou") end
  return { address = hex(a), size = size }
end)

def("dealloc", "libera memoria alocada. params: address", function(p)
  local a = addr(p.address, "address")
  local ok, e = pcall(deAlloc, a)
  if not ok then fail("deAlloc falhou: " .. tostring(e)) end
  return { address = hex(a), freed = true }
end)

-- ===========================================================================
-- 5/6. Scanner ASSINCRONO (first/next scan e AOB)
-- ---------------------------------------------------------------------------
-- Nunca esperar o scan dentro do metodo. O MemScan do CE usa dezenas de
-- threads que, em algum momento, precisam da thread principal; bloquear a
-- thread principal em waitTillDone() travou o CE 7.7.1 de forma intermitente
-- em teste real (gdb: thread principal em pthread_cond_wait e ~33 threads
-- "Memscan TScanCo" presas no mesmo mutex). Por isso scan_first, scan_next e
-- aob_scan so DISPARAM o scan e voltam na hora; o cliente consulta
-- scan_status ate done=true (o `ce` faz isso sozinho) e so entao le os
-- resultados. A thread principal fica livre o tempo todo.
-- ===========================================================================
local VT = { byte = vtByte, word = vtWord, dword = vtDword, qword = vtQword,
             float = vtSingle, double = vtDouble, string = vtString, widestring = vtString,
             bytes = vtByteArray, all = vtAll, binary = vtBinary, pointer = nil }

local FIRST_OPT = { exact = soExactValue, value = soExactValue, between = soValueBetween,
                    bigger = soBiggerThan, greater = soBiggerThan, smaller = soSmallerThan,
                    less = soSmallerThan, unknown = soUnknownValue }
local NEXT_OPT = { exact = soExactValue, value = soExactValue, between = soValueBetween,
                   bigger = soBiggerThan, greater = soBiggerThan, smaller = soSmallerThan,
                   less = soSmallerThan, increased = soIncreasedValue,
                   increased_by = soIncreasedValueBy, decreased = soDecreasedValue,
                   decreased_by = soDecreasedValueBy, changed = soChanged,
                   unchanged = soUnchanged }
local ROUND = { rounded = rtRounded, truncated = rtTruncated, extreme = rtExtremerounded }

local function ticks() return (getTickCount and getTickCount()) or math.floor(os.clock() * 1000) end

local function scanRecord(id)
  if id == nil or id == "last" then id = ScanOrder[#ScanOrder] end
  local rec = id and Scans[id]
  if not rec then fail("scan nao encontrado: " .. tostring(id) .. " (use scan_first)") end
  return rec, id
end

-- Pronto? (espera de no maximo 1 ms: nunca segura a thread principal)
local function scanIsDone(rec)
  if rec.done then return true end
  local ok, r = pcall(rec.ms.waitTillDone, 1)
  if ok and r == true then
    rec.done = true
    rec.t1 = rec.t1 or ticks()
  end
  return rec.done
end

local function requireDone(rec, id)
  if not scanIsDone(rec) then
    fail("o scan " .. tostring(id) .. " ainda esta rodando: consulte scan_status ate done=true")
  end
end

-- Dispara o scan sem esperar. OnScanDone marca o fim (chega pela thread principal).
local function launch(rec, starter)
  rec.done, rec.t0, rec.t1 = false, ticks(), nil
  pcall(function()
    rec.ms.OnScanDone = function() rec.done = true; rec.t1 = rec.t1 or ticks() end
  end)
  local ok, err = pcall(starter)
  if not ok then
    rec.done = true
    fail(tostring(err))
  end
end

local function register(rec)
  local id = newId("s")
  Scans[id] = rec
  ScanOrder[#ScanOrder + 1] = id
  return id
end

local function readResults(rec, offset, limite, comValores, comNomes)
  local fl = createFoundList(rec.ms)
  fl.initialize()
  local total = fl.Count or 0
  local out = {}
  offset = math.max(0, tonumber(offset) or 0)
  local ultimo = math.min(total, offset + limite) - 1
  for i = offset, ultimo do
    local a = "0x" .. fl.Address[i]
    local item = { address = a }
    if comValores then item.value = fl.Value[i] end
    if comNomes then item.name = nameOf(tonumber(fl.Address[i], 16)) end
    out[#out + 1] = item
  end
  fl.deinitialize()
  fl.destroy()
  return out, total
end

local function scanSummary(rec, id, p)
  local preview = tonumber(p.preview)
  if preview == nil then preview = 20 end
  local r = { scan_id = id, done = true, type = rec.type, found = rec.ms.FoundCount, scans = rec.scans,
              seconds = (rec.t1 and rec.t0) and ((rec.t1 - rec.t0) / 1000) or nil, pattern = rec.pattern }
  if rec.ms.ErrorString and rec.ms.ErrorString ~= "" then
    r.error = rec.ms.ErrorString
    rec.errored = true  -- ver scan_free: nao destruir
  end
  if preview > 0 and (r.found or 0) > 0 then
    local nomes = p.names or rec.aob
    r.results = readResults(rec, 0, math.min(preview, CONFIG.max_results), not rec.aob, nomes)
    r.truncated = r.found > #r.results
  end
  return r
end

local function running(rec, id)
  return { scan_id = id, done = false, running = true, type = rec.type, scans = rec.scans,
           next = "scan_status {scan_id} ate done=true" }
end

def("scan_first", "DISPARA um first scan (assincrono; depois scan_status). params: value?, value2?, type?=dword, option? (exact|between|bigger|smaller|unknown), rounding?, module?|start?/stop?, protection?, aligned?=true, hex?, unicode?, case?",
function(p)
  requireProcess()
  local t = canonType(p.type, "dword")
  local vt = VT[t]
  if vt == nil then fail("tipo nao escaneavel: " .. t) end
  local optName = tostring(p.option or (p.value == nil and "unknown" or "exact")):lower()
  local so = FIRST_OPT[optName]
  if so == nil then fail("option invalida para first scan: " .. optName) end
  if so ~= soUnknownValue and p.value == nil then fail("'value' obrigatorio para option=" .. optName) end
  local rt = ROUND[tostring(p.rounding or "rounded"):lower()] or rtRounded

  local start, stop = 0, (is64() and 0x7FFFFFFFFFFFFFFF or 0xFFFFFFFF)
  if p.module then
    local m = findModule(p.module)
    if not m then fail("modulo nao encontrado: " .. tostring(p.module)) end
    start, stop = m.base, m.base + m.size
  end
  if p.start then start = addr(p.start, "start") end
  if p.stop then stop = addr(p.stop, "stop") end

  local prot = p.protection or (IS_WIN and "+W*X-C" or "+W*X*C")
  local alignType, alignParam = fsmNotAligned, "1"
  local sz = sizeOf(t)
  if p.aligned ~= false and sz and sz > 1 then alignType, alignParam = fsmAligned, tostring(sz) end
  if t == "all" and p.aligned ~= false then alignType, alignParam = fsmAligned, "4" end
  local isHex = (p.hex == true) or (t == "bytes")
  local uni = (t == "widestring" or p.unicode == true)

  local ms = createMemScan()
  local rec = { ms = ms, type = t, created = os.time(), scans = 1, first = optName,
                hex = isHex, unicode = uni, case = p.case == true }
  local okL, errL = pcall(launch, rec, function()
    ms.firstScan(so, vt, rt,
      p.value ~= nil and tostring(p.value) or "", p.value2 ~= nil and tostring(p.value2) or "",
      start, stop, prot, alignType, alignParam, isHex, false, uni, p.case == true)
  end)
  if not okL then pcall(ms.destroy); fail("firstScan falhou: " .. tostring(errL)) end
  return running(rec, register(rec))
end)
alias("scan_new", "scan_first")
alias("scan_create", "scan_first")

def("scan_next", "DISPARA um next scan (assincrono; depois scan_status). params: scan_id?=ultimo, option? (exact|between|bigger|smaller|increased|increased_by|decreased|decreased_by|changed|unchanged), value?, value2?, percentage?, compare_to? ('FIRST' ou salvo)",
function(p)
  local rec, id = scanRecord(p.scan_id)
  requireDone(rec, id)
  local optName = tostring(p.option or (p.value == nil and "changed" or "exact")):lower()
  local so = NEXT_OPT[optName]
  if so == nil then fail("option invalida para next scan: " .. optName) end
  local precisa = { exact = 1, value = 1, between = 1, bigger = 1, greater = 1, smaller = 1,
                    less = 1, increased_by = 1, decreased_by = 1 }
  if precisa[optName] and p.value == nil then fail("'value' obrigatorio para option=" .. optName) end
  local rt = ROUND[tostring(p.rounding or "rounded"):lower()] or rtRounded
  local okL, errL = pcall(launch, rec, function()
    rec.ms.nextScan(so, rt,
      p.value ~= nil and tostring(p.value) or "", p.value2 ~= nil and tostring(p.value2) or "",
      rec.hex, false, rec.unicode, rec.case, p.percentage == true, p.compare_to)
  end)
  if not okL then fail("nextScan falhou: " .. tostring(errL)) end
  rec.scans = rec.scans + 1
  rec.last = optName
  return running(rec, id)
end)
alias("scan_refine", "scan_next")

def("aob_scan", "DISPARA busca de padrao de bytes ('48 8B ?? 05'; assincrono, depois scan_status). params: pattern, module?, protection?='*W*X*C'",
function(p)
  requireProcess()
  local pat = p.pattern or p.aob
  if type(pat) ~= "string" or pat == "" then fail("'pattern' obrigatorio") end
  local start, stop = 0, (is64() and 0x7FFFFFFFFFFFFFFF or 0xFFFFFFFF)
  if p.module then
    local m = findModule(p.module)
    if not m then fail("modulo nao encontrado: " .. tostring(p.module)) end
    start, stop = m.base, m.base + m.size
  end
  local ms = createMemScan()
  local rec = { ms = ms, type = "bytes", created = os.time(), scans = 1, first = "aob",
                hex = true, unicode = false, case = false, aob = true, pattern = pat }
  local okL, errL = pcall(launch, rec, function()
    ms.firstScan(soExactValue, vtByteArray, rtRounded, pat, "", start, stop,
                 p.protection or "*W*X*C", fsmNotAligned, "1", true, false, false, false)
  end)
  if not okL then pcall(ms.destroy); fail("AOB falhou: " .. tostring(errL)) end
  return running(rec, register(rec))
end)

def("scan_status", "estado de um scan assincrono; com done=true traz found e previa. params: scan_id?, preview?=20, names?",
function(p)
  local rec, id = scanRecord(p.scan_id)
  if not scanIsDone(rec) then
    local r = running(rec, id)
    r.seconds = (ticks() - (rec.t0 or ticks())) / 1000
    pcall(function() r.progress = rec.ms.getProgress() end)
    return r
  end
  return scanSummary(rec, id, p)
end)

def("scan_cancel", "interrompe um scan em andamento. params: scan_id?", function(p)
  local rec, id = scanRecord(p.scan_id)
  if scanIsDone(rec) then return { scan_id = id, done = true, cancelled = false } end
  pcall(rec.ms.terminateScan, false)
  return { scan_id = id, cancelled = true }
end)

def("scan_results", "resultados (scan concluido). params: scan_id?, offset?=0, limit?=100, values?=true, names?",
function(p)
  local rec, id = scanRecord(p.scan_id)
  requireDone(rec, id)
  local limite = math.min(tonumber(p.limit) or 100, CONFIG.max_results)
  local out, total = readResults(rec, p.offset, limite, p.values ~= false and not rec.aob, p.names)
  return { scan_id = id, type = rec.type, total = total, offset = tonumber(p.offset) or 0,
           count = #out, truncated = total > (tonumber(p.offset) or 0) + #out, results = out }
end)

def("scan_save", "salva resultados p/ comparar depois (compare_to). params: scan_id?, name",
function(p)
  local rec, id = scanRecord(p.scan_id)
  requireDone(rec, id)
  if not p.name then fail("'name' obrigatorio") end
  rec.ms.saveCurrentResults(p.name)
  return { scan_id = id, saved = p.name }
end)

def("scan_list", "scans abertos", function()
  local out = {}
  for _, id in ipairs(ScanOrder) do
    local r = Scans[id]
    if r then
      local pronto = scanIsDone(r)
      out[#out + 1] = { scan_id = id, type = r.type, done = pronto, found = pronto and r.ms.FoundCount or nil,
                        scans = r.scans, first = r.first, last = r.last, pattern = r.pattern }
    end
  end
  return { count = #out, scans = out }
end)

def("scan_free", "libera scan(s) (interrompe se estiver rodando). params: scan_id? | all=true", function(p)
  local alvos = {}
  if p.all then alvos = { table.unpack(ScanOrder) }
  else local _, id = scanRecord(p.scan_id); alvos[1] = id end
  for _, id in ipairs(alvos) do
    local r = Scans[id]
    if r then
      if not scanIsDone(r) then pcall(r.ms.terminateScan, true) end
      if r.errored then
        -- Scan que terminou com erro interno do CE (ex.: "thread 2:Duplicate ID",
        -- visto no 7.7.1): destroy() pode esperar para sempre por threads mortas.
        -- Melhor vazar o objeto do que travar a thread principal.
        log("scan %s com erro do CE: objeto mantido (sem destroy)", id)
      else
        pcall(r.ms.destroy)
      end
    end
    Scans[id] = nil
    for i = #ScanOrder, 1, -1 do if ScanOrder[i] == id then table.remove(ScanOrder, i) end end
  end
  return { freed = #alvos }
end)

-- ===========================================================================
-- 7. Tabela de enderecos (memory records), freeze, .CT
-- ===========================================================================
local VT_NAME = { byte = "vtByte", word = "vtWord", dword = "vtDword", qword = "vtQword",
                  float = "vtSingle", double = "vtDouble", string = "vtString",
                  widestring = "vtString", bytes = "vtByteArray", pointer = "vtQword",
                  binary = "vtBinary" }

local function al() return getAddressList() end

-- Endereco absoluto -> '"modulo"+offset' (sobrevive a ASLR) ou hex puro.
local function moduleRelative(a)
  for _, m in ipairs(listModules()) do
    if a >= m.base and a < m.base + m.size then
      return string.format('"%s"+%X', m.name, a - m.base)
    end
  end
  return string.format("%X", a)
end

-- Texto de endereco que o CE consegue reinterpretar sozinho (memory records
-- sao reavaliados pelo CE o tempo todo; "modulo.simbolo" nao resolve no Linux).
local function ceAddrString(param)
  if type(param) == "number" then return moduleRelative(param) end
  local s = tostring(param)
  if not s:match("^0[xX]%x+$") and not s:match("^%x+$") then
    local ok, a = pcall(getAddressSafe, s)
    if ok and a ~= nil and toNumber(a) ~= 0 then return s end
  end
  local r, err = resolve(s)
  if not r then fail(err) end
  return moduleRelative(r)
end

local function recordInfo(mr)
  local r = { id = mr.ID, index = mr.Index, description = mr.Description,
              type = mr.VarType, active = mr.Active }
  local okA, a = pcall(function() return mr.Address end)
  r.address = okA and a or nil
  local n = mr.OffsetCount or 0
  if n > 0 then
    -- ordem natural (a mesma do record_add / ce add): OffsetText[n-1] e o 1o aplicado
    r.offsets = {}
    for i = n - 1, 0, -1 do
      local okO, o = pcall(function() return mr.OffsetText[i] end)
      r.offsets[#r.offsets + 1] = okO and o or nil
    end
  end
  local okC, c = pcall(function() return mr.CurrentAddress end)
  if okC and c then r.current_address = hex(c) end
  local okV, v = pcall(function() return mr.Value end)
  if okV then r.value = v end
  if mr.Type == vtAutoAssembler then r.script = true end
  if mr.IsGroupHeader then r.group = true end
  return r
end

local function findRecord(p)
  local lista = al()
  if p.id ~= nil then
    local mr = lista.getMemoryRecordByID(tonumber(p.id))
    if mr then return mr end
    fail("memory record nao encontrado: id=" .. tostring(p.id))
  end
  if p.description then
    local mr = lista.getMemoryRecordByDescription(p.description)
    if mr then return mr end
    fail("memory record nao encontrado: " .. tostring(p.description))
  end
  fail("informe 'id' ou 'description'")
end

def("records", "lista a tabela de enderecos. params: filter?, limit?", function(p)
  local lista = al()
  local filtro = p.filter and tostring(p.filter):lower()
  local limite = tonumber(p.limit) or 500
  local out = {}
  for i = 0, lista.Count - 1 do
    local mr = lista[i]
    if not filtro or (mr.Description or ""):lower():find(filtro, 1, true) then
      if #out < limite then out[#out + 1] = recordInfo(mr) end
    end
  end
  return { count = #out, total = lista.Count, records = out }
end)

def("record_add", "adiciona entrada na tabela. params: address (ou base), offsets[]?, type?, description?, value?, freeze?, hex?, signed?, length? (string/bytes)",
function(p)
  local t = canonType(p.type, "dword")
  local mr = al().createMemoryRecord()
  mr.Description = p.description or ("agente " .. tostring(p.address or p.base))
  local base = p.address or p.base
  if base == nil then mr.destroy(); fail("'address' obrigatorio") end
  local okA, txt = pcall(ceAddrString, base)
  if not okA then mr.destroy(); fail(txt) end
  mr.Address = txt
  if type(p.offsets) == "table" and #p.offsets > 0 then
    mr.OffsetCount = #p.offsets
    -- No CE, Offset[0] e o ULTIMO aplicado; recebemos na ordem natural.
    for i, o in ipairs(p.offsets) do
      local txt = type(o) == "number" and string.format("%X", o) or tostring(o):gsub("^0[xX]", "")
      mr.OffsetText[#p.offsets - i] = txt
    end
  end
  mr.VarType = VT_NAME[t] or "vtDword"
  if t == "string" or t == "widestring" then
    pcall(function() mr.String.Size = tonumber(p.length) or 32; mr.String.Unicode = (t == "widestring") end)
  elseif t == "bytes" then
    pcall(function() mr.Aob.Size = tonumber(p.length) or 8 end)
  end
  if p.hex then mr.ShowAsHex = true end
  if p.signed then mr.ShowAsSigned = true end
  if p.value ~= nil then mr.Value = tostring(p.value) end
  if p.freeze then mr.Active = true end
  Records[mr.ID] = true
  return recordInfo(mr)
end)

def("record_add_script", "cria entrada de script Auto Assembler na tabela (vira 'cheat' clicavel no CE). params: script, description?, enable?",
function(p)
  if type(p.script) ~= "string" then fail("'script' obrigatorio") end
  local mr = al().createMemoryRecord()
  mr.Type = vtAutoAssembler
  mr.Script = p.script
  mr.Description = p.description or "script do agente"
  Records[mr.ID] = true
  if p.enable then
    mr.Active = true
    if not mr.Active then
      local info = recordInfo(mr)
      info.error = "o script nao ativou (veja com aa_check)"
      return info
    end
  end
  return recordInfo(mr)
end)

def("record_set", "altera entrada. params: id|description, value?, freeze? (bool), description_new?",
function(p)
  local mr = findRecord(p)
  if p.value ~= nil then mr.Value = tostring(p.value) end
  if p.freeze ~= nil then mr.Active = p.freeze and true or false end
  if p.active ~= nil then mr.Active = p.active and true or false end
  if p.description_new then mr.Description = p.description_new end
  return recordInfo(mr)
end)

def("record_delete", "remove entrada(s). params: id | description | agent_only=true (as criadas pelo agente)",
function(p)
  local n = 0
  if p.agent_only then
    local lista = al()
    for id in pairs(Records) do
      local mr = lista.getMemoryRecordByID(id)
      if mr then pcall(function() mr.Active = false end); mr.destroy(); n = n + 1 end
      Records[id] = nil
    end
    return { deleted = n }
  end
  local mr = findRecord(p)
  Records[mr.ID] = nil
  pcall(function() mr.Active = false end)
  mr.destroy()
  return { deleted = 1 }
end)

def("freeze", "congela valor (cria entrada ativa). params: address|base, offsets[]?, type?, value?, description?",
function(p)
  p.freeze = true
  p.description = p.description or ("freeze " .. tostring(p.address or p.base))
  return Methods.record_add(p)
end)

def("unfreeze", "descongela. params: id|description, delete?=false", function(p)
  local mr = findRecord(p)
  mr.Active = false
  if p.delete then Records[mr.ID] = nil; mr.destroy(); return { id = p.id, deleted = true } end
  return recordInfo(mr)
end)

def("table_save", "salva a tabela (.CT). params: path", function(p)
  if not p.path then fail("'path' obrigatorio") end
  saveTable(p.path)
  return { saved = p.path }
end)

def("table_load", "carrega .CT/.CETRAINER sem dialogo de Lua. params: path, merge?=false", function(p)
  if not p.path then fail("'path' obrigatorio") end
  local fs = createFileStream(p.path, fmOpenRead | fmShareDenyNone)
  local ok, e = pcall(loadTable, fs, p.merge and true or false, true)
  pcall(fs.destroy)
  if not ok then fail("loadTable falhou: " .. tostring(e)) end
  if not p.merge then Records = {} end  -- IDs sao reaproveitados pelo CE
  return { loaded = p.path, records = al().Count }
end)

-- ===========================================================================
-- 8. Auto Assembler (transacional) e assemble
-- ===========================================================================
-- O autoAssembleCheck do CE 7.7 so valida scripts com [ENABLE] e [DISABLE]
-- (ou nenhum); com so [ENABLE] devolve false sem erro. Por isso check sem
-- mensagem nao prova erro de sintaxe.
def("aa_check", "valida script Auto Assembler. params: script, target_self?", function(p)
  if type(p.script) ~= "string" then fail("'script' obrigatorio") end
  local okE, errE = autoAssembleCheck(p.script, true, p.target_self and true or false)
  local temDisable = p.script:lower():find("%[disable%]") ~= nil
  local okD, errD = true, nil
  if temDisable then okD, errD = autoAssembleCheck(p.script, false, p.target_self and true or false) end
  local inconclusivo = (not okE) and (errE == nil or errE == "")
  local notas = {}
  if inconclusivo then notas[#notas + 1] = "CE 7.7 nao valida script so com [ENABLE]; teste com aa_apply" end
  -- [DISABLE] checado sozinho nao conhece o que o [ENABLE] alocou/registrou:
  -- dealloc/unregistersymbol acusam erro, mas o revert real (com disableInfo) funciona.
  local falsoNeg = (not okD) and type(errD) == "string" and
    (errD:lower():find("dealloc", 1, true) or errD:lower():find("unregistersymbol", 1, true)) ~= nil
  if falsoNeg then
    notas[#notas + 1] = "erro no [DISABLE] isolado em dealloc/unregistersymbol e falso negativo conhecido; o revert real usa o disableInfo"
  end
  return { enable_ok = okE and true or false, enable_error = errE,
           disable_ok = (okD or falsoNeg) and true or false, disable_error = errD,
           inconclusive = inconclusivo or nil,
           note = #notas > 0 and table.concat(notas, " | ") or nil }
end)

def("aa_apply", "executa [ENABLE] e guarda disableInfo p/ reverter. params: script, target_self?",
function(p)
  if type(p.script) ~= "string" then fail("'script' obrigatorio") end
  local ts = p.target_self and true or false
  local ok, info = autoAssemble(p.script, ts)
  if not ok then fail("autoAssemble falhou: " .. tostring(info)) end
  local id = newId("aa")
  AAScripts[id] = { script = p.script, target_self = ts, disableInfo = info, at = os.time() }
  local r = { aa_id = id, applied = true }
  if type(info) == "table" then
    r.allocs, r.symbols = {}, {}
    for k, v in pairs(info.allocs or {}) do
      r.allocs[#r.allocs + 1] = { name = k, address = hex(toNumber(v.address) or v.address), size = v.size }
    end
    for k, v in pairs(info.registeredsymbols or {}) do r.symbols[#r.symbols + 1] = tostring(type(k) == "number" and v or k) end
  end
  return r
end)

def("aa_revert", "executa [DISABLE] de um script aplicado. params: aa_id", function(p)
  local e = AAScripts[p.aa_id]
  if not e then fail("aa_id nao encontrado: " .. tostring(p.aa_id)) end
  local ok, err = autoAssemble(e.script, e.target_self, e.disableInfo)
  if not ok then fail("falha ao reverter: " .. tostring(err)) end
  AAScripts[p.aa_id] = nil
  return { aa_id = p.aa_id, reverted = true }
end)

def("aa_list", "scripts AA aplicados", function()
  local out = {}
  for id, e in pairs(AAScripts) do
    out[#out + 1] = { aa_id = id, at = e.at, lines = select(2, e.script:gsub("\n", "\n")) + 1 }
  end
  return { count = #out, scripts = out }
end)

def("aa_revert_all", "reverte todos os scripts AA aplicados", function()
  local n, falhas = 0, {}
  for id, e in pairs(AAScripts) do
    local ok, err = autoAssemble(e.script, e.target_self, e.disableInfo)
    if ok then n = n + 1 else falhas[#falhas + 1] = { aa_id = id, error = tostring(err) } end
    AAScripts[id] = nil
  end
  return { reverted = n, failures = falhas }
end)

def("assemble", "monta 1 instrucao. params: line, address?", function(p)
  if type(p.line) ~= "string" then fail("'line' obrigatorio") end
  local a = p.address and addr(p.address, "address") or nil
  local ok, b = pcall(assemble, p.line, a)
  if not ok or type(b) ~= "table" then fail("assemble falhou: " .. tostring(b)) end
  return { line = p.line, address = a and hex(a) or nil, bytes = bytesToHex(b), size = #b }
end)

-- ===========================================================================
-- 9. Disassembly
-- ===========================================================================
def("disassemble", "desmonta N instrucoes. params: address, count?=10 (max 500)", function(p)
  requireProcess()
  local a = addr(p.address, "address")
  local n = math.max(1, math.min(tonumber(p.count) or 10, 500))
  local out = {}
  for _ = 1, n do
    local ok, s = pcall(disassemble, a)
    if not ok or not s then break end
    local _, bytes, opcode, extra = splitDis(s)
    local size = getInstructionSize(a) or 1
    out[#out + 1] = { address = hex(a), name = nameOf(a), bytes = bytes, opcode = opcode,
                      extra = (extra and extra ~= "") and extra or nil, size = size }
    a = a + math.max(size, 1)
  end
  return { count = #out, instructions = out }
end)

def("instruction_size", "tamanho da instrucao. params: address", function(p)
  requireProcess()
  local a = addr(p.address, "address")
  return { address = hex(a), size = getInstructionSize(a) }
end)

-- ===========================================================================
-- 10. Debugger: "o que escreve/acessa este endereco" (assincrono)
-- ===========================================================================
local BPT = { write = bptWrite, access = bptAccess, execute = bptExecute }
local BPM = { debugreg = bpmDebugRegister, int3 = bpmInt3, exception = bpmException }

local function regsTable()
  local regs = {}
  local nomes = is64() and { "RAX", "RBX", "RCX", "RDX", "RSI", "RDI", "RBP", "RSP", "RIP",
                             "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15" }
                         or { "EAX", "EBX", "ECX", "EDX", "ESI", "EDI", "EBP", "ESP", "EIP" }
  for _, r in ipairs(nomes) do
    local v = rawget(_G, r)
    if v then regs[r] = hex(v) end
  end
  return regs
end

local function hitsList(w)
  local out = {}
  for _, ia in ipairs(w.order) do out[#out + 1] = w.hits[ia] end
  table.sort(out, function(x, y) return x.count > y.count end)
  return out
end

def("debug_start", "anexa o debugger. params: interface? (0 padrao)", function(p)
  requireProcess()
  if not debug_isDebugging() then
    local ok, e = pcall(debugProcess, tonumber(p.interface) or 0)
    if not ok then fail("debugProcess falhou: " .. tostring(e)) end
  end
  return { debugging = debug_isDebugging() and true or false,
           interface = debug_getCurrentDebuggerInterface and debug_getCurrentDebuggerInterface() or nil }
end)

def("watch_start", "breakpoint de dados que COLETA quem escreve/acessa (nao para o alvo). params: address, size?=4, kind?=write|access|execute, method?=debugreg",
function(p)
  requireProcess()
  local a = addr(p.address, "address")
  local kind = tostring(p.kind or "write"):lower()
  local trig = BPT[kind]
  if trig == nil then fail("kind invalido: " .. kind) end
  local size = tonumber(p.size) or 4
  local metodo = BPM[tostring(p.method or "debugreg"):lower()] or bpmDebugRegister
  if not debug_isDebugging() then
    local ok, e = pcall(debugProcess, 0)
    if not ok then fail("debugProcess falhou: " .. tostring(e)) end
  end
  local id = newId("wt")
  local w = { id = id, address = a, size = size, kind = kind, hits = {}, order = {},
              total = 0, started = os.time() }
  local function cb()
    local ip = rawget(_G, "RIP") or rawget(_G, "EIP")
    if ip then
      -- breakpoint de dados dispara DEPOIS da instrucao: o culpado e a anterior
      local ia = ip
      if kind ~= "execute" then
        local okP, prev = pcall(getPreviousOpcode, ip)
        if okP and prev then ia = prev end
      end
      w.total = w.total + 1
      local h = w.hits[ia]
      if not h then
        if #w.order < CONFIG.max_hits then
          local okD, d = pcall(disassemble, ia)
          h = { address = hex(ia), name = nameOf(ia), count = 0, instruction = okD and d or nil,
                registers = regsTable() }
          w.hits[ia] = h
          w.order[#w.order + 1] = ia
          pushEvent("watch_hit", { watch_id = id, address = hex(ia) })
        end
      end
      if h then h.count = h.count + 1 end
    end
    pcall(debug_continueFromBreakpoint, co_run)
    return 1
  end
  local ok, e = pcall(debug_setBreakpoint, a, size, trig, metodo, cb)
  if not ok then fail("debug_setBreakpoint falhou: " .. tostring(e)) end
  Watches[id] = w
  return { watch_id = id, address = hex(a), size = size, kind = kind }
end)

def("watch_poll", "hits coletados. params: watch_id", function(p)
  local w = Watches[p.watch_id]
  if not w then fail("watch nao encontrado: " .. tostring(p.watch_id)) end
  return { watch_id = w.id, address = hex(w.address), kind = w.kind, total_hits = w.total,
           seconds = os.time() - w.started, instructions = hitsList(w) }
end)

def("watch_stop", "remove o breakpoint e devolve os hits. params: watch_id | all=true", function(p)
  local alvos = {}
  if p.all then for id in pairs(Watches) do alvos[#alvos + 1] = id end
  else alvos[1] = p.watch_id end
  local res = {}
  for _, id in ipairs(alvos) do
    local w = Watches[id]
    if w then
      pcall(debug_removeBreakpoint, w.address)
      res[#res + 1] = { watch_id = id, address = hex(w.address), kind = w.kind, total_hits = w.total,
                        instructions = hitsList(w) }
      Watches[id] = nil
    end
  end
  if #res == 1 and not p.all then return res[1] end
  return { stopped = #res, watches = res }
end)

def("breakpoints", "lista breakpoints ativos", function()
  local ok, l = pcall(debug_getBreakpointList)
  local out = {}
  if ok and type(l) == "table" then for _, a in ipairs(l) do out[#out + 1] = hex(toNumber(a) or a) end end
  return { count = #out, breakpoints = out, debugging = debug_isDebugging() and true or false }
end)

def("events", "eventos assincronos. params: since?=0", function(p)
  local desde = tonumber(p.since) or 0
  local out = {}
  for _, ev in ipairs(Events) do if ev.seq > desde then out[#out + 1] = ev end end
  return { count = #out, last_seq = EventSeq, events = out }
end)

-- ===========================================================================
-- 11. Processo: pause, speedhack, mono
-- ===========================================================================
def("pause", "pausa o alvo", function() requireProcess(); pause(); return { paused = true } end)
def("unpause", "retoma o alvo", function() requireProcess(); unpause(); return { paused = false } end)

local function alvoWine()
  for _, m in ipairs(listModules()) do
    local n = (m.name or ""):lower()
    if n == "ntdll.dll" or n == "kernel32.dll" then return true end
  end
  return false
end

def("speedhack", "muda a velocidade do alvo (injeta o speedhack). params: speed (1.0 normal), force? (obrigatorio em alvo Linux nativo: no CE 7.7.1 isso ja derrubou o CE)",
function(p)
  requireProcess()
  local s = tonumber(p.speed)
  if not s then fail("'speed' obrigatorio") end
  if OS == 2 and not alvoWine() and not p.force then
    fail("speedhack em processo Linux nativo e instavel no CE 7.7.1 (injecao do " ..
         "libceserver-extension falhou e o CE fechou em teste real). Use force=true para tentar.")
  end
  local ok, e = pcall(speedhack_setSpeed, s)
  if not ok then fail("speedhack falhou: " .. tostring(e)) end
  local atual = speedhack_getSpeed and speedhack_getSpeed() or nil
  if atual and math.abs(atual - s) > 1e-6 then
    fail("o speedhack nao aplicou (velocidade atual " .. tostring(atual) .. ")")
  end
  return { speed = atual or s }
end)

def("mono_launch", "injeta o MonoDataCollector (Unity/Mono). Depois use eval com mono_*", function()
  requireProcess()
  if not LaunchMonoDataCollector then fail("monoscript.lua nao carregado") end
  local ok, r = pcall(LaunchMonoDataCollector)
  if not ok then fail("LaunchMonoDataCollector falhou: " .. tostring(r)) end
  return { mono_base = (r and r ~= 0) and hex(toNumber(r) or r) or nil, ok = (r and r ~= 0) and true or false }
end)

-- ===========================================================================
-- 12. GUI, hotkeys, timers
-- ===========================================================================
def("gui_show", "mostra a janela principal do CE", function()
  pcall(unhideMainCEwindow)
  pcall(function() MainForm.show(); MainForm.bringToFront() end)
  return { visible = true }
end)

def("gui_hide", "esconde as janelas do CE (continua funcionando)", function()
  pcall(hideAllCEWindows)
  return { visible = false }
end)

def("hotkey_add", "hotkey global que roda Lua. params: keys (ex 'VK_F5' ou {VK_CONTROL,VK_F5}), action (Lua)",
function(p)
  if type(p.action) ~= "string" then fail("'action' deve ser codigo Lua") end
  local fn, err = load(p.action, "=agent_hotkey", "t", _G)
  if not fn then fail("erro de sintaxe na acao: " .. tostring(err)) end
  local keys = p.keys
  if type(keys) == "string" then keys = { rawget(_G, keys) or keys } end
  if type(keys) == "table" then
    for i, k in ipairs(keys) do if type(k) == "string" then keys[i] = rawget(_G, k) or k end end
  end
  local okH, hk = pcall(createHotkey, function() pcall(fn) end, keys)
  if not okH or not hk then fail("createHotkey falhou: " .. tostring(hk)) end
  local id = newId("hk")
  Hotkeys[id] = hk
  return { hotkey_id = id }
end)

def("hotkey_remove", "remove hotkey. params: hotkey_id", function(p)
  local hk = Hotkeys[p.hotkey_id]
  if hk then pcall(hk.destroy) end
  Hotkeys[p.hotkey_id] = nil
  return { removed = hk ~= nil }
end)

def("timer_add", "roda Lua periodicamente no CE. params: action (Lua), interval?=1000 ms", function(p)
  if type(p.action) ~= "string" then fail("'action' deve ser codigo Lua") end
  local fn, err = load(p.action, "=agent_timer", "t", _G)
  if not fn then fail("erro de sintaxe na acao: " .. tostring(err)) end
  local t = createTimer(nil)
  t.Interval = math.max(10, tonumber(p.interval) or 1000)
  t.OnTimer = function() pcall(fn) end
  t.Enabled = true
  local id = newId("tm")
  Timers[id] = t
  return { timer_id = id, interval = t.Interval }
end)

def("timer_remove", "remove timer. params: timer_id", function(p)
  local t = Timers[p.timer_id]
  if t then pcall(t.destroy) end
  Timers[p.timer_id] = nil
  return { removed = t ~= nil }
end)

-- ===========================================================================
-- 13. Limpeza e encerramento
-- ===========================================================================
def("cleanup", "desfaz o estado do agente. params: revert_aa?=true, rollback_writes?=false, records?=true",
function(p)
  local r = {}
  if p.revert_aa ~= false then r.aa = Methods.aa_revert_all({}).reverted end
  if p.rollback_writes then r.writes = Methods.txn_rollback({ all = true }).reverted_writes end
  r.watches = Methods.watch_stop({ all = true }).stopped
  r.scans = Methods.scan_free({ all = true }).freed
  if p.records ~= false then r.records = Methods.record_delete({ agent_only = true }).deleted end
  local nh, nt = 0, 0
  for id, hk in pairs(Hotkeys) do pcall(hk.destroy); Hotkeys[id] = nil; nh = nh + 1 end
  for id, t in pairs(Timers) do pcall(t.destroy); Timers[id] = nil; nt = nt + 1 end
  r.hotkeys, r.timers = nh, nt
  Events = {}
  return r
end)

def("ce_close", "fecha o Cheat Engine sem dialogo 'salvar tabela?' (salva backup .CT antes). params: backup?=true",
function(p)
  local backup
  local okL, n = pcall(function() return al().Count end)
  if p.backup ~= false and okL and n and n > 0 then
    local dir = (os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or ".") .. "/.local/share")) ..
                "/cheatengine/agent-backups"
    if IS_WIN then dir = CONFIG.state_dir .. "\\backups" end
    mkdirs(dir)
    backup = dir .. SEP .. "antes-de-fechar-" .. os.date("%Y%m%d-%H%M%S") .. ".CT"
    pcall(saveTable, backup)
  end
  -- Sem isso o CE pergunta "salvar alteracoes?" e, headless, ninguem responde.
  pcall(function() MainForm.OnCloseQuery = function() return true end end)
  stop()
  local t = createTimer(nil)
  t.Interval = 300
  t.OnTimer = function(tt) tt.destroy(); closeCE() end
  t.Enabled = true
  return { closing = true, backup = backup }
end)

-- ===========================================================================
-- Despacho (sempre na thread principal)
-- ===========================================================================
local Stats = { served = 0, errors = 0, clients = 0, started = os.time() }

local function runMethod(method, params)
  local fn = Methods[method]
  if not fn then return nil, "metodo desconhecido: " .. tostring(method) .. " (veja 'help')" end
  local ok, res = pcall(fn, type(params) == "table" and params or {})
  if not ok then return nil, tostring(res) end
  if res == nil then return nil, "o metodo nao retornou resultado" end
  return res
end

local function onMain(method, params)
  if inMainThread and inMainThread() then return runMethod(method, params) end
  local box = {}
  local ok, err = pcall(synchronize, function()
    box.res, box.err = runMethod(method, params)
  end)
  if not ok then return nil, "synchronize falhou: " .. tostring(err) end
  return box.res, box.err
end

local TOKEN  -- definido no bootstrap

local function handleRaw(raw, exigirToken)
  local inicio = os.clock()
  local okD, req = pcall(jsonDecode, raw)
  if not okD or type(req) ~= "table" then
    return { id = nil, error = { code = -32700, message = "JSON invalido: " .. tostring(req) } }
  end
  if exigirToken and req.token ~= TOKEN then
    return { id = req.id, error = { code = -32001, message = "token invalido (leia o arquivo token do STATE_DIR)" } }
  end
  local res, err = onMain(req.method, req.params)
  Stats.served = Stats.served + 1
  local resp = { id = req.id, ms = math.floor((os.clock() - inicio) * 1000) }
  if err then
    Stats.errors = Stats.errors + 1
    resp.error = { code = -32000, message = err }
  else
    resp.result = res
  end
  return resp
end

-- ===========================================================================
-- Transporte 1: TCP localhost
-- ===========================================================================
local RS = string.char(0x1E)
local Server = { socket = nil, port = nil, stopping = false }

local function sendAll(c, s)
  local enviado = 0
  local tentativas = 0
  while enviado < #s do
    local n = c.writeString(s:sub(enviado + 1))
    if n == nil then return false end
    if n == 0 then
      tentativas = tentativas + 1
      if tentativas > 50 then return false end
      sleep(5)
    end
    enviado = enviado + n
  end
  return true
end

-- Fila de pedidos TCP -> thread principal. A thread do cliente so enfileira;
-- quem executa e o timer despachante (contexto normal da thread principal,
-- como um script de tabela), nunca um synchronize aninhado.
local Jobs = {}
local JobsCS = nil
pcall(function() JobsCS = createCriticalSection() end)

local function enqueue(job)
  if JobsCS then JobsCS.enter() end
  Jobs[#Jobs + 1] = job
  if JobsCS then JobsCS.leave() end
end

local function takeJobs()
  if JobsCS then JobsCS.enter() end
  local lote = Jobs
  Jobs = {}
  if JobsCS then JobsCS.leave() end
  return lote
end

local function serveClient(c)
  Stats.clients = Stats.clients + 1
  local buf = ""
  while not Server.stopping do
    local b = c.readBytesMin(1)
    if b == nil then break end
    buf = buf .. byteTableToString(b)
    if #buf > CONFIG.max_payload then
      sendAll(c, jsonEncode({ error = { code = -32600, message = "pedido grande demais" } }) .. RS)
      break
    end
    while true do
      local pos = buf:find(RS, 1, true)
      if not pos then break end
      local raw = buf:sub(1, pos - 1)
      buf = buf:sub(pos + 1)
      if raw ~= "" then
        -- NAO executa aqui nem via synchronize: enfileira e espera o despachante
        -- (timer da thread principal) responder.
        local job = { raw = raw, done = false }
        if createEvent then pcall(function() job.ev = createEvent(false, false) end) end
        enqueue(job)
        local voltas = 0
        while not job.done do
          if job.ev then job.ev.waitFor(250) else sleep(5) end
          voltas = voltas + 1
          -- encerrando (ce_close/recarga): ainda da ~5 s para a resposta sair
          if Server.stopping and voltas > 20 then break end
        end
        if job.ev then pcall(job.ev.destroy) end
        if job.done and not sendAll(c, job.resp .. RS) then
          log("falha ao enviar resposta")
        end
      end
    end
  end
  Stats.clients = Stats.clients - 1
  pcall(c.destroy)
end

local function startTcp()
  -- O celua.txt do 7.7.1 documenta createServerSocket, mas a funcao real (a
  -- que o server.lua oficial usa) e createSocketServer(porta, localhostOnly).
  local criar = rawget(_G, "createSocketServer") or rawget(_G, "createServerSocket")
  if not criar then log("sem createSocketServer nesta versao do CE"); return false end
  for i = 0, CONFIG.port_tries - 1 do
    local porta = CONFIG.port + i
    local ok, ss = pcall(criar, porta, true)
    if ok and ss then
      Server.socket, Server.port = ss, porta
      break
    end
  end
  if not Server.socket then
    log("TCP indisponivel nas portas %d..%d", CONFIG.port, CONFIG.port + CONFIG.port_tries - 1)
    return false
  end
  createThread(function(t)
    t.Name = "ce_agent_bridge:tcp"
    while not Server.stopping and not t.Terminated do
      local okA, c = pcall(Server.socket.acceptConnection, true)
      if Server.stopping then if okA and c then pcall(c.destroy) end break end
      if okA and c then
        createThread(function(ct)
          ct.Name = "ce_agent_bridge:client"
          local okC, errC = pcall(serveClient, c)
          if not okC then log("erro no cliente: %s", tostring(errC)); pcall(c.destroy) end
        end)
      else
        sleep(100)
      end
    end
    pcall(Server.socket.destroy)
    log("servidor TCP encerrado")
  end)
  return true
end

-- ===========================================================================
-- Transporte 2: caixa de correio em disco (lida pelo despachante)
-- ===========================================================================
local MailTimer = nil

local function pollMailbox()
  local ok, files = pcall(getFileList, CONFIG.mailbox_dir, "req_*.json")
  if not ok or type(files) ~= "table" then return end
  for _, f in ipairs(files) do
    local caminho = f
    if not (f:find("/", 1, true) or f:find("\\", 1, true)) then caminho = CONFIG.mailbox_dir .. SEP .. f end
    local nome = caminho:match("[^/\\]+$") or ""
    local raw = readFile(caminho)
    os.remove(caminho)
    if raw then
      local resp = handleRaw(raw, false)
      local rid = nome:match("^req_(.-)%.json$") or tostring(resp.id)
      writeFileAtomic(CONFIG.mailbox_dir .. SEP .. "resp_" .. rid .. ".json", jsonEncode(resp))
    end
  end
end

-- Despachante unico (thread principal): pedidos TCP enfileirados + caixa de
-- correio. Protegido contra reentrada (um metodo que processe mensagens nao
-- faz o timer rodar outro pedido no meio dele).
local Despachando = false
local Ciclo = 0

local function dispatchTick()
  if Despachando then return end
  Despachando = true
  local okT, errT = pcall(function()
    if #Jobs > 0 then
      for _, job in ipairs(takeJobs()) do
        local okH, resp = pcall(handleRaw, job.raw, true)
        if not okH then resp = { error = { code = -32603, message = tostring(resp) } } end
        local okE, txt = pcall(jsonEncode, resp)
        job.resp = okE and txt or '{"error":{"code":-32603,"message":"resposta nao serializavel"}}'
        job.done = true
        if job.ev then pcall(job.ev.setEvent) end
      end
    end
    Ciclo = Ciclo + 1
    if CONFIG.enable_mailbox and Ciclo % 4 == 0 then pollMailbox() end
  end)
  Despachando = false
  if not okT then log("erro no despachante: %s", tostring(errT)) end
end

local function startDispatcher()
  if CONFIG.enable_mailbox then mkdirs(CONFIG.mailbox_dir) end
  MailTimer = createTimer(nil)
  MailTimer.Interval = 5
  MailTimer.OnTimer = function() dispatchTick() end
  MailTimer.Enabled = true
end

-- ===========================================================================
-- Bootstrap
-- ===========================================================================
stop = function()
  Server.stopping = true
  if MailTimer then pcall(MailTimer.destroy); MailTimer = nil end
  -- destrava o acceptConnection com uma conexao local descartavel
  if Server.port then
    pcall(function()
      local c = connectToTCPServer("127.0.0.1", Server.port)
      if c then c.destroy() end
    end)
  end
  pcall(os.remove, CONFIG.state_dir .. SEP .. "bridge.json")
end

local function bootstrap()
  mkdirs(CONFIG.state_dir)
  local tokenPath = CONFIG.state_dir .. SEP .. "token"
  TOKEN = (readFile(tokenPath) or ""):gsub("%s+", "")
  if #TOKEN < 32 then
    TOKEN = randomHex(24)
    writeFileAtomic(tokenPath, TOKEN, true)
  end
  startDispatcher()
  local tcpOk = CONFIG.enable_tcp and startTcp() or false
  local info = {
    bridge = BRIDGE_VERSION, protocol = PROTOCOL,
    ce = getCEVersion and getCEVersion() or nil, os = OS,
    ce_pid = getCheatEngineProcessID and getCheatEngineProcessID() or nil,
    port = tcpOk and Server.port or nil, host = "127.0.0.1",
    mailbox = CONFIG.enable_mailbox and CONFIG.mailbox_dir or nil,
    token_file = tokenPath, started = os.time(),
  }
  writeFileAtomic(CONFIG.state_dir .. SEP .. "bridge.json", jsonEncode(info), true)
  log("v%s pronta | tcp=%s | mailbox=%s | CE %s", BRIDGE_VERSION,
      tostring(info.port), tostring(info.mailbox), tostring(info.ce))
end

local scriptPath = (debug and debug.getinfo and debug.getinfo(1, "S").source or ""):gsub("^@", "")

_G.ce_bridge = {
  version = BRIDGE_VERSION, protocol = PROTOCOL, config = CONFIG,
  methods = Methods, docs = Docs, path = scriptPath, stats = Stats,
  call = function(method, params)
    local res, err = runMethod(method, params)
    if err then error(err, 2) end
    return res
  end,
  safe_call = runMethod,
  push_event = pushEvent,
  encode = jsonEncode,
  stop = stop,
  status = function()
    return { version = BRIDGE_VERSION, port = Server.port, mailbox = CONFIG.mailbox_dir,
             served = Stats.served, errors = Stats.errors, clients = Stats.clients }
  end,
}

local okB, errB = pcall(bootstrap)
if not okB then
  log("FALHA no bootstrap: %s", tostring(errB))
  if print then print("[ce_agent_bridge] falha no bootstrap: " .. tostring(errB)) end
end
