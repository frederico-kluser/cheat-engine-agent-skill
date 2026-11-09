--[[
  lua_stubs.lua — API do Cheat Engine falsa, para testar a ponte fora do CE.

  Carregado ANTES de autorun/ce_agent_bridge.lua por scripts/test_autorun.py.
  A ideia: se a ponte tem um erro de runtime (nome de função errado, nil index,
  bad argument), ele aparece aqui como mensagem de erro do Lua 5.3 real do CE,
  em vez de virar um diálogo silencioso dentro da GUI do Cheat Engine.

  Todo stub registra a chamada em _STUB_CALLS para que o teste possa afirmar
  "o handler X chamou mesmo a API Y".
]]

_STUB_CALLS = {}
local function rec(name, ...)
  _STUB_CALLS[#_STUB_CALLS + 1] = { name = name, args = { ... } }
  return ...
end
_G.rec = rec

-- ---------------------------------------------------------------- constantes
-- Nomes reais do CELua 7.7 (celua.txt). A ponte passa esses valores como string
-- para as propriedades do MemScan, entao basta que existam como globais.
local SCAN_OPTIONS = {
  "soExactValue", "soValueBetween", "soBiggerThan", "soSmallerThan",
  "soIncreasedValue", "soIncreasedValueBy", "soDecreasedValue",
  "soDecreasedValueBy", "soChanged", "soUnchanged",
}
for _, n in ipairs(SCAN_OPTIONS) do _G[n] = n end

local VAR_TYPES = {
  "vtByte", "vtWord", "vtDword", "vtQword", "vtSingle", "vtDouble", "vtString",
  "vtUnicodeString", "vtByteArray", "vtBinary", "vtAll", "vtAutoAssembler",
  "vtPointer", "vtGrouped",
}
for _, n in ipairs(VAR_TYPES) do _G[n] = n end

_G.roundedDefault = "roundedDefault"
_G.rtRounded = "rtRounded"
_G.stNewScan, _G.stNextScan, _G.stFirstScan = "stNewScan", "stNextScan", "stFirstScan"
_G.scanDontCare, _G.scanExclude, _G.scanInclude = "scanDontCare", "scanExclude", "scanInclude"
_G.tpNormal = "tpNormal"
_G.ffExactValue = "ffExactValue"
_G.littleEndian, _G.bigEndian = "littleEndian", "bigEndian"

-- ------------------------------------------------------------------ maquina
function getCEVersion() return 7.7 end
function getCheatEngineFileVersion() return 7.7, { major = 7, minor = 7, release = 0, build = 0 } end
function getOperatingSystem() return rec("getOperatingSystem", 0) end
function getSystemArchitecture() return rec("getSystemArchitecture", 1) end
function getABI() return rec("getABI", 0) end
function getCheatEngineProcessID() return rec("getCheatEngineProcessID", 4321) end
function isAdmin() return rec("isAdmin", false) end
function getOpenedProcessID() return _STUB_PID or 0 end
function getOpenedProcessHandle() return _STUB_PID and 0x1F4 or 0 end
function targetIs64Bit() return rec("targetIs64Bit", true) end
function setPointerSize(size) return rec("setPointerSize", size) end
function getPointerSize() return 8 end
function getAddressSafe(expr, local_)
  rec("getAddressSafe", expr, local_)
  if expr == "jogo.exe+1000" then return 0x140001000 end
  if expr == "jogo.exe" then return 0x140000000 end
  if expr == "naoexiste" then return nil end
  return tonumber(expr)
end
function getAddress(expr, local_) return rec("getAddress", expr, local_) or 0x140001000 end
function getNameFromAddress(addr) return rec("getNameFromAddress", addr, "jogo.exe+1000") end
function getModuleSize(name) return rec("getModuleSize", name, 0x10000) end
function registerSymbol(name, addr, nosave) return rec("registerSymbol", name, addr, nosave) end
function unregisterSymbol(name) return rec("unregisterSymbol", name) end
function reinitializeSymbolhandler() return rec("reinitializeSymbolhandler", true) end
function enumModules(pid)
  rec("enumModules", pid)
  return { { Name = "jogo.exe", Address = 0x140000000, Size = 0x10000, Is64Bit = true },
           { Name = "kernel32.dll", Address = 0x7FF000000000, Size = 0x200000 } }
end
function enumSectionsOfModule(mod)
  rec("enumSectionsOfModule", mod)
  return { { Name = ".text", Address = 0x140001000, Size = 0x8000 },
           { Name = ".data", Address = 0x140009000, Size = 0x1000 } }
end
function getProcesslist()
  rec("getProcesslist")
  return _STUB_PROCESSLIST or {}
end
function getProcessIDFromProcessName(name)
  rec("getProcessIDFromProcessName", name)
  if name == "jogo.exe" then return 4242 end
  return nil
end
function openProcess(id)
  rec("openProcess", id)
  if id == 0 or id == nil then _STUB_PID = nil else _STUB_PID = id end
  return _STUB_PID
end
function getThreadlist() return rec("getThreadlist", { 100, 200 }) end
function closeRemoteHandle(h, pid) return rec("closeRemoteHandle", h, pid) end
function duplicateHandle(h, a, b) return rec("duplicateHandle", h, a, b, 0x1F8) end

-- ------------------------------------------------------------ memoria (alvo)
-- Backing store simples: _STUB_MEM[addr] = byte, para read/write coerentes.
_STUB_MEM = {}
local function memRead(addr, n)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = _STUB_MEM[addr + i] or 0 end
  return out
end
local function memWrite(addr, bytes)
  for i = 1, #bytes do _STUB_MEM[addr + i - 1] = bytes[i] end
  return true
end
_G.memRead, _G.memWrite = memRead, memWrite

function readBytes(addr, count, asTable)
  rec("readBytes", addr, count, asTable)
  local t = memRead(addr, count)
  if asTable then return t end
  return string.char(table.unpack(t))
end
function readByte(addr) rec("readByte", addr); return memRead(addr, 1)[1] end
function readSmallInteger(addr)
  rec("readSmallInteger", addr)
  local b = memRead(addr, 2); return b[1] + b[2] * 256
end
function readInteger(addr)
  rec("readInteger", addr)
  local b = memRead(addr, 4)
  return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
end
function readQword(addr)
  rec("readQword", addr)
  local b = memRead(addr, 8)
  local v = 0
  for i = 8, 1, -1 do v = v * 256 + b[i] end
  return v
end
function readPointer(addr) return rec("readPointer", addr, readQword(addr)) end
function readFloat(addr) return rec("readFloat", addr, 1.5) end
function readDouble(addr) return rec("readDouble", addr, 3.25) end
function readString(addr, maxlen, wide)
  rec("readString", addr, maxlen, wide)
  return "texto-de-teste"
end
function writeBytes(addr, ...)
  local args = { ... }
  local bytes = (type(args[1]) == "table") and args[1] or args
  rec("writeBytes", addr, #bytes)
  return memWrite(addr, bytes)
end
function writeByte(addr, v) rec("writeByte", addr, v); return memWrite(addr, { v }) end
function writeSmallInteger(addr, v)
  rec("writeSmallInteger", addr, v); return memWrite(addr, { v % 256, math.floor(v / 256) % 256 })
end
function writeInteger(addr, v)
  rec("writeInteger", addr, v)
  return memWrite(addr, { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 })
end
function writeQword(addr, v) rec("writeQword", addr, v); return memWrite(addr, { 0, 0, 0, 0, 0, 0, 0, 0 }) end
function writePointer(addr, v) return rec("writePointer", addr, v, writeQword(addr, v)) end
function writeFloat(addr, v) rec("writeFloat", addr, v); return memWrite(addr, { 0, 0, 0, 0 }) end
function writeDouble(addr, v) rec("writeDouble", addr, v); return memWrite(addr, { 0, 0, 0, 0, 0, 0, 0, 0 }) end
function writeString(addr, s, wide) rec("writeString", addr, s, wide); return true end
function getMemoryProtection(addr) return rec("getMemoryProtection", addr, { r = true, w = true, x = false }) end
function setMemoryProtection(addr, size, prot) return rec("setMemoryProtection", addr, size, prot) end
function fullAccess(addr, size) return rec("fullAccess", addr, size) end
function allocateMemory(size, base, prot) rec("allocateMemory", size, base, prot); return 0x20000000 end
function deAlloc(addr, size) return rec("deAlloc", addr, size) end
function enumMemoryRegions() return rec("enumMemoryRegions", {}) end

-- ---------------------------------------------------------- auto assembler
local AAResult = {}
function autoAssembleCheck(text, enable, targetself)
  rec("autoAssembleCheck", text, enable, targetself)
  if text:find("SINTaxe_ruim") then return false, "error in line 1: bad syntax" end
  return true
end
function autoAssemble(text, targetself, disableInfo)
  rec("autoAssemble", text, targetself)
  if text:find("FALHA") then return false end
  local info = { scripts = { { text = text } } }
  if type(disableInfo) == "table" then disableInfo[1] = info end
  return true
end
function getInstructionSize(addr) return rec("getInstructionSize", addr, 5) end
function disassemble(addr) return rec("disassemble", addr, string.format("%X - 48 8B 05 ?? ?? ?? ?? - mov rax,[rip+?]", addr)) end
function splitDisassembledString(s) return rec("splitDisassembledString", s, string.format("%X", 0x140001000), "48 8B 05", "mov rax,[rip+?]") end
function compile(text, addr, self, kernel, nodebug) return rec("compile", text, addr, 5) end

-- ---------------------------------------------------------------- MemScan
local MemScanMT = {}
-- Como no CE real, propriedades desconhecidas resolvem pelo metatable; FoundList
-- e criada sob demanda (linha 2661 do celua.txt: createFoundList(memscan)).
MemScanMT.__index = function(t, k)
  if k == "FoundList" then
    if rawget(t, "_fl") == nil then rawset(t, "_fl", createFoundList(t)) end
    return rawget(t, "_fl")
  end
  return rawget(MemScanMT, k)
end
function MemScanMT:firstScan(...)
  rec("memscan.firstScan", ...)
  self.FoundCount = 3
  self.LastScanType = "stFirstScan"
  self.Result = 3
  self.Results = { 0x140001000, 0x140002000, 0x140003000 }
  return true
end
function MemScanMT:nextScan(...)
  rec("memscan.nextScan", ...)
  self.FoundCount = 2
  self.LastScanType = "stNextScan"
  return true
end
function MemScanMT:newScan() rec("memscan.newScan"); return true end
function MemScanMT:scan() rec("memscan.scan"); return true end
function MemScanMT:terminateScan(force) return rec("memscan.terminateScan", force) end
function MemScanMT:waitTillDone(timeout) return rec("memscan.waitTillDone", timeout, true) end
function MemScanMT:destroy() rec("memscan.destroy"); return true end

function createMemScan(progressbar)
  rec("createMemScan", progressbar)
  return setmetatable({ FoundCount = 0, ErrorString = "", Percentage = 0, VarType = "vtDword",
                        ScanOption = "soExactValue", LastScanType = "stNewScan" }, MemScanMT)
end
function getCurrentMemscan() return rec("getCurrentMemscan", nil) end

-- --------------------------------------------------------------- FoundList
function createFoundList(memscan)
  rec("createFoundList", memscan)
  local addrs = memscan and memscan.Results or {}
  local Address, Value = {}, {}
  for i, a in ipairs(addrs) do
    -- FoundList do CE e indexada a partir de 0 (celua.txt 2661-2677)
    Address[i - 1] = string.format("%X", a)
    Value[i - 1] = tostring(1000 + i)
  end
  local fl = { Count = #addrs, Address = Address, Value = Value, _ready = false }
  function fl:initialize() self._ready = true; rec("foundlist.initialize"); return true end
  function fl:deinitialize() self._ready = false; rec("foundlist.deinitialize"); return true end
  function fl:getCount() return self.Count end
  function fl:getAddress(i) return string.format("%X", addrs[i + 1] or 0) end
  function fl:getValue(i) return tostring(1234 + i) end
  function fl:destroy() rec("foundlist.destroy"); return true end
  return fl
end

-- ---------------------------------------------------------- memory records
function getAddressList()
  rec("getAddressList")
  local al = { Count = 0, _items = {} }
  function al:createMemoryRecord(...) rec("addresslist.createMemoryRecord", ...); return createMemoryRecord() end
  function al:getMemoryRecord(i) return self._items[i + 1] end
  return al
end
local memRecordN = 0
function createMemoryRecord()
  memRecordN = memRecordN + 1
  rec("createMemoryRecord")
  return { Description = "novo", Address = "0", Type = 4, Value = "0", IsFrozen = false,
           OffsetCount = 0, Offset = {}, ID = memRecordN,
           getAddress = function() return 0x140001000 end,
           delete = function() rec("memoryrecord.delete"); return true end }
end

-- --------------------------------------------------------------- threads
function inMainThread() return rec("inMainThread", true) end
function synchronize(fn, ...) rec("synchronize"); return fn(...) end
function checkSynchronize(timeout) return rec("checkSynchronize", timeout, true) end
function sleep(ms) rec("sleep", ms); return true end
function getCurrentThreadObject() return nil end
function createThread(fn, ...)
  rec("createThread")
  -- Nao executa a thread: o teste nao quer um servidor de verdade nem loops.
  local th = { Name = "", Finished = false, Terminated = false, Result = nil, Priority = "tpNormal" }
  function th:freeOnTerminate(v) self._fot = v; return v end
  function th:synchronize(...) return fn(...) end
  return th
end

-- ------------------------------------------------------------------ timer
function createTimer(owner, enabled)
  rec("createTimer", owner, enabled)
  local t = { Interval = 1000, Enabled = true, OnTimer = nil, _n = 0 }
  function t:destroy() rec("timer.destroy"); return true end
  function t:getInterval() return self.Interval end
  function t:setInterval(v) self.Interval = v end
  _STUB_TIMERS = _STUB_TIMERS or {}
  _STUB_TIMERS[#_STUB_TIMERS + 1] = t
  return t
end

-- -------------------------------------------------------------- sockets
local PipeMT = {}
PipeMT.__index = function(t, k) return rawget(PipeMT, k) end
function PipeMT:lock() end
function PipeMT:unlock() end
function PipeMT:readBytesMin(min, max) rec("pipe.readBytesMin", min, max); return "" end
function PipeMT:readBytes(n) rec("pipe.readBytes", n); return string.rep("\0", n) end
function PipeMT:writeBytes(t, n) rec("pipe.writeBytes", #t); return #t end
function PipeMT:writeString(s, z) rec("pipe.writeString", s, z); return #s end

function createServerSocket(port, localhostOnly)
  rec("createServerSocket", port, localhostOnly)
  local srv = setmetatable({ Connected = false, Timeout = 0, port = port,
                             localhostOnly = localhostOnly }, PipeMT)
  function srv:acceptConnection(split) rec("serversocket.acceptConnection", split); return nil end
  return srv
end
function createPipe(name, ...) rec("createPipe", name, ...); return setmetatable({ valid = true, handle = 0x44 }, PipeMT) end
function connectToTCPServer(host, port) rec("connectToTCPServer", host, port); return setmetatable({}, PipeMT) end
function connectToPipe(name, t) rec("connectToPipe", name, t); return setmetatable({}, PipeMT) end
function openLuaServer(name) rec("openLuaServer", name); return true end
function connectToCEServer(host, port) rec("connectToCEServer", host, port); return setmetatable({}, PipeMT) end

-- ------------------------------------------------------------------- debug
function debug_setBreakpoint(addr, size, trigger, method, fn)
  rec("debug_setBreakpoint", addr, size, trigger, method, fn and "fn" or nil)
  return true
end
function debug_removeBreakpoint(addr) return rec("debug_removeBreakpoint", addr, true) end
function debug_getContext(...) rec("debug_getContext", ...); return {} end
function debug_continueFromBreakpoint(m) return rec("debug_continueFromBreakpoint", m) end

-- --------------------------------------------------------------- interface
local forms = {
  { Name = "MainForm", Caption = "Cheat Engine 7.7", ClassName = "TMainForm", Visible = true },
  { Name = "MemoryView", Caption = "Memory Viewer", ClassName = "TMemoryView", Visible = false },
  { Name = "LuaConsole", Caption = "Lua Console", ClassName = "TLuaForm", Visible = true },
}
for _, f in ipairs(forms) do
  f.show = function(self) self.Visible = true; rec("form.show", self.Name) end
  f.hide = function(self) self.Visible = false; rec("form.hide", self.Name) end
  f.bringToFront = function(self) rec("form.bringToFront", self.Name) end
  f.setFocus = function(self) rec("form.setFocus", self.Name) end
  f.findComponent = function(self, n) rec("form.findComponent", self.Name, n); return nil end
end
forms[1].edtSearch = { Text = "", doClick = function() rec("component.doClick", "edtSearch") end }
function getFormCount() return rec("getFormCount", #forms) end
function getForm(i)
  rec("getForm", i)
  if type(i) == "number" then return forms[i + 1] end
  for _, f in ipairs(forms) do if f.Name == i then return f end end
  return nil
end

function createHotkey(fn, ...) rec("createHotkey", ...); return { destroy = function() rec("hotkey.destroy") end } end
function createHotkeyEx(down, up, ...) rec("createHotkeyEx", ...); return { destroy = function() end } end
function showMessage(t) rec("showMessage", t); return true end
function messageDialog(t, ty) rec("messageDialog", t, ty); return 1 end
-- [[ fim dos stubs ]]
